extends Node

## Multiplayer lobby singleton (autoload "GameLobby").
## Uses Epic Online Services (EOS) for NAT-traversed P2P when the EOS plugin
## is available.  Falls back to plain ENet (direct IP) automatically when the
## plugin is absent or EOS is not ready, so local / LAN play still works.
##
## EOS path  → host_lobby() creates an EOS Lobby and an EOSGMultiplayerPeer
##             server.  The lobby_id returned acts as the shareable room code.
##             Joiners call join_lobby(lobby_id) which finds the lobby by ID
##             and connects via EOSGMultiplayerPeer P2P.
##
## ENet path → legacy host_lobby_enet(port) / join_lobby_enet(ip, port) kept for
##             in-editor testing or when EOS credentials are not yet set.

signal connected
signal connection_failed
signal player_joined(id: int, p_name: String)
signal player_left(id: int)
signal game_starting
signal server_closed                       ## host left / connection lost
signal chat_received(sender: String, text: String)  ## new chat message
signal alert_received(text: String)                  ## red kick/ban notices
signal player_renamed(id: int, new_name: String)     ## name deduplicated after collision

const DEFAULT_PORT : int = 7777
const MAX_PLAYERS  : int = 8
const SOCKET_NAME  : String = "MonkeLobby"  ## EOS P2P socket identifier

var peer       : MultiplayerPeer = null
var players    : Dictionary = {}   # peer_id → { "name": String }
var banned_ids : Array[int] = []   # peer IDs barred from reconnecting

## Full EOS lobby ID — share this for others to join.
var current_lobby_id : String = ""

## True when using EOS P2P peer (false = ENet).
var _using_eos : bool = false

## Reference to the HLobbies autoload node (set lazily).
var _hlobbies : Node = null
## The HLobby object for the currently active EOS lobby.
var _hlobby = null


func get_local_name() -> String:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		return gs.player_name
	return "Player"


func is_host() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.is_server()


## Returns true when EOS is available and ready for P2P.
func eos_available() -> bool:
	if not Engine.has_singleton("IEOS"):
		return false
	if not has_node("/root/EOSBootstrap"):
		return false
	return get_node("/root/EOSBootstrap").is_ready


# ── Host / Join (EOS + ENet auto-select) ─────────────────────────────────────

## Host a lobby.
## When EOS is ready: creates an EOS Lobby and returns its lobby_id as a String
## via the [current_lobby_id] property.  Emits [connected].
## When EOS is not available: falls back to ENet on [port].
## Returns OK or an Error code; check [current_lobby_id] for the room code.
func host_lobby(port: int = DEFAULT_PORT) -> Error:
	if eos_available():
		return await _host_lobby_eos()
	return _host_lobby_enet(port)


## Join a lobby.
## [code_or_address]: EOS lobby_id string  OR  an IP address string.
## When EOS is ready and the string looks like a lobby id, uses EOS P2P.
## Otherwise falls back to ENet using [code_or_address] as the IP.
func join_lobby(code_or_address: String = "127.0.0.1", port: int = DEFAULT_PORT) -> Error:
	if eos_available():
		return await _join_lobby_eos(code_or_address)
	return _join_lobby_enet(code_or_address, port)


func disconnect_lobby() -> void:
	# Leave / destroy the EOS lobby if active.
	if _using_eos and _hlobby != null:
		if is_host():
			_hlobby.destroy_async()
		else:
			_hlobby.leave_async()
		_hlobby = null
	current_lobby_id = ""
	_using_eos = false
	if peer != null:
		peer.close()
		peer = null
	_disconnect_multiplayer_signals()
	multiplayer.multiplayer_peer = null
	players.clear()


## Safely disconnect all multiplayer signal handlers so re-joining is clean.
func _disconnect_multiplayer_signals() -> void:
	var mp := multiplayer
	if mp.connected_to_server.is_connected(_on_connected):
		mp.connected_to_server.disconnect(_on_connected)
	if mp.connection_failed.is_connected(_on_failed):
		mp.connection_failed.disconnect(_on_failed)
	if mp.server_disconnected.is_connected(_on_server_disconnected):
		mp.server_disconnected.disconnect(_on_server_disconnected)
	if mp.peer_connected.is_connected(_on_peer_connected):
		mp.peer_connected.disconnect(_on_peer_connected)
	if mp.peer_disconnected.is_connected(_on_peer_disconnected):
		mp.peer_disconnected.disconnect(_on_peer_disconnected)


