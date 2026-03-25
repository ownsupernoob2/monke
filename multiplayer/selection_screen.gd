extends Node3D

## Multiplayer voting selection screen.
## Three stations around the camera — players vote, majority wins, ties broken randomly.
##   • Front  (−Z) : Gamemode
##   • Left   (−X) : Map
##   • Back   (+Z) : Buff

# ── Data ──────────────────────────────────────────────────────────────────────
const ALL_GAMEMODES : Array[String] = [
	"Last Person Standing",
	"Banana Frenzy",
	"Tag",
	"Bomb Tag",
]

const ALL_MAPS : Dictionary = {
	"Swamp Forest":  "res://maps/SwampForest.tscn",
	"Rainforest":    "res://maps/Rainforest.tscn",
	"Red Canyon":    "res://maps/RedCanyon.tscn",
	"Moon Forest":   "res://maps/MoonForest.tscn",
}

const ALL_BUFFS : Array[String] = [
	"Repulsor", "Attraction", "Monkey Speed", "Wind Rider",
]

const PLAYER_SCENE : String = "res://components/Player.tscn"

# ── State ─────────────────────────────────────────────────────────────────────
enum Phase { INTRO, GAMEMODE, MAP, BUFF, LAUNCHING, LEADERBOARD }
var current_phase  : int   = Phase.INTRO
var _phase_timer   : float = 10.0
var _can_select    : bool  = false
var _phase_decided : bool  = false
var _my_vote       : int   = -1   # card index this player voted for (-1 = none)

var offered_gamemodes : Array[String] = []
var offered_maps      : Array[String] = []
var offered_buffs     : Array[String] = []

var chosen_gamemode : String = ""
var chosen_map_path : String = ""
var chosen_buff     : String = ""

# Current-phase votes: peer_id (int) → card_idx (int)
var _current_votes : Dictionary = {}

# Leaderboard.
var _from_leaderboard    : bool   = false   ## arriving after a completed round
var _leaderboard_station : Node3D = null    ## built at runtime

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var camera       : Camera3D        = $CameraPivot/Camera3D
@onready var cam_pivot    : Node3D          = $CameraPivot
@onready var anim_player  : AnimationPlayer = $AnimationPlayer

@onready var gm_cards  : Array[Node3D] = [$Stations/GamemodeStation/Card1,
										   $Stations/GamemodeStation/Card2,
										   $Stations/GamemodeStation/Card3]
@onready var map_cards : Array[Node3D] = [$Stations/MapStation/Card1,
										   $Stations/MapStation/Card2,
										   $Stations/MapStation/Card3]
@onready var buff_cards : Array[Node3D] = [$Stations/BuffStation/Card1,
											$Stations/BuffStation/Card2,
											$Stations/BuffStation/Card3]

# UI
@onready var title_label   : Label     = $UILayer/TopBar/TitleLabel
@onready var timer_label   : Label     = $UILayer/TopBar/TimerLabel
@onready var gm_preview    : Label     = $UILayer/PreviewBar/GMPreview
@onready var map_preview   : Label     = $UILayer/PreviewBar/MapPreview
@onready var buff_preview  : Label     = $UILayer/PreviewBar/BuffPreview
@onready var blackout      : ColorRect = $UILayer/Blackout


