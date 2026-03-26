extends Node3D

## 3D main menu with SubViewport-rendered cards and camera transitions.
## The monkey spins beside the main menu card.  Cosmetic arrows sit beside
## the monkey and are clickable from the main section.

const SPIN_SPEED := 0.5
const MONKEY_BOB_AMPLITUDE := 0.16
const MONKEY_BOB_SPEED := 1.6
const CAM_IDLE_BOB := 0.1
const CAM_IDLE_SPEED := 0.6
const CARD_FLOAT_AMPLITUDE := 0.12
const CARD_FLOAT_SPEED := 0.9
const FIREFLY_COUNT := 18

# ── Section layout ────────────────────────────────────────────────────────────
enum Section { TITLE, MAIN, SETTINGS }

# Camera pivot target Y-rotation for each section.
const CAM_Y := {
	Section.TITLE:     0.0,
	Section.MAIN:      0.0,
	Section.SETTINGS:  PI / 2.0,
}

# Card world positions and facing rotations.
const CARD_POS := {
	Section.TITLE:     Vector3(-4.0, 0, -3),
	Section.MAIN:      Vector3(1.5, 0, -5),
	Section.SETTINGS:  Vector3(-5, 0, 0),
}
const CARD_ROT_Y := {
	Section.TITLE:     PI * 0.75,
	Section.MAIN:      PI,
	Section.SETTINGS:  PI / 2.0,
}

const CARD_VP_SIZE    := Vector2i(560, 760)
const CARD_QUAD_SIZE  := Vector2(3.2, 4.2)
const TITLE_VP_SIZE   := Vector2i(480, 640)
const TITLE_QUAD_SIZE := Vector2(2.8, 3.8)
const SETTINGS_VP_SIZE := Vector2i(600, 820)
const SETTINGS_QUAD_SIZE := Vector2(3.4, 4.6)
const TRANSITION_TIME := 0.8
const MOUSE_LOOK_SPEED := 8.0
const MONKE_LOOK_BACK_OFFSET := 0.0
const MONKE_LOOK_PITCH_MAX := 0.5
const MONKE_LOOK_DISTANCE := 40.0

# ── State ─────────────────────────────────────────────────────────────────────
var _current_section := Section.MAIN
var _transitioning   := false
var _fx_time : float = 0.0

# Per-card data: { section, node, viewport, mesh, quad_size }
var _cards : Array[Dictionary] = []
var _fireflies : Array[Dictionary] = []
var _card_base_y : Dictionary = {}
var _base_cam_pos : Vector3 = Vector3.ZERO
var _base_cam_rot_x : float = 0.0
var _base_monkey_y : float = 0.0
var _monke_visual : Node3D = null
var _hat_index : int = -1
var _face_index : int = 0
var _suit_index : int = -1
var _monke_neutral_rot_x : float = 0.0
var _monke_neutral_rot_y : float = 0.0

# ── .tscn references ─────────────────────────────────────────────────────────
@onready var camera_pivot         := $CameraPivot
@onready var monkey_pivot         := $MonkeyPivot
@onready var _title_card_node     : Node3D = get_node_or_null("TitleCard") as Node3D
@onready var _main_card_node      : Node3D = get_node_or_null("MainCard") as Node3D
@onready var _settings_card_node  : Node3D = get_node_or_null("SettingsCard") as Node3D

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
	_title_card_node = _ensure_card_node(_title_card_node, Section.TITLE, TITLE_VP_SIZE, TITLE_QUAD_SIZE)
	_main_card_node = _ensure_card_node(_main_card_node, Section.MAIN, CARD_VP_SIZE, CARD_QUAD_SIZE)
	_settings_card_node = _ensure_card_node(_settings_card_node, Section.SETTINGS, SETTINGS_VP_SIZE, SETTINGS_QUAD_SIZE)
	_setup_monkey()
	_build_title_card()
	_build_main_card()
	_build_settings_card()
	_build_main_cosmetic_arrows()
	_setup_card_idle_bases()
	_build_ambient_fx()
	_build_version_label()
	_base_cam_pos = camera_pivot.position
	_base_cam_rot_x = camera_pivot.rotation.x
	_base_monkey_y = monkey_pivot.position.y

	if has_node("/root/GameSettings"):
		var gs := get_node("/root/GameSettings")
		if gs.disconnect_message != "":
			_show_disconnect_popup(gs.disconnect_message)
			gs.disconnect_message = ""


