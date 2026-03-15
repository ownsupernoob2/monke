class_name BananaSpawner
extends Node3D

## ── Scene / counts ─────────────────────────────────────────────────────────────
## Banana scene to instantiate (res://components/Banana.tscn).
@export var banana_scene   : PackedScene
## Number of bananas alive at any time.  New ones spawn only after one is eaten.
@export var max_bananas    : int   = 20

## ── Spawn area (world-space rectangle centred on this node) ────────────────────
## Half-width of the spawn area along X.
@export var area_half_x    : float = 15.0
## Half-depth of the spawn area along Z.
@export var area_half_z    : float = 15.0
## Minimum and maximum spawn height (world Y).
@export var min_height     : float = 9.0
@export var max_height     : float = 14.5

## ── Spacing ────────────────────────────────────────────────────────────────────
## Minimum distance between any two bananas.  Enforced on spawn attempts.
@export var min_spacing    : float = 3.0
## Maximum placement attempts per banana before giving up (avoids infinite loop).
@export var max_attempts   : int   = 20

## ── Respawn timing ─────────────────────────────────────────────────────────────
## Seconds to wait after a banana is consumed before spawning a replacement.
@export var respawn_delay  : float = 5.0

## ── Buff bananas ─────────────────────────────────────────────────────────────
## Probability (0–1) that a spawned banana carries the selected round buff.
## 0 = all regular; 1 = all buff bananas.
@export var buff_spawn_chance : float = 0.25

# ── Runtime ─────────────────────────────────────────────────────────────────────
var _rng       := RandomNumberGenerator.new()
var _container : Node3D
var _bananas   : Array[Node3D] = []   ## currently alive bananas


func _ready() -> void:
	_rng.randomize()
	_container       = Node3D.new()
	_container.name  = "Bananas"
	add_child(_container)

	# Initial batch.
	for _i in max_bananas:
		_spawn_one()


## ─── Internal ──────────────────────────────────────────────────────────────────

func _spawn_one() -> void:
	if banana_scene == null:
		return
	var pos : Vector3 = _pick_position()

	var banana : Node = banana_scene.instantiate()
	banana.position = pos
	# Assign the currently selected buff to a subset of spawned bananas.
	if buff_spawn_chance > 0.0 and _rng.randf() < buff_spawn_chance:
		var gs : Node = get_node_or_null("/root/GameSettings")
		var selected_buff := ""
		if gs != null:
			selected_buff = str(gs.selected_buff)
		if selected_buff != "":
			banana.buff_type = selected_buff
	_container.add_child(banana)
	_bananas.append(banana)

	# Listen for pickup → schedule respawn.
	if banana.has_signal("picked_up"):
		banana.picked_up.connect(_on_banana_collected.bind(banana))


## Try to find a valid position that respects min_spacing.
func _pick_position() -> Vector3:
	var origin := global_position
	for _attempt in max_attempts:
		var bx := origin.x + _rng.randf_range(-area_half_x, area_half_x)
		var bz := origin.z + _rng.randf_range(-area_half_z, area_half_z)
		var by := _rng.randf_range(min_height, max_height)
		var candidate := Vector3(bx, by, bz)

		# Check minimum distance to all existing bananas.
		var too_close := false
		for b in _bananas:
			if is_instance_valid(b) and b.global_position.distance_to(candidate) < min_spacing:
				too_close = true
				break
		if not too_close:
			return candidate
	# Fallback: ignore spacing and just pick a random spot.
	return Vector3(
		origin.x + _rng.randf_range(-area_half_x, area_half_x),
		_rng.randf_range(min_height, max_height),
		origin.z + _rng.randf_range(-area_half_z, area_half_z)
	)


func _on_banana_collected(_picker: Node3D, _amount: float, banana: Node3D) -> void:
	_bananas.erase(banana)
	# Wait, then spawn a replacement.
	get_tree().create_timer(respawn_delay).timeout.connect(_spawn_one)