# ── EOS implementation ────────────────────────────────────────────────────────

func _host_lobby_eos() -> Error:
	# Ensure any previous lobby / peer is fully torn down before re-hosting.
	disconnect_lobby()

	await get_node("/root/EOSBootstrap").wait_until_ready()

	var hlobbies : Node = _get_hlobbies()
	if hlobbies == null:
		push_error("Lobby: HLobbies autoload not found – can't host via EOS.")
		return ERR_UNAVAILABLE

	var create_opts = EOS.Lobby.CreateLobbyOptions.new()
	create_opts.max_lobby_members = MAX_PLAYERS
	create_opts.bucket_id = "monke"
	create_opts.enable_join_by_id = true
	create_opts.permission_level = EOS.Lobby.LobbyPermissionLevel.PublicAdvertised

	var lobby = await hlobbies.create_lobby_async(create_opts)
	if lobby == null:
		push_error("Lobby: EOS create_lobby_async failed.")
		connection_failed.emit()
		return FAILED

	_hlobby = lobby
	current_lobby_id = lobby.lobby_id
	_using_eos = true

	# Spawn the EOSGMultiplayerPeer server.
	var eos_peer = EOSGMultiplayerPeer.new()
	eos_peer.create_server(SOCKET_NAME)
	peer = eos_peer
	multiplayer.multiplayer_peer = peer
	# Disconnect first in case of a previous failed host attempt.
	_disconnect_multiplayer_signals()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	_register_self()
	connected.emit()
	return OK


func _join_lobby_eos(lobby_id: String) -> Error:
	# Ensure any previous lobby / peer is fully torn down before joining.
	disconnect_lobby()

	await get_node("/root/EOSBootstrap").wait_until_ready()

	var hlobbies : Node = _get_hlobbies()
	if hlobbies == null:
		push_error("Lobby: HLobbies autoload not found – can't join via EOS.")
		return ERR_UNAVAILABLE

	# JoinLobbyById only works for integrated/console platforms.
	# For cross-network PC play we must search by lobby ID first to get the
	# lobby details handle, then join with that handle.
	var results = await hlobbies.search_by_lobby_id_async(lobby_id)
	if results == null or results.is_empty():
		push_error("Lobby: EOS search_by_lobby_id_async found nothing for id: %s" % lobby_id)
		connection_failed.emit()
		return FAILED

	# Read host PUID from the search result NOW — it's fully populated here.
	# The HLobby returned by join_async uses init_from_id which may fail to
	# copy lobby details if the EOS SDK cache hasn't updated yet (NotFound).
	var host_puid : String = results[0].owner_product_user_id
	if host_puid == "":
		push_error("Lobby: could not determine host PUID from search result.")
		connection_failed.emit()
		return FAILED

	var lobby = await hlobbies.join_async(results[0])
	if lobby == null:
		push_error("Lobby: EOS join_async failed for id: %s" % lobby_id)
		connection_failed.emit()
		return FAILED

	_hlobby = lobby
	current_lobby_id = lobby_id
	_using_eos = true

	var eos_peer = EOSGMultiplayerPeer.new()
	eos_peer.create_client(SOCKET_NAME, host_puid)
	peer = eos_peer
	multiplayer.multiplayer_peer = peer
	# Disconnect first in case of a previous failed join attempt.
	_disconnect_multiplayer_signals()
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	return OK


func _get_hlobbies() -> Node:
	if _hlobbies != null:
		return _hlobbies
	if has_node("/root/HLobbies"):
		_hlobbies = get_node("/root/HLobbies")
		return _hlobbies
	return null


# ── ENet fallback ─────────────────────────────────────────────────────────────

func _host_lobby_enet(port: int = DEFAULT_PORT) -> Error:
	var enet_peer := ENetMultiplayerPeer.new()
	var err := enet_peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		push_error("Lobby: ENet create_server failed – %s" % error_string(err))
		return err
	peer = enet_peer
	_using_eos = false
	multiplayer.multiplayer_peer = peer
	_register_self()
	_disconnect_multiplayer_signals()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	connected.emit()
	return OK


