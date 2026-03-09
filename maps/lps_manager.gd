extends Node

## Last Person Standing gamemode manager.
## Features: rounds, time limit, sudden death (rising lava plane),
## spectator camera for dead players, podium between rounds, alive-count HUD.

# ── Config ─────────────────────────────────────────────────────────────────────
var total_rounds       : int   = 3
var current_round      : int   = 0
var round_time_limit   : float = 120.0   ## seconds per round before sudden death
var _round_timer       : float = 0.0
var _deathmatch_active : bool  = false

# ── Lava plane (sudden death) ─────────────────────────────────────────────────────
var _kill_y           : float         = -999.0  # current lava height (host)
var _lava_rise_speed  : float         = 0.0     # m/s, accelerates after start
var _lava_plane       : MeshInstance3D = null   # visual on every peer
const _LAVA_START_Y   : float         = -40.0   # well below all maps
const _LAVA_RISE_ACCEL : float        = 0.08    # m/s² acceleration
const _LAVA_RISE_MAX  : float         = 5.0     # terminal velocity m/s
const _LAVA_KILL_ABOVE : float        = 1.8     # kill when player Y < lava_y + this

# ── State ─────────────────────────────────────────────────────────────────────
var _alive_peers   : Array[int] = []     # peer IDs still alive this round
var _scores        : Dictionary = {}     # peer_id → cumulative points
var _round_active  : bool = false
var _all_peer_ids  : Array[int] = []     # every peer that started the match
var _death_order   : Array[int] = []     # host-only: peer IDs in order of death

# ── Spectator ─────────────────────────────────────────────────────────────────
var _spectating        : bool     = false
var _spectate_targets  : Array[Player] = []   # alive players to cycle through
var _spectate_index    : int      = 0
var _spectate_camera   : Camera3D = null
var _local_player      : Player   = null      # cached ref to local Player node

# ── Podium ────────────────────────────────────────────────────────────────────
var _podium_layer      : CanvasLayer  = null
var _podium_label      : Label        = null
var _scores_container  : HBoxContainer = null


func _ready() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		total_rounds = gs.round_count
		# Resume a multi-round match if one is active.
		if gs.lps_match_active:
			_scores = gs.lps_scores.duplicate()
			current_round = gs.lps_current_round

	# Listen for players leaving mid-game.
	if has_node("/root/GameLobby"):
		GameLobby.player_left.connect(_on_peer_left)
		GameLobby.server_closed.connect(_on_server_closed)

	# Wait one frame so all Player nodes are spawned by main.gd.
	await get_tree().process_frame
	_cache_local_player()
	_start_round()


