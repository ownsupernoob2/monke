class_name Player
extends CharacterBody3D

# ── Movement constants ────────────────────────────────────────────────────────
const GRAVITY           := 9.8

# ── Hunger settings (tweak in the Inspector) ──────────────────────────────────
@export var max_hunger             : float = 100.0
@export var hunger_drain_rate      : float = 0.65  ## gentler beginner drain
@export var starvation_death_delay : float = 10.0  ## seconds at zero before death

# ── Push settings (tweak in the Inspector) ────────────────────────────────────
## Velocity impulse applied per hand push (m/s).
@export var push_force     : float = 10.0
## Minimum seconds between successive pushes on the same hand.
@export var push_cooldown  : float = 0.35
## Fraction of max hunger consumed per hand push.
@export var push_hunger_cost_pct : float = 0.02
## Horizontal speed multiplier per physics frame while on the floor.
## 0.85^60fps ≈ stops in ~0.5 s – gives a crisp "planted" feel.
@export var floor_friction : float = 0.85
## Horizontal speed multiplier per physics frame while airborne.
## 0.9998^60fps ≈ 0.988/s — barely any drag so momentum carries naturally.
@export var air_damping    : float = 0.9998
## Minimum speed injected when grabbing a vine from a standstill.
## Gives the pendulum an initial kick so it swings immediately.
@export var swing_launch_speed : float = 2.5

# ── Release feel (tweak in the Inspector) ──────────────────────────────────────
## Speed multiplier applied on release in the full 3-D look direction.
## >1.0 gives a base launch even without combos.
@export var release_boost_mult : float = 1.35
## Hard speed cap (m/s) on release without any combo.  Combos exceed this.
@export var base_release_cap : float = 12.0
## Camera FOV at rest.
@export var fov_base       : float = 70.0
## Camera FOV at full swing speed (fov_speed_full m/s).
@export var fov_max        : float = 108.0
## Speed (m/s) at which FOV reaches fov_max.
@export var fov_speed_full : float = 14.0

# ── Combo system (tweak in the Inspector) ──────────────────────────────────────
## Max seconds to hold a vine before the alternating combo resets on release.
@export var combo_hold_limit       : float = 2.0
## Hunger drain reduction per combo step (0.15 = −15 % drain per step).
@export var combo_hunger_reduction : float = 0.15
## Minimum hunger drain multiplier at high combo (0.10 = 90 % reduction cap).
@export var min_hunger_drain_mult  : float = 0.10
## Extra release-boost fraction per combo step (0.06 = +6 % per step).
## No combo=×1.0 | ×2=×1.12 | ×5=×1.30 …
@export var combo_speed_bonus      : float = 0.06

# ── Swing feel (tweak in the Inspector) ──────────────────────────────────────
## Per-physics-frame velocity multiplier while grabbing a vine.
## At 60 fps: 0.992^60 ≈ 0.62/s — vines bleed off runaway speed naturally.
@export var swing_damping     : float = 0.992
## Hard speed ceiling while swinging (m/s). Prevents endless combo stacking.
@export var max_swing_speed   : float = 9.0
## Tangential force (m/s²) nudging velocity toward the look direction while
## grabbing. Small value = "bending" feel; physics still dominates.
@export var swing_steer_force : float = 3.0

# ── Poo system (tweak in the Inspector) ──────────────────────────────────────────
## Poo projectile scene – assigned via the Inspector (or Player.tscn).
@export var poo_scene       : PackedScene
## Temporary toggle while poo is being reworked.
@export var poo_enabled     : bool = false
## Hunger consumed when creating a poo.  Fails silently if hunger is below this.
@export var poo_hunger_cost : float = 10.0
## Launch speed of a thrown poo (m/s).
@export var poo_throw_force : float = 22.0
@export var black_speed_multiplier : float = 1.22
@export var blue_repulsion_force_mult : float = 1.75
@export var wind_dash_force : float = 12.5
@export var wind_dash_upward_boost : float = 2.2

const EFFECT_DURATION : float = 10.0
const ATTRACTION_RADIUS : float = 5.0
const ATTRACTION_PULL_SPEED : float = 4.5

# ── Multiplayer state ─────────────────────────────────────────────────────────
## True = this is the local player (gets camera/input). False = network puppet.
var is_local    : bool  = true
## Set by setup_network() to prevent _ready() from overriding is_local.
var _network_configured : bool = false
var _net_pos    : Vector3 = Vector3.ZERO  # target pos from authority
var _net_rot_y  : float   = 0.0          # target Y rotation
var _net_head_x : float   = 0.0          # target head pitch
var _net_left_grab : bool = false
var _net_right_grab : bool = false
var _net_left_grab_pos : Vector3 = Vector3.ZERO
var _net_right_grab_pos : Vector3 = Vector3.ZERO

# ── Runtime state ─────────────────────────────────────────────────────────────
var hunger      : float = 100.0
var is_dead     : bool  = false
var is_starving : bool  = false
var _hunger_enabled       : bool = true
var _hunger_passive_drain : bool = true  ## set false in Tag mode — only abilities cost hunger

# Per-player push cooldown (path → remaining seconds) to avoid spammy impulses.
var _player_push_cooldowns : Dictionary = {}

# Per-hand cooldown timers.
var _left_cooldown  : float = 0.0
var _right_cooldown : float = 0.0

# ── Vine / hand state ─────────────────────────────────────────────────────────────
enum HandState { FREE, GRABBING, HOLDING_POO }
var left_hand_state  : HandState = HandState.FREE
var right_hand_state : HandState = HandState.FREE
var left_grab_point  : Marker3D  = null   ## GrabPoint on the grabbed vine
var right_grab_point : Marker3D  = null

# ── Swing pivot state (set on grab, consumed by rope constraint every frame) ──
## World position of the vine's top anchor used as the pendulum pivot.
var _left_pivot     : Vector3 = Vector3.ZERO
var _left_rope_len  : float   = 0.0
var _right_pivot    : Vector3 = Vector3.ZERO
var _right_rope_len : float   = 0.0

## Live reference to the grabbed Vine so we can update its chain each frame.
var _left_vine  : Vine = null
var _right_vine : Vine = null

## Extra FOV degrees injected on a timed release; decays to 0 each frame.
var _fov_pulse : float = 0.0
var _active_buff : String = ""
var _buff_outline : MeshInstance3D = null
var _role_outline : MeshInstance3D = null
var _effect_timers : Dictionary = {}
var _effect_stacks : Dictionary = {}
var _effect_aura : MeshInstance3D = null
var _aura_time : float = 0.0
var _base_push_force : float = 0.0
var _base_release_cap : float = 0.0
var _base_max_swing_speed : float = 0.0
var _base_swing_launch_speed : float = 0.0
var _wind_dash_ready : bool = true
var _wind_dash_cooldown : float = 0.0

