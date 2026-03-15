extends Node

## EOS Bootstrap autoload ("EOSBootstrap").
## Initialises the Epic Online Services platform once, then performs an
## anonymous device-id login so the rest of the game can use EOS features
## (P2P lobbies, NAT relay) without requiring any Epic account.
##
## ── SETUP ────────────────────────────────────────────────────────────────
## Credentials are loaded at runtime from  res://eos_credentials.cfg
## which is gitignored.  Copy  eos_credentials.cfg.template  →
## eos_credentials.cfg  and fill in your values from the Epic Dev Portal.
## GitHub Actions injects them automatically via repository secrets.
## ─────────────────────────────────────────────────────────────────────────

## Emitted once EOS is up and the local user is logged in.
signal eos_ready

## True after login_async() succeeds.
var is_ready : bool = false
## True once bootstrap has finished attempting EOS init/login (success or fail).
var init_complete : bool = false

## The local product user id string (set after login).
var product_user_id : String = ""


func _ready() -> void:
	# Don't block the scene tree – initialise in the background.
	_init_eos.call_deferred()


func _init_eos() -> void:
	if not _eos_available():
		push_warning("EOSBootstrap: EOS plugin not found – multiplayer will fall back to ENet.")
		is_ready = false
		init_complete = true
		eos_ready.emit()
		return

	# ── Load credentials ─────────────────────────────────────────────────
	# Try in order:
	#  1. Next to the executable (exported build, credentials placed alongside .exe)
	#  2. res:// (packed into the PCK via export include_filter, or running in editor)
	var cfg := ConfigFile.new()
	var cfg_err : int = ERR_FILE_NOT_FOUND
	if not OS.has_feature("editor"):
		var exe_dir := OS.get_executable_path().get_base_dir()
		cfg_err = cfg.load(exe_dir.path_join("eos_credentials.cfg"))
	if cfg_err != OK:
		cfg_err = cfg.load("res://eos_credentials.cfg")
	if cfg_err != OK:
		push_error("EOSBootstrap: eos_credentials.cfg not found (err %d). Place it next to the .exe or ensure it is included in the export PCK." % cfg_err)
		init_complete = true
		eos_ready.emit()
		return

	# ── Initialise platform ───────────────────────────────────────────────
	var creds = HCredentials.new()
	creds.product_name    = cfg.get_value("eos", "product_name",    "")
	creds.product_version = cfg.get_value("eos", "product_version", "")
	creds.product_id      = cfg.get_value("eos", "product_id",      "")
	creds.sandbox_id      = cfg.get_value("eos", "sandbox_id",      "")
	creds.deployment_id   = cfg.get_value("eos", "deployment_id",   "")
	creds.client_id       = cfg.get_value("eos", "client_id",       "")
	creds.client_secret   = cfg.get_value("eos", "client_secret",   "")

	# Guard: the EOS plugin crashes (signal 11) when any required field is empty.
	var required_fields := [creds.product_name, creds.product_version, creds.product_id,
			creds.sandbox_id, creds.deployment_id, creds.client_id, creds.client_secret]
	if required_fields.any(func(f): return f == ""):
		push_warning("EOSBootstrap: One or more EOS credentials are empty – falling back to ENet.")
		init_complete = true
		eos_ready.emit()
		return

	var ok : bool = await HPlatform.setup_eos_async(creds)
	if not ok:
		push_error("EOSBootstrap: HPlatform.setup_eos_async failed.")
		init_complete = true
		eos_ready.emit()
		return

	# ── Anonymous login (device-id, no Epic account required) ─────────────
	var display_name : String = _get_player_name()
	ok = await HAuth.login_anonymous_async(display_name)
	if not ok:
		push_error("EOSBootstrap: HAuth.login_anonymous_async failed.")
		init_complete = true
		eos_ready.emit()
		return

	product_user_id = HAuth.product_user_id
	is_ready = true
	init_complete = true
	eos_ready.emit()


## Call this if you need to wait until EOS is ready from another script.
## Returns immediately if already ready, otherwise awaits the signal.
func wait_until_ready() -> void:
	if not init_complete:
		await eos_ready


## Re-login with a new display name (call after the player changes their name).
func refresh_display_name() -> void:
	if not _eos_available():
		return
	var display_name : String = _get_player_name()
	await HAuth.login_anonymous_async(display_name)
	product_user_id = HAuth.product_user_id


# ── Internal helpers ──────────────────────────────────────────────────────────

func _get_player_name() -> String:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		var n : String = gs.player_name
		if n.strip_edges() != "":
			return n
	return "Player"


func _eos_available() -> bool:
	# The EOS plugin exposes the global "IEOS" singleton when enabled.
	return Engine.has_singleton("IEOS")