func _process(delta: float) -> void:
	if not _round_active:
		return

	# ── Round timer ──────────────────────────────────────────────────────
	if not _deathmatch_active:
		_round_timer -= delta
		if _round_timer <= 0.0 and GameLobby.is_host():
			rpc("_rpc_start_deathmatch")
			_rpc_start_deathmatch()
		# Update HUD timer for local player.
		_update_local_hud_timer()

	# ── Spectator camera follow ──────────────────────────────────────────
	if _spectating and _spectate_camera and _spectate_targets.size() > 0:
		_spectate_index = clampi(_spectate_index, 0, _spectate_targets.size() - 1)
		var target : Player = _spectate_targets[_spectate_index]
		if is_instance_valid(target) and not target.is_dead:
			var behind := target.global_position + target.global_transform.basis.z * 3.0 + Vector3.UP * 1.5
			_spectate_camera.global_position = _spectate_camera.global_position.lerp(behind, delta * 5.0)
			_spectate_camera.look_at(target.global_position + Vector3.UP * 0.8)
		else:
			# Current target died or was freed — refresh immediately.
			_refresh_spectate_targets()
			_update_spectate_hud()

	# ── Deathmatch: rising lava ───────────────────────────────────
	if _deathmatch_active:
		# Raise the lava.
		if GameLobby.is_host():
			_lava_rise_speed = minf(_lava_rise_speed + _LAVA_RISE_ACCEL * delta, _LAVA_RISE_MAX)
			_kill_y += _lava_rise_speed * delta
			# Broadcast new height to all clients (and update locally via call_local).
			rpc("_rpc_sync_lava", _kill_y)
		# Host kills players below the lava.
		if GameLobby.is_host():
			var players_container : Node = get_parent().get_node_or_null("Players")
			if players_container:
				for child : Node in players_container.get_children():
					if child is Player and not child.is_dead:
						if child.global_position.y < _kill_y + _LAVA_KILL_ABOVE:
							var pid : int = child.get_multiplayer_authority()
							rpc("_rpc_force_kill", pid)
							_rpc_force_kill(pid)


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
	_round_active = true
	_deathmatch_active = false
	_round_timer = round_time_limit
	# Clean up lava from the previous round.
	_destroy_lava_plane()
	_kill_y          = -999.0
	_lava_rise_speed = 0.0
	_alive_peers.clear()
	_all_peer_ids.clear()
	_death_order.clear()

	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		push_error("LPS: No 'Players' container found!")
		return

	for child : Node in players_container.get_children():
		if child is Player:
			var pid : int = child.get_multiplayer_authority()
			_alive_peers.append(pid)
			_all_peer_ids.append(pid)
			if not _scores.has(pid):
				_scores[pid] = 0
			# Reset the player for the new round.
			child.is_dead = false
			if child.is_local:
				child.hunger = child.max_hunger
			if not child.player_died.is_connected(_on_player_died.bind(pid)):
				child.player_died.connect(_on_player_died.bind(pid))

	# Stop spectating from previous round.
	_stop_spectating()
	# Disable crocs at round start — re-enabled when overtime begins.
	_hide_crocs()

	# Update HUD.
	_update_local_hud_round()
	_update_local_hud_alive()

	# Flash round text.
	_show_round_banner("Round %d" % current_round)
	await get_tree().create_timer(2.5).timeout
	if is_inside_tree():
		_hide_round_banner()


func _on_player_died(peer_id : int) -> void:
	if not _round_active:
		return
	if peer_id in _alive_peers:
		_alive_peers.erase(peer_id)
	# Host tracks death order for placement scoring.
	if GameLobby.is_host() and peer_id not in _death_order:
		_death_order.append(peer_id)
	_update_local_hud_alive()

	# If the local player just died, enter spectator mode.
	if _local_player and peer_id == _local_player.get_multiplayer_authority():
		_start_spectating()
	elif _spectating:
		# Someone we might be watching died — refresh targets and auto-switch.
		_refresh_spectate_targets()
		_update_spectate_hud()

	# Check for round end — only the host decides.
	if GameLobby.is_host() and _alive_peers.size() <= 1:
		var winner_id : int = _alive_peers[0] if _alive_peers.size() == 1 else -1
		_award_round_points(winner_id)
		rpc("_rpc_round_over", winner_id, _scores)
		_rpc_round_over(winner_id, _scores)


func _on_peer_left(peer_id: int) -> void:
	# Treat as death for the round.
	if peer_id in _alive_peers:
		_alive_peers.erase(peer_id)
		_update_local_hud_alive()
	# Host tracks death order.
	if GameLobby.is_host() and peer_id not in _death_order:
		_death_order.append(peer_id)
	# Refresh spectate targets.
	_refresh_spectate_targets()
	# Check round end.
	if _round_active and GameLobby.is_host() and _alive_peers.size() <= 1:
		var winner_id : int = _alive_peers[0] if _alive_peers.size() == 1 else -1
		_award_round_points(winner_id)
		rpc("_rpc_round_over", winner_id, _scores)
		_rpc_round_over(winner_id, _scores)


