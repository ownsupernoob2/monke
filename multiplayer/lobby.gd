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
signal match_state_changed(in_progress: bool, map_path: String)

const DEFAULT_PORT : int = 7777
const MAX_PLAYERS  : int = 8
const SOCKET_NAME  : String = "MonkeLobby"  ## EOS P2P socket identifier

var peer       : MultiplayerPeer = null
var players    : Dictionary = {}   # peer_id → { "name": String }
var banned_ids : Array[int] = []   # peer IDs barred from reconnecting

## Full EOS lobby ID — share this for others to join.
var current_lobby_id : String = ""
## Short human-friendly room code for EOS lobbies.
var current_short_code : String = ""

## Live match state used for late-join routing.
var match_in_progress : bool = false
var active_map_path : String = ""
var active_gamemode : String = ""
var active_buff : String = ""

## True when using EOS P2P peer (false = ENet).
var _using_eos : bool = false
var _current_lobby_public : bool = true
var _disconnect_in_progress : bool = false
## Locally hidden lobby IDs (typically stale listings after host leaves).
var _hidden_public_lobbies : Dictionary = {}

## Reference to the HLobbies autoload node (set lazily).
var _hlobbies : Node = null
## The HLobby object for the currently active EOS lobby.
var _hlobby = null


func _notification(what: int) -> void:
	# Ensure host-owned lobbies are disbanded when quitting the app.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		disconnect_lobby()


func get_local_name() -> String:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		return gs.player_name
	return "Player"


func is_host() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func is_current_lobby_public() -> bool:
	return _current_lobby_public


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
func host_lobby(port: int = DEFAULT_PORT, public_lobby: bool = true) -> Error:
	if eos_available():
		return await _host_lobby_eos(public_lobby)
	return _host_lobby_enet(port)


## Join a lobby.
## [code_or_address]: EOS lobby_id string  OR  an IP address string.
## When EOS is ready and the string looks like a lobby id, uses EOS P2P.
## Otherwise falls back to ENet using [code_or_address] as the IP.
func join_lobby(code_or_address: String = "127.0.0.1", port: int = DEFAULT_PORT) -> Error:
	if eos_available():
		return await _join_lobby_eos(code_or_address)
	return _join_lobby_enet(code_or_address, port)


## Lists currently visible public EOS lobbies for the game's bucket.
## Returns Array of Dictionary: { lobby_id, short_code, host_name, members, max_members }
func list_public_lobbies() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not eos_available():
		return result
	await get_node("/root/EOSBootstrap").wait_until_ready()
	var hlobbies : Node = _get_hlobbies()
	if hlobbies == null:
		return result
	# Fetch by bucket first so discovery still works even if custom attributes
	# are missing on older lobbies; then filter locally.
	var lobbies = await hlobbies.search_by_bucket_id_async("monke")
	if lobbies == null:
		return result
	for lb in lobbies:
		if lb == null:
			continue
		if str(lb.lobby_id) == "" or str(lb.owner_product_user_id) == "":
			continue
		if _hidden_public_lobbies.has(str(lb.lobby_id)):
			continue
		if int(lb.members.size()) <= 0:
			continue
		# Strict rule: only advertised lobbies are listed.
		var is_public: bool = (lb.permission_level == EOS.Lobby.LobbyPermissionLevel.PublicAdvertised)
		if not is_public:
			continue
		var pub_attr = lb.get_attribute("lobby_public")
		if pub_attr is Dictionary and pub_attr.has("value"):
			var raw_pub: String = str(pub_attr.value).to_lower()
			if raw_pub == "0" or raw_pub == "false":
				is_public = false
		if not is_public:
			continue
		var host_name := "Host"
		var attr = lb.get_attribute("host_name")
		if attr is Dictionary and attr.has("value"):
			host_name = str(attr.value)
		result.append({
			"lobby_id": str(lb.lobby_id),
			"short_code": "",
			"host_name": host_name,
			"members": int(lb.members.size()),
			"max_members": int(lb.max_members),
		})
	return result


## Host-only: switch active EOS lobby between public/private visibility.
func set_current_lobby_public(public_lobby: bool) -> bool:
	if not _using_eos or _hlobby == null or not is_host():
		return false
	_hlobby.permission_level = EOS.Lobby.LobbyPermissionLevel.PublicAdvertised \
			if public_lobby else EOS.Lobby.LobbyPermissionLevel.InviteOnly
	_hlobby.add_attribute("lobby_public", "1" if public_lobby else "0", EOS.Lobby.LobbyAttributeVisibility.Public)
	var ok : bool = await _hlobby.update_async()
	if ok:
		_current_lobby_public = public_lobby
	return ok


