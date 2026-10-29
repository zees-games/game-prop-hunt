extends Node

## The round-end and scoreboard presentation layer of [PhClient], with the state it shares.

const PhFigure := preload("ph_figure.gd")
const PhNetBridge := preload("net/ph_net_bridge.gd")
const PhGame := preload("ph_game.gd")
const PhPlayer := preload("ph_player.gd")
const PhKillcam := preload("ph_killcam.gd")
const PhHud := preload("ph_hud.gd")
const PhSettings := preload("ph_settings.gd")

const CHANNEL := "ph.client"

var game: PhGame = null
var player: PhPlayer = null
var hud: PhHud = null
var board: DotMenuScoreboard = null
var chat: DotGameChatClient = null
var settings: PhSettings = null
var view_model: ZeeViewModel = null
var net: DotNetManager = null
## Records every frame and replays the round's last moment ([PhKillcam]); then the reveal.
var killcam: PhKillcam = null
var winner_reveal: DotWinnerReveal = null
## The server's `mp_killcam_time`; -1 until it has said, so the config's number stands.
var _killcam_sec: float = -1.0
var _round_ending: bool = false
var _round_end_number: int = 0
var _round_end_winner: int = 0
var _round_end_why: String = ""
var _round_board_open: bool = false
var _hud_was_visible: bool = true
var _started_msec: int = Time.get_ticks_msec()
## dot-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [DotGameClient].
var platform: DotGameClient = null


func _dress_board() -> void:
	if board == null:
		return

	board.title_text = "Prop Hunt"
	board.columns = [
		{"key": &"avatar", "kind": DotMenuScoreboard.KIND_AVATAR, "width": 0.0},
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"points", "title": "Points", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_by = &"points"
	board.decorate = _decorate_row
	board.prepare = _prepare_board


func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var id := PhNetBridge.player_key(int(row.get("id", 0)))
	if not game.players.has(id):
		id = StringName(str(row.get("id", "")))
	var who: PhPlayer = game.players.get(id)
	if who == null:
		return
	row["avatar"] = _face(who)
	row["points"] = who.points
	row["team"] = game.team_of(id)
	if int(row.get("ping", -1)) < 0 and who.ping_ms >= 0:
		row["ping"] = who.ping_ms
	if who == player:
		row["you"] = true


## The map in the header, and the two sides as the teams, props first.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	snap["header"] = {"Map": str(game.map_doc.get("name", "")), "Round": str(game.round_number)}
	snap["teams"] = [
		{"id": PhGame.PROPS, "name": game.side_name(PhGame.PROPS), "color": game.side_colour(PhGame.PROPS)},
		{"id": PhGame.HUNTERS, "name": game.side_name(PhGame.HUNTERS), "color": game.side_colour(PhGame.HUNTERS)},
	]


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	if game != null:
		for id in game.players:
			var who: PhPlayer = game.players[id]
			rows.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Prop Hunt", "game": "offline"}, "players": rows}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)


var _portraits: Dictionary = {}


func _face(who: PhPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


## A player's face for the board: their figure's head, rendered once per skin. See
## mg-deathrun, where this came from.
func _portrait(atlas: String) -> Texture2D:
	if _portraits.has(atlas):
		return _portraits[atlas]

	var view := SubViewport.new()
	view.name = "Portrait%d" % _portraits.size()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(view)

	var figure := PhFigure.new()
	view.add_child(figure)
	figure.build(1.8, atlas, Color.WHITE)
	figure.global_position = Vector3.ZERO

	var eye := Camera3D.new()
	eye.fov = 30.0
	view.add_child(eye)
	# The people's heads are big: the face is about 1.35 m up a 1.8 m person.
	eye.look_at_from_position(Vector3(0.0, 1.45, -2.0), Vector3(0.0, 1.35, 0.0), Vector3.UP)
	eye.current = true

	var texture := view.get_texture()
	_portraits[atlas] = texture
	return texture



## A hider found is the moment, seen from the hunter who found them; anything else from the
## victim's own eyes.
func _note_death(victim: PhPlayer, by: PhPlayer, weapon_id: StringName = &"") -> void:
	if killcam == null or victim == null:
		return
	if by != null and by != victim:
		killcam.note_moment(by.player_id, "found", victim.display_name, weapon_id)
	else:
		killcam.note_moment(victim.player_id, "out")


## `mp_killcam_time`, from the server's replicated cvar.
func _on_killcam_cvar(cvar_name: String, value: String) -> void:
	if cvar_name == "mp_killcam_time" and value.strip_edges().is_valid_float():
		_killcam_sec = clampf(value.to_float(), 0.0, 30.0)


func _begin_round_end(number: int, winner: int, why: String) -> void:
	_round_end_number = number
	_round_end_winner = winner
	_round_end_why = why
	_round_ending = true
	if killcam == null:
		_reveal_round()
		return
	# The clock running out has no death to show: the replay is from a prop still hidden.
	if why.begins_with("time"):
		for p: PhPlayer in game.players_on(PhGame.PROPS):
			if p.is_alive():
				killcam.note_moment(p.player_id, "still hidden when time ran out")
				break
	killcam.hide_while_playing = [hud, chat.window if chat != null else null, view_model, platform.hud if platform != null else null]
	if killcam.round_ended():
		DotLog.debug(CHANNEL, "the winner waits for the killcam")


## The winning side and its best three, after the killcam and before the board.
func _reveal_round() -> void:
	if not _round_ending or winner_reveal == null or winner_reveal.is_active():
		return
	var rows: Array = []
	for key: StringName in game.players:
		var who: PhPlayer = game.players[key]
		if _round_end_winner == 0 or game.team_of(key) == _round_end_winner:
			rows.append(who)
	rows.sort_custom(func(a: PhPlayer, b: PhPlayer) -> bool: return a.points > b.points)
	var entries: Array = []
	for who: PhPlayer in rows.slice(0, 3):
		entries.append({"name": who.display_name, "score": "%d %s" % [who.points, "point" if who.points == 1 else "points"],
			"colour": game.side_colour(game.team_of(who.player_id))})
	winner_reveal.reduced_motion = settings != null and settings.settings != null and settings.settings.get_bool(&"reduce_motion", false)
	var title := "%s WIN" % game.side_name(_round_end_winner).to_upper() if _round_end_winner != 0 else "DRAW"
	var shown := winner_reveal.present(entries, {"title": title,
		"subtitle": _round_end_why.substr(0, 1).to_upper() + _round_end_why.substr(1) if _round_end_why != "" else "Round %d" % _round_end_number,
		"hint": "Jump to skip"}) if not entries.is_empty() else DotResult.fail(DotError.CODE_INVALID, "nobody to show")
	if not shown.ok:
		_open_round_board()
		return
	if hud != null:
		_hud_was_visible = hud.visible
		hud.visible = false


func _on_reveal_finished(_skipped: bool) -> void:
	if hud != null and not killcam.is_playing():
		hud.visible = _hud_was_visible
	if _round_ending:
		_open_round_board()


func _open_round_board() -> void:
	if board != null and not board.is_open():
		board.open()
		_round_board_open = true


## A new round: whatever is still up goes, so it never covers the start.
func _end_round_presentation() -> void:
	_round_ending = false
	if killcam != null:
		killcam.skip()
	if winner_reveal != null:
		winner_reveal.skip()
	if _round_board_open and board != null:
		board.close()
	_round_board_open = false


func _killcam_frame() -> void:
	if killcam != null and game != null:
		killcam.frame()