func _on_server_closed() -> void:
	# Host left — lobby.gd handles the scene change via chat.gd.
	_round_active = false


# ══════════════════════════════════════════════════════════════════════════════
#  SUDDEN DEATH / DEATHMATCH
# ══════════════════════════════════════════════════════════════════════════════

@rpc("authority", "reliable", "call_remote")
func _rpc_start_deathmatch() -> void:
	_deathmatch_active = true
	_kill_y            = _LAVA_START_Y
	_lava_rise_speed   = 0.5   # starts slow, accelerates
	# Update HUD.
	if _local_player and _local_player.hud:
		_local_player.hud.show_deathmatch_warning()
	# Reduce banana spawning.
	_reduce_bananas()
	# Spawn the lava visual on every peer.
	_spawn_lava_plane()
	# Overtime: unleash the crocodiles!
	_enable_crocs()


@rpc("authority", "unreliable", "call_local")
func _rpc_sync_lava(y_pos: float) -> void:
	_kill_y = y_pos
	if _lava_plane and is_instance_valid(_lava_plane):
		_lava_plane.global_position.y = y_pos


func _spawn_lava_plane() -> void:
	if _lava_plane:
		return
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(400.0, 400.0)
	var mat  := StandardMaterial3D.new()
	mat.albedo_color         = Color(1.0, 0.30, 0.0, 0.90)
	mat.emission_enabled     = true
	mat.emission             = Color(1.0, 0.20, 0.0)
	mat.emission_energy_multiplier = 2.5
	mat.transparency         = BaseMaterial3D.TRANSPARENCY_ALPHA
	_lava_plane = MeshInstance3D.new()
	_lava_plane.name = "LavaPlane"
	_lava_plane.mesh = mesh
	_lava_plane.set_surface_override_material(0, mat)
	_lava_plane.global_position = Vector3(0.0, _LAVA_START_Y, 0.0)
	get_parent().add_child(_lava_plane)


func _destroy_lava_plane() -> void:
	if _lava_plane and is_instance_valid(_lava_plane):
		_lava_plane.queue_free()
	_lava_plane = null


func _reduce_bananas() -> void:
	for child : Node in get_parent().get_children():
		if child is BananaSpawner:
			child.max_bananas = maxi(child.max_bananas / 3, 2)


@rpc("authority", "reliable", "call_remote")
func _rpc_force_kill(peer_id: int) -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		return
	var node : Node = players_container.get_node_or_null("Player_%d" % peer_id)
	if node and node is Player and not node.is_dead:
		node.die()


# ══════════════════════════════════════════════════════════════════════════════
#  ROUND OVER
# ══════════════════════════════════════════════════════════════════════════════

@rpc("authority", "reliable", "call_remote")
func _rpc_round_over(winner_id : int, updated_scores : Dictionary) -> void:
	_round_active = false
	_scores = updated_scores

	_stop_spectating()
	_freeze_local_player()

	# Mark match complete when all rounds are done.
	if current_round >= total_rounds:
		if has_node("/root/GameSettings"):
			get_node("/root/GameSettings").lps_match_complete = true

	# Save scores/round so the selection-screen leaderboard can read them.
	_save_match_state()

	# Brief pause so the final kill registers visually, then hand off to selection screen.
	await get_tree().create_timer(1.0).timeout
	if is_inside_tree():
		_go_to_selection()


## Stop the local player's hunger timer so they can’t die during the scene transition.
func _freeze_local_player() -> void:
	if _local_player and is_instance_valid(_local_player) and not _local_player.is_dead:
		if _local_player.hunger_death_timer and \
				not _local_player.hunger_death_timer.is_queued_for_deletion():
			_local_player.hunger_death_timer.stop()