func disconnect_lobby() -> void:
	# Backward-compatible fire-and-forget API.
	disconnect_lobby_async()


func disconnect_lobby_async() -> void:
	if _disconnect_in_progress:
		while _disconnect_in_progress:
			await get_tree().create_timer(0.05).timeout
		return
	_disconnect_in_progress = true
	if is_host() and multiplayer.has_multiplayer_peer():
		rpc("_rpc_host_disbanding")
		await get_tree().create_timer(0.12).timeout

	# If we were the host, hide this lobby locally from public browse results.
	# EOS can briefly show stale listings after destroy/leave due eventual consistency.
	if is_host() and current_lobby_id != "":
		_hidden_public_lobbies[current_lobby_id] = true

	# Leave / destroy the EOS lobby if active.
	if _using_eos and _hlobby != null:
		var eos_ok : bool = false
		var lobby_ref = _hlobby
		if is_host():
			if lobby_ref.is_valid():
				lobby_ref.permission_level = EOS.Lobby.LobbyPermissionLevel.InviteOnly
				lobby_ref.add_attribute("lobby_public", "0", EOS.Lobby.LobbyAttributeVisibility.Public)
				await lobby_ref.update_async()
			if lobby_ref.is_valid():
				eos_ok = await lobby_ref.destroy_async()
			# Retry once; EOS can race during scene/app shutdown.
			if not eos_ok and lobby_ref.is_valid():
				await get_tree().create_timer(0.2).timeout
				eos_ok = await lobby_ref.destroy_async()
			# Final fallback: leave if destroy is unavailable.
			if not eos_ok and lobby_ref.is_valid():
				eos_ok = await lobby_ref.leave_async()
		else:
			if lobby_ref.is_valid():
				eos_ok = await lobby_ref.leave_async()
		if not eos_ok:
			print("Lobby: EOS leave/destroy did not complete (likely shutdown race).")
		_hlobby = null
	current_lobby_id = ""
	current_short_code = ""
	_using_eos = false
	_set_match_state(false, "", "", "")
	if peer != null:
		peer.close()
		peer = null
	_disconnect_multiplayer_signals()
	if multiplayer != null:
		multiplayer.multiplayer_peer = null
	for pid : int in players.keys():
		player_left.emit(pid)
	players.clear()
	_disconnect_in_progress = false


func ensure_local_registered() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var my_id : int = multiplayer.get_unique_id()
	if my_id <= 0:
		return
	if not players.has(my_id):
		_register_self()
		if is_host():
			_broadcast_player_snapshot()


## Safely disconnect all multiplayer signal handlers so re-joining is clean.
func _disconnect_multiplayer_signals() -> void:
	if multiplayer == null:
		return
	var mp := multiplayer
	if mp == null:
		return
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

func _host_lobby_eos(public_lobby: bool = true) -> Error:
	# Ensure any previous lobby / peer is fully torn down before re-hosting.
	await disconnect_lobby_async()

	await get_node("/root/EOSBootstrap").wait_until_ready()

	var hlobbies : Node = _get_hlobbies()
	if hlobbies == null:
		push_error("Lobby: HLobbies autoload not found – can't host via EOS.")
		return ERR_UNAVAILABLE

	var create_opts = EOS.Lobby.CreateLobbyOptions.new()
	create_opts.max_lobby_members = MAX_PLAYERS
	create_opts.bucket_id = "monke"
	create_opts.enable_join_by_id = true
	create_opts.permission_level = EOS.Lobby.LobbyPermissionLevel.PublicAdvertised \
			if public_lobby else EOS.Lobby.LobbyPermissionLevel.InviteOnly

	var lobby = await hlobbies.create_lobby_async(create_opts)
	if lobby == null:
		push_error("Lobby: EOS create_lobby_async failed.")
		connection_failed.emit()
		return FAILED

	_hlobby = lobby
	current_lobby_id = lobby.lobby_id
	_using_eos = true
	_current_lobby_public = public_lobby
	current_short_code = ""
	# New host session should always be visible in browser (if public).
	_hidden_public_lobbies.erase(current_lobby_id)

	# Metadata used by lobby finder and short-code joining.
	_hlobby.add_attribute("host_name", get_local_name(), EOS.Lobby.LobbyAttributeVisibility.Public)
	_hlobby.add_attribute("lobby_public", "1" if public_lobby else "0", EOS.Lobby.LobbyAttributeVisibility.Public)
	await _hlobby.update_async()

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
	await disconnect_lobby_async()

	await get_node("/root/EOSBootstrap").wait_until_ready()

	var hlobbies : Node = _get_hlobbies()
	if hlobbies == null:
		push_error("Lobby: HLobbies autoload not found – can't join via EOS.")
		return ERR_UNAVAILABLE

	var query := lobby_id.strip_edges()
	if query == "":
		connection_failed.emit()
		return ERR_INVALID_PARAMETER
	# If the user explicitly joins by ID, don't keep it hidden locally.
	_hidden_public_lobbies.erase(query)

	# Join by full EOS lobby ID.
	var results = await hlobbies.search_by_lobby_id_async(query)
	if results == null or results.is_empty():
		push_error("Lobby: no EOS lobby found for id: %s" % query)
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
		push_error("Lobby: EOS join_async failed for id/code: %s" % query)
		connection_failed.emit()
		return FAILED

	_hlobby = lobby
	current_lobby_id = str(lobby.lobby_id)
	current_short_code = ""
	_using_eos = true
	_current_lobby_public = true

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
	request_match_state()
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
	await disconnect_lobby_async()
	get_tree().change_scene_to_file("res://multiplayer/ConnectScreen.tscn")


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
	if players.size() < 2:
		send_system_message("Need at least 2 players to start.")
		return
	rpc("_rpc_start_game")
	_rpc_start_game()


