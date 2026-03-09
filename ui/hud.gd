extends CanvasLayer

# Node paths match the hierarchy defined in Player.tscn / HUD.tscn.
@onready var hunger_label     : Label       = $Control/TopLeft/VBox/HungerLabel
@onready var hunger_bar       : ProgressBar = $Control/TopLeft/VBox/HungerBar
@onready var starvation_label : Label       = $Control/TopLeft/VBox/StarvationLabel
@onready var death_label      : Label       = $Control/DeathLabel
@onready var crosshair        : Label       = $Control/Crosshair
@onready var combo_label      : Label       = $Control/ComboLabel
@onready var speed_lines                    = $Control/SpeedLines

# ── Game-state HUD (top-right) ───────────────────────────────────────────────
@onready var round_label      : Label       = $Control/TopRight/RoundLabel
@onready var alive_label      : Label       = $Control/TopRight/AliveLabel
@onready var timer_label      : Label       = $Control/TopRight/TimerLabel

# ── Spectator bar (bottom-centre) ────────────────────────────────────────────
@onready var spectate_bar     : HBoxContainer = $Control/SpectateBar
@onready var spectate_label   : Label         = $Control/SpectateBar/SpectateLabel


func _ready() -> void:
	starvation_label.visible = false
	death_label.visible      = false
	combo_label.visible      = false
	round_label.text         = ""
	alive_label.text         = ""
	timer_label.text         = ""
	spectate_bar.visible     = false


## Called every frame by the player's `hunger_changed` signal.
func update_hunger(value: float, max_value: float) -> void:
	hunger_bar.max_value = max_value
	hunger_bar.value     = value
	hunger_label.text    = "Hunger  %d / %d" % [int(value), int(max_value)]

	# Colour-code the bar: green → yellow → red.
	var ratio := value / max_value
	if ratio > 0.5:
		hunger_bar.modulate = Color(0.2, 0.9, 0.2)    # green
	elif ratio > 0.25:
		hunger_bar.modulate = Color(1.0, 0.75, 0.0)   # yellow
	else:
		hunger_bar.modulate = Color(1.0, 0.25, 0.25)  # red


## Called every frame by the player's `starvation_tick` signal.
func update_starvation_timer(time_left: float) -> void:
	if time_left > 0.0:
		starvation_label.visible = true
		starvation_label.text    = "STARVING  dying in %.1fs" % time_left
	else:
		starvation_label.visible = false


## Called once by the player's `player_died` signal.
func show_death_screen() -> void:
	death_label.visible   = true
	# Hunger is irrelevant after death — hide it.
	hunger_bar.visible       = false
	hunger_label.visible     = false
	starvation_label.visible = false


## White = nothing in range.  Bright green + scale-up + ring = vine is grabbable.
var _vine_targeted : bool = false
var _vine_pulse_t  : float = 0.0

func set_vine_targeted(targeting: bool) -> void:
	if targeting:
		crosshair.text = "[ + ]"
		crosshair.add_theme_font_size_override("font_size", 26)
		_vine_pulse_t += get_process_delta_time()
		var pulse := 0.85 + 0.15 * sin(_vine_pulse_t * 6.0)
		crosshair.modulate = Color(0.2, 1.0, 0.3, pulse)
	else:
		crosshair.text = "+"
		crosshair.add_theme_font_size_override("font_size", 20)
		crosshair.modulate = Color(1, 1, 1, 0.7)
		_vine_pulse_t = 0.0
	_vine_targeted = targeting


## Shows a coloured counter when the chain is 2+; hides it otherwise.
func update_combo(count: int) -> void:
	if count < 2:
		combo_label.visible = false
		return
	combo_label.visible = true
	combo_label.text    = "×%d" % count
	var col: Color
	if   count >= 8: col = Color(1.0, 0.15, 0.15)
	elif count >= 5: col = Color(1.0, 0.50, 0.10)
	elif count >= 3: col = Color(1.0, 0.85, 0.00)
	else:            col = Color(0.45, 1.0,  0.30)
	combo_label.add_theme_color_override("font_color", col)
	combo_label.modulate = Color(2.5, 2.5, 2.5, 1.0)
	var tw := create_tween()
	tw.tween_property(combo_label, "modulate", Color.WHITE, 0.25)


## Called by the player's speed_changed signal every process frame.
func set_speed(speed: float) -> void:
	speed_lines.set_speed(speed)


# ── Game-state updates (called by LPS manager) ──────────────────────────────

func update_round_info(current: int, total: int) -> void:
	round_label.text = "Round %d / %d" % [current, total]


func update_alive_count(alive: int) -> void:
	alive_label.text = "Alive: %d" % alive


func update_game_timer(time_left: float) -> void:
	if time_left > 0.0:
		timer_label.text = "%d:%02d" % [int(time_left) / 60, int(time_left) % 60]
	else:
		timer_label.text = ""


func show_deathmatch_warning() -> void:
	timer_label.text = "SUDDEN DEATH"
	timer_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))


# ── Spectator mode ──────────────────────────────────────────────────────────

func show_spectating(player_name: String) -> void:
	spectate_bar.visible = true
	spectate_label.text = "Spectating: %s  |  LMB/RMB to switch" % player_name
	death_label.visible = false  # hide "YOU DIED" during spectating


func hide_spectating() -> void:
	spectate_bar.visible = false