## Host-only: compute placement points for this round.
func _award_round_points(winner_id : int) -> void:
	# Build placements: winner is 1st, then reverse death order gives 2nd, 3rd, …
	var placements : Array[int] = []
	if winner_id >= 0:
		placements.append(winner_id)
	# _death_order = [first_to_die, …, last_to_die]
	# Reverse it so the last to die (before the winner) = 2nd place.
	for i : int in range(_death_order.size() - 1, -1, -1):
		placements.append(_death_order[i])

	var points := [3, 2, 1]
	for i : int in placements.size():
		var pid : int = placements[i]
		if not _scores.has(pid):
			_scores[pid] = 0
		if i < points.size():
			_scores[pid] += points[i]


## Persist scores & round number in GameSettings so they survive scene changes.
func _save_match_state() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.lps_scores = _scores.duplicate()
		gs.lps_current_round = current_round
		gs.lps_match_active = true


## Return to selection screen between rounds.
func _go_to_selection() -> void:
	_hide_podium()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://multiplayer/SelectionScreen.tscn")


# ══════════════════════════════════════════════════════════════════════════════
#  PODIUM
# ══════════════════════════════════════════════════════════════════════════════

func _show_podium(is_final: bool, round_winner_id: int) -> void:
	_ensure_podium_ui()

	# Build sorted leaderboard.
	var sorted_peers : Array[int] = []
	for pid : int in _scores:
		sorted_peers.append(pid)
	sorted_peers.sort_custom(func(a: int, b: int) -> bool: return _scores[a] > _scores[b])

	if is_final:
		var best_name := _peer_name(sorted_peers[0]) if sorted_peers.size() > 0 else "Nobody"
		_podium_label.text = "%s WINS THE MATCH!" % best_name
	else:
		var winner_name := _peer_name(round_winner_id) if round_winner_id >= 0 else "Draw"
		_podium_label.text = "%s wins Round %d!" % [winner_name, current_round]

	# Build score cards – one per player, sorted by rank.
	_scores_container.get_children().map(func(c: Node) -> void: c.queue_free())
	var medal_colors : Array[Color] = [
		Color(1.00, 0.84, 0.00),  # gold
		Color(0.75, 0.75, 0.75),  # silver
		Color(0.80, 0.50, 0.20),  # bronze
	]
	var rank_labels : Array[String] = ["1ST", "2ND", "3RD"]
	for i : int in sorted_peers.size():
		var pid   : int    = sorted_peers[i]
		var pname : String = _peer_name(pid)
		var pts   : int    = _scores[pid]
		var accent : Color = medal_colors[i] if i < medal_colors.size() else Color.WHITE

		# Card container.
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(110.0, 0.0)
		var sb := StyleBoxFlat.new()
		sb.bg_color       = accent.darkened(0.55)
		sb.border_color   = accent
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		card.add_theme_stylebox_override("panel", sb)
		_scores_container.add_child(card)

		var vbox := VBoxContainer.new()
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		vbox.add_theme_constant_override("separation", 4)
		card.add_child(vbox)

		# Rank badge.
		var rank_lbl := Label.new()
		rank_lbl.text = rank_labels[i] if i < rank_labels.size() else "%dth" % (i + 1)
		rank_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rank_lbl.add_theme_font_size_override("font_size", 18)
		rank_lbl.add_theme_color_override("font_color", accent)
		vbox.add_child(rank_lbl)

		# Player name.
		var name_lbl := Label.new()
		name_lbl.text = pname
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.add_theme_font_size_override("font_size", 14)
		name_lbl.add_theme_color_override("font_color", Color.WHITE)
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(name_lbl)

		# Score.
		var pts_lbl := Label.new()
		pts_lbl.text = "%d pts" % pts
		pts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pts_lbl.add_theme_font_size_override("font_size", 16)
		pts_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
		vbox.add_child(pts_lbl)

	_podium_layer.visible = true

	# Camera + celebration.
	if round_winner_id >= 0:
		var players_container : Node = get_parent().get_node_or_null("Players")
		if players_container:
			var winner_node : Node = players_container.get_node_or_null("Player_%d" % round_winner_id)
			if winner_node and winner_node is Player:
				if is_final:
					_celebrate_winner(winner_node as Player)
				else:
					_animate_podium_camera(winner_node as Player)


