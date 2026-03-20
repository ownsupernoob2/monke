extends Node3D

## Assign res://components/Player.tscn in the Inspector.
@export var player_scene : PackedScene

@onready var spawn_point : Marker3D = $SpawnPoint

## Multiplayer: container that holds all player nodes.
var _players_node : Node3D = null

## Track spawned peer IDs to avoid double-spawn.
var _spawned_peers : Dictionary = {}
var _peer_spawn_slot : Dictionary = {}
var _used_spawn_slots : Dictionary = {}

## Chat overlay instance (multiplayer only).
var _chat : Node = null


func _ready() -> void:
	_apply_settings()
	_apply_map_vine_style()

	# Create a dedicated container for players.
	_players_node = Node3D.new()
	_players_node.name = "Players"
	add_child(_players_node)

	if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		# Multiplayer mode — spawn one player per connected peer.
		_setup_multiplayer()
	else:
		# Singleplayer fallback.
		_spawn_local_player()


func _apply_map_vine_style() -> void:
	# Forest maps keep the default jungle-green vines.
	if scene_file_path.find("RedCanyon.tscn") == -1:
		return

	var rope_color := Color(0.48, 0.30, 0.10)
	for n in find_children("*", "Vine", true, false):
		var vine := n as Vine
		if vine:
			vine.segment_color = rope_color


func _apply_settings() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		if not gs.ground_enemies_enabled:
			for child in get_children():
				if child.name == "Swamp":
					for swamp_child in child.get_children():
						if swamp_child.name.begins_with("Crocodile"):
							swamp_child.queue_free()


# ── Singleplayer ──────────────────────────────────────────────────────────────

func _spawn_local_player() -> void:
	if player_scene == null:
		push_error("Main: 'player_scene' export is not assigned.")
		return
	var player : Player = player_scene.instantiate() as Player
	if player == null:
		push_error("Main: player_scene.instantiate() returned null – check Player.tscn.")
		return
	# Explicitly mark as local BEFORE add_child so _ready() sees is_local = true.
	player.setup_network(true)
	_players_node.add_child(player)
	player.global_position = spawn_point.global_position
	player.player_died.connect(_on_player_died.bind(0))
	_apply_hunger(player)
	_apply_buff(player)


# ── Multiplayer ───────────────────────────────────────────────────────────────

func _setup_multiplayer() -> void:
	# Spawn chat overlay.
	var chat_scene := load("res://ui/Chat.tscn")
	if chat_scene:
		_chat = chat_scene.instantiate()
		add_child(_chat)

	# Spawn for every peer already in the lobby.
	for peer_id : int in GameLobby.players.keys():
		_spawn_mp_player(peer_id)

	# Fallback: on fast scene transitions, clients can enter the map before
	# GameLobby.players has finished syncing. Ensure the local player exists.
	var local_id : int = multiplayer.get_unique_id()
	if not _spawned_peers.has(local_id):
		_spawn_mp_player(local_id)

	# Late-joiners (shouldn't happen mid-game, but safe).
	GameLobby.player_joined.connect(func(_id : int, _n : String) -> void: _spawn_mp_player(_id))
	GameLobby.player_left.connect(_on_peer_left)

	# Host-disconnect for clients.
	GameLobby.server_closed.connect(_on_server_closed)

	# Spawn gamemode manager if applicable.
	_spawn_gamemode_manager()


func _spawn_mp_player(peer_id : int) -> void:
	if _spawned_peers.has(peer_id):
		return
	if player_scene == null:
		push_error("Main: 'player_scene' export is not assigned.")
		return

	var player : Player = player_scene.instantiate() as Player
	player.name = "Player_%d" % peer_id

	# Decide local vs puppet BEFORE adding to tree – _ready() reads is_local.
	var is_mine : bool = (peer_id == multiplayer.get_unique_id())
	player.setup_network(is_mine)

	# Assign multiplayer authority BEFORE adding to tree so _ready knows.
	player.set_multiplayer_authority(peer_id)
	_players_node.add_child(player)
	_spawned_peers[peer_id] = true

	# Place each player on a different platform (if available).
	var platforms := _get_platform_positions()
	var slot : int = _assign_spawn_slot(peer_id, platforms.size())
	if slot >= 0 and slot < platforms.size():
		player.global_position = platforms[slot] + Vector3(0, 2, 0)
	else:
		# Fallback ring placement keeps players separated even without platforms.
		var radius := 3.0 + float(slot) * 0.45
		var angle := float(slot) * 0.9
		var offset := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		player.global_position = spawn_point.global_position + offset

	# Ensure players never physically collide with each other.
	_refresh_player_collision_exceptions()

	# Wire death signal.
	player.player_died.connect(_on_player_died.bind(peer_id))

	if is_mine:
		_apply_hunger(player)
	_apply_buff(player)


