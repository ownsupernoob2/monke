extends Node3D

## 3D main menu with SubViewport-rendered cards and camera transitions.
## The monkey spins beside the main menu card.  Clicking Settings or
## Customize tweens the camera to their respective 3D sections.

const SPIN_SPEED := 0.5

# ── Section layout ────────────────────────────────────────────────────────────
enum Section { MAIN, SETTINGS, CUSTOMIZE }

# Camera pivot target Y-rotation for each section.
const CAM_Y := {
	Section.MAIN:      0.0,
	Section.SETTINGS:  PI / 2.0,
	Section.CUSTOMIZE: PI,
}

# Card world positions and facing rotations.
const CARD_POS := {
	Section.MAIN:      Vector3(1.5, 0, -5),
	Section.SETTINGS:  Vector3(-5, 0, 0),
	Section.CUSTOMIZE: Vector3(0, 0, 5),
}
const CARD_ROT_Y := {
	Section.MAIN:      PI,
	Section.SETTINGS:  PI / 2.0,
	Section.CUSTOMIZE: 0.0,
}

const CARD_VP_SIZE    := Vector2i(420, 560)
const CARD_QUAD_SIZE  := Vector2(3.2, 4.2)
const TRANSITION_TIME := 0.8

# ── State ─────────────────────────────────────────────────────────────────────
var _current_section := Section.MAIN
var _transitioning   := false

# Per-card data: { section, node, viewport, mesh, quad_size }
var _cards : Array[Dictionary] = []

# ── .tscn references ─────────────────────────────────────────────────────────
@onready var camera_pivot := $CameraPivot
@onready var monkey_pivot := $MonkeyPivot

# ── Settings widgets (populated during build) ────────────────────────────────
var _master_slider     : HSlider  = null
var _sfx_slider        : HSlider  = null
var _sens_slider       : HSlider  = null
var _fullscreen_toggle : CheckBox = null
var _vsync_toggle      : CheckBox = null
var _master_lbl        : Label    = null
var _sfx_lbl           : Label    = null
var _sens_lbl          : Label    = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_setup_monkey()
	_build_main_card()
	_build_settings_card()
	_build_customize_card()
	_build_version_label()

	if has_node("/root/GameSettings"):
		var gs := get_node("/root/GameSettings")
		if gs.disconnect_message != "":
			_show_disconnect_popup(gs.disconnect_message)
			gs.disconnect_message = ""


func _process(delta: float) -> void:
	monkey_pivot.rotate_y(SPIN_SPEED * delta)


# ══════════════════════════════════════════════════════════════════════════════
#  MONKEY
# ══════════════════════════════════════════════════════════════════════════════

func _setup_monkey() -> void:
	var monke_scene := load("res://models/monke.glb") as PackedScene
	if not monke_scene:
		return
	var monke := monke_scene.instantiate()
	monkey_pivot.add_child(monke)
	var tex := load("res://models/monke_texture.png") as Texture2D
	if tex:
		for child in monke.get_children():
			if child is MeshInstance3D:
				var mat := StandardMaterial3D.new()
				mat.albedo_texture = tex
				mat.roughness = 0.5
				child.material_override = mat


# ══════════════════════════════════════════════════════════════════════════════
#  CARD HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _create_card(section: Section,
		vp_size: Vector2i = CARD_VP_SIZE,
		quad_size: Vector2 = CARD_QUAD_SIZE) -> Dictionary:
	var card := Node3D.new()
	card.position = CARD_POS[section]
	card.rotation.y = CARD_ROT_Y[section]
	add_child(card)

	var vp := SubViewport.new()
	vp.name = "VP"
	vp.size = vp_size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	card.add_child(vp)

	var mesh_inst := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = quad_size
	quad.flip_faces = true
	mesh_inst.mesh = quad
	mesh_inst.position.y = quad_size.y * 0.5
	card.add_child(mesh_inst)

	call_deferred("_apply_vp_material", mesh_inst, vp)

	var info := {
		"section": section,
		"node": card,
		"viewport": vp,
		"mesh": mesh_inst,
		"quad_size": quad_size,
	}
	_cards.append(info)
	return info