## Final-match celebration: spotlight, confetti, cinematic camera crane.
func _celebrate_winner(winner: Player) -> void:
	# ─ Animated spotlight from above ─
	var spot := SpotLight3D.new()
	spot.name   = "CelebSpot"
	spot.light_color  = Color(1.0, 0.92, 0.65)   # warm cream white
	spot.light_energy = 0.0
	spot.spot_angle   = 22.0
	spot.spot_range   = 28.0
	spot.shadow_enabled = false
	spot.global_position = winner.global_position + Vector3(0.0, 18.0, 0.0)
	spot.look_at(winner.global_position + Vector3.UP * 0.8)
	get_parent().add_child(spot)

	# Fade spotlight in.
	var spot_tw := create_tween()
	spot_tw.tween_property(spot, "light_energy", 5.0, 1.2).set_trans(Tween.TRANS_SINE)

	# Slowly lower the spotlight toward the winner.
	var spot_lower := create_tween()
	spot_lower.tween_property(spot, "global_position",
		winner.global_position + Vector3(0.0, 9.0, 0.0), 3.5).set_trans(Tween.TRANS_CUBIC)

	# ─ Cinematic camera: start high and crane down ─
	if not _spectate_camera:
		_spectate_camera = Camera3D.new()
		_spectate_camera.name = "SpectateCamera"
		get_parent().add_child(_spectate_camera)
	_spectate_camera.current = true
	var start_pos := winner.global_position + Vector3(0.0, 14.0, 0.0)
	var end_pos   := winner.global_position + Vector3(3.5, 3.0, 5.5)
	_spectate_camera.global_position = start_pos
	_spectate_camera.look_at(winner.global_position + Vector3.UP * 0.8)
	var cam_tw := create_tween()
	cam_tw.set_ease(Tween.EASE_IN_OUT)
	cam_tw.tween_method(
		func(t: float) -> void:
			if is_instance_valid(_spectate_camera) and is_instance_valid(winner):
				_spectate_camera.global_position = start_pos.lerp(end_pos, t)
				_spectate_camera.look_at(winner.global_position + Vector3.UP * 0.8),
		0.0, 1.0, 4.0)

	# ─ Confetti (2D canvas) ─
	var layer := CanvasLayer.new()
	layer.name  = "ConfettiLayer"
	layer.layer = 8
	get_parent().add_child(layer)

	var vp_size : Vector2 = get_viewport().get_visible_rect().size
	var origins : Array[Vector2] = [
		Vector2(vp_size.x * 0.5, -20.0),
		Vector2(80.0,           vp_size.y * 0.35),
		Vector2(vp_size.x - 80.0, vp_size.y * 0.35),
	]
	var spreads : Array[float] = [180.0, 70.0, 70.0]

	for k : int in origins.size():
		var p := CPUParticles2D.new()
		p.emitting               = true
		p.amount                 = 60
		p.lifetime               = 3.2
		p.explosiveness          = 0.55
		p.spread                 = spreads[k]
		p.gravity                = Vector2(0.0, 280.0)
		p.initial_velocity_min   = 90.0
		p.initial_velocity_max   = 280.0
		p.angular_velocity_min   = -240.0
		p.angular_velocity_max   = 240.0
		p.scale_amount_min       = 5.0
		p.scale_amount_max       = 11.0
		p.one_shot               = true
		p.position               = origins[k]
		var grad := Gradient.new()
		grad.colors = PackedColorArray([
			Color(1.0, 0.85, 0.0),
			Color(1.0, 0.25, 0.25),
			Color(0.25, 0.80, 1.0),
			Color(0.25, 1.00, 0.45),
		])
		p.color_ramp = grad
		layer.add_child(p)

	# ─ Pulse the podium title ─
	var scale_tw := create_tween()
	scale_tw.set_loops(4)
	scale_tw.tween_property(_podium_label, "scale", Vector2(1.08, 1.08), 0.35)
	scale_tw.tween_property(_podium_label, "scale", Vector2.ONE,         0.35)

	# Clean up after the podium timeout.
	await get_tree().create_timer(8.0).timeout
	if is_instance_valid(spot):  spot.queue_free()
	if is_instance_valid(layer): layer.queue_free()


