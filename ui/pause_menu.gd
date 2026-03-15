extends CanvasLayer

## Pause-menu overlay for multiplayer.  Does NOT pause the tree;
## just shows UI and releases the cursor.

signal resumed          ## Emitted when the player closes the menu.
signal back_to_menu     ## Emitted when "Back to Menu" is pressed.

@onready var panel       : PanelContainer = $Panel
@onready var fov_slider  : HSlider        = $Panel/VBox/FOVRow/FOVSlider
@onready var fov_label   : Label          = $Panel/VBox/FOVRow/FOVValue
@onready var sens_slider : HSlider        = $Panel/VBox/SensRow/SensSlider
@onready var sens_label  : Label          = $Panel/VBox/SensRow/SensValue
@onready var fullscreen_btn : CheckButton = $Panel/VBox/FullscreenRow/FullscreenBtn

var _is_open : bool = false


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep processing even if tree paused

	# Initialise sliders from GameSettings.
	var gs : Node = _gs()
	if gs:
		fov_slider.value  = gs.fov
		fov_label.text    = "%d" % int(gs.fov)
		sens_slider.value = gs.mouse_sensitivity
		sens_label.text   = "%.2f" % gs.mouse_sensitivity
		fullscreen_btn.button_pressed = gs.fullscreen

	fov_slider.value_changed.connect(_on_fov_changed)
	sens_slider.value_changed.connect(_on_sens_changed)
	fullscreen_btn.toggled.connect(_on_fullscreen_toggled)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if _is_open:
			close()
		else:
			open()
		get_viewport().set_input_as_handled()


func open() -> void:
	_is_open = true
	visible  = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	_is_open = false
	visible  = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	resumed.emit()


func _on_resume_pressed() -> void:
	close()


func _on_back_to_menu_pressed() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	back_to_menu.emit()
	if has_node("/root/GameLobby"):
		var lobby : Node = get_node("/root/GameLobby")
		await lobby.disconnect_lobby_async()
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


func _on_exit_pressed() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if has_node("/root/GameLobby"):
		var lobby : Node = get_node("/root/GameLobby")
		await lobby.disconnect_lobby_async()
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


func _on_fov_changed(value: float) -> void:
	fov_label.text = "%d" % int(value)
	var gs : Node = _gs()
	if gs:
		gs.fov = value


func _on_fullscreen_toggled(enabled: bool) -> void:
	var gs : Node = _gs()
	if gs:
		gs.fullscreen = enabled
		gs._apply_display()


func _on_sens_changed(value: float) -> void:
	sens_label.text = "%.2f" % value
	var gs : Node = _gs()
	if gs:
		gs.mouse_sensitivity = value


func _gs() -> Node:
	if has_node("/root/GameSettings"):
		return get_node("/root/GameSettings")
	return null