func _apply_vp_material(mesh_inst: MeshInstance3D, vp: SubViewport) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = vp.get_texture()
	mat.uv1_scale = Vector3(-1, 1, 1)
	mesh_inst.set_surface_override_material(0, mat)


func _styled_button(text: String, parent: Control, font_size: int = 22,
		color := Color(0.85, 0.9, 0.8)) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(300, 44)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 0.9))
	btn.add_theme_color_override("font_pressed_color", color * 0.8)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.28, 0.1, 0.92)
	sb.border_color = Color(0.3, 0.65, 0.25)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(8)
	btn.add_theme_stylebox_override("normal", sb)

	var hover := sb.duplicate()
	hover.bg_color = Color(0.18, 0.45, 0.15, 0.95)
	hover.border_color = Color(0.45, 0.85, 0.35)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("focus", hover)

	var pressed := sb.duplicate()
	pressed.bg_color = Color(0.08, 0.18, 0.06, 0.95)
	btn.add_theme_stylebox_override("pressed", pressed)

	parent.add_child(btn)
	return btn


func _spacer(parent: Control, height: float) -> void:
	var s := Control.new()
	s.custom_minimum_size.y = height
	parent.add_child(s)


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN CARD
# ══════════════════════════════════════════════════════════════════════════════

func _build_main_card() -> void:
	var info := _create_card(Section.MAIN)
	var vp : SubViewport = info.viewport

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.1, 0.04)
	bg.size = Vector2(vp.size)
	vp.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.size = Vector2(vp.size)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 10)
	vp.add_child(vbox)

	var title := Label.new()
	title.text = "MONKE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color(0.9, 0.78, 0.25))
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "need banana"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.72, 0.45, 0.85))
	vbox.add_child(subtitle)

	_spacer(vbox, 20)

	_styled_button("PLAY", vbox).pressed.connect(_on_play)
	_styled_button("TUTORIAL", vbox).pressed.connect(_on_tutorial)
	_styled_button("CUSTOMIZE", vbox, 22, Color(0.9, 0.78, 0.25)).pressed.connect(
			func(): _transition_to(Section.CUSTOMIZE))
	_styled_button("PLAYGROUND", vbox).pressed.connect(_on_playground)
	_styled_button("SETTINGS", vbox).pressed.connect(
			func(): _transition_to(Section.SETTINGS))

	_spacer(vbox, 8)

	_styled_button("EXIT", vbox, 22, Color(0.85, 0.55, 0.5)).pressed.connect(_on_exit)


# ══════════════════════════════════════════════════════════════════════════════
#  SETTINGS CARD
# ══════════════════════════════════════════════════════════════════════════════

