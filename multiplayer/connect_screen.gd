extends Control

## Create/Join lobby screen with EOS lobby browser.

@onready var status_label : Label    = $VBox/StatusLabel
@onready var name_edit    : LineEdit = $VBox/NameRow/NameEdit
@onready var back_btn     : Button   = $VBox/BackBtn

@onready var create_tab_btn : Button = get_node_or_null("VBox/ModeRow/CreateTabBtn")
@onready var join_tab_btn   : Button = $VBox/ModeRow/JoinTabBtn

@onready var create_panel   : VBoxContainer = get_node_or_null("VBox/CreatePanel") as VBoxContainer
@onready var public_toggle  : CheckBox = get_node_or_null("VBox/CreatePanel/PublicToggle") as CheckBox
@onready var create_btn     : Button   = get_node_or_null("VBox/CreatePanel/CreateBtn") as Button

@onready var join_panel     : VBoxContainer = $VBox/JoinPanel
@onready var code_edit      : LineEdit = $VBox/JoinPanel/CodeRow/CodeEdit
@onready var address_row    : HBoxContainer = $VBox/JoinPanel/AddressRow
@onready var address_edit   : LineEdit = $VBox/JoinPanel/AddressRow/AddressEdit
@onready var refresh_btn    : Button   = $VBox/JoinPanel/RefreshBtn
@onready var lobby_list     : ItemList = $VBox/JoinPanel/LobbyList
@onready var join_btn       : Button   = $VBox/JoinPanel/JoinBtn

@onready var lobby : Node = get_node("/root/GameLobby")
var _public_lobbies : Array[Dictionary] = []

# ─ Loading overlay (built at runtime) ─
var _loading_overlay  : CanvasLayer = null
var _loading_label    : Label   = null
var _loading_msg_base : String  = ""
var _dot_timer        : float   = 0.0
var _dot_count        : int     = 0
var _loading_active   : bool    = false
var _join_connected_fired : bool = false
var _scene_transitioning  : bool = false


func _resolve_create_paths() -> void:
	# Support both scene layouts:
	# 1) VBox/CreatePanel
	# 2) VBox/ModeRow/CreatePanel
	if create_panel == null:
		create_panel = get_node_or_null("VBox/ModeRow/CreatePanel") as VBoxContainer
	if public_toggle == null:
		public_toggle = get_node_or_null("VBox/ModeRow/CreatePanel/PublicToggle") as CheckBox
	if create_btn == null:
		create_btn = get_node_or_null("VBox/ModeRow/CreatePanel/CreateBtn") as Button


func _process(delta: float) -> void:
	if not _loading_active:
		return
	_dot_timer += delta
	if _dot_timer >= 0.45:
		_dot_timer = 0.0
		_dot_count = (_dot_count + 1) % 4
		_loading_label.text = _loading_msg_base + ".".repeat(_dot_count)


func _show_loading(msg: String) -> void:
	if _loading_overlay == null:
		_build_loading_overlay()
	_loading_msg_base = msg
	_loading_label.text = msg
	_loading_overlay.visible = true
	_loading_active = true
	_dot_timer = 0.0
	_dot_count = 0


func _hide_loading() -> void:
	_loading_active = false
	if _loading_overlay:
		_loading_overlay.visible = false


func _build_loading_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.name = "LoadingLayer"
	layer.layer = 100
	add_child(layer)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.72)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)

	_loading_label = Label.new()
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 28)
	_loading_label.add_theme_color_override("font_color", Color.WHITE)
	_loading_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_loading_label)

	_loading_overlay = layer



func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_resolve_create_paths()
	if create_tab_btn:
		create_tab_btn.pressed.connect(func() -> void: _set_mode_create())
	join_tab_btn.pressed.connect(func() -> void: _set_mode_join())
	create_btn.pressed.connect(_on_create_lobby)
	join_btn.pressed.connect(_on_join)
	refresh_btn.pressed.connect(_refresh_public_lobbies)
	lobby_list.item_selected.connect(_on_lobby_selected)
	back_btn.pressed.connect(_on_back)
	name_edit.text_changed.connect(_on_name_changed)

	# Only wire connected signal for the async join path.
	# Host navigates manually after await completes.
	lobby.connection_failed.connect(_on_connection_failed)

	# Pre-fill name only if a real name was previously saved.
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		if gs.player_name != "":
			name_edit.text = gs.player_name
	name_edit.placeholder_text = "Enter your name…"
	if public_toggle:
		public_toggle.button_pressed = true
	_apply_button_styles()
	if public_toggle:
		_apply_checkbox_style(public_toggle)

	# Gate the screen until EOS bootstrap has attempted login.
	_set_actions_enabled(false)
	await _await_eos_bootstrap_ready()
	_set_actions_enabled(true)

	_update_ui_for_mode()
	_set_mode_create()
	_on_name_changed(name_edit.text)