# ── Shift-lock (third-person) ─────────────────────────────────────────────────
var _shift_lock       : bool    = false
var _default_cam_pos  : Vector3 = Vector3.ZERO
const SHIFT_LOCK_CAM_OFFSET := Vector3(0.6, 0.3, 2.5)

# ── Combo state ───────────────────────────────────────────────────────────────
## Current alternating-grab streak.  0 = inactive.
var _combo            : int   = 0
## 0 = left grabbed last,  1 = right grabbed last,  -1 = no grab yet.
var _last_grab_hand   : int   = -1
## The vine grabbed most recently – grabbing it again breaks the combo.
var _last_vine        : Vine  = null
## Time (s) held on the vine since the most-recent grab.
var _combo_hold_timer : float = 0.0
## Chain-node index grabbed per hand (for live arm tracking).
var _left_grab_idx    : int   = -1
var _right_grab_idx   : int   = -1

# ── Poo state (per-hand) ──────────────────────────────────────────────────────
## Each hand independently tracks its own held poo visual.
var _left_poo_visual  : Node3D = null
var _right_poo_visual : Node3D = null
## Double-tap timers per hand.
var _left_dtap_timer  : float = 0.0
var _right_dtap_timer : float = 0.0
const DTAP_WINDOW     : float = 0.22  ## seconds – quick but intentional
## Input consumption flags:  set in _input when poo fires, checked by
## _check_vine_grab / _handle_push to suppress accidental grabs/pushes.
var _left_consumed    : bool  = false
var _right_consumed   : bool  = false
## Emitted every frame with the new hunger value (used by HUD).
signal hunger_changed(value: float, max_value: float)
## Emitted every frame while the starvation timer is running (0 = cancelled).
signal starvation_tick(time_left: float)
## Emitted once when the player actually dies.
signal player_died
## Emitted on every grab or combo reset – count is the new combo value.
signal combo_changed(count: int)
## Emitted every _process frame with the player's current speed in m/s.
signal speed_changed(speed: float)

# ── Cached node references ────────────────────────────────────────────────────
@onready var head               : Node3D   = $Head
@onready var camera             : Camera3D = $Head/Camera3D
@onready var hunger_death_timer : Timer    = $HungerDeathTimer
@onready var hud                           = $HUD
@onready var left_hand_ray      : RayCast3D  = $Head/LeftHandRay
@onready var right_hand_ray     : RayCast3D  = $Head/RightHandRay
@onready var vine_ray           : ShapeCast3D = $Head/VineRay
@onready var left_hand          : Hand        = $Head/LeftHand
@onready var right_hand         : Hand        = $Head/RightHand
@onready var torso              : MeshInstance3D = $Torso
@onready var left_shoulder_socket  : Marker3D = get_node_or_null("LeftShoulderSocket")
@onready var right_shoulder_socket : Marker3D = get_node_or_null("RightShoulderSocket")


func _ready() -> void:
	# Safety: in multiplayer ensure is_local matches authority even if
	# setup_network() was somehow missed. Skip if explicitly configured.
	if not _network_configured:
		if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			is_local = is_multiplayer_authority()

	# Create the floating name label shown above every player.
	_create_name_label()

	if not is_local:
		# This is a remote puppet — remove input, camera, HUD, raycasts entirely.
		camera.current = false
		# CanvasLayer ignores 'visible' — must remove HUD/PauseMenu from tree.
		hud.queue_free()
		hud = null
		if has_node("PauseMenu"):
			get_node("PauseMenu").queue_free()
		left_hand_ray.enabled = false
		right_hand_ray.enabled = false
		vine_ray.enabled = false
		hunger_death_timer.queue_free()
		_hunger_enabled = false
		return

	# ── Local player setup ──
	# Don't show own name label (first-person view; would clutter screen).
	if has_node("NameLabel3D"):
		get_node("NameLabel3D").visible = false
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	torso.visible = false  # first-person: don't render own body
	_default_cam_pos = camera.position

	# Register shift-lock input action (Q key).
	if not InputMap.has_action("shift_lock"):
		InputMap.add_action("shift_lock")
		var ev := InputEventKey.new()
		ev.keycode = KEY_Q
		InputMap.action_add_event("shift_lock", ev)

	# Wind Banana input action (Space).
	if not InputMap.has_action("air_dash"):
		InputMap.add_action("air_dash")
		var dash_ev := InputEventKey.new()
		dash_ev.keycode = KEY_SPACE
		InputMap.action_add_event("air_dash", dash_ev)

	_base_push_force = push_force
	_base_release_cap = base_release_cap
	_base_max_swing_speed = max_swing_speed
	_base_swing_launch_speed = swing_launch_speed
	_clear_effects()

	# Apply FOV from GameSettings.
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		fov_base = gs.fov
		camera.fov = gs.fov

	# Exclude the player's own body from all raycasts.
	left_hand_ray.add_exception(self)
	right_hand_ray.add_exception(self)
	vine_ray.add_exception(self)

	# Configure the starvation timer.
	hunger_death_timer.wait_time = starvation_death_delay
	hunger_death_timer.one_shot  = true
	hunger_death_timer.timeout.connect(_on_death_timer_timeout)

	# Wire hunger signals directly into the HUD (self-contained).
	hunger_changed.connect(hud.update_hunger)
	starvation_tick.connect(hud.update_starvation_timer)
	player_died.connect(hud.show_death_screen)
	combo_changed.connect(hud.update_combo)
	speed_changed.connect(hud.set_speed)

	# Prime the HUD with the starting value immediately.
	hunger_changed.emit(hunger, max_hunger)


## Called by main.gd right after instantiation, BEFORE _ready.
func setup_network(local : bool) -> void:
	is_local = local
	_network_configured = true


## Creates the floating name label shown above this player.
func _create_name_label() -> void:
	var peer_id : int = get_multiplayer_authority()
	var name_lbl := Label3D.new()
	name_lbl.name = "NameLabel3D"
	name_lbl.position = Vector3(0.0, 2.0, 0.0)
	name_lbl.font_size = 32
	name_lbl.outline_size = 8
	name_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_lbl.no_depth_test = true
	name_lbl.render_priority = 1
	name_lbl.modulate = Color.WHITE
	if has_node("/root/GameLobby"):
		name_lbl.text = GameLobby.display_name(peer_id)
		# Keep label up-to-date if the host deduplicates this player's name later.
		GameLobby.player_renamed.connect(
			func(renamed_id: int, new_name: String) -> void:
				if renamed_id == peer_id and is_instance_valid(name_lbl):
					name_lbl.text = new_name
		)
	else:
		name_lbl.text = "Player %d" % peer_id
	add_child(name_lbl)