func _hide_podium() -> void:
	if _podium_layer:
		_podium_layer.visible = false


func _ensure_podium_ui() -> void:
	if _podium_layer:
		return
	_podium_layer = CanvasLayer.new()
	_podium_layer.layer = 9
	_podium_layer.name = "PodiumUI"
	add_child(_podium_layer)

	var panel := PanelContainer.new()
	panel.anchors_preset = Control.PRESET_CENTER
	panel.offset_left   = -340.0
	panel.offset_right  =  340.0
	panel.offset_top    = -185.0
	panel.offset_bottom =  185.0
	_podium_layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(vbox)

	_podium_label = Label.new()
	_podium_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_podium_label.add_theme_font_size_override("font_size", 32)
	_podium_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	vbox.add_child(_podium_label)

	var spacer2 := Control.new()
	spacer2.custom_minimum_size.y = 12.0
	vbox.add_child(spacer2)

	# Scroll container for score cards (handles many players gracefully).
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0.0, 140.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_scores_container = HBoxContainer.new()
	_scores_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_scores_container.add_theme_constant_override("separation", 8)
	scroll.add_child(_scores_container)


func _animate_podium_camera(winner: Player) -> void:
	# Orbit camera around the winner.
	if not _spectate_camera:
		_spectate_camera = Camera3D.new()
		_spectate_camera.name = "SpectateCamera"
		get_parent().add_child(_spectate_camera)

	_spectate_camera.current = true
	var orbit_pos := winner.global_position + Vector3(0, 2.5, 4.0)
	var tw := create_tween()
	tw.tween_property(_spectate_camera, "global_position", orbit_pos, 1.0).set_trans(Tween.TRANS_SINE)
	await tw.finished
	if is_instance_valid(_spectate_camera) and is_instance_valid(winner):
		_spectate_camera.look_at(winner.global_position + Vector3.UP * 0.8)


# ══════════════════════════════════════════════════════════════════════════════
#  SPECTATOR SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

func _start_spectating() -> void:
	if _spectating:
		return
	_spectating = true
	_refresh_spectate_targets()

	# Always create and activate the spectate camera, even when no targets exist
	# yet (e.g. solo test or simultaneous deaths). The process loop will follow
	# a target as soon as one becomes available.
	if not _spectate_camera:
		_spectate_camera = Camera3D.new()
		_spectate_camera.name = "SpectateCamera"
		get_parent().add_child(_spectate_camera)

	_spectate_index = 0
	_spectate_camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Show spectating HUD.
	_update_spectate_hud()


func _stop_spectating() -> void:
	if not _spectating:
		return
	_spectating = false
	_spectate_targets.clear()

	if _spectate_camera:
		_spectate_camera.queue_free()
		_spectate_camera = null

	# Restore local camera.
	if _local_player and is_instance_valid(_local_player) and not _local_player.is_dead:
		_local_player.camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Hide spectate bar on HUD.
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
	# Clamp index.
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
	var pid : int = target.get_multiplayer_authority()
	_local_player.hud.show_spectating(_peer_name(pid))


# ══════════════════════════════════════════════════════════════════════════════
#  RESPAWN / END
# ══════════════════════════════════════════════════════════════════════════════