func _process(delta: float) -> void:
	_fx_time += delta
	monkey_pivot.position.y = _base_monkey_y + sin(_fx_time * MONKEY_BOB_SPEED) * MONKEY_BOB_AMPLITUDE
	_update_monkey_mouse_look(delta)

	# Subtle camera breathing to keep the scene alive.
	camera_pivot.position.y = _base_cam_pos.y + sin(_fx_time * CAM_IDLE_SPEED) * CAM_IDLE_BOB
	camera_pivot.rotation.x = _base_cam_rot_x + sin(_fx_time * CAM_IDLE_SPEED * 0.8) * 0.02

	# Cards gently float to feel less rigid.
	for card_info in _cards:
		var section : int = card_info.section
		if not _card_base_y.has(section):
			continue
		var node : Node3D = card_info.node
		var phase := float(section) * 1.7
		node.position.y = float(_card_base_y[section]) + sin(_fx_time * CARD_FLOAT_SPEED + phase) * CARD_FLOAT_AMPLITUDE

	# Fireflies orbit lazily around the menu focal area.
	for f in _fireflies:
		var n : MeshInstance3D = f.node
		var base : Vector3 = f.base
		var phase : float = f.phase
		var radius : float = f.radius
		n.position = base + Vector3(
			cos(_fx_time * 0.7 + phase) * radius,
			sin(_fx_time * 1.1 + phase) * 0.18,
			sin(_fx_time * 0.6 + phase) * radius
		)


# ══════════════════════════════════════════════════════════════════════════════
#  MONKEY
# ══════════════════════════════════════════════════════════════════════════════

func _setup_monkey() -> void:
	var monke_scene := load("res://models/monke.glb") as PackedScene
	if not monke_scene:
		return
	var monke := monke_scene.instantiate()
	monkey_pivot.add_child(monke)
	if monke is Node3D:
		_monke_visual = monke as Node3D
		_sync_preview_cosmetics_from_player_scene()
		_monke_neutral_rot_x = _monke_visual.rotation.x
		_monke_neutral_rot_y = _monke_visual.rotation.y
	var tex := load("res://models/monke_texture.png") as Texture2D
	if tex:
		for child in monke.get_children():
			if child is MeshInstance3D:
				var mat := StandardMaterial3D.new()
				mat.albedo_texture = tex
				mat.roughness = 0.5
				child.material_override = mat
	_apply_customize_visuals()


func _sync_preview_cosmetics_from_player_scene() -> void:
	if _monke_visual == null:
		return

	var dst_cosmetics := _preview_cosmetics_root()
	if dst_cosmetics == null:
		return

	var player_scene := load("res://components/Player.tscn") as PackedScene
	if player_scene == null:
		return

	var player_preview := player_scene.instantiate()
	if player_preview == null:
		return

	var src_cosmetics := player_preview.get_node_or_null("Head/Cosmetics") as Node3D
	if src_cosmetics == null:
		src_cosmetics = player_preview.get_node_or_null("Cosmetics") as Node3D
	if src_cosmetics == null:
		player_preview.queue_free()
		return

	for group_name in ["Hats", "Suits", "Bodies"]:
		var src_group := src_cosmetics.get_node_or_null(group_name) as Node3D
		if src_group == null:
			continue

		var dst_group := dst_cosmetics.get_node_or_null(group_name) as Node3D
		if dst_group == null:
			dst_group = Node3D.new()
			dst_group.name = group_name
			dst_cosmetics.add_child(dst_group)

		for old_child in dst_group.get_children():
			old_child.queue_free()

		for src_child in src_group.get_children():
			if src_child is Node3D:
				var copied := (src_child as Node3D).duplicate()
				copied.visible = false
				dst_group.add_child(copied)

	var hat_count := _scene_cosmetic_count("Hats")
	if hat_count > 0 and (_hat_index < 0 or _hat_index >= hat_count):
		_hat_index = 0
	var suit_count := _scene_cosmetic_count("Suits")
	if suit_count > 0 and _suit_index >= suit_count:
		_suit_index = 0

	player_preview.queue_free()