# ══════════════════════════════════════════════════════════════════════════════
#  LIFECYCLE
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_multiplayer_authority(GameLobby.get_host_peer_id())
	_setup_leaderboard_station()
	# Hide 3-D Label3Ds — SubViewport card UIs replace them.
	for card : Node3D in gm_cards + map_cards + buff_cards:
		var lbl := card.get_node_or_null("Label3D")
		if lbl:
			lbl.visible = false

	blackout.modulate.a = 0.0
	gm_preview.text   = "Gamemode: ---"
	map_preview.text  = "Map: ---"
	buff_preview.text = "Buff: ---"
	timer_label.text  = ""

	for card : Node3D in gm_cards + map_cards + buff_cards:
		var area : Area3D = card.get_node("Area3D")
		area.input_event.connect(_on_card_input.bind(card))

	anim_player.animation_finished.connect(_on_anim_finished)

	# Chat overlay.
	var chat_scene := load("res://ui/Chat.tscn")
	if chat_scene:
		add_child(chat_scene.instantiate())

	# Pause menu (Escape key).
	var pause_scene := load("res://ui/PauseMenu.tscn")
	if pause_scene:
		add_child(pause_scene.instantiate())

	# Host-disconnect.
	GameLobby.server_closed.connect(_on_server_closed)

	var gs : Node = get_node_or_null("/root/GameSettings")
	var has_prior_rounds : bool = gs != null and gs.lps_match_active

	if GameLobby.is_host():
		_randomise_offerings()
		_apply_labels()

		if has_prior_rounds:
			# Show the inter-round (or final) leaderboard, then proceed.
			title_label.text = ""
			_populate_leaderboard()
			await _show_leaderboard()
			await get_tree().create_timer(5.0).timeout
			if not is_inside_tree():
				return
			if gs.lps_match_complete:
				# Match over — send everyone back to the lobby.
				rpc("_rpc_end_to_lobby")
				_end_to_lobby()
				return
			title_label.text = "STARTING SOON..."
			await get_tree().create_timer(0.5).timeout
			_from_leaderboard = true
			rpc("_rpc_sync_offerings", offered_gamemodes, offered_maps, offered_buffs)
			_start_intro()
		else:
			title_label.text = "STARTING SOON..."
			await get_tree().create_timer(1.0).timeout
			rpc("_rpc_sync_offerings", offered_gamemodes, offered_maps, offered_buffs)
			_start_intro()
	else:
		title_label.text = "WAITING FOR HOST..."
		if has_prior_rounds:
			_populate_leaderboard()
			_show_leaderboard()  # fire-and-forget tween for clients


func _process(delta : float) -> void:
	if current_phase == Phase.INTRO or current_phase == Phase.LAUNCHING or current_phase == Phase.LEADERBOARD:
		return
	if not _can_select or _phase_decided:
		return
	_phase_timer -= delta
	timer_label.text = "%d" % maxi(ceili(_phase_timer), 0)
	if _phase_timer <= 0.0 and GameLobby.is_host():
		_finalize_current_phase()


# ══════════════════════════════════════════════════════════════════════════════
#  SETUP HELPERS
# ══════════════════════════════════════════════════════════════════════════════

## Thumbnail images for each selectable item.
## Place PNG files at  res://assets/thumbnails/<filename>.png
## Recommended resolution: 512 × 320 px (16:10 looks best on the card).
const _THUMBNAILS : Dictionary = {
	"Swamp Forest":         "res://assets/thumbnails/swamp_forest.png",
	"Rainforest":           "res://assets/thumbnails/rainforest.png",
	"Red Canyon":           "res://assets/thumbnails/red_canyon.png",
	"Moon Forest":          "res://assets/thumbnails/moon_forest.png",
	"Last Person Standing": "res://assets/thumbnails/lps.png",
	"Banana Frenzy":        "res://assets/thumbnails/banana_frenzy.png",
	"Tag":                  "res://assets/thumbnails/tag.png",
	"Bomb Tag":             "res://assets/thumbnails/bomb_tag.png",
	"Repulsor":             "res://assets/thumbnails/poo_power.png",
	"Attraction":           "res://assets/thumbnails/attraction.png",
	"Monkey Speed":         "res://assets/thumbnails/monkey_speed.png",
	"Wind Rider":           "res://assets/thumbnails/vine_master.png",
}

## Short flavour text shown on each card below the title.
const _DESCRIPTIONS : Dictionary = {
	"Last Person Standing":  "Be the last monkey alive.\nCollect bananas to survive starvation.\nEliminate others.",
	"Banana Frenzy":         "Grab as many bananas as you can\nin 2 minutes!\nNo starvation — only points matter.",
	"Tag":                   "One monkey is IT.\nTouch IT to pass the tag!\nScore points every second you're free.",
	"Bomb Tag":              "The bomb explodes in 30 seconds.\nTag someone before time runs out\nor get eliminated.",
	"Repulsor":              "Repulsion aura: shove IT players harder\nand deflect incoming poo.",
	"Attraction":            "Magnet aura: pull nearby bananas\nwithin 5m for 10 seconds.",
	"Monkey Speed":          "Movement boost: faster pushes\nand stronger release speed.",
	"Wind Rider":            "Gain a mid-air dash ability\n(press Space while airborne).",
}

