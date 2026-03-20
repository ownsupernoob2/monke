extends Node

## Banana Frenzy gamemode manager.
## Timer-based round: collecting bananas gives points (not hunger).
## Player with the most points when the timer expires wins the round.
## Hunger is disabled for this mode.

# ── Config ─────────────────────────────────────────────────────────────────────
const POINTS_PER_BANANA : int   = 10
const ROUND_DURATION    : float = 120.0   ## seconds per round

var total_rounds    : int = 3
var current_round   : int = 0

# ── State ─────────────────────────────────────────────────────────────────────
var _bf_points    : Dictionary = {}   # peer_id → points this round
var _scores       : Dictionary = {}   # peer_id → cumulative round points
var _round_timer  : float      = 0.0
var _round_active : bool       = false
var _all_peer_ids : Array[int] = []
var _alive_peers  : Array[int] = []   # peers not yet dead this round
var _in_overtime  : bool       = false  ## true while sudden-death extension is running

# ── Crown / HUD ────────────────────────────────────────────────────────────────
var _crown_instance  : Node3D    = null   ## CrownMarker scene instance
var _hud_instance    : CanvasLayer = null  ## BananaFrenzyHUD instance
var _hud_rows        : Node      = null   ## VBoxContainer "Rows" inside HUD
var _leader_peer     : int       = -1     ## current leader peer ID

# ── Spectator ─────────────────────────────────────────────────────────────────
var _spectating       : bool             = false
var _spectate_targets : Array[Player]    = []
var _spectate_index   : int              = 0
var _spectate_camera  : Camera3D         = null
var _local_player     : Player           = null

# ── Announcement ──────────────────────────────────────────────────────────────
var _announce_layer : CanvasLayer = null
var _announce_label : Label       = null


func _ready() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		total_rounds = gs.round_count
		if gs.lps_match_active:
			_scores = gs.lps_scores.duplicate()
			current_round = gs.lps_current_round

	if has_node("/root/GameLobby"):
		GameLobby.player_left.connect(_on_peer_left)
		GameLobby.server_closed.connect(_on_server_closed)

	await get_tree().process_frame
	_cache_local_player()
	# In BF mode bananas give points not hunger — disable hunger drain entirely.
	if _local_player:
		_local_player.set_hunger_enabled(false)
		if _local_player.hud:
			_local_player.hud.hunger_bar.visible = false
			_local_player.hud.hunger_label.visible = false
			_local_player.hud.starvation_label.visible = false
	_spawn_hud()
	_spawn_crown()
	_start_round()


func _process(delta: float) -> void:
	# ── Spectator camera follow (runs even after round ends) ─────────────
	if _spectating and _spectate_camera and _spectate_targets.size() > 0:
		_spectate_index = clampi(_spectate_index, 0, _spectate_targets.size() - 1)
		var target : Player = _spectate_targets[_spectate_index]
		if is_instance_valid(target) and not target.is_dead:
			var behind := target.global_position + target.global_transform.basis.z * 3.0 + Vector3.UP * 1.5
			_spectate_camera.global_position = _spectate_camera.global_position.lerp(behind, delta * 5.0)
			_spectate_camera.look_at(target.global_position + Vector3.UP * 0.8)
		else:
			_refresh_spectate_targets()
			_update_spectate_hud()

	# ── Crown follows leader ─────────────────────────────────────────────
	if _crown_instance and _leader_peer >= 0:
		var players_container : Node = get_parent().get_node_or_null("Players")
		if players_container:
			var leader_node : Node = players_container.get_node_or_null("Player_%d" % _leader_peer)
			if leader_node and is_instance_valid(leader_node):
				_crown_instance.global_position = (leader_node as Node3D).global_position

	if not _round_active:
		return

	# ── Round timer countdown (host drives end) ──────────────────────────
	_round_timer -= delta
	_update_hud_timer()
	if _round_timer <= 0.0 and GameLobby.is_host():
		_round_active = false
		_end_round_by_timer()


func _input(event: InputEvent) -> void:
	if not _spectating:
		return
	if event.is_action_pressed("spectate_next"):
		_cycle_spectate(1)
		if is_inside_tree():
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("spectate_prev"):
		_cycle_spectate(-1)
		if is_inside_tree():
			get_viewport().set_input_as_handled()


# ══════════════════════════════════════════════════════════════════════════════
#  ROUND LOGIC
# ══════════════════════════════════════════════════════════════════════════════