func _input(event: InputEvent) -> void:
	if not is_local or is_dead:
		return

	# ── Shift-lock toggle (Q) ─────────────────────────────────────────────────
	if event.is_action_pressed("shift_lock"):
		_shift_lock = not _shift_lock
		camera.position = SHIFT_LOCK_CAM_OFFSET if _shift_lock else _default_cam_pos
		torso.visible = _shift_lock
		if _buff_outline and is_instance_valid(_buff_outline):
			_buff_outline.visible = _shift_lock
		get_viewport().set_input_as_handled()
		return

	# ── Mouse look ────────────────────────────────────────────────────────────
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens : float = 0.003
		if has_node("/root/GameSettings"):
			var gs : Node = get_node("/root/GameSettings")
			sens = gs.mouse_sensitivity * 0.006
		rotate_y(-event.relative.x * sens)
		head.rotate_x(-event.relative.y * sens)
		head.rotation.x = clamp(head.rotation.x, -PI / 2.0, PI / 2.0)

	# ── Poo: quick double-tap LMB / RMB ──────────────────────────────────────────
	# First tap opens a 0.22 s window.  Second tap inside the window either:
	#   • spawns a poo in that hand (if FREE)
	#   • (holding poo handled below regardless of window)
	# Any tap while that hand is HOLDING_POO = throw immediately.
	# Setting _*_consumed = true blocks vine grab / push for this input event.
	if poo_enabled:
		if event.is_action_pressed("push_left"):
			if left_hand_state == HandState.HOLDING_POO:
				_throw_poo(true)
				_left_consumed = true
			elif _left_dtap_timer > 0.0 and left_hand_state == HandState.FREE:
				_try_create_poo(true)
				_left_consumed  = true
				_left_dtap_timer = 0.0
			else:
				_left_dtap_timer = DTAP_WINDOW

		if event.is_action_pressed("push_right"):
			if right_hand_state == HandState.HOLDING_POO:
				_throw_poo(false)
				_right_consumed = true
			elif _right_dtap_timer > 0.0 and right_hand_state == HandState.FREE:
				_try_create_poo(false)
				_right_consumed  = true
				_right_dtap_timer = 0.0
			else:
				_right_dtap_timer = DTAP_WINDOW


func _physics_process(delta: float) -> void:
	# ── Ball-and-socket shoulder pins ────────────────────────────────────────
	# Pin each hand's global origin to the torso sides so arms always start
	# from the shoulders regardless of head rotation.
	var _basis := global_transform.basis
	var _lpin := left_shoulder_socket.global_position  if left_shoulder_socket  else global_position + _basis * Vector3(-0.35, 0.9, 0.0)
	var _rpin := right_shoulder_socket.global_position if right_shoulder_socket else global_position + _basis * Vector3( 0.35, 0.9, 0.0)
	left_hand.pin_world  = _lpin
	right_hand.pin_world = _rpin

	# ── Puppet interpolation ─────────────────────────────────────────────────
	if not is_local:
		global_position = global_position.lerp(_net_pos, delta * 15.0)
		rotation.y = lerp_angle(rotation.y, _net_rot_y, delta * 15.0)
		head.rotation.x = lerp_angle(head.rotation.x, _net_head_x, delta * 15.0)
		# Recompute pins with the freshly-interpolated position.
		var _nb := global_transform.basis
		left_hand.pin_world  = left_shoulder_socket.global_position  if left_shoulder_socket  else global_position + _nb * Vector3(-0.35, 0.9, 0.0)
		right_hand.pin_world = right_shoulder_socket.global_position if right_shoulder_socket else global_position + _nb * Vector3( 0.35, 0.9, 0.0)
		# Keep remote hand targets alive between packets so arm stretch stays smooth.
		if _net_left_grab:
			if left_hand_state != HandState.GRABBING:
				left_hand.grab(_net_left_grab_pos)
			else:
				left_hand.update_grab_pos(_net_left_grab_pos)
			left_hand_state = HandState.GRABBING
		elif left_hand_state == HandState.GRABBING:
			left_hand.release()
			left_hand_state = HandState.FREE
		if _net_right_grab:
			if right_hand_state != HandState.GRABBING:
				right_hand.grab(_net_right_grab_pos)
			else:
				right_hand.update_grab_pos(_net_right_grab_pos)
			right_hand_state = HandState.GRABBING
		elif right_hand_state == HandState.GRABBING:
			right_hand.release()
			right_hand_state = HandState.FREE
		_tick_effects(delta)
		_update_effect_aura(delta)
		return

	if is_dead:
		return
	if not poo_enabled:
		_clear_held_poo()

	# ── 1. Release check ──────────────────────────────────────────────────────
	if Input.is_action_just_released("push_left") and left_hand_state == HandState.GRABBING:
		_release_hand(true)
	if Input.is_action_just_released("push_right") and right_hand_state == HandState.GRABBING:
		_release_hand(false)

	# ── 2. Vine grab (runs even while swinging one hand – Tarzan-style lunge) ──
	_check_vine_grab()

	# ── 3. Cooldowns tick always so push is ready the instant you land ─────────
	_tick_cooldowns(delta)

	# ── 4. Gravity (applies in both swing and free-flight) ─────────────────────
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	if is_on_floor() or _is_grabbing():
		_wind_dash_ready = true
	_wind_dash_cooldown = maxf(_wind_dash_cooldown - delta, 0.0)
	_tick_effects(delta)
	_apply_attraction(delta)

	# ── 5. Swinging branch ────────────────────────────────────────────────────
	if _is_grabbing():
		_combo_hold_timer += delta

		# Notify each grabbed vine of the player's current world position so
		# the chain bends toward the player while swinging.
		# update_grab_target only updates the attraction point — the grabbed
		# node index was locked at grab time and must NOT change each frame or
		# the chain will flap between nodes, fighting the constraint solver.
		if _left_vine:
			_left_vine.update_grab_target(global_position)
		if _right_vine:
			_right_vine.update_grab_target(global_position)

		# ── Swing steering ────────────────────────────────────────────────────
		# Nudge velocity toward the 3-D look direction, but only along the
		# tangent of the rope (radial component stripped out) so we never
		# fight the constraint solver.  Gives a physics-respecting "lean".
		var _steer_look := -head.global_transform.basis.z
		var _radial     := Vector3.ZERO
		var _rpivot_n   := 0
		if left_hand_state  == HandState.GRABBING:
			_radial  += (_left_pivot  - global_position).normalized(); _rpivot_n += 1
		if right_hand_state == HandState.GRABBING:
			_radial  += (_right_pivot - global_position).normalized(); _rpivot_n += 1
		if _rpivot_n > 0:
			var _rad_dir := (_radial / _rpivot_n).normalized()
			var _tan     := _steer_look - _rad_dir * _steer_look.dot(_rad_dir)
			if _tan.length_squared() > 0.001:
				velocity += _tan.normalized() * swing_steer_force * delta

		# ── Stage 1 · Pre-move velocity projection ────────────────────────────
		# Remove the outward-radial velocity component BEFORE move_and_slide.
		# This is the kinematic equivalent of rope-tension force: gravity's
		# radial pull is cancelled each frame, leaving only the tangential
		# component that accelerates the player along the pendulum arc.
		# Without this step the player moves through the sphere then snaps
		# back — the source of all visible jitter.
		# 3 Gauss-Seidel passes converge both hand constraints simultaneously.
		for _iter in 3:
			if left_hand_state == HandState.GRABBING:
				_project_swing_velocity(_left_pivot, _left_rope_len)
			if right_hand_state == HandState.GRABBING:
				_project_swing_velocity(_right_pivot, _right_rope_len)

		# move_and_slide lets the player land on platforms while mid-swing.
		move_and_slide()

		# ── Stage 2 · Post-move drift correction ──────────────────────────────
		for _iter in 3:
			if left_hand_state == HandState.GRABBING:
				_correct_rope_length(_left_pivot, _left_rope_len)
			if right_hand_state == HandState.GRABBING:
				_correct_rope_length(_right_pivot, _right_rope_len)

		# ── Swing damping + speed cap ──────────────────────────────────────────
		# Bleed off energy so vines can't stack speed infinitely.
		velocity *= pow(swing_damping, delta * 60.0)
		var _swing_spd := velocity.length()
		if _swing_spd > max_swing_speed:
			velocity = velocity * (max_swing_speed / _swing_spd)

		# ── Live arm tracking ─────────────────────────────────────────────────
		# Point each hand's arm at the actual moving chain node it grabbed.
		if _left_vine and _left_grab_idx >= 0:
			left_hand.update_grab_pos(_left_vine.link_pos(_left_grab_idx))
		if _right_vine and _right_grab_idx >= 0:
			right_hand.update_grab_pos(_right_vine.link_pos(_right_grab_idx))
		return

	# ── 6. Free-flight / grounded branch ─────────────────────────────────────
	if is_on_floor():
		if _combo > 0:
			_combo = 0
			combo_changed.emit(_combo)
		velocity.x *= floor_friction
		velocity.z *= floor_friction
	else:
		velocity.x *= air_damping
		velocity.z *= air_damping

	_handle_push()
	_handle_wind_dash()
	move_and_slide()
	_check_player_collisions()
	_left_consumed  = false
	_right_consumed = false