# Category theme colours used in the image area of each card type.
const _CAT_COLORS : Array[Color] = [
	Color(0.35, 0.15, 0.75),  # Gamemode – purple
	Color(0.10, 0.50, 0.25),  # Map – green
	Color(0.75, 0.45, 0.05),  # Buff – gold
]
const _CAT_LABELS : Array[String] = ["GAMEMODE", "MAP", "BUFF"]


func _randomise_offerings() -> void:
	# Gamemode freshness: with 4 total modes and 3 shown, rotate which one is excluded.
	var gm_pool : Array[String] = ALL_GAMEMODES.duplicate()
	offered_gamemodes = []
	if gm_pool.size() <= 3:
		gm_pool.shuffle()
		for gm : String in gm_pool:
			offered_gamemodes.append(gm)
	else:
		var gs : Node = get_node_or_null("/root/GameSettings")
		var last_excluded := ""
		if gs != null and "last_excluded_gamemode" in gs:
			last_excluded = str(gs.last_excluded_gamemode)

		var excluded_candidates : Array[String] = gm_pool.duplicate()
		if last_excluded != "" and excluded_candidates.has(last_excluded) and excluded_candidates.size() > 1:
			excluded_candidates.erase(last_excluded)
		excluded_candidates.shuffle()
		var excluded : String = excluded_candidates[0]

		for gm : String in gm_pool:
			if gm != excluded:
				offered_gamemodes.append(gm)
		offered_gamemodes.shuffle()

		if gs != null and "last_excluded_gamemode" in gs:
			gs.last_excluded_gamemode = excluded

	var map_names : Array[String] = []
	for k : String in ALL_MAPS.keys():
		map_names.append(k)
	map_names.shuffle()
	offered_maps = [map_names[0], map_names[1], map_names[2]]

	var buff_pool := ALL_BUFFS.duplicate()
	buff_pool.shuffle()
	offered_buffs.clear()
	for i in range(mini(3, buff_pool.size())):
		offered_buffs.append(buff_pool[i])
	offered_buffs = _normalize_three_offers(offered_buffs, ALL_BUFFS)


func _reroll_buff_offerings_for_gamemode(_gamemode: String) -> void:
	var buff_pool := ALL_BUFFS.duplicate()
	buff_pool.shuffle()
	offered_buffs.clear()
	for i in range(mini(3, buff_pool.size())):
		offered_buffs.append(buff_pool[i])
	offered_buffs = _normalize_three_offers(offered_buffs, ALL_BUFFS)


@rpc("any_peer", "reliable", "call_remote")
func _rpc_sync_buff_offerings(buffs : Array) -> void:
	if not _is_host_message_sender():
		return
	offered_buffs.clear()
	for b in buffs:
		offered_buffs.append(str(b))
	offered_buffs = _normalize_three_offers(offered_buffs, ALL_BUFFS)
	for i : int in 3:
		_set_card_text(buff_cards[i], offered_buffs[i])


func _apply_labels() -> void:
	for i : int in 3:
		_set_card_text(gm_cards[i],   _offer_at(offered_gamemodes, i))
		_set_card_text(map_cards[i],  _offer_at(offered_maps, i))
		_set_card_text(buff_cards[i], _offer_at(offered_buffs, i))


func _set_card_text(card : Node3D, text : String) -> void:
	var vp : SubViewport = card.get_node("CardVP")
	var title : Label = vp.get_node("Title")
	title.text = text
	# Description line (only Gamemode cards have this node).
	var desc : Label = vp.get_node_or_null("Desc")
	if desc:
		desc.text = _DESCRIPTIONS.get(text, "")
	# Load thumbnail if we have one for this item and the file exists.
	var thumb : TextureRect = vp.get_node_or_null("Thumbnail")
	if thumb == null:
		return
	if _THUMBNAILS.has(text) and ResourceLoader.exists(_THUMBNAILS[text]):
		var tex := load(_THUMBNAILS[text]) as Texture2D
		if tex:
			thumb.texture = tex
			thumb.visible = true
			# Hide the colour watermark when a real image is present.
			var img_area := vp.get_node_or_null("ImgArea")
			if img_area:
				img_area.visible = false
			return
	thumb.visible = false


func _start_intro() -> void:
	current_phase = Phase.INTRO
	title_label.text = "CHOOSE GAMEMODE"
	_can_select = false
	if _from_leaderboard:
		# Camera is already at the leaderboard pivot; sweep it to the gamemode station.
		_tween_from_leaderboard_to_gamemode()
	else:
		anim_player.play("intro_to_gamemode")