func _update_ui_for_mode() -> void:
	var eos_mode : bool = _eos_available()
	address_row.visible = not eos_mode
	refresh_btn.visible = eos_mode
	lobby_list.visible = eos_mode

	if eos_mode:
		status_label.text = "Create a public/private lobby, or join from public list/code."
	else:
		status_label.text = "EOS not ready - using direct IP join."


func _set_mode_create() -> void:
	if create_panel:
		create_panel.visible = true
	join_panel.visible = false
	if create_tab_btn:
		create_tab_btn.disabled = true
	join_tab_btn.disabled = false


func _set_mode_join() -> void:
	if create_panel:
		create_panel.visible = false
	join_panel.visible = true
	if create_tab_btn:
		create_tab_btn.disabled = false
	join_tab_btn.disabled = true
	if _eos_available():
		_refresh_public_lobbies()


func _set_actions_enabled(enabled: bool) -> void:
	if create_tab_btn:
		create_tab_btn.disabled = not enabled
	if join_tab_btn:
		join_tab_btn.disabled = not enabled
	if create_btn:
		create_btn.disabled = not enabled
	if join_btn:
		join_btn.disabled = not enabled
	if refresh_btn:
		refresh_btn.disabled = not enabled
	if back_btn:
		back_btn.disabled = not enabled
	if name_edit:
		name_edit.editable = enabled
	if code_edit:
		code_edit.editable = enabled
	if address_edit:
		address_edit.editable = enabled


func _await_eos_bootstrap_ready() -> void:
	if not has_node("/root/EOSBootstrap"):
		return
	var bootstrap : Node = get_node("/root/EOSBootstrap")
	if bootstrap.is_ready:
		return
	_show_loading("Connecting to EOS account")
	await bootstrap.wait_until_ready()
	_hide_loading()


func _is_valid_name(raw: String) -> bool:
	var n := raw.strip_edges()
	if n == "":
		return false
	# Disallow any whitespace in names.
	for c in n:
		if c == " " or c == "\t" or c == "\n" or c == "\r":
			return false
	return true


func _on_name_changed(new_text: String) -> void:
	var ok := _is_valid_name(new_text)
	create_btn.disabled = not ok
	join_btn.disabled = not ok
	if create_tab_btn:
		create_tab_btn.disabled = not ok or (create_panel != null and create_panel.visible)
	join_tab_btn.disabled = not ok or join_panel.visible
	if not ok:
		status_label.text = "Enter a name (no spaces) to enable Create Game / Join Game."


func _eos_available() -> bool:
	if not has_node("/root/EOSBootstrap"):
		return false
	return get_node("/root/EOSBootstrap").is_ready


## Returns false and shows an error if the name is empty.
func _save_name() -> bool:
	var n := name_edit.text.strip_edges()
	if not _is_valid_name(n):
		status_label.text = "Please enter a valid name with no spaces."
		name_edit.grab_focus()
		return false
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.player_name = n
	# Refresh the EOS display name to match.
	if has_node("/root/EOSBootstrap"):
		get_node("/root/EOSBootstrap").refresh_display_name()
	return true


func _on_create_lobby() -> void:
	if not _save_name():
		return
	_show_loading("Creating game")
	create_btn.disabled = true
	join_btn.disabled = true
	refresh_btn.disabled = true
	var is_public := public_toggle.button_pressed if public_toggle else true
	var err : int = await lobby.host_lobby(7777, is_public)
	_hide_loading()
	if err != OK:
		status_label.text = "Failed to create game."
		create_btn.disabled = false
		join_btn.disabled = false
		refresh_btn.disabled = false
		return
	# Navigate to lobby room (same as when a client connects).
	_on_connected()


