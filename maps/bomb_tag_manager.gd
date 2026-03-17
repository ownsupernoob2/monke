extends Node

## Bomb Tag gamemode manager.
## One player is the bomb. They must tag another player before the bomb timer ends.
## If timer hits zero, the bomb carrier explodes and is eliminated.
## Last alive player wins the round.

const TAG_RANGE : float = 3.0
const BOMB_DURATION : float = 30.0
const TAG_TRANSFER_COOLDOWN : float = 0.75
const RETAG_WINDOW_DURATION : float = 1.0
const ESP_COLOR_BOMB : Color = Color(1.0, 0.55, 0.10)
const ESP_COLOR_TARGET : Color = Color(0.20, 0.62, 1.0)

var total_rounds : int = 3
var current_round : int = 0

var _round_active : bool = false
var _bomb_peer : int = -1
var _bomb_timer : float = 0.0
var _transfer_cooldown : float = 0.0
var _retag_target_peer : int = -1
var _retag_window_left : float = 0.0

var _alive_peers : Array[int] = []
var _all_peer_ids : Array[int] = []
var _scores : Dictionary = {}  # peer_id -> cumulative round points

var _local_player : Player = null
var _announce_layer : CanvasLayer = null
var _announce_label : Label = null
var _bomb_label : Label3D = null
var _spectating : bool = false
var _spectate_targets : Array[Player] = []
var _spectate_index : int = 0
var _spectate_camera : Camera3D = null


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
	_configure_bananas()
	_start_round()


func _process(delta: float) -> void:
	_update_bomb_esp()
	_update_bomb_label()
	_update_bomb_indicator()
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
	if not _round_active:
		return

	_transfer_cooldown = maxf(_transfer_cooldown - delta, 0.0)
	_retag_window_left = maxf(_retag_window_left - delta, 0.0)
	if _retag_window_left <= 0.0:
		_retag_target_peer = -1
	_bomb_timer = maxf(_bomb_timer - delta, 0.0)
	_update_local_hud()

	if GameLobby.is_host() and _bomb_peer >= 0 and (_transfer_cooldown <= 0.0 or _retag_window_left > 0.0):
		_check_bomb_transfer()

	if GameLobby.is_host() and _bomb_timer <= 0.0:
		_eliminate_bomb_holder()


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


func _start_round() -> void:
	current_round += 1
	_round_active = true
	_bomb_timer = BOMB_DURATION
	_transfer_cooldown = 0.0
	_alive_peers.clear()
	_all_peer_ids.clear()

	var players_container : Node = get_parent().get_node_or_null("Players")
	if players_container == null:
		push_error("BombTag: No 'Players' container found!")
		return

	for child : Node in players_container.get_children():
		if child is Player:
			var p := child as Player
			var pid : int = p.get_multiplayer_authority()
			_alive_peers.append(pid)
			_all_peer_ids.append(pid)
			if not _scores.has(pid):
				_scores[pid] = 0
			p.is_dead = false
			p.set_hunger_enabled(false)
			if not p.player_died.is_connected(_on_player_died.bind(pid)):
				p.player_died.connect(_on_player_died.bind(pid))

	if GameLobby.is_host() and _alive_peers.size() > 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var first_bomb := _alive_peers[rng.randi() % _alive_peers.size()]
		rpc("_rpc_set_bomb", first_bomb, true)
		_rpc_set_bomb(first_bomb, true)

	_stop_spectating()
	_update_local_hud()


func _check_bomb_transfer() -> void:
	if _bomb_peer < 0:
		return
	var players_container : Node = get_parent().get_node_or_null("Players")
	if players_container == null:
		return
	var bomb_node : Node = players_container.get_node_or_null("Player_%d" % _bomb_peer)
	if bomb_node == null or not is_instance_valid(bomb_node):
		return
	var bomb_pos : Vector3 = (bomb_node as Node3D).global_position

	# During cooldown, only allow a quick retag back to the previous holder.
	if _transfer_cooldown > 0.0:
		if _retag_window_left <= 0.0 or _retag_target_peer < 0:
			return
		var retag_node : Node = players_container.get_node_or_null("Player_%d" % _retag_target_peer)
		if retag_node and retag_node is Player:
			var retag_player := retag_node as Player
			if not retag_player.is_dead and _retag_target_peer in _alive_peers:
				if retag_player.global_position.distance_to(bomb_pos) <= TAG_RANGE:
					rpc("_rpc_set_bomb", _retag_target_peer, false)
					_rpc_set_bomb(_retag_target_peer, false)
		return

	var closest_pid : int = -1
	var closest_dist : float = INF

	for child : Node in players_container.get_children():
		if not (child is Player):
			continue
		var p := child as Player
		var pid : int = p.get_multiplayer_authority()
		if pid == _bomb_peer or p.is_dead or pid not in _alive_peers:
			continue
		var distance := p.global_position.distance_to(bomb_pos)
		if distance <= TAG_RANGE and distance < closest_dist:
			closest_dist = distance
			closest_pid = pid
	if closest_pid >= 0:
		rpc("_rpc_set_bomb", closest_pid, false)
		_rpc_set_bomb(closest_pid, false)


