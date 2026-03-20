extends CanvasLayer

## In-game chat overlay.  Press T to open, Enter to send, Escape to cancel.
## Listens to GameLobby.chat_received for incoming messages.
## Messages are persisted in GameSettings.chat_history across scene changes.

const MAX_MESSAGES     : int   = 50
const INACTIVITY_FADE  : float = 10.0  ## seconds of inactivity before chat fades out

var _is_open        : bool  = false
var _inactive_timer : float = 0.0
var _messages : Array[Dictionary] = []  # { "sender": String, "text": String, "time": float }

@onready var chat_container : VBoxContainer = $Panel/Margin/VBox/ScrollContainer/ChatMessages
@onready var input_field    : LineEdit      = $Panel/Margin/VBox/InputRow/InputField
@onready var scroll         : ScrollContainer = $Panel/Margin/VBox/ScrollContainer
@onready var panel          : PanelContainer  = $Panel


func _ready() -> void:
	layer = 10
	input_field.visible = false
	# Make panel semi-transparent when not typing.
	panel.modulate.a = 0.4

	if has_node("/root/GameLobby"):
		GameLobby.chat_received.connect(_on_chat_received)
		GameLobby.server_closed.connect(_on_server_closed)
		GameLobby.alert_received.connect(_on_alert_received)
		GameLobby.player_joined.connect(_on_player_joined)

	input_field.text_submitted.connect(_on_text_submitted)

	# Restore messages from the previous scene (chat persistence).
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		for entry : Dictionary in gs.chat_history:
			if entry.get("type", "msg") == "alert":
				_add_alert_no_save(entry.get("text", ""))
			else:
				_add_message_no_save(entry.get("sender", ""), entry.get("text", ""))
		if gs.chat_history.is_empty():
			_add_message("", "Press T to chat")
	else:
		_add_message_no_save("", "Press T to chat")


func _process(delta: float) -> void:
	if _is_open:
		_inactive_timer = 0.0
		return
	if chat_container.get_child_count() == 0:
		panel.modulate.a = 0.0
		return
	_inactive_timer += delta
	if _inactive_timer >= INACTIVITY_FADE:
		# Smoothly fade toward translucent (keep history readable).
		panel.modulate.a = lerpf(panel.modulate.a, 0.15, delta * 1.5)
	else:
		# Keep visible while recently active.
		panel.modulate.a = 0.4


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("chat") and not _is_open:
		_open_chat()
		if is_inside_tree():
			get_viewport().set_input_as_handled()
	elif _is_open and event.is_action_pressed("ui_cancel"):
		_close_chat()
		if is_inside_tree():
			get_viewport().set_input_as_handled()


func _open_chat() -> void:
	_is_open = true
	_inactive_timer = 0.0
	input_field.visible = true
	input_field.text = ""
	input_field.grab_focus()
	panel.modulate.a = 0.85
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_chat() -> void:
	_is_open = false
	input_field.visible = false
	input_field.release_focus()
	panel.modulate.a = 0.4
	# Only re-capture the mouse if the local player is alive and in gameplay.
	if _should_capture_mouse():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Returns true only when the local player is alive in an active game round.
func _should_capture_mouse() -> bool:
	var players : Node = get_tree().current_scene.get_node_or_null("Players")
	if not players:
		return false
	for child : Node in players.get_children():
		if child is Player and child.is_local and not child.is_dead:
			return true
	return false


func _on_text_submitted(text: String) -> void:
	var msg := text.strip_edges()
	# Host-only slash commands.
	if msg.begins_with("/") and has_node("/root/GameLobby") and GameLobby.is_host():
		_handle_command(msg)
		_close_chat()
		return
	if msg != "" and has_node("/root/GameLobby"):
		var lobby : Node = get_node("/root/GameLobby")
		GameLobby.send_chat(msg)
	_close_chat()


## Broadcast a system message (yellow italic) to all players via alert channel.
## Any script can call this on the local Chat node to post a game event.
func system_message(text: String) -> void:
	if has_node("/root/GameLobby") and GameLobby.is_host():
		GameLobby.send_alert(text)
	else:
		_add_alert(text)