@rpc("authority", "reliable", "call_remote")
func _rpc_start_game() -> void:
	game_starting.emit()


# ── Internal ──────────────────────────────────────────────────────────────────

func _register_self() -> void:
	var my_id : int = multiplayer.get_unique_id()
	var my_name : String = get_local_name()
	if is_host():
		my_name = _unique_name_for(my_id, my_name)
	players[my_id] = { "name": my_name }
	player_joined.emit(my_id, my_name)
	if is_host():
		_prune_stale_players_host()
		_broadcast_player_snapshot()


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
	request_match_state()
	connected.emit()


func _on_failed() -> void:
	connection_failed.emit()


func _on_server_disconnected() -> void:
	# Host left — clean up and notify.
	await disconnect_lobby_async()
	server_closed.emit()


func _on_peer_connected(id: int) -> void:
	if is_host():
		_prune_stale_players_host()
		if _using_eos and peer is EOSGMultiplayerPeer:
			# If the same EOS account reconnects with a new peer id, drop stale entries
			# so lobby size and slots remain accurate.
			var new_puid := str((peer as EOSGMultiplayerPeer).get_peer_user_id(id))
			if new_puid != "":
				var stale_pids : Array[int] = []
				for existing_id : int in players.keys():
					if existing_id == id or existing_id == multiplayer.get_unique_id():
						continue
					var existing_puid := str((peer as EOSGMultiplayerPeer).get_peer_user_id(existing_id))
					if existing_puid != "" and existing_puid == new_puid:
						stale_pids.append(existing_id)
				for stale_id in stale_pids:
					players.erase(stale_id)
					player_left.emit(stale_id)
				if not stale_pids.is_empty():
					_broadcast_player_snapshot()

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
	# Keep room-code/lobby-id authoritative from host so everyone sees the same value.
	rpc_id(id, "_rpc_sync_lobby_identity", current_lobby_id, current_short_code)
	# Also sync current match state so late-joiners can route directly into a live game.
	rpc_id(id, "_rpc_set_match_state", match_in_progress, active_map_path, active_gamemode, active_buff)


func _on_peer_disconnected(id: int) -> void:
	# Compute display name BEFORE erasing so deduplication still works.
	var p_name : String = display_name(id)
	players.erase(id)
	player_left.emit(id)
	# Host broadcasts the leave message.
	if is_host():
		_prune_stale_players_host()
		send_system_message("%s left the game." % p_name)
		_broadcast_player_snapshot()


## Returns the stored (already-deduplicated) name for a peer.
func display_name(pid: int) -> String:
	if not players.has(pid):
		return "Player %d" % pid
	return str(players[pid]["name"])


@rpc("any_peer", "reliable")
func _rpc_register_player(id: int, p_name: String) -> void:
	if is_host():
		var was_new : bool = not players.has(id)
		var unique_name : String = _unique_name_for(id, p_name)
		if was_new:
			players[id] = { "name": unique_name }
			player_joined.emit(id, unique_name)
		else:
			var prev_name : String = str(players[id]["name"])
			players[id]["name"] = unique_name
			if prev_name != unique_name:
				player_renamed.emit(id, unique_name)
		if unique_name != p_name:
			rpc_id(id, "_rpc_set_your_name", unique_name)
		_broadcast_player_snapshot()
		return

	# Clients trust host snapshot; this keeps local state responsive until sync arrives.
	var is_new : bool = not players.has(id)
	if is_new:
		players[id] = { "name": p_name }
		player_joined.emit(id, p_name)
		return
	var prev_client_name : String = str(players[id]["name"])
	if prev_client_name != p_name:
		players[id]["name"] = p_name
		player_renamed.emit(id, p_name)


