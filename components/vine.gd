class_name Vine
extends Node3D

# ── Chain constants ───────────────────────────────────────────────────────────
const LINK_COUNT  : int   = 8      ## Simulation nodes (1 anchor + 7 free).
const VINE_LENGTH : float = 6.0    ## Total rest length in metres.
const LINK_DIST   : float = VINE_LENGTH / (LINK_COUNT - 1)   ## ≈ 0.857 m.
const SEG_TOP_R   : float = 0.10   ## Cylinder top radius (thicker).
const SEG_BOT_R   : float = 0.18   ## Cylinder bottom radius (thick base).
const GRAVITY     : float = 9.8

@export var chain_damping : float = 0.985  ## Verlet velocity retention (0-1).
@export var chain_iters   : int   = 8      ## Gauss-Seidel iterations per frame.
@export var idle_sway     : float = 1.5    ## Idle sway speed (m/s), scaled by delta.
@export var segment_color : Color = Color(0.18, 0.38, 0.07):
	set(value):
		segment_color = value
		if _mat:
			_mat.albedo_color = value

## Fixed anchor at the very top of the vine (ceiling attachment).
@onready var grab_point : Marker3D = $GrabPoint

## Chain node world-space positions (verlet: current + previous).
var _pos      : PackedVector3Array
var _prev_pos : PackedVector3Array

## Procedurally created children.
var _links       : Array[VineLink]       = []
var _link_shapes : Array[CapsuleShape3D] = []   ## one shape per segment for fast height updates
var _segs        : Array[MeshInstance3D] = []

var _mat  : StandardMaterial3D
var _rng  := RandomNumberGenerator.new()

## Fixed world-space anchor set once in _ready().
var _anchor : Vector3

## Idle sway countdown timer.
var _sway_t : float = 0.0

## Grab influence – which chain node to attract toward _grab_target (-1 = none).
var _grab_idx    : int     = -1
var _grab_target : Vector3 = Vector3.ZERO


func _ready() -> void:
	_rng.randomize()
	$MeshInstance3D.visible = false        # replaced by procedural cylinders
	_anchor = grab_point.global_position
	_init_chain()
	_build_links()
	_build_segments()


# ── Initialisation ────────────────────────────────────────────────────────────

func _init_chain() -> void:
	_pos.resize(LINK_COUNT)
	_prev_pos.resize(LINK_COUNT)
	for i in LINK_COUNT:
		var p := _anchor + Vector3(0.0, -LINK_DIST * i, 0.0)
		_pos[i]      = p
		_prev_pos[i] = p


## Spawns LINK_COUNT-1 AnimatableBody3D (VineLink) nodes, one per visual segment.
## Each gets a CapsuleShape3D whose radius matches the visual cylinder at that
## point of the taper.  _apply_links() repositions and reorients them every frame
## so the collision hull always wraps the moving mesh exactly.
## Layer 2 / mask 0 keeps them invisible to CharacterBody3D.move_and_slide while
## the player's VineRay (mask 3 = layers 1+2) still detects them.
func _build_links() -> void:
	for i in LINK_COUNT - 1:
		# Radius at the midpoint of this segment – matches the visual taper.
		var t_mid := (float(i) + 0.5) / (LINK_COUNT - 1)
		var r_mid := lerpf(SEG_TOP_R, SEG_BOT_R, t_mid)
		var shape := CapsuleShape3D.new()
		shape.radius = r_mid
		# height must be >= 2*radius (Godot requirement); starts at rest length.
		shape.height = maxf(LINK_DIST, r_mid * 2.0 + 0.01)
		var link               := VineLink.new()
		link.root_vine          = self
		link.sync_to_physics    = false
		# Layer 2 / mask 0 keeps them invisible to CharacterBody3D.move_and_slide
		# while the player's VineRay (mask 3 = layers 1+2) still detects them.
		link.collision_layer    = 2
		link.collision_mask     = 0
		var col                := CollisionShape3D.new()
		col.shape               = shape
		link.add_child(col)
		add_child(link)
		_links.append(link)
		_link_shapes.append(shape)


## Spawns LINK_COUNT-1 CylinderMesh segments connecting adjacent chain nodes.
func _build_segments() -> void:
	_mat              = StandardMaterial3D.new()
	_mat.albedo_color = segment_color
	for i in LINK_COUNT - 1:
		var t0   := float(i)     / (LINK_COUNT - 1)
		var t1   := float(i + 1) / (LINK_COUNT - 1)
		var r0   := lerpf(SEG_TOP_R, SEG_BOT_R, t0)
		var r1   := lerpf(SEG_TOP_R, SEG_BOT_R, t1)
		var mesh := CylinderMesh.new()
		mesh.height          = LINK_DIST * 1.05   # slight overlap hides seams
		mesh.top_radius      = r0
		mesh.bottom_radius   = r1
		mesh.radial_segments = 5
		mesh.rings           = 1
		var mi               := MeshInstance3D.new()
		mi.mesh               = mesh
		mi.set_surface_override_material(0, _mat)
		add_child(mi)
		_segs.append(mi)


# ── Per-frame update ──────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	_simulate(delta)
	_apply_links()
	_update_visuals()


