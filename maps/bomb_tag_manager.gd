extends Node

## Bomb Tag gamemode manager.
## One player is the bomb. They must tag another player before the bomb timer ends.
## If timer hits zero, the bomb carrier explodes and is eliminated.
## Last alive player wins the round.

const TAG_RANGE : float = 3.0
const BOMB_DURATION : float = 30.0
const TAG_TRANSFER_COOLDOWN : float = 0.75
const ESP_COLOR_BOMB : Color = Color(1.0, 0.55, 0.10)
const ESP_COLOR_TARGET : Color = Color(0.20, 0.62, 1.0)

var total_rounds : int = 3
var current_round : int = 0

var _round_active : bool = false
var _bomb_peer : int = -1
var _bomb_timer : float = 0.0
var _transfer_cooldown : float = 0.0

var _alive_peers : Array[int] = []
var _all_peer_ids : Array[int] = []
var _scores : Dictionary = {}  # peer_id -> cumulative round points

var _local_player : Player = null


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
	if not _round_active:
		return

	_transfer_cooldown = maxf(_transfer_cooldown - delta, 0.0)
	_bomb_timer = maxf(_bomb_timer - delta, 0.0)
	_update_local_hud()

	if GameLobby.is_host() and _bomb_peer >= 0 and _transfer_cooldown <= 0.0:
		_check_bomb_transfer()

	if GameLobby.is_host() and _bomb_timer <= 0.0:
		_eliminate_bomb_holder()


func _start_round() -> void:
	current_round += 1
	_round_active = true
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
		rpc("_rpc_set_bomb", first_bomb)
		_rpc_set_bomb(first_bomb)

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

	for child : Node in players_container.get_children():
		if not (child is Player):
			continue
		var p := child as Player
		var pid : int = p.get_multiplayer_authority()
		if pid == _bomb_peer or p.is_dead or pid not in _alive_peers:
			continue
		if p.global_position.distance_to(bomb_pos) <= TAG_RANGE:
			rpc("_rpc_set_bomb", pid)
			_rpc_set_bomb(pid)
			return


func _eliminate_bomb_holder() -> void:
	if _bomb_peer < 0:
		return
	rpc("_rpc_force_kill", _bomb_peer)
	_rpc_force_kill(_bomb_peer)


@rpc("authority", "reliable", "call_local")
func _rpc_set_bomb(peer_id: int) -> void:
	_bomb_peer = peer_id
	_bomb_timer = BOMB_DURATION
	_transfer_cooldown = TAG_TRANSFER_COOLDOWN
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

	if GameLobby.is_host() and peer_id == _bomb_peer and _alive_peers.size() > 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var next_bomb := _alive_peers[rng.randi() % _alive_peers.size()]
		rpc("_rpc_set_bomb", next_bomb)
		_rpc_set_bomb(next_bomb)


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

	if GameLobby.is_host() and peer_id == _bomb_peer and _alive_peers.size() > 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var next_bomb := _alive_peers[rng.randi() % _alive_peers.size()]
		rpc("_rpc_set_bomb", next_bomb)
		_rpc_set_bomb(next_bomb)


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
	_clear_all_esp()

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
