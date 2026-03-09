extends Node3D

## Assign res://components/Player.tscn in the Inspector.
@export var player_scene : PackedScene

@onready var spawn_point : Marker3D = $SpawnPoint

## Multiplayer: container that holds all player nodes.
var _players_node : Node3D = null

## Track spawned peer IDs to avoid double-spawn.
var _spawned_peers : Dictionary = {}

## Chat overlay instance (multiplayer only).
var _chat : Node = null


func _ready() -> void:
	_apply_settings()

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
	var idx : int = _spawned_peers.size() - 1
	var platforms := _get_platform_positions()
	if platforms.size() > 0:
		player.global_position = platforms[idx % platforms.size()] + Vector3(0, 2, 0)
	else:
		var offset := Vector3(idx * 3.0, 0.0, 0.0)
		player.global_position = spawn_point.global_position + offset

	# Wire death signal.
	player.player_died.connect(_on_player_died.bind(peer_id))

	if is_mine:
		_apply_hunger(player)


func _apply_hunger(player : Player) -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		if not gs.hunger_enabled and player.has_method("set_hunger_enabled"):
			player.set_hunger_enabled(false)


func _on_peer_left(peer_id : int) -> void:
	var node : Node = _players_node.get_node_or_null("Player_%d" % peer_id)
	if node:
		node.queue_free()
	_spawned_peers.erase(peer_id)


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
	# Chat handles the "host left" message and scene switch.
	# If there's no chat (shouldn't happen), do it here as fallback.
	if not _chat:
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
	else:
		var lps_script : Script = load("res://maps/lps_manager.gd")
		var lps := Node.new()
		lps.name = "LPSManager"
		lps.set_script(lps_script)
		add_child(lps)