func _join_lobby_enet(address: String = "127.0.0.1", port: int = DEFAULT_PORT) -> Error:
	var enet_peer := ENetMultiplayerPeer.new()
	var err := enet_peer.create_client(address, port)
	if err != OK:
		push_error("Lobby: ENet create_client failed – %s" % error_string(err))
		connection_failed.emit()
		return err
	peer = enet_peer
	_using_eos = false
	multiplayer.multiplayer_peer = peer
	_disconnect_multiplayer_signals()
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	return OK


# ── Kick / Ban ────────────────────────────────────────────────────────────────

## Kick a player: notify them then drop the connection.
func kick_player(pid: int) -> void:
	if not is_host() or not peer:
		return
	rpc_id(pid, "_rpc_notify_kicked", false)
	await get_tree().create_timer(0.3).timeout
	# Guard against the peer having already disconnected naturally.
	if not peer or not players.has(pid):
		return
	if _using_eos:
		# EOS: kick from lobby (will cause their peer to disconnect).
		if _hlobby != null:
			var kick_opts = EOS.Lobby.KickMemberOptions.new()
			kick_opts.lobby_id = current_lobby_id
			kick_opts.target_user_id = _puid_for_peer(pid)
			EOS.Lobby.LobbyInterface.kick_member(kick_opts)
	else:
		(peer as ENetMultiplayerPeer).disconnect_peer(pid)

## Ban a player: add to blacklist, notify them, then drop the connection.
func ban_player(pid: int) -> void:
	if not is_host() or not peer:
		return
	if pid not in banned_ids:
		banned_ids.append(pid)
	rpc_id(pid, "_rpc_notify_kicked", true)
	await get_tree().create_timer(0.3).timeout
	if not peer or not players.has(pid):
		return
	if _using_eos:
		if _hlobby != null:
			var kick_opts = EOS.Lobby.KickMemberOptions.new()
			kick_opts.lobby_id = current_lobby_id
			kick_opts.target_user_id = _puid_for_peer(pid)
			EOS.Lobby.LobbyInterface.kick_member(kick_opts)
	else:
		(peer as ENetMultiplayerPeer).disconnect_peer(pid)

## Map a Godot peer_id → EOS product_user_id (needed for EOS lobby kicks).
func _puid_for_peer(pid: int) -> String:
	if _using_eos and peer is EOSGMultiplayerPeer:
		return (peer as EOSGMultiplayerPeer).get_peer_user_id(pid)
	return ""

## Received by the target client only: set message and return to menu.
@rpc("authority", "reliable")
func _rpc_notify_kicked(is_ban: bool) -> void:
	var msg := "You have been banned from this server." if is_ban else "You have been kicked from the game."
	if has_node("/root/GameSettings"):
		get_node("/root/GameSettings").disconnect_message = msg
	disconnect_lobby()
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


# ── Alert messages (red, host-broadcast) ─────────────────────────────────────

func send_alert(text: String) -> void:
	rpc("_rpc_alert", text)
	alert_received.emit(text)

@rpc("authority", "reliable", "call_remote")
func _rpc_alert(text: String) -> void:
	alert_received.emit(text)


# ── Chat ──────────────────────────────────────────────────────────────────────

func send_chat(text: String) -> void:
	# Use display_name so the deduplicated name (e.g. "Player2") is shown,
	# not the raw stored name.
	var sender_name := display_name(multiplayer.get_unique_id())
	rpc("_rpc_chat", sender_name, text)
	# Also show locally.
	chat_received.emit(sender_name, text)


@rpc("any_peer", "reliable", "call_remote")
func _rpc_chat(sender_name: String, text: String) -> void:
	chat_received.emit(sender_name, text)


## System message (shown without a sender name prefix).
func send_system_message(text: String) -> void:
	rpc("_rpc_system_msg", text)
	chat_received.emit("", text)


@rpc("any_peer", "reliable", "call_remote")
func _rpc_system_msg(text: String) -> void:
	chat_received.emit("", text)


# ── Game start (host only) ────────────────────────────────────────────────────

