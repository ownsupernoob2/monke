extends Node3D

## Interactive tutorial — teaches core mechanics step by step.
## Spawns a small arena with platforms, vines, and bananas, then
## guides the player through each mechanic with on-screen prompts.
## INFO_WELCOME requires SPACE; other info steps auto-advance after a few seconds.

const PLAYER_SCENE := "res://components/Player.tscn"

const SPAWN_POS := Vector3(0, 7, 0)

# ── Tutorial steps ────────────────────────────────────────────────────────────
enum Step {
	INFO_WELCOME,
	LOOK_AROUND,
	INFO_PUSH,
	PUSH_SURFACE,
	INFO_VINE,
	GRAB_VINE,
	SWING_AND_RELEASE,
	LAND_ON_PLATFORM,
	COMBO_SWING,
	INFO_CAMERA,
	SHIFT_LOCK,
	OBSTACLE_COURSE,
	COMPLETE,
}

# Only the welcome step requires SPACE to continue.
const INFO_STEPS : Array[int] = [
	Step.INFO_WELCOME,
]

# Info steps that auto-advance after a short read delay.
const AUTO_INFO_STEPS : Array[int] = [
	Step.INFO_PUSH,
	Step.INFO_VINE,
	Step.INFO_CAMERA,
]

const INFO_AUTO_ADVANCE_TIME := 5.0

const STEP_TEXT : Dictionary = {
	Step.INFO_WELCOME:
		"Welcome to the tutorial!\n" \
		+ "A mouse is recommended — the game is mostly played with it.\n" \
		+ "If you get stuck, press R to reset your position.\n" \
		+ "Press ESC to open the menu.\n\n" \
		+ "[Press SPACE to continue]",
	Step.LOOK_AROUND:
		"Move your mouse to look around.",
	Step.INFO_PUSH:
		"Looking at a surface and clicking pushes you away from it.\n" \
		+ "Click Left or Right mouse button to push with one hand.\n" \
		+ "Click BOTH mouse buttons at the same time to push harder!",
	Step.PUSH_SURFACE:
		"Look at the platform surface below you and click to push yourself up!\n" \
		+ "Then quickly grab a vine!",
	Step.INFO_VINE:
		"See those vines hanging above?\n" \
		+ "Look at one until the crosshair turns green,\n" \
		+ "then HOLD a mouse button to grab it.\n" \
		+ "Swing by looking in a direction, then release to launch!",
	Step.GRAB_VINE:
		"Look at a vine and HOLD Left or Right Click to grab it.",
	Step.SWING_AND_RELEASE:
		"While hanging, look where you want to go.\nRelease the mouse button to launch!",
	Step.LAND_ON_PLATFORM:
		"Land on one of the platforms ahead.",
	Step.COMBO_SWING:
		"Grab a vine with one hand, release, then grab\n" \
		+ "a DIFFERENT vine with the other hand.\n" \
		+ "Alternate Left → Right → Left for combos!",
	Step.INFO_CAMERA:
		"Press Q to toggle third-person view.\n" \
		+ "Press Q again to return to first-person.",
	Step.SHIFT_LOCK:
		"Try it! Press Q twice to toggle third-person and back.",
	Step.OBSTACLE_COURSE:
		"Complete the obstacle course!\nSwing across the platforms to reach the golden finish platform.",
	Step.COMPLETE:
		"Tutorial complete! You're ready to play.",
}

var _current_step : int = Step.INFO_WELCOME
var _player       : Player = null

# ── Step tracking state ───────────────────────────────────────────────────────
var _look_total      : float = 0.0
var _grabbed_vine    : bool  = false
var _combo_reached   : bool  = false
var _toggled_shift    : bool  = false
var _prev_shift_lock  : bool  = false

# ── Step timing ─────────────────────────────────────────────────────────────
var _info_timer       : float = 0.0

# ── UI ────────────────────────────────────────────────────────────────────────
var _prompt_layer     : CanvasLayer   = null
var _prompt_label     : Label         = null
var _step_label       : Label         = null
var _skip_button      : Button        = null
var _end_buttons      : HBoxContainer = null
var _tip_label        : Label         = null


func _ready() -> void:
	_spawn_player()
	_build_ui()
	_show_step()


# ══════════════════════════════════════════════════════════════════════════════
#  PLAYER
# ══════════════════════════════════════════════════════════════════════════════

func _spawn_player() -> void:
	var scene := load(PLAYER_SCENE) as PackedScene
	_player = scene.instantiate() as Player
	_player.setup_network(true)
	add_child(_player)
	_player.global_position = SPAWN_POS

	# Hunger starts at max, passive drain disabled.
	# Hunger is fully disabled in tutorial to keep onboarding beginner-friendly.
	_player.set_hunger_enabled(false)
	_hide_hunger_ui()

	# Connect signals for tracking progress.
	_player.combo_changed.connect(_on_combo_changed)
	_player.player_died.connect(_on_player_died)