func _eliminate_bomb_holder() -> void:
	if _bomb_peer < 0:
		return
	rpc("_rpc_force_kill", _bomb_peer)
	_rpc_force_kill(_bomb_peer)


@rpc("authority", "reliable", "call_local")
func _rpc_set_bomb(peer_id: int, reset_timer: bool = false) -> void:
	var previous_bomb := _bomb_peer
	_bomb_peer = peer_id
	if reset_timer:
		_bomb_timer = BOMB_DURATION
	_transfer_cooldown = TAG_TRANSFER_COOLDOWN
	if previous_bomb >= 0 and previous_bomb != peer_id:
		_retag_target_peer = previous_bomb
		_retag_window_left = RETAG_WINDOW_DURATION
	else:
		_retag_target_peer = -1
		_retag_window_left = 0.0
	var local_id : int = multiplayer.get_unique_id()
	if peer_id == local_id:
		_show_announcement("You have the bomb! Tag someone!")
	elif previous_bomb == local_id:
		_show_announcement("%s took the bomb." % _display_name(peer_id))
	else:
		_show_announcement("%s has the bomb." % _display_name(peer_id))
	get_tree().create_timer(1.8).timeout.connect(_hide_announcement, CONNECT_ONE_SHOT)
	_update_local_hud()


@rpc("authority", "reliable", "call_local")
func _rpc_force_kill(peer_id: int) -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if players_container == null:
		return
	var node : Node = players_container.get_node_or_null("Player_%d" % peer_id)
	if node and node is Player and not node.is_dead:
		(node as Player).die()


func _on_player_died(peer_id: int) -> void:
	if not _round_active:
		return
	_alive_peers.erase(peer_id)
	_update_local_hud()

	if GameLobby.is_host() and _alive_peers.size() <= 1:
		_round_active = false
		_finish_round()
		return

	if _local_player and peer_id == _local_player.get_multiplayer_authority():
		_start_spectating()
	elif _spectating:
		_refresh_spectate_targets()
		_update_spectate_hud()

	if GameLobby.is_host() and peer_id == _bomb_peer and _alive_peers.size() > 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var next_bomb := _alive_peers[rng.randi() % _alive_peers.size()]
		rpc("_rpc_set_bomb", next_bomb, true)
		_rpc_set_bomb(next_bomb, true)


func _on_peer_left(peer_id: int) -> void:
	if not _round_active:
		return
	_alive_peers.erase(peer_id)
	_all_peer_ids.erase(peer_id)
	_scores.erase(peer_id)
	_update_local_hud()

	if GameLobby.is_host() and _alive_peers.size() <= 1:
		_round_active = false
		_finish_round()
		return

	if _spectating:
		_refresh_spectate_targets()
		_update_spectate_hud()

	if GameLobby.is_host() and peer_id == _bomb_peer and _alive_peers.size() > 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var next_bomb := _alive_peers[rng.randi() % _alive_peers.size()]
		rpc("_rpc_set_bomb", next_bomb, true)
		_rpc_set_bomb(next_bomb, true)


func _finish_round() -> void:
	var ranked : Array[int] = []
	if _alive_peers.size() == 1:
		ranked.append(_alive_peers[0])
	for pid : int in _all_peer_ids:
		if pid not in ranked:
			ranked.append(pid)
	var points := [3, 2, 1]
	for i : int in mini(ranked.size(), points.size()):
		var pid : int = ranked[i]
		if not _scores.has(pid):
			_scores[pid] = 0
		_scores[pid] += points[i]

	rpc("_rpc_round_over", _scores)
	_rpc_round_over(_scores)


@rpc("authority", "reliable", "call_local")
func _rpc_round_over(updated_scores: Dictionary) -> void:
	_round_active = false
	_scores = updated_scores
	_retag_target_peer = -1
	_retag_window_left = 0.0
	_clear_all_esp()
	if _bomb_label and is_instance_valid(_bomb_label):
		_bomb_label.visible = false
	_stop_spectating()
	_clear_mode_status()

	if current_round >= total_rounds and has_node("/root/GameSettings"):
		get_node("/root/GameSettings").lps_match_complete = true

	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.lps_scores = _scores.duplicate()
		gs.lps_current_round = current_round
		gs.lps_match_active = true

	await get_tree().create_timer(1.0).timeout
	if is_inside_tree():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_tree().change_scene_to_file("res://multiplayer/SelectionScreen.tscn")


func _update_local_hud() -> void:
	if _local_player == null or _local_player.hud == null:
		return
	var alive_count := _alive_peers.size()
	_local_player.hud.update_round_info(current_round, total_rounds)
	_local_player.hud.update_alive_count(alive_count)
	_local_player.hud.update_game_timer(_bomb_timer)
	if _bomb_peer < 0:
		_clear_mode_status()
		return
	if _bomb_peer == multiplayer.get_unique_id():
		_local_player.hud.set_mode_status("YOU HAVE THE BOMB", ESP_COLOR_BOMB)
	else:
		_local_player.hud.set_mode_status("BOMB: %s" % _display_name(_bomb_peer), ESP_COLOR_TARGET)


