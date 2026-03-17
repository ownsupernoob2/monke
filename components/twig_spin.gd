class_name TwigSpin
extends Node3D

@export var orbit_radius : float = 2.4
@export var orbit_height : float = 0.2
@export var angular_damping : float = 0.985
@export var steer_accel : float = 4.5
@export var pump_impulse : float = 1.7


func _ready() -> void:
	var twig_mat := StandardMaterial3D.new()
	twig_mat.albedo_color = Color(0.40, 0.27, 0.14)

	var twig_mesh := CylinderMesh.new()
	twig_mesh.top_radius = 0.11
	twig_mesh.bottom_radius = 0.14
	twig_mesh.height = 1.6
	twig_mesh.radial_segments = 8

	var twig_vis := MeshInstance3D.new()
	twig_vis.mesh = twig_mesh
	twig_vis.set_surface_override_material(0, twig_mat)
	twig_vis.position = Vector3(0.0, 0.8, 0.0)
	add_child(twig_vis)

	var ring_body := StaticBody3D.new()
	ring_body.name = "GrabBody"
	ring_body.collision_layer = 4
	ring_body.collision_mask = 0
	ring_body.position = Vector3(0.0, orbit_height, 0.0)
	ring_body.set_meta("twig_spin", self)
	add_child(ring_body)

	var ring_col := CollisionShape3D.new()
	var ring_shape := SphereShape3D.new()
	ring_shape.radius = orbit_radius + 0.08
	ring_col.shape = ring_shape
	ring_body.add_child(ring_col)


func orbit_pos(theta: float) -> Vector3:
	var local := Vector3(cos(theta), 0.0, sin(theta)) * orbit_radius + Vector3(0.0, orbit_height, 0.0)
	return global_position + local


func tangent_dir(theta: float) -> Vector3:
	return Vector3(-sin(theta), 0.0, cos(theta)).normalized()


func project_angle(world_pos: Vector3) -> float:
	var local := world_pos - global_position
	return atan2(local.z, local.x)