func _preview_cosmetics_root() -> Node3D:
	if _monke_visual == null:
		return null

	var head_node := _monke_visual.get_node_or_null("Head") as Node3D
	if head_node == null:
		head_node = _monke_visual.find_child("Head", true, false) as Node3D

	if head_node != null:
		var head_cosmetics := head_node.get_node_or_null("Cosmetics") as Node3D
		if head_cosmetics == null:
			head_cosmetics = Node3D.new()
			head_cosmetics.name = "Cosmetics"
			head_node.add_child(head_cosmetics)
		return head_cosmetics

	var root_cosmetics := _monke_visual.get_node_or_null("Cosmetics") as Node3D
	if root_cosmetics == null:
		root_cosmetics = Node3D.new()
		root_cosmetics.name = "Cosmetics"
		_monke_visual.add_child(root_cosmetics)
	return root_cosmetics


func _apply_customize_visuals() -> void:
	_set_scene_cosmetic_visibility("Hats", _hat_index)
	_set_scene_cosmetic_visibility("Bodies", _face_index)
	_set_scene_cosmetic_visibility("Suits", _suit_index)


func _set_scene_cosmetic_visibility(group_name: String, visible_index: int) -> void:
	var cosmetics_root := _preview_cosmetics_root()
	if cosmetics_root == null:
		return
	var group := cosmetics_root.get_node_or_null(group_name)
	if group == null:
		return
	var i := 0
	for child in group.get_children():
		if child is Node3D:
			(child as Node3D).visible = (i == visible_index)
			i += 1


func _scene_cosmetic_count(group_name: String) -> int:
	var cosmetics_root := _preview_cosmetics_root()
	if cosmetics_root == null:
		return 0
	var group := cosmetics_root.get_node_or_null(group_name)
	if group == null:
		return 0
	var count := 0
	for child in group.get_children():
		if child is Node3D:
			count += 1
	return count


func _update_monkey_mouse_look(delta: float) -> void:
	if _monke_visual == null:
		return
	var cam := camera_pivot.get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var head_world := _monke_visual.global_position + Vector3(0.0, 1.2, 0.0)
	if cam.is_position_behind(head_world):
		return

	# Anchor neutral gaze to the monkey's on-screen position so the cursor over
	# the monkey yields straight-ahead look regardless of where the monkey sits.
	var anchor_screen := cam.unproject_position(head_world)
	var mouse_pos := vp.get_mouse_position()
	var from := cam.project_ray_origin(mouse_pos)
	var dir := cam.project_ray_normal(mouse_pos).normalized()
	var aim_point := from + dir * MONKE_LOOK_DISTANCE

	var anchor_from := cam.project_ray_origin(anchor_screen)
	var anchor_dir := cam.project_ray_normal(anchor_screen).normalized()
	var anchor_point := anchor_from + anchor_dir * MONKE_LOOK_DISTANCE

	var to_target := aim_point - _monke_visual.global_position
	if to_target.length_squared() < 0.0001:
		return

	var target_basis := _monke_visual.global_transform.looking_at(aim_point, Vector3.UP).basis
	var target_euler := target_basis.get_euler()
	var anchor_basis := _monke_visual.global_transform.looking_at(anchor_point, Vector3.UP).basis
	var anchor_euler := anchor_basis.get_euler()
	var delta_y : float = target_euler.y - anchor_euler.y
	var delta_x : float = target_euler.x - anchor_euler.x
	var target_y : float = _monke_neutral_rot_y - delta_y + MONKE_LOOK_BACK_OFFSET
	var target_x : float = clampf(_monke_neutral_rot_x - delta_x, -MONKE_LOOK_PITCH_MAX, MONKE_LOOK_PITCH_MAX)
	_monke_visual.rotation.x = lerpf(_monke_visual.rotation.x, target_x, delta * MOUSE_LOOK_SPEED)
	_monke_visual.rotation.y = lerp_angle(_monke_visual.rotation.y, target_y, delta * MOUSE_LOOK_SPEED)