func _process(delta: float) -> void:
	if not is_local:
		return
	if is_dead:
		return
	_update_effect_aura(delta)
	_update_effect_ui()

	# Send our position and hand state to all other peers every frame.
	if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		var _l_grab := left_hand_state == HandState.GRABBING
		var _r_grab := right_hand_state == HandState.GRABBING
		var stacks : int = int(_effect_stacks.get(_active_buff, 0)) if _active_buff != "" else 0
		var time_left : float = float(_effect_timers.get(_active_buff, 0.0)) if _active_buff != "" else 0.0
		rpc("_rpc_sync_transform", global_position, rotation.y, head.rotation.x,
			_l_grab, left_hand._grab_world if _l_grab else Vector3.ZERO,
			_r_grab, right_hand._grab_world if _r_grab else Vector3.ZERO,
			_active_buff, int(stacks), float(time_left))

	_tick_hunger(delta)
	# Stream live countdown to HUD every frame while the timer is running.
	if is_starving and hunger_death_timer and not hunger_death_timer.is_stopped():
		starvation_tick.emit(hunger_death_timer.time_left)
	# Tint crosshair yellow when a VineLink is within reach of the shape cast.
	var targeting := false
	if vine_ray.is_colliding():
		for i in vine_ray.get_collision_count():
			if vine_ray.get_collider(i) is VineLink:
				targeting = true
				break
	if hud:
		hud.set_vine_targeted(targeting)

	# ── Dynamic FOV ─────────────────────────────────────────────────────
	# Pick up live FOV changes from the pause-menu slider.
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		fov_base = gs.fov
	# Base: quadratic ramp from fov_base at rest to fov_max at fov_speed_full.
	# Pulse: flat spike added on a timed release, decays at 40°/s so it lasts
	#        ~0.45 s — just long enough to register as a camera flick.
	_fov_pulse = maxf(_fov_pulse - delta * 35.0, 0.0)
	var spd        := velocity.length()
	var t          := clampf(spd / fov_speed_full, 0.0, 1.0)
	var target_fov := fov_base + (fov_max - fov_base) * t * t + _fov_pulse
	camera.fov      = lerpf(camera.fov, target_fov, delta * 4.0)
	speed_changed.emit(spd)

	# Track each held poo visual independently.
	if _left_poo_visual != null:
		left_hand.grab(_left_poo_visual.global_position)
	if _right_poo_visual != null:
		right_hand.grab(_right_poo_visual.global_position)

	# Free hands dangle with floppy pendulum physics (don't guide them).
	# Only poo-holding hands track the look direction.
	var _look_fwd := -head.global_transform.basis.z
	if left_hand_state  == HandState.HOLDING_POO:
		left_hand.guide_to(left_hand.global_position + _look_fwd * 0.8)
	if right_hand_state == HandState.HOLDING_POO:
		right_hand.guide_to(right_hand.global_position + _look_fwd * 0.8)


# ── Push system ───────────────────────────────────────────────────────────────

func _tick_cooldowns(delta: float) -> void:
	_left_cooldown   = maxf(_left_cooldown  - delta, 0.0)
	_right_cooldown  = maxf(_right_cooldown - delta, 0.0)
	_left_dtap_timer = maxf(_left_dtap_timer - delta, 0.0)
	_right_dtap_timer = maxf(_right_dtap_timer - delta, 0.0)
	# Tick per-player bump cooldowns.
	for key in _player_push_cooldowns.keys():
		_player_push_cooldowns[key] -= delta
		if _player_push_cooldowns[key] <= 0.0:
			_player_push_cooldowns.erase(key)


## Vine-grab input – runs every physics frame, even while swinging one hand,
## so the player can lunge for a second vine Tarzan-style mid-swing.
## Grab takes absolute priority; if both LMB and RMB are pressed the same frame
## they both grab the same vine (two-hand hang).
func _check_vine_grab() -> void:
	if not vine_ray.is_colliding():
		return
	# ShapeCast3D may hit walls (layer 1) before the vine (layer 2).
	# Walk all hits and take the first VineLink found.
	var link      : VineLink = null
	var hit_point : Vector3  = Vector3.ZERO
	for i in vine_ray.get_collision_count():
		var c := vine_ray.get_collider(i) as VineLink
		if c:
			link      = c
			hit_point = vine_ray.get_collision_point(i)
			break
	if not link:
		return
	var vine   : Vine    = link.root_vine
	# Physics pivot = fixed top anchor (verlet node 0, never moves).
	# Visual hit    = exact surface point the shape struck on the chain.
	var anchor : Vector3 = vine.grab_point.global_position
	# Grab on click OR auto-attach while holding the button (ease of use).
	var left_want  := (Input.is_action_just_pressed("push_left") or Input.is_action_pressed("push_left")) \
			and left_hand_state == HandState.FREE and not _left_consumed
	var right_want := (Input.is_action_just_pressed("push_right") or Input.is_action_pressed("push_right")) \
			and right_hand_state == HandState.FREE and not _right_consumed
	if left_want:
		_grab_vine(vine, true, anchor, hit_point)
	if right_want:
		_grab_vine(vine, false, anchor, hit_point)


