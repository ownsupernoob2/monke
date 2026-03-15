class_name Poo
extends RigidBody3D

# ── Inspector tweaks ──────────────────────────────────────────────────────────
## Seconds before the poo auto-destroys if it doesn't hit anything.
@export var lifetime      : float = 5.0
## Hunger removed from any player struck by this poo.
@export var hunger_damage : float = 15.0

var _thrower : Player = null


func _ready() -> void:
	# Stays frozen in the thrower's hand until throw() is called.
	freeze = true
	# Short delay before HitZone starts monitoring so the poo clears the
	# player's hand without instantly colliding with the ground.
	$HitZone.monitoring = false
	$HitZone.body_entered.connect(_on_body_entered)


## Register the throwing player so they don't hit themselves,
## and exclude them from the RigidBody physics collision too.
func setup(owner_player: Player) -> void:
	_thrower = owner_player
	add_collision_exception_with(owner_player)


## Unfreeze and launch the poo.  Called by the player on throw.
func throw(direction: Vector3, force: float) -> void:
	freeze = false
	linear_velocity = direction * force
	# Enable hit detection after a short delay so the poo doesn't
	# immediately hit the ground at the spawn point.
	get_tree().create_timer(0.15).timeout.connect(func(): $HitZone.monitoring = true)
	get_tree().create_timer(lifetime).timeout.connect(queue_free)


func _on_body_entered(body: Node3D) -> void:
	# Never hit the person who threw it.
	if body == _thrower:
		return
	if body is Player:
		var target_player : Player = body as Player
		if target_player.has_method("has_buff") and target_player.has_buff("Repulsor"):
			_deflect_from(target_player)
			return
		# Drain the victim's hunger (blind/slow mechanic later).
		target_player.add_hunger(-hunger_damage)
	queue_free()


func _deflect_from(player: Player) -> void:
	var away := global_position - player.global_position
	away.y = maxf(away.y, 0.05)
	if away.length_squared() < 0.001:
		away = -player.global_transform.basis.z
	away = away.normalized()
	linear_velocity = away * maxf(linear_velocity.length(), 18.0)
	_thrower = player
	add_collision_exception_with(player)
	$HitZone.monitoring = false
	get_tree().create_timer(0.1).timeout.connect(func() -> void:
		if is_inside_tree():
			$HitZone.monitoring = true
	)