func _cards_for(phase : int) -> Array[Node3D]:
	match phase:
		Phase.GAMEMODE: return gm_cards
		Phase.MAP:      return map_cards
		Phase.BUFF:     return buff_cards
	return gm_cards


# ══════════════════════════════════════════════════════════════════════════════
#  RPC – SYNC OFFERINGS  (host → clients)
# ══════════════════════════════════════════════════════════════════════════════

@rpc("any_peer", "reliable", "call_remote")
func _rpc_sync_offerings(gamemodes : Array, maps : Array, buffs : Array) -> void:
	if not _is_host_message_sender():
		return
	offered_gamemodes.clear()
	offered_maps.clear()
	offered_buffs.clear()
	for g in gamemodes:
		offered_gamemodes.append(str(g))
	for m in maps:
		offered_maps.append(str(m))
	for b in buffs:
		offered_buffs.append(str(b))
	offered_gamemodes = _normalize_three_offers(offered_gamemodes, ALL_GAMEMODES)
	offered_maps = _normalize_three_offers(offered_maps, ALL_MAPS.keys())
	offered_buffs = _normalize_three_offers(offered_buffs, ALL_BUFFS)
	var _gs : Node = get_node_or_null("/root/GameSettings")
	_from_leaderboard = _gs != null and _gs.lps_match_active
	_apply_labels()
	_start_intro()


# ══════════════════════════════════════════════════════════════════════════════
#  ANIMATION CALLBACK
# ══════════════════════════════════════════════════════════════════════════════

func _on_anim_finished(anim_name : StringName) -> void:
	match anim_name:
		&"intro_to_gamemode":
			current_phase = Phase.GAMEMODE
			_begin_voting_phase()


func _begin_voting_phase() -> void:
	_can_select = true
	_phase_decided = false
	_my_vote = -1
	_current_votes.clear()
	_phase_timer = 10.0
	_reset_cards(_cards_for(current_phase))
	_update_vote_displays()


# ══════════════════════════════════════════════════════════════════════════════
#  CARD CLICK
# ══════════════════════════════════════════════════════════════════════════════

func _on_card_input(_cam : Node, event : InputEvent, _pos : Vector3,
					_normal : Vector3, _idx : int, card : Node3D) -> void:
	if not _can_select or _phase_decided:
		return
	if not event is InputEventMouseButton:
		return
	var mb : InputEventMouseButton = event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return

	var cards : Array[Node3D] = _cards_for(current_phase)
	if card not in cards:
		return

	var idx : int = cards.find(card)
	if idx == _my_vote:
		return  # already voted for this card

	_my_vote = idx
	_show_my_selection(cards, idx)

	if GameLobby.is_host():
		_handle_vote(multiplayer.get_unique_id(), idx)
	else:
		rpc_id(GameLobby.get_host_peer_id(), "_rpc_submit_vote", current_phase, idx)


# ══════════════════════════════════════════════════════════════════════════════
#  VISUAL HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _show_my_selection(cards : Array[Node3D], idx : int) -> void:
	for i : int in cards.size():
		var target : Vector3 = Vector3(1.12, 1.12, 1.12) if i == idx else Vector3.ONE
		var tw := create_tween()
		tw.tween_property(cards[i], "scale", target, 0.15)


func _reset_cards(cards : Array[Node3D]) -> void:
	for card : Node3D in cards:
		card.scale = Vector3.ONE
		var mesh : MeshInstance3D = card.get_node("MeshInstance3D")
		mesh.transparency = 0.0
		var vp : SubViewport = card.get_node("CardVP")
		var votes_root : Node2D = vp.get_node("Votes")
		for child : Node in votes_root.get_children():
			child.queue_free()
		var vote_count_lbl : Label = vp.get_node_or_null("VoteCount")
		if vote_count_lbl:
			vote_count_lbl.text = "0 votes"


# ══════════════════════════════════════════════════════════════════════════════
#  RPC – VOTING
# ══════════════════════════════════════════════════════════════════════════════

@rpc("any_peer", "reliable")
func _rpc_submit_vote(phase : int, card_idx : int) -> void:
	if not GameLobby.is_host():
		return
	if phase != current_phase or _phase_decided:
		return
	var sender : int = multiplayer.get_remote_sender_id()
	_handle_vote(sender, card_idx)