## Push input – only reached when both hands are FREE (not grabbing a vine).
## Averages valid push directions and scales force by hand count (1 or 2 hands).
func _handle_push() -> void:
	# Cannot push with empty hunger – no energy.
	if _hunger_enabled and hunger <= 0.0:
		return
	var push_dirs : Array[Vector3] = []

	if Input.is_action_just_pressed("push_left") and not _left_consumed:
		if left_hand_state == HandState.FREE and _left_cooldown <= 0.0 \
				and left_hand_ray.is_colliding() \
				and not left_hand_ray.get_collider() is Vine:
			push_dirs.append(_push_dir_from(left_hand_ray))
			_left_cooldown = push_cooldown

	if Input.is_action_just_pressed("push_right") and not _right_consumed:
		if right_hand_state == HandState.FREE and _right_cooldown <= 0.0 \
				and right_hand_ray.is_colliding() \
				and not right_hand_ray.get_collider() is Vine:
			push_dirs.append(_push_dir_from(right_hand_ray))
			_right_cooldown = push_cooldown

	if push_dirs.is_empty():
		return

	var combined := Vector3.ZERO
	for d in push_dirs:
		combined += d
	velocity += combined.normalized() * push_force * push_dirs.size()

	# Optional hunger cost for pushes.
	if _hunger_enabled:
		hunger = clampf(hunger - push_dirs.size() * push_hunger_cost_pct * max_hunger, 0.0, max_hunger)
		hunger_changed.emit(hunger, max_hunger)



## Attach a hand to the vine at the exact ray-hit point on its surface.
## anchor     = vine_ray.get_collision_point() – the touched surface point.
## rope_len   = current distance from player to anchor (natural hang length).
## Clamped to 0.5 m minimum so a zero-distance grab doesn't collapse the sim.
func _grab_vine(vine: Vine, is_left: bool, anchor: Vector3, hit_point: Vector3) -> void:
	# Use hit_point (the actual surface contact on the vine) to find the nearest
	# chain link, so the arm tracks the segment that was visually touched.
	var link_idx := vine.nearest_link(hit_point)

	# ── Combo check ───────────────────────────────────────────────────────────
	# Rewards L→R→L alternation across DIFFERENT vines.
	# Breaking rules → reset to 0 (not 1) so you have to earn the first step.
	var this_hand_id := 0 if is_left else 1
	var other_vine   := _right_vine if is_left else _left_vine
	var same_vine_as_last := (_last_vine == vine)
	if same_vine_as_last:
		# Spamming the same vine – kill the streak entirely.
		_combo = 0
	elif other_vine != null and other_vine == vine:
		# Both hands on the same vine at once = hang, not a combo swing.
		pass   # don't touch _combo
	else:
		if _last_grab_hand == -1 or this_hand_id != _last_grab_hand:
			_combo += 1   # first grab or correct alternation
		else:
			_combo = 1    # same hand twice – restart at 1
	_last_grab_hand   = this_hand_id
	_last_vine        = vine
	_combo_hold_timer = 0.0
	combo_changed.emit(_combo)

	# ── Launch kick ─────────────────────────────────────────────────────────────
	# If the player grabs a vine while standing still (or moving slowly), the
	# pendulum has no initial velocity and just hangs.  Inject a horizontal
	# kick in the player's current look direction so the swing starts at once.
	# The kick is proportional to how much speed is missing up to launch_speed.
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	if horiz_speed < swing_launch_speed:
		var fwd := -global_transform.basis.z   # player's horizontal forward
		fwd.y    = 0.0
		if fwd.length_squared() > 0.001:
			fwd = fwd.normalized()
			velocity += fwd * (swing_launch_speed - horiz_speed)

	var _chain_pos := vine.link_pos(link_idx)   # actual visual node world position
	# Use the ray hit point for the hand visual so the arm reaches to exactly
	# where the vine was touched, not the nearest chain node centre.
	if is_left:
		var other_already := right_hand_state == HandState.GRABBING
		left_hand_state  = HandState.GRABBING
		left_grab_point  = vine.grab_point
		_left_pivot      = anchor
		_left_rope_len   = maxf((global_position - anchor).length(), 0.5)
		_left_vine       = vine
		_left_grab_idx   = link_idx
		vine.set_grab(link_idx, global_position)
		left_hand.grab(hit_point, other_already)   # ray hit surface, not chain centre
		if other_already:
			right_hand.set_two_handed(true)
	else:
		var other_already := left_hand_state == HandState.GRABBING
		right_hand_state = HandState.GRABBING
		right_grab_point = vine.grab_point
		_right_pivot     = anchor
		_right_rope_len  = maxf((global_position - anchor).length(), 0.5)
		_right_vine      = vine
		_right_grab_idx  = link_idx
		vine.set_grab(link_idx, global_position)
		right_hand.grab(hit_point, other_already)  # ray hit surface, not chain centre
		if other_already:
			left_hand.set_two_handed(true)


## Detach a hand from its vine.
func _release_hand(is_left: bool) -> void:
	# ── Release boost ──────────────────────────────────────────────────────
	# Fires only when the LAST hand releases (the true launch moment).
	# Release always snaps to a guaranteed launch speed, so even low-momentum
	# players regain control immediately. Combo increases that guaranteed speed.
	var other_grabbing := (right_hand_state == HandState.GRABBING) if is_left \
						else (left_hand_state  == HandState.GRABBING)
	if not other_grabbing:
		# Base launch speed is always guaranteed, independent of prior velocity.
		# Combo unlocks additional speed above that base.
		var look_dir := (-head.global_transform.basis.z).normalized()
		var release_spd := base_release_cap + _combo * 1.5
		velocity = look_dir * release_spd
		_fov_pulse = clampf(release_spd * 1.5 + _combo * 1.5, 8.0, 36.0)
		if _combo_hold_timer > combo_hold_limit:
			_combo = 0
			combo_changed.emit(_combo)

	if is_left:
		left_hand_state = HandState.FREE
		left_grab_point = null
		_left_grab_idx  = -1
		if _left_vine:
			_left_vine.clear_grab()
			_left_vine = null
		left_hand.release()
	else:
		right_hand_state = HandState.FREE
		right_grab_point = null
		_right_grab_idx  = -1
		if _right_vine:
			_right_vine.clear_grab()
			_right_vine = null
		right_hand.release()