func _start_round() -> void:
	current_round += 1
	_round_timer  = ROUND_DURATION
	_bf_points    = {}
	_alive_peers.clear()
	_all_peer_ids.clear()

	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		push_error("BF: No 'Players' container found!")
		return

	for child : Node in players_container.get_children():
		if child is Player:
			var pid : int = child.get_multiplayer_authority()
			_alive_peers.append(pid)
			_all_peer_ids.append(pid)
			_bf_points[pid] = 0
			if not _scores.has(pid):
				_scores[pid] = 0
			child.is_dead = false
			if not child.player_died.is_connected(_on_player_died.bind(pid)):
				child.player_died.connect(_on_player_died.bind(pid))

	_in_overtime = false
	_stop_spectating()
	_connect_bananas()
	_update_leader_and_crown()
	_update_hud_scores()
	_update_hud_timer()
	_round_active = true


# ══════════════════════════════════════════════════════════════════════════════
#  BANANA CONNECTIONS
# ══════════════════════════════════════════════════════════════════════════════

func _connect_bananas() -> void:
	## Connect to all existing Banana nodes under the scene.
	_connect_bananas_recursive(get_parent())
	# Also catch bananas spawned later.
	get_parent().child_entered_tree.connect(_on_child_added)


func _connect_bananas_recursive(node: Node) -> void:
	for child : Node in node.get_children():
		if child is Banana:
			if not child.picked_up.is_connected(_on_banana_picked_up):
				child.picked_up.connect(_on_banana_picked_up)
		else:
			_connect_bananas_recursive(child)


func _on_child_added(node: Node) -> void:
	_connect_bananas_recursive(node)


func _on_banana_picked_up(picker: Node3D, _amount: float) -> void:
	if not _round_active or not GameLobby.is_host():
		return
	var pid : int = picker.get_multiplayer_authority()
	if not _bf_points.has(pid):
		_bf_points[pid] = 0
	_bf_points[pid] += POINTS_PER_BANANA

	# Broadcast to all clients.
	rpc("_rpc_update_scores", _bf_points)
	_rpc_update_scores(_bf_points)  # apply locally on host

	# Overtime: end immediately if the tie is now broken.
	if _in_overtime and _all_peer_ids.size() >= 2:
		var top_a : int = 0
		var top_b : int = 0
		for p : int in _all_peer_ids:
			var s : int = _bf_points.get(p, 0)
			if s > top_a:
				top_b = top_a; top_a = s
			elif s > top_b:
				top_b = s
		if top_a > top_b:
			_round_active = false
			_end_round_by_timer()


@rpc("authority", "unreliable", "call_remote")
func _rpc_update_scores(scores: Dictionary) -> void:
	for key in scores:
		_bf_points[key] = int(scores[key])
	_update_leader_and_crown()
	_update_hud_scores()


# ══════════════════════════════════════════════════════════════════════════════
#  PLAYER DEATH
# ══════════════════════════════════════════════════════════════════════════════

func _on_player_died(peer_id: int) -> void:
	if peer_id in _alive_peers:
		_alive_peers.erase(peer_id)
	if _local_player and peer_id == _local_player.get_multiplayer_authority():
		_start_spectating()
	elif _spectating:
		_refresh_spectate_targets()
		_update_spectate_hud()


func _on_peer_left(peer_id: int) -> void:
	if peer_id in _alive_peers:
		_alive_peers.erase(peer_id)
	# Remove them from the live scoreboards so they can't win.
	_all_peer_ids.erase(peer_id)
	_bf_points.erase(peer_id)
	_scores.erase(peer_id)
	if GameLobby.is_host() and _round_active:
		rpc("_rpc_update_scores", _bf_points)
		_rpc_update_scores(_bf_points)
	_refresh_spectate_targets()


func _on_server_closed() -> void:
	_round_active = false


# ══════════════════════════════════════════════════════════════════════════════
#  ROUND END
# ══════════════════════════════════════════════════════════════════════════════

## Host only — called when the timer reaches 0.
func _end_round_by_timer() -> void:
	# Build sorted ranking by bf_points.
	var ranked : Array[int] = []
	for pid : int in _all_peer_ids:
		ranked.append(pid)
	ranked.sort_custom(func(a: int, b: int) -> bool:
		return _bf_points.get(a, 0) > _bf_points.get(b, 0))

	# Tie-check: if top two are equal and this is the first expiry, go to overtime.
	if not _in_overtime and ranked.size() >= 2 \
			and _bf_points.get(ranked[0], 0) == _bf_points.get(ranked[1], 0):
		_in_overtime = true
		rpc("_rpc_start_overtime")
		_rpc_start_overtime()
		return

	_in_overtime = false
	_award_round_points(ranked)
	rpc("_rpc_round_over_bf", _scores)
	_rpc_round_over_bf(_scores)


@rpc("authority", "reliable", "call_remote")
func _rpc_start_overtime() -> void:
	_round_timer  = 30.0
	_round_active = true
	_show_announcement("TIE! Sudden death — next banana wins!")
	await get_tree().create_timer(2.5).timeout
	if is_inside_tree():
		_hide_announcement()


