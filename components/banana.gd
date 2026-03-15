class_name Banana
extends Node3D

# ── Tunable exports ────────────────────────────────────────────────────────────
## Hunger restored when picked up.
@export var hunger_amount : float = 25.0
## Amplitude of the hover-bob in metres.
@export var bob_height    : float = 0.15
## How many full bobs per second.
@export var bob_speed     : float = 2.0
## Spin speed in radians per second.
@export var spin_speed    : float = 1.5
## Buff granted on pickup. Empty string = regular banana (hunger only).
## Valid values: "Repulsor", "Attraction", "Monkey Speed", "Wind Rider"
@export var buff_type     : String = ""

# ── Signals ────────────────────────────────────────────────────────────────────
## Fired just before the banana removes itself.
## Useful for spawners / score trackers later.
signal picked_up(picker: Node3D, amount: float)

# ── Internal state ─────────────────────────────────────────────────────────────
## True once a player has touched this banana. Guards against duplicate triggers
## that can occur when the physics engine fires body_entered more than once.
var _collected : bool  = false
var _time      : float = 0.0
var _base_y    : float = 0.0   # resting Y; bob is offset from this

# ── Node refs ──────────────────────────────────────────────────────────────────
@onready var area : Area3D = $Area3D
@onready var mesh_instance : MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	add_to_group("bananas")
	# Store the Y position set in the editor so the bob is relative to it.
	_base_y = position.y
	_apply_buff_color()
	area.body_entered.connect(_on_body_entered)


func _apply_buff_color() -> void:
	if mesh_instance == null:
		return
	var color := Color(1.0, 0.85, 0.05, 1.0)
	match buff_type:
		"Repulsor":
			color = Color(0.20, 0.62, 1.0, 1.0)
		"Attraction":
			color = Color(0.93, 0.35, 0.55, 1.0)
		"Monkey Speed":
			color = Color(0.18, 0.18, 0.22, 1.0)
		"Wind Rider":
			color = Color(0.70, 1.0, 0.86, 1.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_instance.material_override = mat


func _process(delta: float) -> void:
	if _collected:
		return
	_time += delta
	# Smooth sine-wave hover.
	position.y = _base_y + sin(_time * bob_speed * TAU) * bob_height
	# Constant Y-axis spin.
	rotate_y(spin_speed * delta)


# ── Pickup ─────────────────────────────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	# Only react once, and only to the Player class.
	if _collected:
		return
	if not body is Player:
		return

	_collected = true
	# In Banana Frenzy, points are awarded by the manager — skip hunger.
	var gs : Node = Engine.get_singleton("GameSettings") if Engine.has_singleton("GameSettings") else get_node_or_null("/root/GameSettings")
	var is_bf : bool = gs != null and gs.selected_gamemode == "Banana Frenzy"
	if not is_bf:
		body.add_hunger(hunger_amount)
	# Buff bananas grant their buff on pickup.
	if buff_type != "" and body.has_method("apply_buff"):
		body.apply_buff(buff_type)
	picked_up.emit(body, hunger_amount)
	queue_free()
