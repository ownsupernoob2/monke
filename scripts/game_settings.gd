extends Node

## Global game settings singleton – add as autoload "GameSettings".

# ── Playground options ──────────────────────────────────────
var hunger_enabled : bool = true
var ground_enemies_enabled : bool = true
var selected_map : String = "res://maps/SwampForest.tscn"
var selected_gamemode : String = "Last Person Standing"
var selected_buff : String = ""
var round_count : int = 3
var last_excluded_gamemode : String = ""

# ── LPS match state (persists across rounds / scene changes) ────────────────
var lps_scores         : Dictionary = {}   # peer_id → cumulative points
var lps_current_round  : int        = 0    # last completed round number
var lps_match_active   : bool       = false
var lps_match_complete : bool       = false   # all rounds done; next selection → lobby

func lps_clear() -> void:
	lps_scores.clear()
	lps_current_round  = 0
	lps_match_active   = false
	lps_match_complete = false
	last_excluded_gamemode = ""

# ── Player ──────────────────────────────────────────────────
var player_name : String = ""

# ── Disconnect message (shown on main menu after kick/host-leave) ───────────
var disconnect_message : String = ""
# ── Chat history (persists across scene changes so messages aren’t lost) ──────
## Each entry: { "type": "msg"|"alert", "sender": String, "text": String }
var chat_history : Array = []

func clear_chat_history() -> void:
	chat_history.clear()
# ── Audio / Video ───────────────────────────────────────────
var master_volume : float = 1.0   # 0.0 – 1.0
var music_volume  : float = 0.8
var sfx_volume    : float = 1.0
var mouse_sensitivity : float = 0.5  # 0.0 – 1.0
var fov : float = 75.0               # 50.0 – 120.0
var fullscreen : bool = true
var vsync : bool = true


func _ready() -> void:
	_apply_audio()
	_apply_display()


func _apply_audio() -> void:
	var master_idx := AudioServer.get_bus_index("Master")
	if master_idx >= 0:
		AudioServer.set_bus_volume_db(master_idx, linear_to_db(master_volume))


func _apply_display() -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	if vsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