func _on_join() -> void:
	if not _save_name():
		return
	var target : String
	if _eos_available():
		target = code_edit.text.strip_edges()
		if target == "":
			status_label.text = "Please enter a lobby ID."
			return
		_show_loading("Joining lobby %s" % target)
	else:
		target = _decode_enet_code_or_address(code_edit.text.strip_edges())
		if target == "":
			target = address_edit.text.strip_edges()
		if target == "":
			target = "127.0.0.1"
		_show_loading("Connecting to %s" % target)

	join_btn.disabled = true
	create_btn.disabled = true
	refresh_btn.disabled = true
	_join_connected_fired = false
	# Ensure no stale connection from a previous failed attempt.
	if lobby.connected.is_connected(_on_connected):
		lobby.connected.disconnect(_on_connected)
	# Wire connected signal one-shot — fires asynchronously when peer connects.
	lobby.connected.connect(_on_lobby_connected_signal, CONNECT_ONE_SHOT)
	var err : int = await lobby.join_lobby(target)
	_hide_loading()
	if err != OK:
		if lobby.connected.is_connected(_on_lobby_connected_signal):
			lobby.connected.disconnect(_on_lobby_connected_signal)
		status_label.text = "Connection failed. Check the code and try again."
		create_btn.disabled = false
		join_btn.disabled = false
		refresh_btn.disabled = false
		return

	# EOS can occasionally establish after join_lobby() returns OK but before
	# the connected signal reaches this scene. Avoid getting stuck on this screen.
	if _eos_available() and not _join_connected_fired:
		_show_loading("Finalizing connection")
		await get_tree().create_timer(1.2).timeout
		_hide_loading()
		if not _join_connected_fired:
			_on_connected()


func _on_lobby_connected_signal() -> void:
	_join_connected_fired = true
	_on_connected()


func _on_connected() -> void:
	if _scene_transitioning:
		return
	_scene_transitioning = true
	status_label.text = "Connected!"
	lobby.request_match_state()
	await get_tree().create_timer(0.4).timeout
	if lobby.match_in_progress and lobby.active_map_path != "":
		if has_node("/root/GameSettings"):
			var gs : Node = get_node("/root/GameSettings")
			gs.selected_map = lobby.active_map_path
			gs.selected_gamemode = lobby.active_gamemode
			gs.selected_buff = lobby.active_buff
		get_tree().change_scene_to_file(lobby.active_map_path)
		return
	get_tree().change_scene_to_file("res://multiplayer/LobbyRoom.tscn")


func _on_connection_failed() -> void:
	_hide_loading()
	status_label.text = "Connection failed. Try again."
	create_btn.disabled = false
	join_btn.disabled = false
	refresh_btn.disabled = false


func _refresh_public_lobbies() -> void:
	if not _eos_available():
		return
	refresh_btn.disabled = true
	lobby_list.clear()
	_show_loading("Finding public lobbies")
	_public_lobbies = await lobby.list_public_lobbies()
	_hide_loading()
	for i in _public_lobbies.size():
		var lb := _public_lobbies[i]
		var lobby_id := str(lb.get("lobby_id", ""))
		var line := "%s  [%d/%d]  Code: %s" % [
			str(lb.get("host_name", "Host")),
			int(lb.get("members", 0)),
			int(lb.get("max_members", 8)),
			lobby_id,
		]
		lobby_list.add_item(line)
	refresh_btn.disabled = false
	if _public_lobbies.is_empty():
		status_label.text = "No public lobbies found. Use lobby ID or create one."
	else:
		status_label.text = "Select a public lobby or paste a lobby ID."


func _on_lobby_selected(index: int) -> void:
	if index < 0 or index >= _public_lobbies.size():
		return
	code_edit.text = str(_public_lobbies[index].get("lobby_id", ""))


func _on_back() -> void:
	await lobby.disconnect_lobby_async()
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


func _apply_button_styles() -> void:
	var buttons : Array[Button] = [
		join_tab_btn, create_btn, refresh_btn, join_btn, back_btn,
	]
	if create_tab_btn:
		buttons.append(create_tab_btn)
	for btn in buttons:
		var normal := StyleBoxFlat.new()
		normal.bg_color = Color(0.12, 0.22, 0.35, 0.95)
		normal.border_color = Color(0.35, 0.7, 1.0, 0.85)
		normal.set_border_width_all(2)
		normal.set_corner_radius_all(10)
		normal.set_content_margin_all(8)
		btn.add_theme_stylebox_override("normal", normal)

		var hover := normal.duplicate() as StyleBoxFlat
		hover.bg_color = Color(0.18, 0.32, 0.48, 0.95)
		btn.add_theme_stylebox_override("hover", hover)
		btn.add_theme_stylebox_override("focus", hover)

		var pressed := normal.duplicate() as StyleBoxFlat
		pressed.bg_color = Color(0.08, 0.15, 0.24, 0.95)
		btn.add_theme_stylebox_override("pressed", pressed)
		btn.add_theme_font_size_override("font_size", 18)
		btn.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))


func _apply_checkbox_style(cb: CheckBox) -> void:
	cb.add_theme_font_size_override("font_size", 17)
	cb.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))


func _decode_enet_code_or_address(raw: String) -> String:
	if raw == "":
		return ""
	if not raw.begins_with("M-"):
		return raw
	var payload := raw.substr(2)
	var decoded := Marshalls.base64_to_utf8(payload)
	if ":" in decoded:
		return decoded.split(":", false, 1)[0]
	return decoded