func _build_settings_card() -> void:
	var info := _create_card(Section.SETTINGS, Vector2i(440, 600), Vector2(3.4, 4.6))
	var vp : SubViewport = info.viewport

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.1, 0.04)
	bg.size = Vector2(vp.size)
	vp.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(20, 20)
	vbox.size = Vector2(vp.size.x - 40, vp.size.y - 40)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	vp.add_child(vbox)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.9, 0.78, 0.25))
	vbox.add_child(title)

	_spacer(vbox, 10)

	_master_slider = _setting_row(vbox, "Master Volume")
	_master_lbl = _master_slider.get_meta("value_label")
	_sfx_slider = _setting_row(vbox, "SFX Volume")
	_sfx_lbl = _sfx_slider.get_meta("value_label")
	_sens_slider = _setting_row(vbox, "Sensitivity", 0.1, 2.0, 0.5)
	_sens_lbl = _sens_slider.get_meta("value_label")

	_fullscreen_toggle = CheckBox.new()
	_fullscreen_toggle.text = "  Fullscreen"
	_fullscreen_toggle.add_theme_font_size_override("font_size", 16)
	_fullscreen_toggle.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	vbox.add_child(_fullscreen_toggle)

	_vsync_toggle = CheckBox.new()
	_vsync_toggle.text = "  VSync"
	_vsync_toggle.add_theme_font_size_override("font_size", 16)
	_vsync_toggle.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	vbox.add_child(_vsync_toggle)

	if has_node("/root/GameSettings"):
		var gs := get_node("/root/GameSettings")
		_master_slider.value = gs.master_volume
		_sfx_slider.value = gs.sfx_volume
		_sens_slider.value = gs.mouse_sensitivity
		_fullscreen_toggle.button_pressed = gs.fullscreen
		_vsync_toggle.button_pressed = gs.vsync

	_update_settings_labels()
	_master_slider.value_changed.connect(func(_v: float): _update_settings_labels())
	_sfx_slider.value_changed.connect(func(_v: float): _update_settings_labels())
	_sens_slider.value_changed.connect(func(_v: float): _update_settings_labels())

	_spacer(vbox, 12)

	_styled_button("APPLY", vbox, 20).pressed.connect(_apply_settings)
	_styled_button("BACK", vbox, 20).pressed.connect(
			func(): _apply_settings(); _transition_to(Section.MAIN))


func _setting_row(parent: Control, label_text: String,
		min_val: float = 0.0, max_val: float = 1.0,
		default_val: float = 1.0) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 150
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = 0.01
	slider.value = default_val
	slider.custom_minimum_size = Vector2(120, 20)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size.x = 50
	val_lbl.add_theme_font_size_override("font_size", 14)
	val_lbl.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	row.add_child(val_lbl)

	slider.set_meta("value_label", val_lbl)
	return slider


func _update_settings_labels() -> void:
	if _master_lbl:
		_master_lbl.text = "%d%%" % int(_master_slider.value * 100)
	if _sfx_lbl:
		_sfx_lbl.text = "%d%%" % int(_sfx_slider.value * 100)
	if _sens_lbl:
		_sens_lbl.text = "%d%%" % int(_sens_slider.value * 100)


func _apply_settings() -> void:
	if has_node("/root/GameSettings"):
		var gs := get_node("/root/GameSettings")
		gs.master_volume = _master_slider.value
		gs.sfx_volume = _sfx_slider.value
		gs.mouse_sensitivity = _sens_slider.value
		gs.fullscreen = _fullscreen_toggle.button_pressed
		gs.vsync = _vsync_toggle.button_pressed
		gs._apply_audio()
		gs._apply_display()


# ══════════════════════════════════════════════════════════════════════════════
#  CUSTOMIZE CARD
# ══════════════════════════════════════════════════════════════════════════════

func _build_customize_card() -> void:
	var info := _create_card(Section.CUSTOMIZE)
	var vp : SubViewport = info.viewport

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.1, 0.04)
	bg.size = Vector2(vp.size)
	vp.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.size = Vector2(vp.size)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	vp.add_child(vbox)

	var title := Label.new()
	title.text = "CUSTOMIZE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.9, 0.78, 0.25))
	vbox.add_child(title)

	var coming := Label.new()
	coming.text = "Coming Soon..."
	coming.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	coming.add_theme_font_size_override("font_size", 20)
	coming.add_theme_color_override("font_color", Color(0.7, 0.75, 0.65, 0.7))
	vbox.add_child(coming)

	_spacer(vbox, 30)

	_styled_button("BACK", vbox, 20).pressed.connect(
			func(): _transition_to(Section.MAIN))


# ══════════════════════════════════════════════════════════════════════════════
#  VERSION LABEL
# ══════════════════════════════════════════════════════════════════════════════

func _build_version_label() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	var lbl := Label.new()
	lbl.text = "v0.1 alpha"
	lbl.anchors_preset = Control.PRESET_BOTTOM_RIGHT
	lbl.anchor_left = 1.0
	lbl.anchor_top = 1.0
	lbl.anchor_right = 1.0
	lbl.anchor_bottom = 1.0
	lbl.offset_left = -120
	lbl.offset_top = -30
	lbl.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.4, 0.5, 0.35, 0.5))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	layer.add_child(lbl)