func _handle_vote(peer_id : int, card_idx : int) -> void:
	if _phase_decided:
		return
	_current_votes[peer_id] = card_idx
	# Broadcast updated vote map to all clients; host updates locally.
	var synced : Dictionary = _current_votes.duplicate()
	rpc("_rpc_broadcast_votes", current_phase, synced)
	_update_vote_displays()
	# If everyone has voted, fast-forward to a 2-second grace period
	# so players can still change their mind at the last moment.
	if _current_votes.size() >= GameLobby.players.size() and _phase_timer > 2.0:
		_phase_timer = 2.0


@rpc("any_peer", "reliable", "call_remote")
func _rpc_broadcast_votes(phase : int, vote_dict : Dictionary) -> void:
	if not _is_host_message_sender():
		return
	if phase != current_phase or _phase_decided:
		return
	_current_votes = vote_dict
	_update_vote_displays()


func _update_vote_displays() -> void:
	var cards : Array[Node3D] = _cards_for(current_phase)
	# Build per-card voter data.
	var ids_per_card   : Array = [[], [], []]
	for key in _current_votes:
		var peer_id : int = int(key)
		var idx     : int = int(_current_votes[key])
		if idx >= 0 and idx <= 2:
			ids_per_card[idx].append(peer_id)

	const AVATAR_SIZE  : int = 36
	const AVATAR_GAP   : int = 4
	for i : int in 3:
		var vp : SubViewport = cards[i].get_node("CardVP")
		var votes_root : Node2D = vp.get_node("Votes")
		# Clear existing avatars.
		for child : Node in votes_root.get_children():
			child.queue_free()
		# Update vote-count label.
		var vote_count_lbl : Label = vp.get_node_or_null("VoteCount")
		if vote_count_lbl:
			var n : int = ids_per_card[i].size()
			vote_count_lbl.text = "%d vote%s" % [n, "s" if n != 1 else ""]
		# Rebuild avatar circles.
		var ox : int = 0
		for pid : int in ids_per_card[i]:
			var hue  : float  = fmod(float(abs(pid)) * 0.618, 1.0)
			var col  : Color  = Color.from_hsv(hue, 0.75, 0.95)
			var p_name : String = GameLobby.display_name(pid)

			# Coloured square background (avatar placeholder).
			var circle := ColorRect.new()
			circle.size     = Vector2(AVATAR_SIZE, AVATAR_SIZE)
			circle.position = Vector2(ox, 0)
			circle.color    = col
			votes_root.add_child(circle)

			# Initial-letter label centred inside the square.
			var init_lbl := Label.new()
			init_lbl.text = p_name.substr(0, 1).to_upper()
			init_lbl.size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
			init_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			init_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
			init_lbl.add_theme_font_size_override("font_size", 20)
			init_lbl.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
			circle.add_child(init_lbl)

			ox += AVATAR_SIZE + AVATAR_GAP
			# Wrap to next row after overflow.
			if ox >= 240:
				ox = 0


# ══════════════════════════════════════════════════════════════════════════════
#  PHASE FINALIZATION  (host only)
# ══════════════════════════════════════════════════════════════════════════════

func _finalize_current_phase() -> void:
	if _phase_decided:
		return
	_phase_decided = true
	_can_select = false

	# Tally votes per card.
	var tallies : Array[int] = [0, 0, 0]
	for key in _current_votes:
		var idx : int = int(_current_votes[key])
		if idx >= 0 and idx <= 2:
			tallies[idx] += 1

	# Determine winner — highest votes, random tie-break.
	var max_votes : int = 0
	for t : int in tallies:
		if t > max_votes:
			max_votes = t

	var winner : int = 0
	if max_votes == 0:
		winner = randi() % 3
	else:
		var tied : Array[int] = []
		for i : int in 3:
			if tallies[i] == max_votes:
				tied.append(i)
		winner = tied[randi() % tied.size()]

	# Broadcast result to all clients; apply locally on host.
	rpc("_rpc_phase_result", current_phase, winner)
	_apply_phase_result(current_phase, winner)


# ══════════════════════════════════════════════════════════════════════════════
#  RPC – PHASE RESULT  (host → clients)
# ══════════════════════════════════════════════════════════════════════════════

