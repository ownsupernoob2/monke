extends Node

## Tag gamemode manager.
## One player is "IT" — get close enough to transfer the tag.
## Non-IT players score 1 point per second of survival.
## Hunger does NOT drain passively; only poo / pushes cost hunger.
## Bananas spawn at 40 % of the normal rate.
## Round ends after 2 minutes; highest survival score wins.

const TAG_RANGE      : float = 1.6   ## metres — proximity needed to tag
const ROUND_DURATION : float = 120.0
const TAG_COOLDOWN   : float = 2.0   ## seconds before new IT can transfer again

var total_rounds  : int = 3
var current_round : int = 0

# ── State ──────────────────────────────────────────────────────────────────────
var _it_peer      : int   = -1
var _scores       : Dictionary = {}   # peer_id → survival seconds this round
var _total_scores : Dictionary = {}   # peer_id → cumulative match points
var _all_peer_ids : Array[int] = []
var _alive_peers  : Array[int] = []
var _round_timer  : float = 0.0
var _round_active : bool  = false
var _score_tick   : float = 0.0
var _tag_cooldown : float = 0.0

# ── IT Indicator ───────────────────────────────────────────────────────────────
var _it_label : Label3D = null

# ── HUD ────────────────────────────────────────────────────────────────────────
var _hud_instance   : CanvasLayer = null
var _announce_layer : CanvasLayer = null
var _announce_label : Label       = null

# ── Spectator ──────────────────────────────────────────────────────────────────
var _spectating       : bool           = false
var _spectate_targets : Array[Player]  = []
var _spectate_index   : int            = 0
var _spectate_camera  : Camera3D       = null
var _local_player     : Player         = null


func _ready() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		total_rounds = gs.round_count
		if gs.lps_match_active:
			_total_scores = gs.lps_scores.duplicate()
			current_round = gs.lps_current_round

	if has_node("/root/GameLobby"):
		GameLobby.player_left.connect(_on_peer_left)
		GameLobby.server_closed.connect(_on_server_closed)

	await get_tree().process_frame
	_cache_local_player()
	# Disable passive hunger drain — abilities still cost hunger.
	if _local_player:
		_local_player.set_hunger_passive_drain(false)
	_reduce_banana_count()
	_spawn_hud()
	_start_round()


func _process(delta: float) -> void:
	_update_it_label()

	# Spectator camera follow.
	if _spectating and _spectate_camera and _spectate_targets.size() > 0:
		_spectate_index = clampi(_spectate_index, 0, _spectate_targets.size() - 1)
		var tgt : Player = _spectate_targets[_spectate_index]
		if is_instance_valid(tgt) and not tgt.is_dead:
			var behind := tgt.global_position + tgt.global_transform.basis.z * 3.0 + Vector3.UP * 1.5
			_spectate_camera.global_position = _spectate_camera.global_position.lerp(behind, delta * 5.0)
			_spectate_camera.look_at(tgt.global_position + Vector3.UP * 0.8)
		else:
			_refresh_spectate_targets()

	if not _round_active:
		return

	_tag_cooldown = maxf(_tag_cooldown - delta, 0.0)

	# Score tick: non-IT alive players gain 1 point per second.
	_score_tick += delta
	if _score_tick >= 1.0:
		_score_tick -= 1.0
		if GameLobby.is_host():
			for pid : int in _alive_peers:
				if pid != _it_peer:
					_scores[pid] = _scores.get(pid, 0) + 1
			rpc("_rpc_sync_scores", _scores)
			_rpc_sync_scores(_scores)

	# Proximity tag check — host authoritative.
	if GameLobby.is_host() and _it_peer >= 0 and _tag_cooldown <= 0.0:
		_check_tag_proximity()

	# Round timer.
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
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("spectate_prev"):
		_cycle_spectate(-1)
		get_viewport().set_input_as_handled()


# ══════════════════════════════════════════════════════════════════════════════
#  ROUND LOGIC
# ══════════════════════════════════════════════════════════════════════════════

func _start_round() -> void:
	current_round += 1
	_round_timer  = ROUND_DURATION
	_scores       = {}
	_alive_peers.clear()
	_all_peer_ids.clear()
	_tag_cooldown = 0.0
	_score_tick   = 0.0

	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		push_error("Tag: No 'Players' container found!")
		return

	for child : Node in players_container.get_children():
		if child is Player:
			var pid : int = child.get_multiplayer_authority()
			_alive_peers.append(pid)
			_all_peer_ids.append(pid)
			_scores[pid] = 0
			if not _total_scores.has(pid):
				_total_scores[pid] = 0
			child.is_dead = false
			if not child.player_died.is_connected(_on_player_died.bind(pid)):
				child.player_died.connect(_on_player_died.bind(pid))

	# Host picks an IT player at random.
	if GameLobby.is_host() and _all_peer_ids.size() > 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var first_it : int = _all_peer_ids[rng.randi() % _all_peer_ids.size()]
		rpc("_rpc_set_it", first_it)
		_rpc_set_it(first_it)

	_stop_spectating()
	_show_announcement("Round %d — TAG!" % current_round)
	await get_tree().create_timer(2.5).timeout
	if is_inside_tree():
		_hide_announcement()
		_round_active = true


