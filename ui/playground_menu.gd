extends Control

## Map data: { card_node_name : scene_path }
const MAPS : Dictionary = {
	"SwampForestCard":  "res://maps/SwampForest.tscn",
	"RainforestCard":   "res://maps/Rainforest.tscn",
	"CanyonCard":       "res://maps/RedCanyon.tscn",
	"MoonForestCard":   "res://maps/MoonForest.tscn",
}

var _selected_card_name : String = "SwampForestCard"

# ── Style sub-resources (grabbed from the first card at _ready) ──────────
var _style_normal   : StyleBox
var _style_selected : StyleBox

@onready var map_grid        : HBoxContainer = $MarginContainer/VBoxContainer/MapGrid
@onready var hunger_toggle   : CheckBox      = $MarginContainer/VBoxContainer/OptionsPanel/OptionsVBox/HungerToggle
@onready var enemies_toggle  : CheckBox      = $MarginContainer/VBoxContainer/OptionsPanel/OptionsVBox/EnemiesToggle
@onready var start_button    : Button        = $MarginContainer/VBoxContainer/StartButton
@onready var back_button     : Button        = $MarginContainer/VBoxContainer/HeaderRow/BackButton


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Grab the two panel styles from the first two cards.
	_style_selected = map_grid.get_node("SwampForestCard").get_theme_stylebox("panel")
	_style_normal   = map_grid.get_node("RainforestCard").get_theme_stylebox("panel")

	# Wire up card clicks.
	for card_name in MAPS.keys():
		var card : PanelContainer = map_grid.get_node(card_name)
		# PanelContainer doesn't have a pressed signal, so we use gui_input.
		card.gui_input.connect(_on_card_input.bind(card_name))
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	start_button.pressed.connect(_on_start)
	back_button.pressed.connect(_on_back)
	start_button.grab_focus()

	# Sync toggles with GameSettings (if autoload exists).
	if Engine.has_singleton("GameSettings") or has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		hunger_toggle.button_pressed  = gs.hunger_enabled
		enemies_toggle.button_pressed = gs.ground_enemies_enabled


func _on_card_input(event: InputEvent, card_name: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_select_card(card_name)


func _select_card(card_name: String) -> void:
	_selected_card_name = card_name
	# Update visual highlight.
	for name_key in MAPS.keys():
		var card : PanelContainer = map_grid.get_node(name_key)
		if name_key == card_name:
			card.add_theme_stylebox_override("panel", _style_selected)
		else:
			card.add_theme_stylebox_override("panel", _style_normal)


func _on_start() -> void:
	# Write options into GameSettings autoload.
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.hunger_enabled         = hunger_toggle.button_pressed
		gs.ground_enemies_enabled = enemies_toggle.button_pressed
		gs.selected_map           = MAPS[_selected_card_name]
	if has_node("/root/GameLobby"):
		await get_node("/root/GameLobby").disconnect_lobby_async()

	get_tree().change_scene_to_file(MAPS[_selected_card_name])


func _on_back() -> void:
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")