@rpc("any_peer", "reliable", "call_remote")
func _rpc_phase_result(phase : int, winner_idx : int) -> void:
	if not _is_host_message_sender():
		return
	_apply_phase_result(phase, winner_idx)


func _apply_phase_result(phase : int, winner_idx : int) -> void:
	_phase_decided = true
	_can_select = false

	var cards : Array[Node3D] = _cards_for(phase)
	_highlight_winner(cards, winner_idx)

	# Store the winning selection.
	match phase:
		Phase.GAMEMODE:
			chosen_gamemode = _offer_at(offered_gamemodes, winner_idx)
			gm_preview.text = "Gamemode: %s" % chosen_gamemode
		Phase.MAP:
			var map_name : String = _offer_at(offered_maps, winner_idx)
			chosen_map_path = str(ALL_MAPS.get(map_name, "res://maps/SwampForest.tscn"))
			map_preview.text = "Map: %s" % map_name
		Phase.BUFF:
			chosen_buff = _offer_at(offered_buffs, winner_idx)
			buff_preview.text = "Buff: %s" % chosen_buff

	await get_tree().create_timer(1.2).timeout
	_advance_phase(phase)


func _highlight_winner(cards : Array[Node3D], winner_idx : int) -> void:
	for i : int in cards.size():
		if i == winner_idx:
			var tw := create_tween()
			tw.tween_property(cards[i], "scale", Vector3(1.25, 1.25, 1.25), 0.25)
		else:
			var tw := create_tween()
			tw.tween_property(cards[i], "scale", Vector3.ONE, 0.15)
			var mesh : MeshInstance3D = cards[i].get_node("MeshInstance3D")
			var tw2 := create_tween()
			tw2.tween_property(mesh, "transparency", 0.7, 0.3)


func _advance_phase(phase : int) -> void:
	match phase:
		Phase.GAMEMODE:
			# Buff phase depends on selected gamemode (e.g. no Repulsor in Tag modes).
			if GameLobby.is_host():
				_reroll_buff_offerings_for_gamemode(chosen_gamemode)
				offered_buffs = _normalize_three_offers(offered_buffs, ALL_BUFFS)
				rpc("_rpc_sync_buff_offerings", offered_buffs)
				_rpc_sync_buff_offerings(offered_buffs)
			title_label.text = "CHOOSE MAP"
			anim_player.play("pivot_to_map")
			await anim_player.animation_finished
			current_phase = Phase.MAP
			_begin_voting_phase()
		Phase.MAP:
			title_label.text = "CHOOSE BUFF"
			anim_player.play("pivot_to_buff")
			await anim_player.animation_finished
			current_phase = Phase.BUFF
			_begin_voting_phase()
		Phase.BUFF:
			title_label.text = ""
			timer_label.text = ""
			current_phase = Phase.LAUNCHING
			anim_player.play("pivot_down")
			await anim_player.animation_finished
			await get_tree().create_timer(0.6).timeout
			_launch_game()


# ══════════════════════════════════════════════════════════════════════════════
#  LAUNCH
# ══════════════════════════════════════════════════════════════════════════════

func _launch_game() -> void:
	var tw := create_tween()
	tw.tween_property(blackout, "modulate:a", 1.0, 0.6)
	await tw.finished

	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.selected_map = chosen_map_path
		gs.selected_gamemode = chosen_gamemode
		gs.selected_buff = chosen_buff

	if GameLobby.is_host():
		GameLobby.begin_match(chosen_map_path, chosen_gamemode, chosen_buff)

	get_tree().change_scene_to_file(chosen_map_path)


func _on_server_closed() -> void:
	if has_node("/root/GameSettings"):
		var gs : Node = get_node("/root/GameSettings")
		gs.disconnect_message = "Host left the lobby."
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://ui/MainMenu.tscn")


# ══════════════════════════════════════════════════════════════════════════════
#  PHANTOM CAMERA STATION SYSTEM
# ══════════════════════════════════════════════════════════════════════════════


# ══════════════════════════════════════════════════════════════════════════════
#  LEADERBOARD STATION
# ══════════════════════════════════════════════════════════════════════════════