# ══════════════════════════════════════════════════════════════════════════════
#  TAG TRANSFER
# ══════════════════════════════════════════════════════════════════════════════

func _check_tag_proximity() -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		return
	var it_node : Node = players_container.get_node_or_null("Player_%d" % _it_peer)
	if not it_node or not is_instance_valid(it_node):
		return
	var it_pos : Vector3 = (it_node as Node3D).global_position
	for child : Node in players_container.get_children():
		if not (child is Player):
			continue
		var pid : int = child.get_multiplayer_authority()
		if pid == _it_peer or pid not in _alive_peers:
			continue
		if (child as Node3D).global_position.distance_to(it_pos) <= TAG_RANGE:
			rpc("_rpc_set_it", pid)
			_rpc_set_it(pid)
			return


@rpc("authority", "reliable", "call_local")
func _rpc_set_it(peer_id: int) -> void:
	_it_peer      = peer_id
	_tag_cooldown = TAG_COOLDOWN
	var local_id  : int = multiplayer.get_unique_id()
	if peer_id == local_id:
		_show_announcement("You are IT! 🏃")
	elif has_node("/root/GameLobby"):
		_show_announcement("%s is IT!" % GameLobby.display_name(peer_id))
	else:
		_show_announcement("Player %d is IT!" % peer_id)
	get_tree().create_timer(1.8).timeout.connect(_hide_announcement, CONNECT_ONE_SHOT)
	_update_hud_scores()


@rpc("authority", "reliable", "call_local")
func _rpc_sync_scores(scores: Dictionary) -> void:
	for key in scores:
		_scores[key] = int(scores[key])
	_update_hud_scores()


# ══════════════════════════════════════════════════════════════════════════════
#  PLAYER DEATH / LEAVE
# ══════════════════════════════════════════════════════════════════════════════

func _on_player_died(peer_id: int) -> void:
	_alive_peers.erase(peer_id)
	# If IT died, volunteer the first alive player.
	if peer_id == _it_peer and _alive_peers.size() > 0 and GameLobby.is_host():
		var new_it : int = _alive_peers[0]
		rpc("_rpc_set_it", new_it)
		_rpc_set_it(new_it)
	if _local_player and peer_id == _local_player.get_multiplayer_authority():
		_start_spectating()
	elif _spectating:
		_refresh_spectate_targets()


func _on_peer_left(peer_id: int) -> void:
	_alive_peers.erase(peer_id)
	_all_peer_ids.erase(peer_id)
	_scores.erase(peer_id)
	_total_scores.erase(peer_id)
	if peer_id == _it_peer and _alive_peers.size() > 0 and GameLobby.is_host():
		var new_it : int = _alive_peers[0]
		rpc("_rpc_set_it", new_it)
		_rpc_set_it(new_it)
	_refresh_spectate_targets()


func _on_server_closed() -> void:
	_round_active = false


# ══════════════════════════════════════════════════════════════════════════════
#  ROUND END
# ══════════════════════════════════════════════════════════════════════════════

func _end_round_by_timer() -> void:
	var ranked : Array[int] = _all_peer_ids.duplicate()
	ranked.sort_custom(func(a: int, b: int) -> bool:
		return _scores.get(a, 0) > _scores.get(b, 0))
	_award_round_points(ranked)
	rpc("_rpc_round_over_tag", _total_scores)
	_rpc_round_over_tag(_total_scores)


func _award_round_points(ranked: Array[int]) -> void:
	var pts : Array[int] = [3, 2, 1]
	for i : int in mini(ranked.size(), pts.size()):
		var pid : int = ranked[i]
		if not _total_scores.has(pid):
			_total_scores[pid] = 0
		_total_scores[pid] += pts[i]


@rpc("authority", "reliable", "call_local")
func _rpc_round_over_tag(final_scores: Dictionary) -> void:
	_round_active = false
	_total_scores = final_scores

	_stop_spectating()
	_freeze_local_player()

	if current_round >= total_rounds:
		if has_node("/root/GameSettings"):
			get_node("/root/GameSettings").lps_match_complete = true

	_save_match_state()
	_show_announcement("Round over!")
	await get_tree().create_timer(1.8).timeout
	if is_inside_tree():
		_hide_announcement()
		_go_to_selection()


func _save_match_state() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.lps_scores        = _total_scores.duplicate()
		gs.lps_current_round = current_round
		gs.lps_match_active  = true


func _go_to_selection() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://multiplayer/SelectionScreen.tscn")


