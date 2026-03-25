class_name Zipline
extends Node3D

## Two-point zipline cable.  Place the root node at the *start* anchor and set
## EndMarker's local position to locate the *end* anchor.  Visual cylinder and
## grab collision are built at runtime — the scene file only stores positions.
##
## Physics model (see Player._update_zipline_pivots):
##   • A frictionless ring slides along the cable.
##   • The ring's initial velocity = player's along-cable speed at grab time.
##   • Gravity accelerates the ring downhill; going uphill bleeds speed.
##   • The player hangs from the ring on a fixed-length rope (pendulum pivot
##     moves with the ring), reusing the existing vine constraint solver.

@onready var end_marker : Marker3D = $EndMarker

## Friction damping for the ring slide (0.0 = no friction/full speed, 1.0 = maximum friction).
@export var friction : float = 0.15

## World-space properties cached in _ready for use by Player physics.
var direction : Vector3 = Vector3.RIGHT
var start_pos : Vector3 = Vector3.ZERO
var end_pos   : Vector3 = Vector3.ZERO
var length    : float   = 1.0
var _visual_mesh : MeshInstance3D = null
var _grab_body : StaticBody3D = null
var _stream_enabled : bool = true


func _ready() -> void:
	start_pos = global_position
	end_pos   = end_marker.global_position
	var span  := end_pos - start_pos
	length    = span.length()
	if length > 0.001:
		direction = span / length
	_build_visual()
	_build_grab()


# ── Build ─────────────────────────────────────────────────────────────────────

func _build_visual() -> void:
	var mat               := StandardMaterial3D.new()
	mat.albedo_color       = Color(0.22, 0.18, 0.12)   # dark steel-cable colour
	mat.metallic           = 0.55
	mat.roughness          = 0.35
	var cyl               := CylinderMesh.new()
	cyl.top_radius         = 0.055
	cyl.bottom_radius      = 0.055
	cyl.height             = length
	cyl.radial_segments    = 6
	cyl.rings              = 1
	var mi                := MeshInstance3D.new()
	mi.mesh                = cyl
	mi.set_surface_override_material(0, mat)
	# Centre in local space, +Y running from start toward end.
	var local_dir         := end_marker.position.normalized()
	mi.transform           = Transform3D(_basis_from_dir(local_dir), end_marker.position * 0.5)
	add_child(mi)
	_visual_mesh = mi


func _build_grab() -> void:
	# Thin box hull along the full cable on layer 3 (value 4).
	# VineRay collision_mask = 7 (layers 1+2+3) detects it.
	# CharacterBody3D default mask = 1 passes through cleanly.
	var box          := BoxShape3D.new()
	box.size          = Vector3(0.5, length, 0.5)
	var col          := CollisionShape3D.new()
	col.shape         = box
	var body         := StaticBody3D.new()
	body.collision_layer = 4    # layer 3
	body.collision_mask  = 0
	var local_dir    := end_marker.position.normalized()
	body.transform    = Transform3D(_basis_from_dir(local_dir), end_marker.position * 0.5)
	body.add_child(col)
	# Back-reference so Player can recover this Zipline when a hit is detected.
	body.set_meta("zipline", self)
	add_child(body)
	_grab_body = body


func set_stream_enabled(enabled: bool) -> void:
	if _stream_enabled == enabled:
		return
	_stream_enabled = enabled
	visible = enabled
	if _visual_mesh:
		_visual_mesh.visible = enabled
	if _grab_body:
		_grab_body.collision_layer = 4 if enabled else 0


# ── Helpers ───────────────────────────────────────────────────────────────────

## Basis whose +Y axis aligns with `up` — same convention as vine.gd.
func _basis_from_dir(up: Vector3) -> Basis:
	var fw := Vector3.FORWARD
	if abs(up.dot(fw)) > 0.9:
		fw = Vector3.RIGHT
	var right := up.cross(fw).normalized()
	var fwd   := right.cross(up).normalized()
	return Basis(right, up, -fwd)


## World position of the slide ring at parameter t (metres from start, clamped).
func slide_pos(t: float) -> Vector3:
	return start_pos + direction * clampf(t, 0.0, length)


## Projects a world position onto the cable; returns t in [0, length].
func project_point(world_pos: Vector3) -> float:
	return clampf((world_pos - start_pos).dot(direction), 0.0, length)