## Build the 4th station at the +X world position (camera looks there when
## cam_pivot.rotation.y = −π/2).  All elements are in the station’s local space;
## rotation_degrees.y = 90 ensures the “front” faces the camera.
func _setup_leaderboard_station() -> void:
	_leaderboard_station = Node3D.new()
	_leaderboard_station.name = "LeaderboardStation"
	_leaderboard_station.position = Vector3(7.0, 0.0, 0.0)
	_leaderboard_station.rotation_degrees.y = 90.0
	add_child(_leaderboard_station)

	# ─ Background panel ─
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = Color(0.06, 0.06, 0.14)
	panel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(10.0, 6.5, 0.08)
	var panel_inst := MeshInstance3D.new()
	panel_inst.mesh = panel_mesh
	panel_inst.material_override = panel_mat
	panel_inst.position = Vector3(0.0, 3.2, 0.05)
	_leaderboard_station.add_child(panel_inst)

	# ─ Header card ─
	_create_text_card(_leaderboard_station, "LEADERBOARD", Vector2(780, 180),
			Vector2(4.6, 1.05), Vector3(0.0, 5.85, 0.08), Color(1.0, 0.9, 0.3), 84)

	# ─ Podium blocks: centre/tallest = 1st, left = 2nd, right = 3rd ─
	# Each entry: [local_x, height, colour].
	var pods : Array = [
		[  0.0, 1.4, Color(1.00, 0.84, 0.00)],  # gold
		[ -2.5, 0.9, Color(0.75, 0.75, 0.75)],  # silver
		[  2.5, 0.6, Color(0.80, 0.50, 0.20)],  # bronze
	]
	for pod : Array in pods:
		var px  : float = pod[0]
		var ph  : float = pod[1]
		var col : Color = pod[2]
		var pm := StandardMaterial3D.new()
		pm.albedo_color = col * 0.55
		pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var bm := BoxMesh.new()
		bm.size = Vector3(1.9, ph, 1.1)
		var pi := MeshInstance3D.new()
		pi.mesh = bm
		pi.material_override = pm
		pi.position = Vector3(px, ph * 0.5, 0.0)
		_leaderboard_station.add_child(pi)