func _freeze_local_player() -> void:
	if _local_player and is_instance_valid(_local_player) and not _local_player.is_dead:
		_local_player.set_hunger_passive_drain(true)


# ══════════════════════════════════════════════════════════════════════════════
#  IT INDICATOR  (floating red label above the IT player)
# ══════════════════════════════════════════════════════════════════════════════

func _update_it_label() -> void:
	if _it_peer < 0:
		if _it_label:
			_it_label.visible = false
		return
	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		return
	var it_node : Node = players_container.get_node_or_null("Player_%d" % _it_peer)
	if not it_node or not is_instance_valid(it_node):
		if _it_label:
			_it_label.visible = false
		return
	if not _it_label:
		_it_label = Label3D.new()
		_it_label.name     = "ITLabel"
		_it_label.text     = "⚡ IT!"
		_it_label.font_size = 72
		_it_label.outline_size = 10
		_it_label.modulate = Color(1.0, 0.2, 0.2)
		_it_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_it_label.no_depth_test = true
		_it_label.render_priority = 2
		get_parent().add_child(_it_label)
	_it_label.visible         = true
	_it_label.global_position = (it_node as Node3D).global_position + Vector3(0.0, 2.6, 0.0)


# ══════════════════════════════════════════════════════════════════════════════
#  BANANA COUNT REDUCTION
# ══════════════════════════════════════════════════════════════════════════════

func _reduce_banana_count() -> void:
	_reduce_recursive(get_parent())


func _reduce_recursive(node: Node) -> void:
	for child : Node in node.get_children():
		if child is BananaSpawner:
			child.max_bananas = maxi(ceili(child.max_bananas * 0.4), 3)
			var container : Node = child.get_node_or_null("Bananas")
			if container:
				var existing : Array = container.get_children()
				for i : int in range(child.max_bananas, existing.size()):
					existing[i].queue_free()
		else:
			_reduce_recursive(child)


# ══════════════════════════════════════════════════════════════════════════════
#  HUD
# ══════════════════════════════════════════════════════════════════════════════

func _spawn_hud() -> void:
	_hud_instance = CanvasLayer.new()
	_hud_instance.layer = 5
	add_child(_hud_instance)

	var panel := PanelContainer.new()
	panel.anchors_preset = Control.PRESET_TOP_RIGHT
	panel.offset_left   = -240.0
	panel.offset_right  = 0.0
	panel.offset_top    = 8.0
	panel.offset_bottom = 200.0
	_hud_instance.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	panel.add_child(vbox)

	var timer_lbl := Label.new()
	timer_lbl.name = "TimerLabel"
	timer_lbl.add_theme_font_size_override("font_size", 16)
	timer_lbl.add_theme_color_override("font_color", Color.YELLOW)
	vbox.add_child(timer_lbl)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	vbox.add_child(rows)


func _update_hud_scores() -> void:
	if _hud_instance == null:
		return
	var rows : Node = _hud_instance.get_node_or_null("PanelContainer/VBox/Rows")
	if not rows:
		return
	for c : Node in rows.get_children():
		c.queue_free()

	var pids : Array = _all_peer_ids.duplicate()
	pids.sort_custom(func(a, b): return _scores.get(a, 0) > _scores.get(b, 0))
	for pid : int in pids:
		var pts   : int    = _scores.get(pid, 0)
		var pname : String = GameLobby.display_name(pid) if has_node("/root/GameLobby") else "P%d" % pid
		var it_mark : String = " ⚡" if pid == _it_peer else ""
		var row := Label.new()
		row.text = "%s%s — %ds" % [pname, it_mark, pts]
		row.add_theme_font_size_override("font_size", 13)
		row.add_theme_color_override("font_color",
			Color(1.0, 0.3, 0.3) if pid == _it_peer else Color.WHITE)
		rows.add_child(row)


func _update_hud_timer() -> void:
	if _hud_instance == null:
		return
	var lbl : Label = _hud_instance.get_node_or_null("PanelContainer/VBox/TimerLabel")
	if lbl:
		lbl.text = "⏱ %d s" % maxi(ceili(_round_timer), 0)


# ══════════════════════════════════════════════════════════════════════════════
#  ANNOUNCEMENT UI
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
	_announce_label.anchors_preset    = Control.PRESET_CENTER
	_announce_label.offset_left       = -320.0
	_announce_label.offset_right      = 320.0
	_announce_label.offset_top        = -40.0
	_announce_label.offset_bottom     =  40.0
	_announce_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_announce_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_announce_label.add_theme_font_size_override("font_size", 36)
	_announce_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
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
	if _local_player and _local_player.hud:
		_local_player.hud.show_spectating("Waiting...")


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


func _refresh_spectate_targets() -> void:
	_spectate_targets.clear()
	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		return
	for child : Node in players_container.get_children():
		if child is Player and not child.is_dead and not child.is_local:
			_spectate_targets.append(child as Player)


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