func _simulate(delta: float) -> void:
	# ── Idle sway impulse ─────────────────────────────────────────────────────
	# Fire a random horizontal kick at the lower half every 2-5 s so the vine
	# never hangs perfectly still.  Scaling by delta converts idle_sway from
	# m/s to the correct per-frame position delta that verlet expects.
	# Without delta: 0.5/frame × 60fps = 30 m/s → violent jumping. BUG.
	_sway_t -= delta
	if _sway_t <= 0.0:
		_sway_t = _rng.randf_range(2.0, 5.0)
		var dir := Vector3(
			_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0)
		).normalized()
		for i in range(LINK_COUNT >> 1, LINK_COUNT):
			_prev_pos[i] -= dir * idle_sway * delta

	# ── Verlet integrate (skip anchor node 0) ─────────────────────────────────
	# new_pos = pos + (pos - prev) * damping + gravity * dt²
	for i in range(1, LINK_COUNT):
		var cur  := _pos[i]
		var prev := _prev_pos[i]
		_prev_pos[i] = cur
		_pos[i]      = cur \
			+ (cur - prev) * chain_damping \
			+ Vector3(0.0, -GRAVITY, 0.0) * (delta * delta)

	# ── Grab influence ────────────────────────────────────────────────────────
	# Gently attract the grabbed chain node toward the player's world position
	# so the vine visually bends where the player holds it.
	# 0.05 lerp = 5% per frame — soft enough not to fight the constraint solver.
	# The index is set ONCE at grab time and never changed (avoids chain flap).
	if _grab_idx > 0:
		_pos[_grab_idx] = _pos[_grab_idx].lerp(_grab_target, 0.05)

	# ── Gauss-Seidel distance constraints ─────────────────────────────────────
	# Each pass enforces the rest-length between every adjacent pair of nodes.
	# The anchor is re-pinned at the start of every sub-step.
	# KEY: when i==1, _pos[0] is pinned — all correction goes to _pos[1] (×1.0).
	# When i>1, both nodes are free — split the correction equally (×0.5 each).
	# The previous code applied ×0.5 to _pos[1] only, under-correcting the first
	# link by half and leaking energy into the chain → oscillation / jumping.
	for _it in chain_iters:
		_pos[0] = _anchor
		for i in range(1, LINK_COUNT):
			var pa  := _pos[i - 1]
			var pb  := _pos[i]
			var ab  := pb - pa
			var d   := ab.length()
			if d < 0.001:
				continue
			var diff := ab * (1.0 - LINK_DIST / d)
			if i == 1:
				# Anchor is pinned: apply full correction to the first free node.
				_pos[1] -= diff
			else:
				# Both nodes free: split equally.
				_pos[i - 1] += diff * 0.5
				_pos[i]     -= diff * 0.5
		_pos[0] = _anchor   # guarantee anchor never drifts


## Move and orient each VineLink capsule to match its live visual segment.
## Position  = midpoint of the two adjacent chain nodes.
## Rotation   = +Y axis of the capsule aligned along the segment direction
##              (CapsuleShape3D height runs along local +Y in Godot 4).
## Height     = actual segment length this frame (chain stretches slightly
##              during large swings before constraints settle).
func _apply_links() -> void:
	for i in _links.size():   # LINK_COUNT - 1
		var a       := _pos[i]
		var b       := _pos[i + 1]
		var dir     := b - a
		var seg_len := dir.length()
		if seg_len < 0.001:
			continue
		# Update capsule height to live segment length (clamped >= 2r).
		var r := _link_shapes[i].radius
		_link_shapes[i].height = maxf(seg_len, r * 2.0 + 0.001)
		# Full transform: midpoint + basis whose +Y runs along the segment.
		_links[i].global_transform = Transform3D(
			_basis_from_dir(dir / seg_len), (a + b) * 0.5
		)


## Orient each cylinder segment to span from node i to node i+1.
func _update_visuals() -> void:
	for i in _segs.size():
		var a   := _pos[i]
		var b   := _pos[i + 1]
		var dir     := b - a
		var seg_len := dir.length()
		if seg_len < 0.001:
			continue
		_segs[i].global_transform = Transform3D(
			_basis_from_dir(dir / seg_len), (a + b) * 0.5
		)


## Builds a Basis whose +Y axis points along `up`.
## CylinderMesh has its height along local Y, so this correctly orients
## each segment between two chain nodes.
func _basis_from_dir(up: Vector3) -> Basis:
	var fw := Vector3.FORWARD
	if abs(up.dot(fw)) > 0.9:
		fw = Vector3.RIGHT
	var right := up.cross(fw).normalized()
	var fwd   := right.cross(up).normalized()
	return Basis(right, up, -fwd)


# ── Public API (called by Player) ────────────────────────────────────────────

## Register a grab: set which chain node to attract and the initial target.
## Call ONCE at grab time.  Never call per-frame — that changes the index each
## frame, making the chain flap between different nodes.
func set_grab(link_idx: int, target_world_pos: Vector3) -> void:
	_grab_idx    = link_idx
	_grab_target = target_world_pos


## Update only the attraction target while the player is swinging.
## Separated from set_grab so the index stays fixed for the whole grab duration.
func update_grab_target(target_world_pos: Vector3) -> void:
	_grab_target = target_world_pos


## Release grab influence so the vine swings freely.
func clear_grab() -> void:
	_grab_idx = -1


## World position of chain node i.
func link_pos(i: int) -> Vector3:
	return _pos[i]


## Index of the chain node whose world position is closest to world_pos.
func nearest_link(world_pos: Vector3) -> int:
	var best_i := 0
	var best_d := INF
	for i in LINK_COUNT:
		var d := _pos[i].distance_to(world_pos)
		if d < best_d:
			best_d = d
			best_i = i
	return best_i


## Push chain nodes near world_pos with an impulse.  Verlet integration
## applies the impulse as a position delta (velocity = pos − prev), so
## subtracting from _prev_pos is the correct way to inject energy.
func push_chain(world_pos: Vector3, impulse: Vector3) -> void:
	var idx := nearest_link(world_pos)
	# Affect the hit node and its immediate neighbours for a broader wobble.
	for i in range(maxi(1, idx - 1), mini(LINK_COUNT, idx + 2)):
		_prev_pos[i] -= impulse