func _hide_hunger_ui() -> void:
	if not _player or not _player.hud:
		return
	_player.set_hunger_passive_drain(false)
	_player.hud.hunger_bar.visible = false
	_player.hud.hunger_label.visible = false
	_player.hud.starvation_label.visible = false


func _show_hunger_ui() -> void:
	if not _player or not _player.hud:
		return
	_player.set_hunger_passive_drain(true)
	_player.hud.hunger_bar.visible = true
	_player.hud.hunger_label.visible = true


# ══════════════════════════════════════════════════════════════════════════════
#  UI
# ══════════════════════════════════════════════════════════════════════════════

func _build_ui() -> void:
	_prompt_layer = CanvasLayer.new()
	_prompt_layer.layer = 10
	add_child(_prompt_layer)

	# Step counter (top-left).
	_step_label = Label.new()
	_step_label.position = Vector2(20, 20)
	_step_label.add_theme_font_size_override("font_size", 16)
	_step_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	_prompt_layer.add_child(_step_label)

	# Main prompt (top-centre).
	var container := PanelContainer.new()
	container.anchors_preset = Control.PRESET_CENTER_TOP
	container.anchor_left    = 0.5
	container.anchor_right   = 0.5
	container.offset_left    = -280
	container.offset_right   = 280
	container.offset_top     = 50
	container.offset_bottom  = 200
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.15, 0.05, 0.85)
	style.border_color = Color(0.3, 0.7, 0.2, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	container.add_theme_stylebox_override("panel", style)
	_prompt_layer.add_child(container)

	_prompt_label = Label.new()
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 18)
	_prompt_label.add_theme_color_override("font_color", Color(0.95, 1.0, 0.85))
	_prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	container.add_child(_prompt_label)

	# Skip button (bottom-right).
	_skip_button = Button.new()
	_skip_button.text = "Skip Tutorial"
	_skip_button.anchors_preset = Control.PRESET_BOTTOM_RIGHT
	_skip_button.anchor_left   = 1.0
	_skip_button.anchor_top    = 1.0
	_skip_button.anchor_right  = 1.0
	_skip_button.anchor_bottom = 1.0
	_skip_button.offset_left   = -170
	_skip_button.offset_top    = -50
	_skip_button.offset_right  = -20
	_skip_button.offset_bottom = -15
	_skip_button.add_theme_font_size_override("font_size", 14)
	_skip_button.pressed.connect(_on_skip)
	_prompt_layer.add_child(_skip_button)

	# End-of-tutorial buttons (hidden until COMPLETE).
	_end_buttons = HBoxContainer.new()
	_end_buttons.anchors_preset = Control.PRESET_CENTER
	_end_buttons.anchor_left   = 0.5
	_end_buttons.anchor_right  = 0.5
	_end_buttons.anchor_top    = 0.5
	_end_buttons.anchor_bottom = 0.5
	_end_buttons.offset_left   = -200
	_end_buttons.offset_right  = 200
	_end_buttons.offset_top    = 40
	_end_buttons.offset_bottom = 90
	_end_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_end_buttons.add_theme_constant_override("separation", 20)
	_end_buttons.visible = false
	_prompt_layer.add_child(_end_buttons)

	var playground_btn := Button.new()
	playground_btn.text = "Try Playground"
	playground_btn.add_theme_font_size_override("font_size", 18)
	playground_btn.pressed.connect(_on_go_playground)
	_end_buttons.add_child(playground_btn)

	var menu_btn := Button.new()
	menu_btn.text = "Back to Menu"
	menu_btn.add_theme_font_size_override("font_size", 18)
	menu_btn.pressed.connect(_on_skip)
	_end_buttons.add_child(menu_btn)

	# Ground-reset tip (bottom-centre, hidden by default).
	var tip_panel := PanelContainer.new()
	tip_panel.anchors_preset = Control.PRESET_CENTER_BOTTOM
	tip_panel.anchor_left   = 0.5
	tip_panel.anchor_right  = 0.5
	tip_panel.anchor_top    = 1.0
	tip_panel.anchor_bottom = 1.0
	tip_panel.offset_left   = -160
	tip_panel.offset_right  = 160
	tip_panel.offset_top    = -70
	tip_panel.offset_bottom = -20
	var tip_style := StyleBoxFlat.new()
	tip_style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	tip_style.set_corner_radius_all(8)
	tip_style.set_content_margin_all(10)
	tip_panel.add_theme_stylebox_override("panel", tip_style)
	tip_panel.visible = false
	_prompt_layer.add_child(tip_panel)
	_tip_label = Label.new()
	_tip_label.text = "Press R to reset position"
	_tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_label.add_theme_font_size_override("font_size", 15)
	_tip_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5, 0.9))
	tip_panel.add_child(_tip_label)
	# Keep a reference to the panel via the label's parent.

	# Pause menu (Escape key).
	var pause_scene := load("res://ui/PauseMenu.tscn")
	if pause_scene:
		add_child(pause_scene.instantiate())