func _setup_card_idle_bases() -> void:
	_card_base_y[Section.MAIN] = _main_card_node.position.y
	_card_base_y[Section.SETTINGS] = _settings_card_node.position.y


func _build_ambient_fx() -> void:
	var glow_mat := StandardMaterial3D.new()
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.emission_enabled = true
	glow_mat.emission = Color(0.72, 1.0, 0.48, 1)
	glow_mat.emission_energy_multiplier = 1.8
	glow_mat.albedo_color = Color(0.85, 1.0, 0.65, 1)

	var mesh := SphereMesh.new()
	mesh.radius = 0.035
	mesh.height = 0.07

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in FIREFLY_COUNT:
		var fly := MeshInstance3D.new()
		fly.mesh = mesh
		fly.material_override = glow_mat
		var base := Vector3(rng.randf_range(-6.0, 6.0), rng.randf_range(1.1, 4.2), rng.randf_range(-6.0, 6.0))
		fly.position = base
		add_child(fly)
		_fireflies.append({
			"node": fly,
			"base": base,
			"phase": rng.randf_range(0.0, TAU),
			"radius": rng.randf_range(0.12, 0.42),
		})


# ══════════════════════════════════════════════════════════════════════════════
#  CARD HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _use_card(section: Section, card: Node3D) -> Dictionary:
	var vp        : SubViewport    = card.get_node("VP")
	var mesh_inst : MeshInstance3D = card.get_node("MeshInstance3D")
	if section == Section.SETTINGS:
		vp.size = SETTINGS_VP_SIZE
	elif section == Section.TITLE:
		vp.size = TITLE_VP_SIZE
	else:
		vp.size = CARD_VP_SIZE
	call_deferred("_apply_vp_material", mesh_inst, vp)
	var info := {
		"section":   section,
		"node":      card,
		"viewport":  vp,
		"mesh":      mesh_inst,
		"quad_size": (mesh_inst.mesh as QuadMesh).size,
	}
	_cards.append(info)
	return info


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


func _ensure_card_node(existing: Node3D, section: Section,
		vp_size: Vector2i, quad_size: Vector2) -> Node3D:
	if existing:
		return existing
	var info := _create_card(section, vp_size, quad_size)
	return info.node as Node3D


func _apply_vp_material(mesh_inst: MeshInstance3D, vp: SubViewport) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = vp.get_texture()
	mat.uv1_scale = Vector3(-1, 1, 1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_inst.set_surface_override_material(0, mat)


func _styled_button(text: String, parent: Control, font_size: int = 22,
		color := Color(0.85, 0.9, 0.8)) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(380, 64)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 0.95))
	btn.add_theme_color_override("font_pressed_color", color * 0.85)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.28, 0.10, 0.95)
	sb.border_color = Color(0.35, 0.72, 0.28)
	sb.set_border_width_all(2)
	sb.border_width_top = 3
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(10)
	sb.shadow_size = 6
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_offset = Vector2(3, 5)
	sb.expand_margin_bottom = 4
	btn.add_theme_stylebox_override("normal", sb)

	var hover := sb.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.18, 0.44, 0.14, 0.98)
	hover.border_color = Color(0.50, 0.92, 0.38)
	hover.shadow_size = 9
	hover.shadow_color = Color(0.20, 0.70, 0.15, 0.45)
	hover.shadow_offset = Vector2(3, 7)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("focus", hover)

	var pressed := sb.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.08, 0.18, 0.06, 0.98)
	pressed.border_color = Color(0.22, 0.50, 0.18)
	pressed.shadow_size = 2
	pressed.shadow_offset = Vector2(1, 2)
	pressed.expand_margin_bottom = 0
	btn.add_theme_stylebox_override("pressed", pressed)

	btn.mouse_entered.connect(func() -> void:
		var tw := btn.create_tween()
		tw.set_ease(Tween.EASE_OUT)
		tw.set_trans(Tween.TRANS_BACK)
		tw.tween_property(btn, "scale", Vector2(1.05, 1.05), 0.12)
	)
	btn.mouse_exited.connect(func() -> void:
		var tw := btn.create_tween()
		tw.set_ease(Tween.EASE_OUT)
		tw.set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(btn, "scale", Vector2.ONE, 0.12)
	)

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
	var info := _use_card(Section.MAIN, _main_card_node)
	var vp : SubViewport = info.viewport
	vp.transparent_bg = true

	var vbox := VBoxContainer.new()
	vbox.size = Vector2(vp.size)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	vp.add_child(vbox)

	_spacer(vbox, 20)

	_styled_button("PLAY", vbox, 28).pressed.connect(_on_play)
	_styled_button("TUTORIAL", vbox, 28).pressed.connect(_on_tutorial)
	_styled_button("PLAYGROUND", vbox, 28).pressed.connect(_on_playground)
	_styled_button("SETTINGS", vbox, 28).pressed.connect(
			func(): _transition_to(Section.SETTINGS))

	_spacer(vbox, 12)

	_styled_button("EXIT", vbox, 28, Color(0.85, 0.55, 0.5)).pressed.connect(_on_exit)