## True when at least one hand is holding a vine.
func _is_grabbing() -> bool:
	return left_hand_state == HandState.GRABBING or right_hand_state == HandState.GRABBING


## Stage 1 — Pre-move velocity projection.
## Removes the outward-radial velocity component while the rope is taut.
## Physically: rope tension is an impulsive constraint force that eliminates
## any velocity pulling the player away from the pivot.  Gravity's tangential
## component is preserved, accelerating the player along the pendulum arc.
## Slack rope (dist < rope_len) is left unconstrained — pure free-fall.
func _project_swing_velocity(pivot: Vector3, rope_len: float) -> void:
	var to_player := global_position - pivot
	var dist      := to_player.length()
	if dist < 0.001:
		return
	if dist < rope_len:                   # rope slack — no tension active
		return
	var radial_dir  := to_player / dist
	var outward_vel := velocity.dot(radial_dir)
	if outward_vel > 0.0:                 # only cancel the stretching part
		velocity -= radial_dir * outward_vel


## Stage 2 — Post-move positional drift correction.
## Corrects floating-point error that accumulates because move_and_slide
## integrates a straight chord rather than the curved arc.  After snapping
## position back to the rope sphere, any radial velocity that move_and_slide
## may have re-introduced (e.g. sliding against a surface mid-swing) is also
## removed, preventing a rebound impulse on the next frame.
func _correct_rope_length(pivot: Vector3, rope_len: float) -> void:
	var diff := global_position - pivot
	var dist := diff.length()
	if dist < 0.001 or dist <= rope_len:
		return
	var dir := diff / dist
	global_position  = pivot + dir * rope_len   # positional correction
	var away_vel := velocity.dot(dir)
	if away_vel > 0.0:
		velocity -= dir * away_vel              # velocity correction


## Returns the impulse direction: exact reverse of the ray's shoot direction.
## When looking straight down the ray shoots -Y so the push is +Y (straight up).
## Works correctly at any angle without any per-hand-position offset error.
func _push_dir_from(ray: RayCast3D) -> Vector3:
	# The ray fires along its local -Z. Its local +Z is the exact opposite.
	return ray.global_transform.basis.z.normalized()


## After every move_and_slide, check collision results for VineLinks.
## Push the vine's chain so it swings away realistically, and slow the player.
func _push_hit_vines() -> void:
	for i in get_slide_collision_count():
		var col   := get_slide_collision(i)
		var body  := col.get_collider()
		if body is VineLink:
			var vine : Vine = body.root_vine
			# Don't push the vine you're currently holding.
			if vine == _left_vine or vine == _right_vine:
				continue
			var hit_pos  := col.get_position()
			var _hit_norm := col.get_normal()              # points away from the vine toward us
			var spd      := velocity.length()
			# Push vine in the player's travel direction, scaled by speed.
			var push     := velocity.normalized() * minf(spd * 0.08, 0.5)
			vine.push_chain(hit_pos, push)
			# Slow down the player proportionally.
			velocity *= maxf(1.0 - spd * 0.01, 0.7)


## When colliding with another CharacterBody3D player, apply a mutual bump impulse.
## Local player only — the RPC notifies the remote peer to push back on their end.
func _check_player_collisions() -> void:
	if not is_local or is_dead:
		return
	for i in get_slide_collision_count():
		var body := get_slide_collision(i).get_collider()
		if not (body is Player) or body == self:
			continue
		var other : Player = body as Player
		var path_key : String = str(other.get_path())
		if _player_push_cooldowns.has(path_key):
			continue  # still on cooldown for this target
		_player_push_cooldowns[path_key] = 0.4  # 0.4 s cooldown per target
		# Direction: from self outward toward the other player (horizontal).
		var dir := (other.global_position - global_position)
		dir.y = 0.0
		if dir.length_squared() < 0.001:
			dir = -global_transform.basis.z  # fallback: push in facing dir
		dir = dir.normalized()
		var bump_force : float = 4.5
		var self_recoil_mult : float = 0.5
		if _active_buff == "Repulsor" and _is_tag_it_peer(other.get_multiplayer_authority()):
			var stacks := int(_effect_stacks.get("Repulsor", 1))
			bump_force *= blue_repulsion_force_mult + float(maxi(stacks - 1, 0)) * 0.20
			self_recoil_mult = 0.18
		# Push self backward.
		velocity += -dir * bump_force * self_recoil_mult
		# Ask the other player's authoritative machine to apply the forward push.
		other.rpc_id(other.get_multiplayer_authority(), "receive_push", dir, bump_force)


func _handle_wind_dash() -> void:
	if _active_buff != "Wind Rider":
		return
	if is_on_floor() or _is_grabbing():
		return
	if not _wind_dash_ready or _wind_dash_cooldown > 0.0:
		return
	if not Input.is_action_just_pressed("air_dash"):
		return
	var stacks := int(_effect_stacks.get("Wind Rider", 1))
	var dir := (-head.global_transform.basis.z).normalized()
	velocity += dir * (wind_dash_force + float(maxi(stacks - 1, 0)) * 1.4)
	velocity.y = maxf(velocity.y, 0.0) + wind_dash_upward_boost
	_wind_dash_ready = false
	_wind_dash_cooldown = 0.35
	_fov_pulse = maxf(_fov_pulse, 10.0)


# ── Poo creation / throw ─────────────────────────────────────────────────────

func _try_create_poo(is_left: bool) -> void:
	if not poo_enabled:
		return
	if hunger < poo_hunger_cost:
		return
	# Already holding a poo in this hand – can't stack.
	if is_left and _left_poo_visual != null:
		return
	if not is_left and _right_poo_visual != null:
		return

	hunger = clampf(hunger - poo_hunger_cost, 0.0, max_hunger)
	hunger_changed.emit(hunger, max_hunger)

	var poo_hand := left_hand if is_left else right_hand
	var visual   := MeshInstance3D.new()
	var sphere   := SphereMesh.new()
	sphere.radius = 0.13
	sphere.height = 0.26
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.28, 0.15, 0.04)
	visual.mesh = sphere
	visual.set_surface_override_material(0, mat)
	poo_hand.add_child(visual)
	visual.position = Vector3(0.0, 0.0, -0.7)

	if is_left:
		_left_poo_visual = visual
		left_hand_state  = HandState.HOLDING_POO
	else:
		_right_poo_visual = visual
		right_hand_state  = HandState.HOLDING_POO

	poo_hand.grab(visual.global_position)