## Host-only: award cumulative round points based on this-round ranking.
func _award_round_points(ranked: Array[int]) -> void:
	var pts : Array[int] = [3, 2, 1]
	for i : int in mini(ranked.size(), pts.size()):
		var pid : int = ranked[i]
		if not _scores.has(pid):
			_scores[pid] = 0
		_scores[pid] += pts[i]


@rpc("authority", "reliable", "call_remote")
func _rpc_round_over_bf(final_scores: Dictionary) -> void:
	_round_active = false
	_scores = final_scores

	_stop_spectating()
	_freeze_local_player()

	if current_round >= total_rounds:
		if has_node("/root/GameSettings"):
			get_node("/root/GameSettings").lps_match_complete = true

	_save_match_state()
	var winner_id : int = _find_score_leader(_scores)
	await _play_winner_camera(winner_id)

	_show_announcement("Round over!")
	await get_tree().create_timer(1.8).timeout
	if is_inside_tree():
		_hide_announcement()
		_go_to_selection()


func _save_match_state() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.lps_scores = _scores.duplicate()
		var names_snapshot : Dictionary = {}
		if has_node("/root/GameLobby"):
			for pid : int in _scores.keys():
				names_snapshot[pid] = GameLobby.display_name(pid)
		gs.lps_player_names = names_snapshot
		gs.lps_current_round = current_round
		gs.lps_match_active = true


func _go_to_selection() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://multiplayer/SelectionScreen.tscn")


func _find_score_leader(scores: Dictionary) -> int:
	var best_id : int = -1
	var best_score : int = -999999
	for pid : int in scores.keys():
		var val : int = int(scores.get(pid, 0))
		if val > best_score:
			best_score = val
			best_id = pid
	return best_id


func _play_winner_camera(winner_id: int) -> void:
	await get_tree().create_timer(0.4).timeout
	if winner_id < 0:
		return
	var players_container : Node = get_parent().get_node_or_null("Players")
	if players_container == null:
		return
	var winner_node := players_container.get_node_or_null("Player_%d" % winner_id)
	if winner_node == null or not (winner_node is Player):
		return

	var winner_pos : Vector3 = (winner_node as Player).global_position
	var orbit_cam := Camera3D.new()
	orbit_cam.current = true
	get_parent().add_child(orbit_cam)

	var duration : float = 1.6
	var radius : float = 3.0
	var elapsed : float = 0.0
	while elapsed < duration and is_inside_tree():
		var t : float = elapsed / duration
		var angle : float = t * TAU
		orbit_cam.global_position = winner_pos + Vector3(cos(angle) * radius, 1.8, sin(angle) * radius)
		orbit_cam.look_at(winner_pos + Vector3(0.0, 1.0, 0.0), Vector3.UP)
		await get_tree().process_frame
		elapsed += get_process_delta_time()

	if is_instance_valid(orbit_cam):
		orbit_cam.queue_free()
	if _local_player and is_instance_valid(_local_player):
		_local_player.camera.make_current()


func _freeze_local_player() -> void:
	if _local_player and is_instance_valid(_local_player) and not _local_player.is_dead:
		if _local_player.has_node("HungerDeathTimer"):
			var t : Timer = _local_player.get_node("HungerDeathTimer")
			t.stop()
		elif _local_player.get("hunger_death_timer") != null:
			var t : Timer = _local_player.hunger_death_timer
			if t and not t.is_queued_for_deletion():
				t.stop()


# ══════════════════════════════════════════════════════════════════════════════
#  HUD
# ══════════════════════════════════════════════════════════════════════════════

func _spawn_hud() -> void:
	var hud_scene : PackedScene = load("res://multiplayer/BananaFrenzyHUD.tscn")
	if hud_scene == null:
		push_error("BF: Could not load BananaFrenzyHUD.tscn")
		return
	_hud_instance = hud_scene.instantiate() as CanvasLayer
	add_child(_hud_instance)
	_hud_rows = _hud_instance.get_node_or_null("Panel/VBox/Rows")


func _update_hud_scores() -> void:
	if _hud_rows == null:
		return
	for child : Node in _hud_rows.get_children():
		child.queue_free()

	# Sort by bf_points descending.
	var pids : Array = []
	for pid : int in _all_peer_ids:
		pids.append(pid)
	pids.sort_custom(func(a, b): return _bf_points.get(a, 0) > _bf_points.get(b, 0))

	var medals : Array[String] = ["🥇", "🥈", "🥉"]
	for i : int in pids.size():
		var pid   : int    = pids[i]
		var pts   : int    = _bf_points.get(pid, 0)
		var pname : String = GameLobby.display_name(pid)
		var medal : String = medals[i] if i < medals.size() else "  "
		var row   := Label.new()
		row.text = "%s %s — %d" % [medal, pname, pts]
		row.add_theme_font_size_override("font_size", 14)
		row.add_theme_color_override("font_color", Color.WHITE)
		_hud_rows.add_child(row)