## Called on the client when the host assigned them a different name due to a duplicate.
@rpc("authority", "reliable")
func _rpc_set_your_name(assigned_name: String) -> void:
	var my_id : int = multiplayer.get_unique_id()
	if players.has(my_id):
		players[my_id]["name"] = assigned_name
	player_renamed.emit(my_id, assigned_name)


func _broadcast_player_snapshot() -> void:
	if not is_host() or not multiplayer.has_multiplayer_peer():
		return
	_prune_stale_players_host()
	var snapshot : Dictionary = {}
	for pid : int in players.keys():
		snapshot[pid] = str(players[pid]["name"])
	rpc("_rpc_sync_players", snapshot)
	_rpc_sync_players(snapshot)
	rpc("_rpc_sync_lobby_identity", current_lobby_id, current_short_code)
	_rpc_sync_lobby_identity(current_lobby_id, current_short_code)


func _prune_stale_players_host() -> void:
	if not is_host() or not multiplayer.has_multiplayer_peer():
		return
	var active_ids : Dictionary = {}
	active_ids[multiplayer.get_unique_id()] = true
	for pid : int in multiplayer.get_peers():
		active_ids[pid] = true
	var stale_ids : Array[int] = []
	for pid : int in players.keys():
		if not active_ids.has(pid):
			stale_ids.append(pid)
	for stale_id in stale_ids:
		players.erase(stale_id)
		player_left.emit(stale_id)


@rpc("authority", "reliable", "call_remote")
func _rpc_sync_players(snapshot: Dictionary) -> void:
	var incoming : Dictionary = {}
	for key in snapshot.keys():
		var pid : int = int(key)
		incoming[pid] = str(snapshot[key])

	var to_remove : Array[int] = []
	for pid : int in players.keys():
		if not incoming.has(pid):
			to_remove.append(pid)
	for pid in to_remove:
		players.erase(pid)
		player_left.emit(pid)

	for pid : int in incoming.keys():
		var final_name : String = str(incoming[pid])
		if not players.has(pid):
			players[pid] = { "name": final_name }
			player_joined.emit(pid, final_name)
			continue
		var old_name : String = str(players[pid]["name"])
		if old_name != final_name:
			players[pid]["name"] = final_name
			player_renamed.emit(pid, final_name)


## Sent by the host to all OTHER clients when a player's name was deduplicated.
@rpc("authority", "reliable")
func _rpc_notify_rename(id: int, new_name: String) -> void:
	if players.has(id):
		players[id]["name"] = new_name
	player_renamed.emit(id, new_name)


func _generate_short_code(length: int = 6) -> String:
	const ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var out := ""
	for i in length:
		out += ALPHABET[rng.randi_range(0, ALPHABET.length() - 1)]
	return out


@rpc("authority", "reliable", "call_remote")
func _rpc_sync_lobby_identity(lobby_id: String, short_code: String) -> void:
	current_lobby_id = lobby_id
	current_short_code = short_code


func begin_match(map_path: String, gamemode: String, buff: String) -> void:
	if not is_host():
		return
	_set_match_state(true, map_path, gamemode, buff)
	rpc("_rpc_set_match_state", true, map_path, gamemode, buff)


func end_match() -> void:
	if not is_host():
		return
	_set_match_state(false, "", "", "")
	rpc("_rpc_set_match_state", false, "", "", "")


func request_match_state() -> void:
	if is_host() or not multiplayer.has_multiplayer_peer():
		return
	rpc_id(1, "_rpc_request_match_state")


@rpc("any_peer", "reliable")
func _rpc_request_match_state() -> void:
	if not is_host():
		return
	var requester_id : int = multiplayer.get_remote_sender_id()
	rpc_id(requester_id, "_rpc_set_match_state", match_in_progress, active_map_path, active_gamemode, active_buff)


@rpc("authority", "reliable", "call_remote")
func _rpc_set_match_state(in_progress: bool, map_path: String, gamemode: String, buff: String) -> void:
	_set_match_state(in_progress, map_path, gamemode, buff)


@rpc("authority", "reliable", "call_remote")
func _rpc_host_disbanding() -> void:
	if is_host():
		return
	await disconnect_lobby_async()
	server_closed.emit()


func _set_match_state(in_progress: bool, map_path: String, gamemode: String, buff: String) -> void:
	match_in_progress = in_progress
	active_map_path = map_path
	active_gamemode = gamemode
	active_buff = buff
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		if in_progress:
			gs.selected_map = map_path
			gs.selected_gamemode = gamemode
			gs.selected_buff = buff
	match_state_changed.emit(in_progress, map_path)