func _update_bomb_esp() -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if players_container == null:
		return
	var local_id : int = multiplayer.get_unique_id()
	var local_is_bomb : bool = (_bomb_peer == local_id)

	for child : Node in players_container.get_children():
		if not (child is Player):
			continue
		var p := child as Player
		var pid : int = p.get_multiplayer_authority()
		if pid == local_id or p.is_dead or pid not in _alive_peers:
			p.set_role_outline(false)
			continue
		if local_is_bomb:
			# Bomb holder sees all available targets in blue.
			p.set_role_outline(true, ESP_COLOR_TARGET)
		else:
			# Non-bomb players see current bomb holder in orange.
			if pid == _bomb_peer:
				p.set_role_outline(true, ESP_COLOR_BOMB)
			else:
				p.set_role_outline(false)


func _clear_all_esp() -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if players_container == null:
		return
	for child : Node in players_container.get_children():
		if child is Player:
			(child as Player).set_role_outline(false)


func _cache_local_player() -> void:
	var players_container : Node = get_parent().get_node_or_null("Players")
	if players_container == null:
		return
	for child : Node in players_container.get_children():
		if child is Player and child.is_local:
			_local_player = child as Player
			return


func _update_bomb_label() -> void:
	if _bomb_peer < 0:
		if _bomb_label:
			_bomb_label.visible = false
		return
	var players_container : Node = get_parent().get_node_or_null("Players")
	if players_container == null:
		if _bomb_label:
			_bomb_label.visible = false
		return
	var bomb_node : Node = players_container.get_node_or_null("Player_%d" % _bomb_peer)
	if bomb_node == null or not is_instance_valid(bomb_node):
		if _bomb_label:
			_bomb_label.visible = false
		return
	if bomb_node is Player and (bomb_node as Player).is_dead:
		if _bomb_label:
			_bomb_label.visible = false
		return
	if _bomb_label == null:
		_bomb_label = Label3D.new()
		_bomb_label.name = "BombLabel"
		_bomb_label.text = "💣"
		_bomb_label.font_size = 88
		_bomb_label.outline_size = 10
		_bomb_label.modulate = ESP_COLOR_BOMB
		_bomb_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_bomb_label.no_depth_test = true
		_bomb_label.render_priority = 2
		get_parent().add_child(_bomb_label)
	_bomb_label.visible = true
	_bomb_label.global_position = (bomb_node as Node3D).global_position + Vector3(0.0, 2.95, 0.0)


func _update_bomb_indicator() -> void:
	_update_local_hud()


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
	_announce_label.offset_left = -320.0
	_announce_label.offset_right = 320.0
	_announce_label.offset_top = -40.0
	_announce_label.offset_bottom = 40.0
	_announce_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_announce_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_announce_label.add_theme_font_size_override("font_size", 36)
	_announce_label.add_theme_color_override("font_color", ESP_COLOR_BOMB)
	_announce_layer.add_child(_announce_label)


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
	if _local_player == null or _local_player.hud == null:
		return
	if _spectate_targets.is_empty():
		_local_player.hud.show_spectating("Waiting...")
		return
	_spectate_index = clampi(_spectate_index, 0, _spectate_targets.size() - 1)
	var target : Player = _spectate_targets[_spectate_index]
	_local_player.hud.show_spectating(_display_name(target.get_multiplayer_authority()))


func _clear_mode_status() -> void:
	if _local_player and _local_player.hud:
		_local_player.hud.clear_mode_status()


func _display_name(peer_id: int) -> String:
	if has_node("/root/GameLobby"):
		return GameLobby.display_name(peer_id)
	return "Player %d" % peer_id


func _configure_bananas() -> void:
	_configure_bananas_recursive(get_parent())


func _configure_bananas_recursive(node: Node) -> void:
	var selected_buff := ""
	if has_node("/root/GameSettings"):
		selected_buff = str(get_node("/root/GameSettings").selected_buff)
	for child : Node in node.get_children():
		if child is BananaSpawner:
			child.buff_spawn_chance = 1.0
			child.max_bananas = maxi(ceili(child.max_bananas * 0.5), 3)
			var container : Node = child.get_node_or_null("Bananas")
			if container and selected_buff != "":
				for banana_node : Node in container.get_children():
					if banana_node is Banana and banana_node.buff_type == "":
						banana_node.buff_type = selected_buff
						if banana_node.has_method("_apply_buff_color"):
							banana_node.call("_apply_buff_color")
		else:
			_configure_bananas_recursive(child)


func _on_server_closed() -> void:
	_round_active = false
	_retag_target_peer = -1
	_retag_window_left = 0.0
	_stop_spectating()
	_clear_mode_status()