func _respawn_all() -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		return
	var spawn_pt : Marker3D = get_parent().get_node("SpawnPoint") as Marker3D
	# Collect platform positions for spread spawning.
	var platforms : Array[Vector3] = []
	var plat_node : Node = get_parent().get_node_or_null("Platforms")
	if plat_node:
		for child in plat_node.get_children():
			if child is StaticBody3D:
				platforms.append(child.global_position)
	var idx : int = 0
	for child : Node in players_container.get_children():
		if child is Player:
			child.is_dead = false
			# Restore all hidden visuals.
			if child.has_node("Head"):
				child.get_node("Head").visible = true
			var name_lbl : Node = child.get_node_or_null("NameLabel3D")
			if name_lbl and not child.is_local:
				name_lbl.visible = true
			if child.has_node("PuppetBody"):
				child.get_node("PuppetBody").visible = not child.is_local
			child.velocity = Vector3.ZERO
			if platforms.size() > 0:
				child.global_position = platforms[idx % platforms.size()] + Vector3(0, 2, 0)
			else:
				var offset := Vector3(idx * 3.0, 0.0, 0.0)
				child.global_position = spawn_pt.global_position + offset
			if child.is_local:
				child.hunger = child.max_hunger
				child.is_starving = false
				if child.hunger_death_timer and not child.hunger_death_timer.is_queued_for_deletion():
					child.hunger_death_timer.stop()
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				# Re-enable camera.
				child.camera.make_current()
				# Hide death label.
				if child.hud:
					child.hud.death_label.visible = false
			idx += 1

	# Reset banana spawner counts.
	for child : Node in get_parent().get_children():
		if child is BananaSpawner:
			child.max_bananas = 20  # original value


func _end_match() -> void:
	_hide_podium()
	if has_node("/root/GameSettings"):
		get_node("/root/GameSettings").lps_clear()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Return to lobby keeping the connection alive.
	# (Selection screen normally handles this via _rpc_end_to_lobby;
	#  this fallback path is kept for safety.)
	get_tree().change_scene_to_file("res://multiplayer/LobbyRoom.tscn")


# ══════════════════════════════════════════════════════════════════════════════
#  HUD HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _cache_local_player() -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if not players_container:
		return
	for child : Node in players_container.get_children():
		if child is Player and child.is_local:
			_local_player = child as Player
			return


func _update_local_hud_round() -> void:
	if _local_player and _local_player.hud:
		_local_player.hud.update_round_info(current_round, total_rounds)


func _update_local_hud_alive() -> void:
	if _local_player and _local_player.hud:
		_local_player.hud.update_alive_count(_alive_peers.size())


func _update_local_hud_timer() -> void:
	if _local_player and _local_player.hud:
		_local_player.hud.update_game_timer(_round_timer)
		var lbl : Label = _local_player.hud.timer_label
		if lbl:
			if _round_timer > 0.0 and _round_timer <= 30.0:
				lbl.add_theme_color_override("font_color", Color(1.0, 0.25, 0.25))
			else:
				lbl.remove_theme_color_override("font_color")


func _show_round_banner(text: String) -> void:
	_ensure_podium_ui()
	_podium_label.text = text
	_scores_container.get_children().map(func(c: Node) -> void: c.queue_free())
	_podium_layer.visible = true


func _hide_round_banner() -> void:
	if _podium_layer:
		_podium_layer.visible = false


# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _peer_name(peer_id : int) -> String:
	return GameLobby.display_name(peer_id)


## Disable all Crocodile nodes — called at the start of every LPS round.
func _hide_crocs() -> void:
	_set_croc_state(get_parent(), false)

## Re-enable all Crocodile nodes — called when deathmatch/overtime begins.
func _enable_crocs() -> void:
	_set_croc_state(get_parent(), true)

func _set_croc_state(node: Node, enabled: bool) -> void:
	for child : Node in node.get_children():
		if child is Crocodile:
			child.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
			child.visible = enabled
		else:
			_set_croc_state(child, enabled)