func _throw_poo(is_left: bool) -> void:
	if not poo_enabled:
		return
	var visual := _left_poo_visual if is_left else _right_poo_visual
	if visual == null:
		return

	var throw_pos := visual.global_position
	var throw_dir := -head.global_transform.basis.z

	visual.queue_free()
	if is_left:
		_left_poo_visual = null
		left_hand_state  = HandState.FREE
		left_hand.release()
	else:
		_right_poo_visual = null
		right_hand_state  = HandState.FREE
		right_hand.release()

	if poo_scene:
		var poo : Poo = poo_scene.instantiate() as Poo
		get_parent().add_child(poo)
		poo.global_position = throw_pos
		poo.setup(self)
		poo.throw(throw_dir, poo_throw_force)


# ── Hunger logic ──────────────────────────────────────────────────────────────

func _tick_hunger(delta: float) -> void:
	if not _hunger_enabled or not _hunger_passive_drain or not is_local:
		return
	# High combo = less hunger drain (reward for skilful alternating swings).
	var drain_mult := maxf(1.0 - _combo * combo_hunger_reduction, min_hunger_drain_mult)
	hunger = clamp(hunger - hunger_drain_rate * drain_mult * delta, 0.0, max_hunger)
	hunger_changed.emit(hunger, max_hunger)

	if hunger <= 0.0:
		if not is_starving:
			is_starving = true
			if hunger_death_timer and not hunger_death_timer.is_queued_for_deletion():
				hunger_death_timer.start()
	else:
		if is_starving:
			# Hunger recovered – cancel the death countdown.
			is_starving = false
			if hunger_death_timer and not hunger_death_timer.is_queued_for_deletion():
				hunger_death_timer.stop()
			starvation_tick.emit(0.0)


## Public API – call this from banana pickups (implemented later).
func add_hunger(amount: float) -> void:
	hunger = clamp(hunger + amount, 0.0, max_hunger)
	hunger_changed.emit(hunger, max_hunger)


## Disable the hunger system entirely (playground option).
func set_hunger_enabled(enabled: bool) -> void:
	_hunger_enabled = enabled
	if not enabled:
		hunger = max_hunger
		hunger_changed.emit(hunger, max_hunger)
		if is_starving:
			is_starving = false
			if hunger_death_timer and not hunger_death_timer.is_queued_for_deletion():
				hunger_death_timer.stop()
			starvation_tick.emit(0.0)
		if hud and hud.has_node("Control/TopLeft"):
			hud.get_node("Control/TopLeft").visible = false
	elif hud and hud.has_node("Control/TopLeft"):
		hud.get_node("Control/TopLeft").visible = true


## Disable only the passive hunger drain; ability costs (poo, push) still apply.
func set_hunger_passive_drain(enabled: bool) -> void:
	_hunger_passive_drain = enabled
	if not enabled and is_starving:
		is_starving = false
		if hunger_death_timer and not hunger_death_timer.is_queued_for_deletion():
			hunger_death_timer.stop()
		starvation_tick.emit(0.0)


## Called (locally on the receiving machine) when another player bumps into this one.
@rpc("any_peer", "unreliable", "call_local")
func receive_push(direction: Vector3, force: float) -> void:
	if not is_local or is_dead:
		return
	velocity += direction * force


func _is_tag_it_peer(peer_id: int) -> bool:
	var parent_node : Node = get_parent()
	if parent_node == null:
		return false
	var main_node : Node = parent_node.get_parent()
	if main_node == null or not main_node.has_node("TagManager"):
		return false
	var tag_mgr : Node = main_node.get_node("TagManager")
	if not tag_mgr.has_method("is_it_peer"):
		return false
	return bool(tag_mgr.call("is_it_peer", peer_id))


func has_buff(buff_name: String) -> bool:
	return float(_effect_timers.get(buff_name, 0.0)) > 0.0


func _clear_effects() -> void:
	_effect_timers.clear()
	_effect_stacks.clear()
	_active_buff = ""
	if _effect_aura and is_instance_valid(_effect_aura):
		_effect_aura.visible = false
	_recompute_effect_stats()
	_update_buff_outline()
	if hud != null and hud.has_method("set_buff_hint"):
		hud.set_buff_hint("")
	_update_effect_ui()


func apply_buff(buff_name: String) -> void:
	if buff_name == "":
		return
	_active_buff = buff_name
	var stacks := int(_effect_stacks.get(buff_name, 0)) + 1
	_effect_stacks[buff_name] = stacks
	_effect_timers[buff_name] = EFFECT_DURATION
	_recompute_effect_stats()
	_update_effect_ui()
	_update_effect_aura(0.0)
	if hud != null and hud.has_method("set_buff_hint"):
		hud.set_buff_hint(_active_buff)
	_update_buff_outline()


func _tick_effects(delta: float) -> void:
	if _effect_timers.is_empty():
		return
	var prev_active := _active_buff
	var expired : Array[String] = []
	for key in _effect_timers.keys():
		var effect_name := str(key)
		var t := float(_effect_timers[effect_name]) - delta
		if t <= 0.0:
			expired.append(effect_name)
		else:
			_effect_timers[effect_name] = t
	for effect_name in expired:
		_effect_timers.erase(effect_name)
		_effect_stacks.erase(effect_name)
	if _active_buff == "" or not _effect_timers.has(_active_buff):
		_active_buff = ""
		var best_t := -1.0
		for key in _effect_timers.keys():
			var effect_name := str(key)
			var t := float(_effect_timers[effect_name])
			if t > best_t:
				best_t = t
				_active_buff = effect_name
	_recompute_effect_stats()
	if prev_active != _active_buff or expired.size() > 0:
		if hud != null and hud.has_method("set_buff_hint"):
			hud.set_buff_hint(_active_buff)
		_update_buff_outline()
	_update_effect_ui()


func _recompute_effect_stats() -> void:
	push_force = _base_push_force
	base_release_cap = _base_release_cap
	max_swing_speed = _base_max_swing_speed
	swing_launch_speed = _base_swing_launch_speed
	if has_buff("Monkey Speed"):
		var stacks := int(_effect_stacks.get("Monkey Speed", 1))
		var mult := black_speed_multiplier + float(maxi(stacks - 1, 0)) * 0.10
		push_force *= mult
		base_release_cap *= mult
		max_swing_speed *= mult
		swing_launch_speed *= mult


func _update_effect_ui() -> void:
	if hud == null or not hud.has_method("set_effects"):
		return
	var rows : Array[Dictionary] = []
	for key in _effect_timers.keys():
		var effect_name := str(key)
		rows.append({
			"name": effect_name,
			"stacks": int(_effect_stacks.get(effect_name, 1)),
			"time_left": float(_effect_timers.get(effect_name, 0.0)),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("time_left", 0.0)) > float(b.get("time_left", 0.0)))
	hud.set_effects(rows)


