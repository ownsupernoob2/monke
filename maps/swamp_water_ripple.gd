extends Node

## Drives touch ripples on the swamp water shader.

@export var water_mesh_path : NodePath = NodePath("Swamp/WaterMesh")
@export var water_zone_path : NodePath = NodePath("Swamp/WaterZone")
@export var ripple_interval : float = 0.32

var _water_mesh : MeshInstance3D = null
var _water_zone : Area3D = null
var _water_material : ShaderMaterial = null
var _ripple_time : float = 999.0
var _pulse_timer : float = 0.0
var _touching_players : Dictionary = {}


func _ready() -> void:
	_water_mesh = get_node_or_null(water_mesh_path) as MeshInstance3D
	_water_zone = get_node_or_null(water_zone_path) as Area3D
	if _water_mesh and _water_mesh.get_surface_override_material(0) is ShaderMaterial:
		_water_material = _water_mesh.get_surface_override_material(0) as ShaderMaterial
	if _water_zone:
		_water_zone.body_entered.connect(_on_body_entered)
		_water_zone.body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	if _water_material == null:
		return
	_ripple_time += delta
	_water_material.set_shader_parameter("ripple_time", _ripple_time)

	if _touching_players.is_empty():
		return
	_pulse_timer -= delta
	if _pulse_timer <= 0.0:
		for body in _touching_players.values():
			if is_instance_valid(body):
				_trigger_ripple((body as Node3D).global_position)
				break
		_pulse_timer = ripple_interval


func _on_body_entered(body: Node) -> void:
	if not (body is Player):
		return
	_touching_players[body.get_instance_id()] = body
	_trigger_ripple((body as Node3D).global_position)
	_pulse_timer = ripple_interval


func _on_body_exited(body: Node) -> void:
	if not (body is Player):
		return
	_touching_players.erase(body.get_instance_id())


func _trigger_ripple(world_pos: Vector3) -> void:
	if _water_material == null:
		return
	_ripple_time = 0.0
	_water_material.set_shader_parameter("ripple_center_world", Vector2(world_pos.x, world_pos.z))
	_water_material.set_shader_parameter("ripple_time", _ripple_time)