# ══════════════════════════════════════════════════════════════════════════════
#  CAMERA TRANSITIONS
# ══════════════════════════════════════════════════════════════════════════════

func _transition_to(section: Section) -> void:
	if _transitioning or section == _current_section:
		return
	_transitioning = true
	_current_section = section

	var target_y : float = CAM_Y[section]
	var current_y : float = camera_pivot.rotation.y
	var diff : float = fmod(target_y - current_y + PI, TAU) - PI

	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(camera_pivot, "rotation:y", current_y + diff, TRANSITION_TIME)
	tween.tween_callback(func(): _transitioning = false)


# ══════════════════════════════════════════════════════════════════════════════
#  INPUT FORWARDING  (3D card → SubViewport)
# ══════════════════════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if _transitioning:
		return

	# ESC returns to main section from sub-sections.
	if event.is_action_pressed("ui_cancel") and _current_section != Section.MAIN:
		if _current_section == Section.SETTINGS:
			_apply_settings()
		_transition_to(Section.MAIN)
		get_viewport().set_input_as_handled()
		return

	if not (event is InputEventMouseButton or event is InputEventMouseMotion):
		return

	for card_info in _cards:
		if card_info.section != _current_section:
			continue
		if _forward_to_card(event, card_info):
			get_viewport().set_input_as_handled()
		return


func _forward_to_card(event: InputEvent, card_info: Dictionary) -> bool:
	var mouse_pos : Vector2
	if event is InputEventMouseButton:
		mouse_pos = event.position
	elif event is InputEventMouseMotion:
		mouse_pos = event.position
	else:
		return false

	var cam := camera_pivot.get_node("Camera3D") as Camera3D
	var from := cam.project_ray_origin(mouse_pos)
	var dir  := cam.project_ray_normal(mouse_pos)

	var mesh : MeshInstance3D = card_info.mesh
	var vp   : SubViewport    = card_info.viewport
	var quad_size : Vector2   = card_info.quad_size

	# Plane intersection with the card's visible face.
	var mesh_t := mesh.global_transform
	var normal := (-mesh_t.basis.z).normalized()
	var center := mesh_t.origin

	var denom := normal.dot(dir)
	if abs(denom) < 0.001:
		return false
	var t := normal.dot(center - from) / denom
	if t < 0.0:
		return false
	var hit := from + dir * t

	# Convert hit to local quad coordinates.
	var local := mesh_t.affine_inverse() * hit
	var u := local.x / quad_size.x + 0.5
	var v := -local.y / quad_size.y + 0.5

	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return false

	# Correct for uv1_scale.x = -1.
	u = 1.0 - u

	var vp_pos := Vector2(u * float(vp.size.x), v * float(vp.size.y))

	var fwd := event.duplicate()
	if fwd is InputEventMouseButton:
		fwd.position = vp_pos
		fwd.global_position = vp_pos
	elif fwd is InputEventMouseMotion:
		fwd.position = vp_pos
		fwd.global_position = vp_pos

	vp.push_input(fwd)
	return true


# ══════════════════════════════════════════════════════════════════════════════
#  ACTIONS
# ══════════════════════════════════════════════════════════════════════════════

func _on_play() -> void:
	get_tree().change_scene_to_file("res://multiplayer/ConnectScreen.tscn")

func _on_tutorial() -> void:
	get_tree().change_scene_to_file("res://ui/Tutorial.tscn")

func _on_playground() -> void:
	get_tree().change_scene_to_file("res://ui/PlaygroundMenu.tscn")

func _on_exit() -> void:
	get_tree().quit()


func _show_disconnect_popup(msg: String) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	var dialog := AcceptDialog.new()
	dialog.title = "Disconnected"
	dialog.dialog_text = msg
	dialog.min_size = Vector2i(320, 100)
	layer.add_child(dialog)
	dialog.popup_centered()
