extends Control

## Connecting screen – host or join with lobby code, enter player name,
## then go to 3D lobby room.
##
## When EOS is available (EOSBootstrap.is_ready == true):
##   • Host button creates an EOS lobby and shows the room code.
##   • Join button accepts the room code and connects via EOS P2P.
## When EOS is not available (plugin missing / credentials not set):
##   • Falls back to the old address:port flow so LAN play still works.

@onready var status_label : Label    = $VBox/StatusLabel
@onready var host_btn     : Button   = $VBox/HostBtn
@onready var join_btn     : Button   = $VBox/JoinBtn
@onready var code_row     : HBoxContainer = $VBox/CodeRow
@onready var code_edit    : LineEdit = $VBox/CodeRow/CodeEdit
@onready var name_edit    : LineEdit = $VBox/NameRow/NameEdit
@onready var back_btn     : Button   = $VBox/BackBtn

## Shown only in ENet-fallback mode.
@onready var address_row  : HBoxContainer = $VBox/AddressRow
@onready var address_edit : LineEdit      = $VBox/AddressRow/AddressEdit

@onready var lobby : Node = get_node("/root/GameLobby")


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	host_btn.pressed.connect(_on_host)
	join_btn.pressed.connect(_on_join)
	back_btn.pressed.connect(_on_back)

	# Only wire connected signal for the async join path.
	# Host navigates manually after await completes.
	lobby.connection_failed.connect(_on_connection_failed)

	# Pre-fill name from settings.
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		name_edit.text = gs.player_name

	_update_ui_for_mode()


func _update_ui_for_mode() -> void:
	var eos_mode : bool = _eos_available()
	# EOS mode: show code field, hide address field.
	# ENet mode: hide code field, show address field.
	code_row.visible    = eos_mode
	address_row.visible = not eos_mode

	if eos_mode:
		status_label.text = "Ready. Host or enter a room code to join."
	else:
		status_label.text = "EOS not ready – using direct IP."


func _eos_available() -> bool:
	if not has_node("/root/EOSBootstrap"):
		return false
	return get_node("/root/EOSBootstrap").is_ready


func _save_name() -> void:
	var n := name_edit.text.strip_edges()
	if n == "":
		n = "Player"
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.player_name = n
	# Refresh the EOS display name to match.
	if has_node("/root/EOSBootstrap"):
		get_node("/root/EOSBootstrap").refresh_display_name()


func _on_host() -> void:
	_save_name()
	status_label.text = "Creating lobby…"
	host_btn.disabled = true
	join_btn.disabled = true
	var err : int = await lobby.host_lobby()
	if err != OK:
		status_label.text = "Failed to create lobby."
		host_btn.disabled = false
		join_btn.disabled = false
		return
	# Navigate to lobby room (same as when a client connects).
	_on_connected()


func _on_join() -> void:
	_save_name()
	var target : String
	if _eos_available():
		target = code_edit.text.strip_edges()
		if target == "":
			status_label.text = "Please enter a room code."
			return
		status_label.text = "Joining room %s…" % target
	else:
		target = address_edit.text.strip_edges()
		if target == "":
			target = "127.0.0.1"
		status_label.text = "Connecting to %s…" % target

	host_btn.disabled = true
	join_btn.disabled = true
	# Ensure no stale connection from a previous failed attempt.
	if lobby.connected.is_connected(_on_connected):
		lobby.connected.disconnect(_on_connected)
	# Wire connected signal one-shot — fires asynchronously when peer connects.
	lobby.connected.connect(_on_connected, CONNECT_ONE_SHOT)
	var err : int = await lobby.join_lobby(target)
	if err != OK:
		if lobby.connected.is_connected(_on_connected):
			lobby.connected.disconnect(_on_connected)
		status_label.text = "Connection failed. Check the code and try again."
		host_btn.disabled = false
		join_btn.disabled = false


func _on_connected() -> void:
	status_label.text = "Connected!"
	await get_tree().create_timer(0.4).timeout
	get_tree().change_scene_to_file("res://multiplayer/LobbyRoom.tscn")


func _on_connection_failed() -> void:
	status_label.text = "Connection failed. Try again."
	host_btn.disabled = false
	join_btn.disabled = false


func _on_back() -> void:
	lobby.disconnect_lobby()
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")