func _show_step() -> void:
	_prompt_label.text = STEP_TEXT.get(_current_step, "")

	# Count only interactive steps for the step counter.
	var interactive_idx := 0
	var interactive_total := 0
	for s in Step.values():
		if s == Step.COMPLETE:
			break
		if s not in INFO_STEPS:
			interactive_total += 1
			if s < _current_step:
				interactive_idx += 1
	if _current_step not in INFO_STEPS and _current_step != Step.COMPLETE:
		_step_label.text = "Step %d / %d" % [interactive_idx + 1, interactive_total]
	elif _current_step == Step.COMPLETE:
		_step_label.text = ""
	else:
		_step_label.text = ""

	# Show/hide end buttons.
	_end_buttons.visible = (_current_step == Step.COMPLETE)
	_skip_button.visible = (_current_step != Step.COMPLETE)

	# Start auto-advance timer for non-welcome info steps.
	if _current_step in AUTO_INFO_STEPS:
		_info_timer = INFO_AUTO_ADVANCE_TIME
	else:
		_info_timer = 0.0

	# Sync shift-lock baseline so stale state doesn't immediately advance the step.
	if _current_step == Step.SHIFT_LOCK:
		_toggled_shift = false
		if is_instance_valid(_player):
			_prev_shift_lock = _player._shift_lock


func _advance_step() -> void:
	_current_step += 1
	if _current_step > Step.COMPLETE:
		_current_step = Step.COMPLETE
	_show_step()


# ══════════════════════════════════════════════════════════════════════════════
#  STEP DETECTION
# ══════════════════════════════════════════════════════════════════════════════

func _input(event: InputEvent) -> void:
	# SPACE advances info-only steps.
	if _current_step in INFO_STEPS and event is InputEventKey \
			and event.keycode == KEY_SPACE and event.pressed and not event.echo:
		_advance_step()
		return

	# R resets player position (not the tutorial).
	if event is InputEventKey and event.keycode == KEY_R and event.pressed and not event.echo:
		_reset_player_position()
		return

	if _current_step == Step.LOOK_AROUND and event is InputEventMouseMotion:
		_look_total += event.relative.length()
		if _look_total > 600.0:
			_advance_step()



func _process(delta: float) -> void:
	if not is_instance_valid(_player) or _player.is_dead:
		return

	# Auto-advance timed info steps.
	if _current_step in AUTO_INFO_STEPS:
		_info_timer -= delta
		if _info_timer <= 0.0:
			_advance_step()
			return

	# Ground-reset tip: show when on the floor at ground level.
	var on_ground := _player.is_on_floor() and _player.global_position.y < 2.5
	if is_instance_valid(_tip_label) and _tip_label.get_parent():
		_tip_label.get_parent().visible = on_ground and _current_step != Step.COMPLETE

	match _current_step:
		Step.PUSH_SURFACE:
			if _player.velocity.length() > 5.0 and not _player._is_grabbing():
				_advance_step()

		Step.GRAB_VINE:
			if _player.left_hand_state == Player.HandState.GRABBING \
					or _player.right_hand_state == Player.HandState.GRABBING:
				_grabbed_vine = true
				_advance_step()

		Step.SWING_AND_RELEASE:
			if _grabbed_vine and _player.left_hand_state == Player.HandState.FREE \
					and _player.right_hand_state == Player.HandState.FREE:
				if _player.velocity.length() > 2.0:
					_advance_step()

		Step.LAND_ON_PLATFORM:
			if _player.is_on_floor() and _player.global_position.y > 4.0:
				_advance_step()

		Step.SHIFT_LOCK:
			var cur_sl : bool = _player._shift_lock
			if cur_sl != _prev_shift_lock:
				_prev_shift_lock = cur_sl
				if not _toggled_shift:
					_toggled_shift = true
				else:
					_advance_step()

		Step.COMBO_SWING:
			pass  # handled by signal

		Step.OBSTACLE_COURSE:
			# Reached the golden finish platform.
			var fp := get_node_or_null("FinishPlatform") as StaticBody3D
			if fp and _player.is_on_floor():
				var dist := _player.global_position.distance_to(fp.global_position)
				if dist < 5.0 and _player.global_position.y > 9.0:
					_advance_step()


func _on_combo_changed(count: int) -> void:
	if _current_step == Step.COMBO_SWING and count >= 2:
		_combo_reached = true
		_advance_step()


func _reset_player_position() -> void:
	if not is_instance_valid(_player):
		return
	_player.velocity = Vector3.ZERO
	_player.global_position = SPAWN_POS
	if _player.camera:
		_player.camera.make_current()


func _on_player_died() -> void:
	# Player cannot die in the tutorial — reset position instead.
	if is_instance_valid(_player):
		_player.is_dead = false
		_player.is_starving = false
		if _player.hunger_death_timer and not _player.hunger_death_timer.is_queued_for_deletion():
			_player.hunger_death_timer.stop()
		_player.velocity = Vector3.ZERO
		_player.global_position = SPAWN_POS
		_player.camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if _player.hud:
			_player.hud.death_label.visible = false
		_hide_hunger_ui()


func _on_skip() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


func _on_go_playground() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://ui/PlaygroundMenu.tscn")
