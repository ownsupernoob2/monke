extends Node3D

## 3D lobby room – players appear as their in-game model standing side by side.

@onready var player_container : Node3D  = $PlayerContainer
@onready var start_btn        : Button  = $UILayer/BottomBar/StartBtn
@onready var back_btn         : Button  = $UILayer/BottomBar/BackBtn
@onready var count_label      : Label   = $UILayer/TopBar/CountLabel
@onready var ip_label         : Label   = $UILayer/TopBar/IPLabel
@onready var show_ip_btn      : Button  = $UILayer/TopBar/ShowIPBtn
@onready var copy_code_btn    : Button  = $UILayer/TopBar/CopyCodeBtn
@onready var public_toggle    : CheckBox = $UILayer/TopBar/PublicToggle
@onready var rounds_spin      : SpinBox = $UILayer/BottomBar/RoundsSpinBox
@onready var rounds_label     : Label   = $UILayer/BottomBar/RoundsLabel

@onready var lobby : Node = get_node("/root/GameLobby")

var _public_ip  : String = ""
var _lan_ip     : String = ""
var _ip_visible : bool   = false

const PLAYER_SCENE : String = "res://components/Player.tscn"

var _loading_layer : CanvasLayer = null
var _loading_label : Label = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_style_lobby_buttons()

	start_btn.visible = lobby.is_host()
	start_btn.pressed.connect(_on_start)
	back_btn.pressed.connect(_on_back)

	# Rounds selector – host only.
	rounds_spin.visible = lobby.is_host()
	rounds_label.visible = lobby.is_host()
	rounds_spin.value = 3
	rounds_spin.value_changed.connect(_on_rounds_changed)

	# Show public IP (ENet) or room code (EOS) so the host can share it.
	_lan_ip = _get_local_ip()
	ip_label.text = "Code: fetching..."
	show_ip_btn.pressed.connect(_on_toggle_ip)
	copy_code_btn.pressed.connect(_on_copy_code)
	public_toggle.visible = lobby.is_host() and lobby.eos_available()
	public_toggle.button_pressed = lobby.is_current_lobby_public()
	if public_toggle.visible:
		public_toggle.toggled.connect(_on_public_toggled)

	if lobby.eos_available():
		# EOS mode – show/mask the room code.
		_refresh_ip_label()
	else:
		# ENet mode – fetch public IP as before.
		ip_label.text = "IP: fetching..."
		copy_code_btn.visible = true
		_fetch_public_ip()

	lobby.player_joined.connect(_on_player_joined)
	lobby.player_left.connect(_on_player_left)
	lobby.player_renamed.connect(_on_player_renamed)
	lobby.game_starting.connect(_on_game_starting)
	lobby.server_closed.connect(_on_server_closed)
	lobby.match_state_changed.connect(_on_match_state_changed)
	lobby.ensure_local_registered()

	# Late-join safety: if this client landed here while a match is live,
	# route directly into the running map.
	if lobby.match_in_progress and lobby.active_map_path != "":
		_on_match_state_changed(true, lobby.active_map_path)
		return

	# Add chat overlay.
	var chat_scene := load("res://ui/Chat.tscn")
	if chat_scene:
		add_child(chat_scene.instantiate())

	# Create display models for every player already in the lobby.
	var ordered_ids : Array = lobby.players.keys()
	ordered_ids.sort()
	for id : int in ordered_ids:
		var p_name : String = lobby.players[id]["name"]
		_spawn_player_model(id, p_name)
	_update_count()


# ── Player model display ──────────────────────────────────────────────────────

func _spawn_player_model(id: int, _p_name: String) -> void:
	var scene : PackedScene = load(PLAYER_SCENE)
	if scene == null:
		push_error("LobbyRoom: could not load Player.tscn")
		return

	var player_node : Node = scene.instantiate()
	player_node.name = "P_%d" % id

	# Mark as a display puppet: no camera, no input, no HUD, torso visible.
	player_node.set_multiplayer_authority(id)
	player_node.setup_network(false)

	# Face toward the lobby camera (rotate 180° around Y).
	player_node.rotation.y = PI

	# Space models evenly along X. Player origin is at feet → y = 0.
	var slot : int = player_container.get_child_count()
	player_node.position = Vector3(slot * 1.6 - 3.2, 0.0, 0.0)

	player_container.add_child(player_node)  # triggers _ready() → strips camera/HUD

	# Freeze all processing so puppet physics don't run in the lobby.
	player_node.set_process_mode(Node.PROCESS_MODE_DISABLED)