func _handle_command(cmd: String) -> void:
	var parts := cmd.split(" ", false, 1)
	if parts.size() < 2:
		_add_alert("Usage: /kick <name>  |  /ban <name>  |  /system <message>")
		return
	var command := parts[0].to_lower()
	var target_name := parts[1].strip_edges()
	match command:
		"/system":
			# Broadcast a host system message to all players.
			GameLobby.send_alert("[System] " + target_name)
			return
		"/kick", "/ban":
			var pid := _find_peer_by_name(target_name)
			if pid <= 0:
				_add_alert("Player '%s' not found." % target_name)
				return
			if pid == multiplayer.get_unique_id():
				_add_alert("You cannot kick yourself.")
				return
			var is_ban := (command == "/ban")
			var display := GameLobby.display_name(pid)
			var action  := "banned" if is_ban else "kicked"
			GameLobby.send_alert("%s has been %s from the game." % [display, action])
			if is_ban:
				GameLobby.ban_player(pid)
			else:
				GameLobby.kick_player(pid)
		_:
			_add_alert("Unknown command: %s" % command)


func _find_peer_by_name(name: String) -> int:
	# Match against display_name so "Player2" correctly finds the renamed duplicate.
	for id : int in GameLobby.players:
		if GameLobby.display_name(id).to_lower() == name.to_lower():
			return id
	return -1


func _on_chat_received(sender: String, text: String) -> void:
	_add_message(sender, text)


func _on_player_joined(id: int, _p_name: String) -> void:
	# Skip showing a message for the local player joining themselves.
	if id == multiplayer.get_unique_id():
		return
	# Use display_name so duplicate names show the (2), (3)… suffix.
	var name_display := GameLobby.display_name(id)
	_add_message("", "%s joined the game." % name_display)


func _on_alert_received(text: String) -> void:
	_add_alert(text)


func _add_message(sender: String, text: String) -> void:
	# Save to persistent history.
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.chat_history.append({"type": "msg", "sender": sender, "text": text})
		if gs.chat_history.size() > MAX_MESSAGES:
			gs.chat_history.pop_front()
	_add_message_no_save(sender, text)


func _add_message_no_save(sender: String, text: String) -> void:
	# Reset inactivity so the panel is visible for the new message.
	_inactive_timer = 0.0
	if not _is_open:
		panel.modulate.a = 0.4
	var label := RichTextLabel.new()
	label.fit_content = true
	label.bbcode_enabled = true
	label.scroll_active = false
	label.custom_minimum_size.x = 280
	if sender == "":
		# System message.
		label.text = "[color=yellow][i]%s[/i][/color]" % text
	else:
		label.text = "[b]%s:[/b] %s" % [sender, text]
	label.add_theme_font_size_override("normal_font_size", 14)
	chat_container.add_child(label)
	_trim_and_scroll()


func _add_alert(text: String) -> void:
	# Save to persistent history.
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.chat_history.append({"type": "alert", "text": text})
		if gs.chat_history.size() > MAX_MESSAGES:
			gs.chat_history.pop_front()
	_add_alert_no_save(text)


func _add_alert_no_save(text: String) -> void:
	_inactive_timer = 0.0
	if not _is_open:
		panel.modulate.a = 0.4
	var label := RichTextLabel.new()
	label.fit_content = true
	label.bbcode_enabled = true
	label.scroll_active = false
	label.custom_minimum_size.x = 280
	label.text = "[color=red][b]%s[/b][/color]" % text
	label.add_theme_font_size_override("normal_font_size", 14)
	chat_container.add_child(label)
	_trim_and_scroll()




func _trim_and_scroll() -> void:
	# Cap message count.
	while chat_container.get_child_count() > MAX_MESSAGES:
		chat_container.get_child(0).queue_free()
	# Wait two frames so fit_content labels finish their layout before scrolling.
	# Guard against the node having been freed while awaiting.
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if not is_inside_tree():
		return
	scroll.scroll_vertical = scroll.get_v_scroll_bar().max_value as int


func _on_server_closed() -> void:
	_add_message("", "Host left the server.")
	# Only set disconnect message if one hasn't already been set (e.g. by kick/ban).
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		if gs.disconnect_message.is_empty():
			gs.disconnect_message = "Host left the lobby."
		# Clear chat history on disconnect so a fresh session starts clean.
		gs.clear_chat_history()
	# Return to main menu after a short delay.
	await get_tree().create_timer(1.0).timeout
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")