func _apply_attraction(delta: float) -> void:
	if not is_local or not has_buff("Attraction"):
		return
	var stacks := int(_effect_stacks.get("Attraction", 1))
	var pull_speed := ATTRACTION_PULL_SPEED + float(maxi(stacks - 1, 0)) * 0.8
	for n in get_tree().get_nodes_in_group("bananas"):
		if not (n is Node3D):
			continue
		var banana := n as Node3D
		var to_player := global_position - banana.global_position
		var dist := to_player.length()
		if dist <= 0.05 or dist > ATTRACTION_RADIUS:
			continue
		banana.global_position += to_player.normalized() * pull_speed * delta


func _get_buff_color(buff: String) -> Color:
	match buff:
		"Repulsor":     return Color(0.20, 0.62, 1.0)
		"Attraction":   return Color(0.93, 0.35, 0.55)
		"Monkey Speed": return Color(0.60, 0.20, 0.90)
		"Wind Rider":   return Color(0.45, 1.0, 0.72)
		_:              return Color(1.0, 1.0, 1.0)


func _update_effect_aura(delta: float) -> void:
	if _active_buff == "":
		if _effect_aura and is_instance_valid(_effect_aura):
			_effect_aura.visible = false
		return
	if torso == null:
		return
	if _effect_aura == null or not is_instance_valid(_effect_aura):
		var ring := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.72
		mesh.height = 1.44
		ring.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_color = Color(1, 1, 1, 0.14)
		mat.emission_enabled = true
		mat.emission_energy_multiplier = 2.2
		ring.material_override = mat
		torso.add_child(ring)
		_effect_aura = ring
	_aura_time += delta
	var c := _get_buff_color(_active_buff)
	var stacks := int(_effect_stacks.get(_active_buff, 1))
	if _effect_aura.material_override is StandardMaterial3D:
		var m := _effect_aura.material_override as StandardMaterial3D
		m.albedo_color = Color(c.r, c.g, c.b, 0.12)
		m.emission = c
		m.emission_energy_multiplier = 2.2 + float(maxi(stacks - 1, 0)) * 0.35
	_effect_aura.visible = not is_dead
	var pulse := 1.0 + sin(_aura_time * 5.0) * 0.08
	_effect_aura.scale = Vector3.ONE * pulse


func _update_buff_outline() -> void:
	if _buff_outline and is_instance_valid(_buff_outline):
		_buff_outline.queue_free()
		_buff_outline = null
	if _active_buff == "":
		return
	if torso == null or torso.mesh == null:
		return
	var outline := MeshInstance3D.new()
	outline.mesh = torso.mesh
	outline.scale = Vector3(1.12, 1.12, 1.12)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_FRONT
	mat.albedo_color = _get_buff_color(_active_buff)
	mat.emission_enabled = true
	mat.emission = _get_buff_color(_active_buff)
	mat.emission_energy_multiplier = 1.8
	outline.material_override = mat
	torso.add_child(outline)
	_buff_outline = outline
	_buff_outline.visible = (not is_local) or _shift_lock


func set_role_outline(enabled: bool, color: Color = Color.WHITE) -> void:
	if not enabled:
		if _role_outline and is_instance_valid(_role_outline):
			_role_outline.queue_free()
			_role_outline = null
		return
	if torso == null or torso.mesh == null:
		return
	if _role_outline == null or not is_instance_valid(_role_outline):
		var outline := MeshInstance3D.new()
		outline.mesh = torso.mesh
		outline.scale = Vector3(1.18, 1.18, 1.18)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_FRONT
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
		mat.albedo_color = Color(color.r, color.g, color.b, 0.90)
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 2.2
		outline.material_override = mat
		torso.add_child(outline)
		_role_outline = outline
	if _role_outline.material_override is StandardMaterial3D:
		var rmat := _role_outline.material_override as StandardMaterial3D
		rmat.albedo_color = Color(color.r, color.g, color.b, 0.90)
		rmat.emission = color
	_role_outline.visible = true


func _on_death_timer_timeout() -> void:
	die()


func _clear_held_poo() -> void:
	if _left_poo_visual:
		_left_poo_visual.queue_free()
		_left_poo_visual = null
	if _right_poo_visual:
		_right_poo_visual.queue_free()
		_right_poo_visual = null
	if left_hand_state == HandState.HOLDING_POO:
		left_hand_state = HandState.FREE
		left_hand.release()
	if right_hand_state == HandState.HOLDING_POO:
		right_hand_state = HandState.FREE
		right_hand.release()


func die() -> void:
	if is_dead:
		return
	is_dead = true
	set_role_outline(false)
	_clear_effects()
	_combo          = 0
	_last_vine      = null
	_last_grab_hand = -1
	# Reset shift-lock on death.
	if _shift_lock:
		_shift_lock = false
		camera.position = _default_cam_pos
		torso.visible = false
	if is_local:
		combo_changed.emit(_combo)
	if _left_poo_visual:
		_left_poo_visual.queue_free()
		_left_poo_visual = null
		left_hand_state  = HandState.FREE
	if _right_poo_visual:
		_right_poo_visual.queue_free()
		_right_poo_visual = null
		right_hand_state = HandState.FREE
	# Hide everything visible on this player.
	if head:
		head.visible = false
	torso.visible = false
	var name_lbl := get_node_or_null("NameLabel3D")
	if name_lbl:
		name_lbl.visible = false
	if is_local:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player_died.emit()
	# Broadcast death to all peers.
	if is_local and multiplayer.has_multiplayer_peer():
		rpc("_rpc_die")


@rpc("any_peer", "reliable", "call_remote")
func _rpc_die() -> void:
	if not is_dead:
		is_dead = true
		set_role_outline(false)
		_clear_effects()
		if head:
			head.visible = false
		torso.visible = false
		var name_lbl := get_node_or_null("NameLabel3D")
		if name_lbl:
			name_lbl.visible = false
		player_died.emit()


# ── Network transform sync ───────────────────────────────────────────────────

@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_sync_transform(pos: Vector3, rot_y: float, head_x: float,
		l_grab: bool, l_grab_pos: Vector3, r_grab: bool, r_grab_pos: Vector3,
		active_buff: String, active_stacks: int, active_time_left: float) -> void:
	_net_pos    = pos
	_net_rot_y  = rot_y
	_net_head_x = head_x
	_net_left_grab = l_grab
	_net_right_grab = r_grab
	_net_left_grab_pos = l_grab_pos
	_net_right_grab_pos = r_grab_pos
	if active_buff != "" and active_time_left > 0.0:
		var buff_changed := _active_buff != active_buff
		_active_buff = active_buff
		_effect_stacks[active_buff] = maxi(active_stacks, 1)
		_effect_timers[active_buff] = maxf(float(_effect_timers.get(active_buff, 0.0)), active_time_left)
		_recompute_effect_stats()
		if buff_changed:
			_update_buff_outline()
		_update_effect_aura(0.0)
	elif active_buff == "" and not _effect_timers.is_empty():
		_clear_effects()