func _update_hud_timer() -> void:
	## Optionally write the remaining seconds to a "Timer" label in the HUD if present.
	if _hud_instance == null:
		return
	var lbl : Label = _hud_instance.get_node_or_null("Panel/VBox/TimerLabel")
	if lbl:
		var total_secs : int = maxi(ceili(_round_timer), 0)
		var mins : int = floori(float(total_secs) / 60.0)
		var secs : int = total_secs % 60
		lbl.text = "⏱ %02d:%02d" % [mins, secs]


# ══════════════════════════════════════════════════════════════════════════════
#  CROWN
# ══════════════════════════════════════════════════════════════════════════════

func _spawn_crown() -> void:
	var crown_scene : PackedScene = load("res://maps/CrownMarker.tscn")
	if crown_scene == null:
		push_error("BF: Could not load CrownMarker.tscn")
		return
	_crown_instance = crown_scene.instantiate() as Node3D
	_crown_instance.visible = false
	get_parent().add_child(_crown_instance)


func _update_leader_and_crown() -> void:
	if _all_peer_ids.is_empty():
		return
	var best_pid  : int = _all_peer_ids[0]
	var best_pts  : int = _bf_points.get(best_pid, 0)
	for pid : int in _all_peer_ids:
		var pts : int = _bf_points.get(pid, 0)
		if pts > best_pts:
			best_pts = pts
			best_pid = pid
	_leader_peer = best_pid if best_pts > 0 else -1
	if _crown_instance:
		_crown_instance.visible = (_leader_peer >= 0)


# ══════════════════════════════════════════════════════════════════════════════
#  ANNOUNCEMENT UI  (lightweight overlay label)
# ══════════════════════════════════════════════════════════════════════════════

func _show_announcement(text: String) -> void:
	_ensure_announce_ui()
	_announce_label.text = text
	_announce_layer.visible = true


func _hide_announcement() -> void:
	if _announce_layer:
		_announce_layer.visible = false


func _ensure_announce_ui() -> void:
	if _announce_layer:
		return
	_announce_layer = CanvasLayer.new()
	_announce_layer.layer = 8
	add_child(_announce_layer)
	_announce_label = Label.new()
	_announce_label.anchors_preset = Control.PRESET_CENTER
	_announce_label.offset_left   = -320.0
	_announce_label.offset_right  = 320.0
	_announce_label.offset_top    = -40.0
	_announce_label.offset_bottom = 40.0
	_announce_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_announce_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_announce_label.add_theme_font_size_override("font_size", 36)
	_announce_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0))
	_announce_layer.add_child(_announce_label)


# ══════════════════════════════════════════════════════════════════════════════
#  SPECTATOR SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

func _start_spectating() -> void:
	if _spectating:
		return
	_spectating = true
	_refresh_spectate_targets()
	if not _spectate_camera:
		_spectate_camera = Camera3D.new()
		_spectate_camera.name = "SpectateCamera"
		get_parent().add_child(_spectate_camera)
	_spectate_index = 0
	_spectate_camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_update_spectate_hud()


func _stop_spectating() -> void:
	if not _spectating:
		return
	_spectating = false
	_spectate_targets.clear()
	if _spectate_camera:
		_spectate_camera.queue_free()
		_spectate_camera = null
	if _local_player and is_instance_valid(_local_player) and not _local_player.is_dead:
		_local_player.camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _local_player and _local_player.hud:
		_local_player.hud.hide_spectating()


func _cycle_spectate(direction: int) -> void:
	_refresh_spectate_targets()
	if _spectate_targets.is_empty():
		return
	_spectate_index = (_spectate_index + direction) % _spectate_targets.size()
	if _spectate_index < 0:
		_spectate_index = _spectate_targets.size() - 1
	_update_spectate_hud()


func _refresh_spectate_targets() -> void:
	_spectate_targets.clear()
	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		return
	for child : Node in players_container.get_children():
		if child is Player and not child.is_dead and not child.is_local:
			_spectate_targets.append(child as Player)
	if _spectate_targets.size() > 0:
		_spectate_index = clampi(_spectate_index, 0, _spectate_targets.size() - 1)


func _update_spectate_hud() -> void:
	if not _local_player or not _local_player.hud:
		return
	if _spectate_targets.is_empty():
		_local_player.hud.show_spectating("Waiting for others...")
		return
	_spectate_index = clampi(_spectate_index, 0, _spectate_targets.size() - 1)
	var target : Player = _spectate_targets[_spectate_index]
	_local_player.hud.show_spectating(GameLobby.display_name(target.get_multiplayer_authority()))


# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _cache_local_player() -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		return
	for child : Node in players_container.get_children():
		if child is Player and child.is_local:
			_local_player = child as Player
			return