## Populate the leaderboard with player capsules + score labels.
## Reads scores from GameSettings.lps_scores — call after the scene settles.
func _populate_leaderboard() -> void:
	if _leaderboard_station == null:
		return
	var gs : Node = get_node_or_null("/root/GameSettings")
	if gs == null:
		return

	# Remove stale contestants if re-entering the screen.
	for child : Node in _leaderboard_station.get_children():
		if child.name.begins_with("Contestant"):
			child.queue_free()

	# Sort players by score descending.
	var scores : Dictionary = gs.lps_scores
	var saved_names : Dictionary = gs.lps_player_names if gs.get("lps_player_names") != null else {}
	var sorted_ids : Array = []
	for pid : int in scores:
		sorted_ids.append(pid)
	sorted_ids.sort_custom(func(a : int, b : int) -> bool:
		return scores.get(a, 0) > scores.get(b, 0))

	# Matches the podium x/top-y values in _setup_leaderboard_station().
	var pod_x     : Array[float] = [  0.0, -2.5,  2.5]
	var pod_top_y : Array[float] = [  1.4,  0.9,  0.6]
	var ranks     : Array[String] = ["1ST", "2ND", "3RD"]

	for i : int in mini(sorted_ids.size(), 3):
		var pid   : int    = sorted_ids[i]
		var pts   : int    = scores.get(pid, 0)
		var pname : String = str(saved_names.get(pid, GameLobby.display_name(pid)))

		var root := Node3D.new()
		root.name = "Contestant%d" % i
		root.position = Vector3(pod_x[i], pod_top_y[i], 0.0)
		_leaderboard_station.add_child(root)

		# Player model (same pattern as LobbyRoom).
		var player_scene_res : PackedScene = load(PLAYER_SCENE)
		if player_scene_res:
			var puppet : Node = player_scene_res.instantiate()
			puppet.name = "PlayerModel"
			puppet.set_multiplayer_authority(pid)  # so NameLabel3D uses correct name
			puppet.setup_network(false)            # display-only, no camera/input
			puppet.rotation.y = PI                 # face the camera
			root.add_child(puppet)
			puppet.set_process_mode(Node.PROCESS_MODE_DISABLED)
			# Hide the auto-generated name label — we use info_lbl below instead.
			var auto_lbl : Node = puppet.get_node_or_null("NameLabel3D")
			if auto_lbl:
				auto_lbl.visible = false

			# Continuous 360° spin + up/down tilt (showcase turntable).
			var spin_tw := create_tween().set_loops()
			spin_tw.tween_property(puppet, "rotation:y", PI + TAU, 5.0).from(PI)
			var tilt_tw := create_tween().set_loops()
			tilt_tw.tween_property(puppet, "rotation:x", 0.35, 1.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tilt_tw.tween_property(puppet, "rotation:x", -0.35, 1.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tilt_tw.tween_property(puppet, "rotation:x", 0.0, 1.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

		# Rank + info as separate viewport cards (2D text rendered onto quads).
		var rank_col := Color(1.0, 0.9, 0.3) if i == 0 else Color(0.95, 0.95, 1.0)
		_create_text_card(root, ranks[i], Vector2(260, 110), Vector2(1.25, 0.52),
				Vector3(0.0, -0.48, 0.04), rank_col, 56)
		_create_text_card(root, "%s\n%d pts" % [pname, pts], Vector2(420, 180),
				Vector2(1.95, 0.82), Vector3(0.0, 2.55, 0.04), Color(0.95, 0.95, 1.0), 46)


func _create_text_card(parent: Node3D, text: String, vp_size: Vector2,
		world_size: Vector2, offset: Vector3, text_color: Color, font_size: int) -> void:
	var holder := Node3D.new()
	holder.position = offset
	parent.add_child(holder)

	var vp := SubViewport.new()
	vp.size = Vector2i(int(vp_size.x), int(vp_size.y))
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	holder.add_child(vp)

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.80)
	bg.size = vp_size
	vp.add_child(bg)

	var lbl := Label.new()
	lbl.text = text
	lbl.size = vp_size
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", text_color)
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	lbl.add_theme_constant_override("outline_size", 6)
	vp.add_child(lbl)

	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = world_size
	qm.flip_faces = true
	quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = vp.get_texture()
	mat.uv1_scale = Vector3(-1, 1, 1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material_override = mat
	holder.add_child(quad)


## Tween the camera pivot to face the leaderboard station.
## Awaitable — host awaits it; clients call fire-and-forget.
func _show_leaderboard() -> void:
	current_phase = Phase.LEADERBOARD
	timer_label.text = ""
	var tw := create_tween()
	tw.set_ease(Tween.EASE_IN_OUT)
	tw.set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(cam_pivot, "position", Vector3(0.0, 2.5, 0.0), 1.2)
	tw.parallel().tween_property(cam_pivot, "rotation",
		Vector3(-0.12, -PI * 0.5, 0.0), 1.2)
	await tw.finished


## Sweep the camera from the leaderboard back to the gamemode station.
## Fires-and-forgets when called by clients, awaited by host.
func _tween_from_leaderboard_to_gamemode() -> void:
	var tw := create_tween()
	tw.set_ease(Tween.EASE_IN_OUT)
	tw.set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(cam_pivot, "rotation",
		Vector3(-0.12, 0.0, 0.0), 2.0)
	tw.tween_callback(func() -> void:
		current_phase = Phase.GAMEMODE
		_begin_voting_phase())


## Return all players to the lobby without disconnecting.
@rpc("any_peer", "reliable", "call_remote")
func _rpc_end_to_lobby() -> void:
	if not _is_host_message_sender():
		return
	_end_to_lobby()


func _end_to_lobby() -> void:
	if GameLobby.is_host():
		GameLobby.end_match()
	if has_node("/root/GameSettings"):
		get_node("/root/GameSettings").lps_clear()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://multiplayer/LobbyRoom.tscn")


func _normalize_three_offers(values: Array, fallback_pool: Array) -> Array[String]:
	var out : Array[String] = []
	for v in values:
		var s := str(v)
		if s != "" and s != "---" and not out.has(s):
			out.append(s)
	for v in fallback_pool:
		var s := str(v)
		if s != "" and not out.has(s):
			out.append(s)
	while out.size() < 3:
		out.append("---")
	if out.size() > 3:
		out = out.slice(0, 3)
	return out


func _offer_at(values: Array[String], index: int) -> String:
	if index >= 0 and index < values.size():
		return values[index]
	return "---"


func _is_host_message_sender() -> bool:
	if GameLobby.is_host():
		return true
	var sender : int = multiplayer.get_remote_sender_id()
	# Local/call_local path.
	if sender == 0:
		return true
	return sender == GameLobby.get_host_peer_id()
