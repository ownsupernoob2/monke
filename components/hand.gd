class_name Hand
extends Node3D

# ── Exports ───────────────────────────────────────────────────────────────────
@export var rest_length    : float = 0.7   ## arm length while dangling
@export var grab_length    : float = 1.6   ## max reach when extending to a vine
@export var tip_damping    : float = 0.06  ## 0 = infinitely floppy, 1 = rigid
## Absolute maximum arm extension during a grab (metres).
@export var max_grab_reach : float = 5.0
## Spring stiffness for the rubber-band retraction (higher = snappier).
@export var grab_spring_k       : float = 28.0
## Spring damping — one-hand grab (underdamped = slight bounce).
@export var grab_spring_damp    : float = 6.0
## Spring damping — two-hand grab (more damped = gentler settle).
@export var grab_spring_damp_2h : float = 11.0

# ── State ─────────────────────────────────────────────────────────────────────
var _tip_world      : Vector3 = Vector3.ZERO
var _tip_vel        : Vector3 = Vector3.ZERO
var _is_grabbing    : bool    = false
var _grab_world     : Vector3 = Vector3.ZERO
var _grab_reach     : float   = 1.6
var _initialized    : bool    = false
## World position the free arm tracks; zero = floppy pendulum physics.
var _guided_target  : Vector3 = Vector3.ZERO
## Visually displayed arm length – springs toward _grab_reach on grab.
var _display_len    : float   = 0.7
var _display_vel    : float   = 0.0
## Active damping coefficient (set per grab, one-hand vs two-hand).
var _active_damp    : float   = 6.0

## When non-zero, the hand's global position is forced to this point every
## physics frame — implements the "shoulder anchor" ball-and-socket effect.
var pin_world : Vector3 = Vector3.ZERO
## Tracks whether pin_world has been applied at least once, so _tip_world
## can be seeded from the real shoulder position on the first pinned frame.
var _pin_applied : bool = false

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var pivot    : Node3D         = $Pivot
@onready var arm_mesh : MeshInstance3D = $Pivot/ArmMesh


func _ready() -> void:
	# Rotate the cylinder so its height-axis (local Y) aligns with Pivot's -Z.
	# After this rotation: cylinder starts at z=0 (shoulder) and extends toward -Z.
	arm_mesh.rotation_degrees.x = -90.0
	# Imported arm texture/mesh faces the opposite direction by default.
	arm_mesh.rotation_degrees.y = 180.0
	_set_arm_length(rest_length)


# ── Public API ────────────────────────────────────────────────────────────────

## Called by player when this hand grabs a vine.
## Pass two_handed=true when both hands are grabbing so the spring settles softer.
func grab(grab_world_pos: Vector3, two_handed: bool = false) -> void:
	var already := _is_grabbing
	_is_grabbing  = true
	_grab_world   = grab_world_pos
	_tip_vel      = Vector3.ZERO
	_grab_reach   = clampf((grab_world_pos - global_position).length(), 0.3, max_grab_reach)
	# Only reset the spring on a fresh grab, not when called every frame.
	if not already:
		_display_len  = max_grab_reach
		_display_vel  = 0.0
	_active_damp  = grab_spring_damp_2h if two_handed else grab_spring_damp


## Update the target world position while already grabbing (tracks moving vines).
func update_grab_pos(new_pos: Vector3) -> void:
	_grab_world = new_pos


## Switch damping after grab (e.g. partner grabs second vine mid-swing).
func set_two_handed(on: bool) -> void:
	_active_damp = grab_spring_damp_2h if on else grab_spring_damp


## Called by player when this hand releases a vine.
func release() -> void:
	_is_grabbing    = false
	_guided_target  = Vector3.ZERO
	_reset_tip()
	_tip_vel = global_transform.basis.z * 2.5


## Point the resting arm toward a world position instead of floppy physics.
## Player calls this every process frame for free/poo-holding hands.
func guide_to(world_pos: Vector3) -> void:
	_guided_target = world_pos
	_tip_vel       = Vector3.ZERO


# ── Physics ───────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	# Anchor shoulder to body side when ball-and-socket mode is active.
	if pin_world != Vector3.ZERO:
		global_position = pin_world
		# On the very first pinned frame, seed _tip_world from the socket
		# position so the arm hangs naturally from the torso immediately
		# instead of stuttering from the old scene-tree offset position.
		if not _pin_applied:
			_tip_world  = global_position + Vector3(0.0, -rest_length, 0.0)
			_tip_vel    = Vector3.ZERO
			_pin_applied = true

	# Defer initialisation to the first physics frame so global_position is valid.
	if not _initialized:
		_reset_tip()
		_initialized = true

	if _is_grabbing:
		_update_grab()
	else:
		_update_floppy(delta)


func _update_grab() -> void:
	var to_grab := _grab_world - global_position
	if to_grab.length_squared() < 0.001:
		return
	_grab_reach = clampf(to_grab.length(), 0.25, max_grab_reach)

	# Spring the displayed length toward the actual reach (rubber-band retraction).
	# F = -k*(x - target) - damp*v  →  second-order spring with damping.
	var delta := get_physics_process_delta_time()
	var force := -grab_spring_k * (_display_len - _grab_reach) \
				 - _active_damp * _display_vel
	_display_vel += force * delta
	_display_len += _display_vel * delta
	_display_len  = maxf(_display_len, 0.1)   # never collapse to zero

	_point_arm_at(_grab_world, _display_len)


func _update_floppy(delta: float) -> void:
	# When player sets a guide direction, track it instead of doing pendulum sim.
	if _guided_target.length_squared() > 0.001:
		_tip_world = _tip_world.lerp(_guided_target, minf(delta * 20.0, 1.0))
		_point_arm_at(_tip_world, rest_length)
		return

	const GRAVITY := 9.8

	# Particle gravity.
	_tip_vel.y -= GRAVITY * delta

	# Frame-rate-independent exponential damping.
	_tip_vel *= pow(1.0 - tip_damping, delta * 60.0)

	# Move the tip.
	_tip_world += _tip_vel * delta

	# Inextensible pendulum constraint: keep tip exactly rest_length away.
	var offset := _tip_world - global_position
	var dist   := offset.length()
	if dist > 0.001:
		_tip_world = global_position + offset.normalized() * rest_length
		# Cancel the radial (stretch) component of velocity so it can't escape.
		var dir   := offset.normalized()
		_tip_vel  -= dir * _tip_vel.dot(dir)

	_point_arm_at(_tip_world, rest_length)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _point_arm_at(target: Vector3, length: float) -> void:
	var to_target := target - global_position
	if to_target.length_squared() < 0.0001:
		return
	# Guard against degenerate up vector (arm pointing straight up/down).
	var up_hint := Vector3.UP
	if absf(to_target.normalized().dot(Vector3.UP)) > 0.98:
		up_hint = Vector3.FORWARD
	pivot.look_at(target, up_hint)
	_set_arm_length(length)


func _set_arm_length(length: float) -> void:
	# CylinderMesh height=1 unit. scale.y = actual length.
	# position.z = -length/2 so the arm base is at the pivot origin (shoulder)
	# and the tip is at z = -length.
	arm_mesh.scale.y    = length
	arm_mesh.position.z = -length * 0.5


func _reset_tip() -> void:
	# Tip starts directly in front of the hand in world space.
	_tip_world = global_position + global_transform.basis * Vector3(0, 0, -rest_length)
	_tip_vel   = Vector3.ZERO