func _apply_hunger(player : Player) -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		if not gs.hunger_enabled and player.has_method("set_hunger_enabled"):
			player.set_hunger_enabled(false)


func _apply_buff(player : Player) -> void:
	# Buffs are now pickup-based (special bananas), not granted at spawn.
	if player == null:
		return


func _on_peer_left(peer_id : int) -> void:
	var node : Node = _players_node.get_node_or_null("Player_%d" % peer_id)
	if node:
		node.queue_free()
	_spawned_peers.erase(peer_id)
	if _peer_spawn_slot.has(peer_id):
		var slot : int = int(_peer_spawn_slot[peer_id])
		_peer_spawn_slot.erase(peer_id)
		_used_spawn_slots.erase(slot)


func _assign_spawn_slot(peer_id: int, slot_count: int) -> int:
	if _peer_spawn_slot.has(peer_id):
		return int(_peer_spawn_slot[peer_id])

	# Deterministic ordering keeps peer -> spawn mapping stable across clients.
	var deterministic_index := _sorted_peer_index(peer_id)
	if slot_count > 0 and deterministic_index < slot_count:
		_peer_spawn_slot[peer_id] = deterministic_index
		_used_spawn_slots[deterministic_index] = true
		return deterministic_index

	# More players than available platforms: use fallback ring slots.
	if slot_count > 0:
		var overflow_slot : int = slot_count + maxi(0, deterministic_index - slot_count)
		_peer_spawn_slot[peer_id] = overflow_slot
		return overflow_slot

	# No platforms case: still assign a unique synthetic slot index.
	var fallback_slot : int = deterministic_index
	_peer_spawn_slot[peer_id] = fallback_slot
	return fallback_slot


func _sorted_peer_index(peer_id: int) -> int:
	var ids: Array[int] = []
	for id_variant in GameLobby.players.keys():
		ids.append(int(id_variant))
	if not ids.has(peer_id):
		ids.append(peer_id)
	ids.sort()
	var index := ids.find(peer_id)
	if index == -1:
		return 0
	return index


func _refresh_player_collision_exceptions() -> void:
	var nodes := _players_node.get_children()
	for i in range(nodes.size()):
		var player_a := nodes[i] as PhysicsBody3D
		if player_a == null:
			continue
		for j in range(i + 1, nodes.size()):
			var player_b := nodes[j] as PhysicsBody3D
			if player_b == null:
				continue
			player_a.add_collision_exception_with(player_b)
			player_b.add_collision_exception_with(player_a)


## Collect world positions of all platforms in the map's Platforms node.
func _get_platform_positions() -> Array[Vector3]:
	var positions : Array[Vector3] = []
	var plat_node : Node = get_node_or_null("Platforms")
	if plat_node:
		for child in plat_node.get_children():
			if child is StaticBody3D:
				positions.append(child.global_position)
	return positions


func _on_server_closed() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		if gs.disconnect_message.is_empty():
			gs.disconnect_message = "Host left the lobby."
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


func _on_player_died(peer_id : int) -> void:
	print("Player %d died!" % peer_id)


func _spawn_gamemode_manager() -> void:
	var gm : String = ""
	if has_node("/root/GameSettings"):
		gm = get_node("/root/GameSettings").selected_gamemode

	if gm == "Banana Frenzy":
		var bf_script : Script = load("res://maps/banana_frenzy_manager.gd")
		var bf := Node.new()
		bf.name = "BananaFrenzyManager"
		bf.set_script(bf_script)
		add_child(bf)
	elif gm == "Tag":
		var tag_script : Script = load("res://maps/tag_manager.gd")
		var tag := Node.new()
		tag.name = "TagManager"
		tag.set_script(tag_script)
		add_child(tag)
	elif gm == "Bomb Tag":
		var bomb_script : Script = load("res://maps/bomb_tag_manager.gd")
		var bomb := Node.new()
		bomb.name = "BombTagManager"
		bomb.set_script(bomb_script)
		add_child(bomb)
	else:
		var lps_script : Script = load("res://maps/lps_manager.gd")
		var lps := Node.new()
		lps.name = "LPSManager"
		lps.set_script(lps_script)
		add_child(lps)
