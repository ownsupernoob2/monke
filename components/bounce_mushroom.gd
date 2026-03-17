class_name BounceMushroom
extends Area3D

@export var bounce_speed : float = 12.0
@export var min_horizontal_speed : float = 7.0
@export var horizontal_scale : float = 1.15
@export var hit_cooldown : float = 0.22

var _cooldowns : Dictionary = {}


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	for key in _cooldowns.keys():
		_cooldowns[key] = float(_cooldowns[key]) - delta
		if _cooldowns[key] <= 0.0:
			_cooldowns.erase(key)


func _on_body_entered(body: Node) -> void:
	if not (body is Player):
		return
	var player := body as Player
	if player.is_dead:
		return

	var id := player.get_instance_id()
	if _cooldowns.has(id):
		return
	_cooldowns[id] = hit_cooldown

	var horiz := Vector3(player.velocity.x, 0.0, player.velocity.z)
	if horiz.length() < min_horizontal_speed:
		var fallback := -player.global_transform.basis.z
		fallback.y = 0.0
		if fallback.length_squared() < 0.001:
			fallback = Vector3.FORWARD
		horiz = fallback.normalized() * min_horizontal_speed
	else:
		horiz = horiz.normalized() * (horiz.length() * horizontal_scale)

	player.velocity.x = horiz.x
	player.velocity.z = horiz.z
	player.velocity.y = maxf(bounce_speed, player.velocity.y * 0.5 + bounce_speed * 0.3)