func start_game() -> void:
	if not is_host():
		return
	rpc("_rpc_start_game")
	_rpc_start_game()


@rpc("authority", "reliable", "call_remote")
func _rpc_start_game() -> void:
	game_starting.emit()


# ── Internal ──────────────────────────────────────────────────────────────────

func _register_self() -> void:
	var my_id : int = multiplayer.get_unique_id()
	var my_name : String = _unique_name_for(my_id, get_local_name())
	players[my_id] = { "name": my_name }
	player_joined.emit(my_id, my_name)


## Returns a unique name for [param id] based on [param base], appending 2/3/… if taken.
func _unique_name_for(id: int, base: String) -> String:
	var candidate : String = base
	var suffix : int = 2
	while true:
		var taken : bool = false
		for existing_id : int in players:
			if existing_id != id and players[existing_id]["name"] == candidate:
				taken = true
				break
		if not taken:
			return candidate
		candidate = "%s%d" % [base, suffix]
		suffix += 1
	return candidate


func _on_connected() -> void:
	_register_self()
	# Broadcast our name to all existing peers.
	rpc("_rpc_register_player", multiplayer.get_unique_id(), get_local_name())
	connected.emit()


func _on_failed() -> void:
	connection_failed.emit()


func _on_server_disconnected() -> void:
	# Host left — clean up and notify.
	disconnect_lobby()
	server_closed.emit()


func _on_peer_connected(id: int) -> void:
	# Reject banned peers immediately.
	if id in banned_ids:
		rpc_id(id, "_rpc_notify_kicked", true)
		await get_tree().create_timer(0.2).timeout
		if not peer:
			return
		if _using_eos:
			if _hlobby != null:
				var kick_opts = EOS.Lobby.KickMemberOptions.new()
				kick_opts.lobby_id = current_lobby_id
				kick_opts.target_user_id = _puid_for_peer(id)
				EOS.Lobby.LobbyInterface.kick_member(kick_opts)
		else:
			(peer as ENetMultiplayerPeer).disconnect_peer(id)
		return
	# Tell the new peer about ALL currently connected players so they can
	# populate their lobby view completely (not just the host).
	for existing_id : int in players.keys():
		rpc_id(id, "_rpc_register_player", existing_id, players[existing_id]["name"])


func _on_peer_disconnected(id: int) -> void:
	# Compute display name BEFORE erasing so deduplication still works.
	var p_name : String = display_name(id)
	players.erase(id)
	player_left.emit(id)
	# Host broadcasts the leave message.
	if is_host():
		send_system_message("%s left the game." % p_name)


## Returns the stored (already-deduplicated) name for a peer.
func display_name(pid: int) -> String:
	if not players.has(pid):
		return "Player %d" % pid
	return str(players[pid]["name"])


@rpc("any_peer", "reliable")
func _rpc_register_player(id: int, p_name: String) -> void:
	var is_new : bool = not players.has(id)
	var unique_name : String = _unique_name_for(id, p_name)
	players[id] = { "name": unique_name }
	if is_new:
		player_joined.emit(id, unique_name)
	# If the host had to rename this player due to a duplicate, broadcast the
	# final name to the renamed player AND to all other connected clients so
	# every lobby view stays in sync.
	if is_host() and unique_name != p_name:
		rpc_id(id, "_rpc_set_your_name", unique_name)
		for other_id : int in players.keys():
			if other_id != id and other_id != multiplayer.get_unique_id():
				rpc_id(other_id, "_rpc_notify_rename", id, unique_name)
		player_renamed.emit(id, unique_name)


## Called on the client when the host assigned them a different name due to a duplicate.
@rpc("authority", "reliable")
func _rpc_set_your_name(assigned_name: String) -> void:
	var my_id : int = multiplayer.get_unique_id()
	if players.has(my_id):
		players[my_id]["name"] = assigned_name
	player_renamed.emit(my_id, assigned_name)


## Sent by the host to all OTHER clients when a player's name was deduplicated.
@rpc("authority", "reliable")
func _rpc_notify_rename(id: int, new_name: String) -> void:
	if players.has(id):
		players[id]["name"] = new_name
	player_renamed.emit(id, new_name)