func _remove_player_model(id: int) -> void:
	var node : Node = player_container.get_node_or_null("P_%d" % id)
	if node:
		node.queue_free()
	await get_tree().create_timer(0.1).timeout
	_reposition_models()


func _reposition_models() -> void:
	var models : Array[Node] = []
	for child : Node in player_container.get_children():
		models.append(child)
	models.sort_custom(func(a: Node, b: Node) -> bool:
		var a_id := int(str(a.name).trim_prefix("P_"))
		var b_id := int(str(b.name).trim_prefix("P_"))
		return a_id < b_id
	)
	var i : int = 0
	for child : Node in models:
		child.position.x = i * 1.6 - 3.2
		i += 1


func _update_count() -> void:
	count_label.text = "Players: %d / %d" % [lobby.players.size(), lobby.MAX_PLAYERS]
	if lobby.is_host():
		start_btn.disabled = lobby.players.size() < 2


# ── Signals ───────────────────────────────────────────────────────────────────

func _on_player_joined(id: int, p_name: String) -> void:
	if player_container.has_node("P_%d" % id):
		return
	_spawn_player_model(id, p_name)
	_reposition_models()
	_update_count()


## Update the floating name label on a model whose name was deduplicated.
func _on_player_renamed(id: int, new_name: String) -> void:
	var node := player_container.get_node_or_null("P_%d" % id)
	if node == null:
		return
	var lbl := node.get_node_or_null("NameLabel3D")
	if lbl:
		lbl.text = new_name


func _on_player_left(id: int) -> void:
	_remove_player_model(id)
	_update_count()


func _on_game_starting() -> void:
	get_tree().change_scene_to_file("res://multiplayer/SelectionScreen.tscn")


func _on_server_closed() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.disconnect_message = "Host left the lobby."
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


func _on_start() -> void:
	if lobby.players.size() < 2:
		count_label.text = "Players: %d / %d  (Need at least 2 to start)" % [lobby.players.size(), lobby.MAX_PLAYERS]
		return
	lobby.start_game()


func _on_back() -> void:
	_show_loading("Closing lobby")
	_set_ui_enabled(false)
	await lobby.disconnect_lobby_async()
	_hide_loading()
	if has_node("/root/GameSettings"):
		get_node("/root/GameSettings").clear_chat_history()
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


func _notification(what: int) -> void:
	# Host leaving the room via window close should disband the lobby.
	if what == NOTIFICATION_WM_CLOSE_REQUEST and lobby and lobby.is_host():
		lobby.disconnect_lobby_async()


func _on_rounds_changed(value: float) -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.round_count = int(value)


func _on_match_state_changed(in_progress: bool, map_path: String) -> void:
	if not in_progress or map_path == "":
		return
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.selected_map = lobby.active_map_path
		gs.selected_gamemode = lobby.active_gamemode
		gs.selected_buff = lobby.active_buff
	get_tree().change_scene_to_file(map_path)


func _get_local_ip() -> String:
	for addr : String in IP.get_local_addresses():
		# Skip loopback and IPv6; pick the first LAN address.
		if addr.begins_with("127.") or addr.begins_with("::") or ":" in addr:
			continue
		return addr
	return "127.0.0.1"


# ── Public IP fetch  ──────────────────────────────────────────────────────────

func _fetch_public_ip() -> void:
	var http := HTTPRequest.new()
	http.name = "IPFetcher"
	add_child(http)
	http.request_completed.connect(_on_ip_response.bind(http))
	var err : int = http.request("https://api.ipify.org")
	if err != OK:
		ip_label.text = "IP: (unavailable)"
		http.queue_free()


func _on_ip_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		_public_ip = body.get_string_from_utf8().strip_edges()
	else:
		_public_ip = _get_local_ip()  # fallback to LAN IP
	_refresh_ip_label()


func _on_toggle_ip() -> void:
	_ip_visible = not _ip_visible
	_refresh_ip_label()


