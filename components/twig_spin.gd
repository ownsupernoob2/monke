class_name TwigSpin
extends Node3D

@export var grab_height : float = 0.2


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

	var grab_body := StaticBody3D.new()
	grab_body.name = "GrabBody"
	grab_body.collision_layer = 4
	grab_body.collision_mask = 0
	grab_body.position = Vector3(0.0, grab_height, 0.0)
	grab_body.set_meta("twig_spin", self)
	add_child(grab_body)

	var grab_col := CollisionShape3D.new()
	var grab_shape := SphereShape3D.new()
	grab_shape.radius = 0.15
	grab_col.shape = grab_shape
	grab_body.add_child(grab_col)


func grab_pos() -> Vector3:
	return global_position + Vector3(0.0, grab_height, 0.0)