# ══════════════════════════════════════════════════════════════════════════════
#  TITLE CARD
# ══════════════════════════════════════════════════════════════════════════════

func _build_title_card() -> void:
	var info := _use_card(Section.TITLE, _title_card_node)
	var vp : SubViewport = info.viewport
	vp.transparent_bg = true

	var vbox := VBoxContainer.new()
	vbox.size = Vector2(vp.size)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vp.add_child(vbox)

	_spacer(vbox, 80)

	var title := Label.new()
	title.text = "MONKE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(0.9, 0.78, 0.25))
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "need banana"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.72, 0.45, 0.85))
	vbox.add_child(subtitle)

	var pulse := create_tween()
	pulse.set_loops()
	pulse.tween_property(title, "modulate", Color(1.0, 0.9, 0.35, 1.0), 0.7)
	pulse.tween_property(title, "modulate", Color(0.9, 0.78, 0.25, 1.0), 0.7)


# ══════════════════════════════════════════════════════════════════════════════
#  SETTINGS CARD
# ══════════════════════════════════════════════════════════════════════════════

func _build_settings_card() -> void:
	var info := _use_card(Section.SETTINGS, _settings_card_node)
	var vp : SubViewport = info.viewport
	vp.transparent_bg = true

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(28, 24)
	vbox.size = Vector2(vp.size.x - 56, vp.size.y - 48)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	vp.add_child(vbox)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 46)
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
	_fullscreen_toggle.add_theme_font_size_override("font_size", 20)
	_fullscreen_toggle.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	vbox.add_child(_fullscreen_toggle)

	_vsync_toggle = CheckBox.new()
	_vsync_toggle.text = "  VSync"
	_vsync_toggle.add_theme_font_size_override("font_size", 20)
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

	_styled_button("APPLY", vbox, 24).pressed.connect(_apply_settings)
	_styled_button("BACK", vbox, 24).pressed.connect(
			func(): _apply_settings(); _transition_to(Section.MAIN))


func _setting_row(parent: Control, label_text: String,
		min_val: float = 0.0, max_val: float = 1.0,
		default_val: float = 1.0) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 220
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = 0.01
	slider.value = default_val
	slider.custom_minimum_size = Vector2(180, 26)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size.x = 66
	val_lbl.add_theme_font_size_override("font_size", 18)
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