func _on_copy_code() -> void:
	var code : String = lobby.current_short_code
	if code.is_empty():
		if lobby.eos_available():
			code = lobby.current_lobby_id
		else:
			code = _enet_share_code()
	if code.is_empty():
		return
	DisplayServer.clipboard_set(code)
	var prev : String = copy_code_btn.text
	copy_code_btn.text = "Copied!"
	await get_tree().create_timer(1.8).timeout
	copy_code_btn.text = prev


func _refresh_ip_label() -> void:
	# EOS mode – display the room code.
	if lobby.eos_available():
		var code : String = lobby.current_short_code
		if code == "":
			code = lobby.current_lobby_id
		if code == "":
			ip_label.text = "Code: (not hosting)"
			show_ip_btn.text = "Show"
			copy_code_btn.visible = false
			return
		copy_code_btn.visible = true
		if _ip_visible:
			ip_label.text = "Room code: %s" % code
			show_ip_btn.text = "Hide"
		else:
			ip_label.text = "Room code: ******"
			show_ip_btn.text = "Show"
		return

	# ENet mode – display LAN / WAN IPs.
	if _public_ip == "":
		ip_label.text = "IP: fetching..."
		show_ip_btn.text = "Show"
		return
	var enet_code := _enet_share_code()
	if _ip_visible:
		# LAN IP = for players on the same Wi-Fi/network (including yourself).
		# WAN IP = for players joining over the internet (needs port forward 4433).
		ip_label.text = "LAN: %s  |  WAN: %s  |  Code: %s" % [_lan_ip, _public_ip, enet_code]
		show_ip_btn.text = "Hide"
	else:
		ip_label.text = "IP/Code: ***********"
		show_ip_btn.text = "Show"


func _enet_share_code() -> String:
	var target := "%s:%d" % [_public_ip if _public_ip != "" else _lan_ip, lobby.DEFAULT_PORT]
	return "M-" + Marshalls.utf8_to_base64(target)


func _style_lobby_buttons() -> void:
	var buttons : Array[Button] = [start_btn, back_btn, show_ip_btn, copy_code_btn]
	for btn in buttons:
		var normal := StyleBoxFlat.new()
		normal.bg_color = Color(0.1, 0.22, 0.18, 0.95)
		normal.border_color = Color(0.35, 0.85, 0.6, 0.85)
		normal.set_border_width_all(2)
		normal.set_corner_radius_all(10)
		normal.set_content_margin_all(8)
		btn.add_theme_stylebox_override("normal", normal)

		var hover := normal.duplicate() as StyleBoxFlat
		hover.bg_color = Color(0.15, 0.32, 0.26, 0.95)
		btn.add_theme_stylebox_override("hover", hover)
		btn.add_theme_stylebox_override("focus", hover)

		var pressed := normal.duplicate() as StyleBoxFlat
		pressed.bg_color = Color(0.07, 0.15, 0.12, 0.95)
		btn.add_theme_stylebox_override("pressed", pressed)

	public_toggle.add_theme_font_size_override("font_size", 15)
	public_toggle.add_theme_color_override("font_color", Color(0.9, 0.98, 0.94))


func _on_public_toggled(pressed: bool) -> void:
	public_toggle.disabled = true
	var ok : bool = await lobby.set_current_lobby_public(pressed)
	public_toggle.disabled = false
	if not ok:
		public_toggle.set_pressed_no_signal(not pressed)


func _set_ui_enabled(enabled: bool) -> void:
	start_btn.disabled = not enabled
	back_btn.disabled = not enabled
	show_ip_btn.disabled = not enabled
	copy_code_btn.disabled = not enabled
	rounds_spin.editable = enabled
	if public_toggle:
		public_toggle.disabled = not enabled


func _show_loading(text: String) -> void:
	if _loading_layer == null:
		_loading_layer = CanvasLayer.new()
		_loading_layer.layer = 100
		add_child(_loading_layer)
		var bg := ColorRect.new()
		bg.color = Color(0.0, 0.0, 0.0, 0.72)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		_loading_layer.add_child(bg)
		_loading_label = Label.new()
		_loading_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_loading_label.add_theme_font_size_override("font_size", 30)
		_loading_label.add_theme_color_override("font_color", Color.WHITE)
		_loading_layer.add_child(_loading_label)
	_loading_label.text = text
	_loading_layer.visible = true


func _hide_loading() -> void:
	if _loading_layer:
		_loading_layer.visible = false