func _build_main_cosmetic_arrows() -> void:
	var arrow_specs := [
		# Labels are intentionally flipped because the card UV is mirrored.
		{"pos": Vector3(-1.95, 1.22, 0.22), "model_type": "hat", "dir": -1, "label": ">"},
		{"pos": Vector3(1.95, 1.22, 0.22), "model_type": "hat", "dir": 1, "label": "<"},
		{"pos": Vector3(-1.95, -0.28, 0.22), "model_type": "suit", "dir": -1, "label": ">"},
		{"pos": Vector3(1.95, -0.28, 0.22), "model_type": "suit", "dir": 1, "label": "<"},
	]

	for spec in arrow_specs:
		var card := Node3D.new()
		card.position = spec.pos
		monkey_pivot.add_child(card)

		var vp := SubViewport.new()
		vp.name = "VP"
		vp.size = Vector2i(92, 92)
		vp.transparent_bg = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		card.add_child(vp)

		var btn := Button.new()
		btn.text = str(spec.label)
		btn.custom_minimum_size = Vector2(92, 92)
		btn.add_theme_font_size_override("font_size", 38)
		btn.add_theme_color_override("font_color", Color(0.9, 0.78, 0.25))

		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.12, 0.28, 0.10, 0.9)
		sb.border_color = Color(0.35, 0.72, 0.28)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(10)
		btn.add_theme_stylebox_override("normal", sb)

		var hover := sb.duplicate() as StyleBoxFlat
		hover.bg_color = Color(0.18, 0.44, 0.14, 0.96)
		hover.border_color = Color(0.50, 0.92, 0.38)
		btn.add_theme_stylebox_override("hover", hover)
		btn.add_theme_stylebox_override("focus", hover)

		btn.pressed.connect(func(): _cycle_model(str(spec.model_type), int(spec.dir)))
		vp.add_child(btn)

		var mesh_inst := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.5, 0.5)
		quad.flip_faces = true
		mesh_inst.mesh = quad
		mesh_inst.position.y = 0.25
		card.add_child(mesh_inst)

		_apply_vp_material(mesh_inst, vp)

		_cards.append({
			"section": Section.MAIN,
			"node": card,
			"viewport": vp,
			"mesh": mesh_inst,
			"quad_size": quad.size,
		})


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
	var vp := get_viewport()
	if not vp:
		return
	if _route_menu_input(event):
		vp.set_input_as_handled()


func _route_menu_input(event: InputEvent) -> bool:
	if _transitioning:
		return false

	# ESC returns to main section from sub-sections.
	if event.is_action_pressed("ui_cancel") and _current_section != Section.MAIN:
		if _current_section == Section.SETTINGS:
			_apply_settings()
		_transition_to(Section.MAIN)
		return true

	if not (event is InputEventMouseButton or event is InputEventMouseMotion):
		return false

	if _forward_to_first_hit(event, _cards, _current_section):
		return true

	return false


func _forward_to_first_hit(event: InputEvent, card_list: Array, section_filter := -1) -> bool:
	for card_info in card_list:
		if section_filter != -1 and int(card_info.get("section", -1)) != section_filter:
			continue
		if _forward_to_card(event, card_info):
			return true
	return false


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

	if not is_instance_valid(vp) or not vp.is_inside_tree() or vp.get_tree() == null:
		return false
	vp.push_input(fwd)
	return true


# ══════════════════════════════════════════════════════════════════════════════
#  ACTIONS
# ══════════════════════════════════════════════════════════════════════════════

func _on_play() -> void:
	get_tree().call_deferred("change_scene_to_file", "res://multiplayer/ConnectScreen.tscn")

func _on_tutorial() -> void:
	get_tree().call_deferred("change_scene_to_file", "res://ui/Tutorial.tscn")

func _on_playground() -> void:
	get_tree().call_deferred("change_scene_to_file", "res://ui/PlaygroundMenu.tscn")

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


func _cycle_model(model_type: String, direction: int) -> void:
	if model_type == "hat":
		var hat_count := _scene_cosmetic_count("Hats")
		if hat_count <= 0:
			return
		# Include one additional "empty" slot at index -1.
		var hat_total := hat_count + 1
		var hat_state := _hat_index + 1
		hat_state = posmod(hat_state + direction, hat_total)
		_hat_index = hat_state - 1
	elif model_type == "suit":
		var suit_count := _scene_cosmetic_count("Suits")
		if suit_count <= 0:
			return
		# Include one additional "empty" slot at index -1.
		var suit_total := suit_count + 1
		var suit_state := _suit_index + 1
		suit_state = posmod(suit_state + direction, suit_total)
		_suit_index = suit_state - 1
	elif model_type == "face":
		var body_count := _scene_cosmetic_count("Bodies")
		if body_count <= 0:
			return
		_face_index = posmod(_face_index + direction, body_count)
	else:
		return
	_apply_customize_visuals()
