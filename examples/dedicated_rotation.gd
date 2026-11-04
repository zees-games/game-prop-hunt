extends "dedicated_base.gd"

## The server state and console helpers every dedicated check shares, and the maps.yml checks.

const PhGame := preload("../game/ph_game.gd")

var server: DotServer = null
var game: PhGame = null


## maps.yml on the live module: a map outside the active rotation stays installed and loadable by `ph_map` but is never drawn, balloted or nominated;
## a rotation switch takes effect; the game's and dot-vote's commands are renamed from `commands:`; no file changes nothing.
func _test_map_rotation_file() -> void:
	_section("maps.yml")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(game != null and game.catalogue != null and vote != null and vote.get("director") != null,
		"the game has maps and a vote")

	if game == null or game.catalogue == null or vote == null or vote.get("director") == null:
		return

	var director: DotVoteDirector = vote.get("director")
	var catalogue := game.catalogue
	game.config.map_ids = PackedStringArray()
	var built := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "main",
		"rotations": {
			"main": {"mode": "cycle", "maps": ["ph_house", "ph_office"]},
			"alt": {"maps": ["ph_office"]},
		},
		"commands": {"names": {"rtv": "rockthevote", "ph_map": "setnextis", "ph_maps": "maplist"}},
	}}], "mg-prop-hunt")
	_check(built.ok, "a maps.yml with two rotations and renamed commands parses",
		"" if built.ok else built.error.message)
	if not built.ok:
		return

	var kept_file: DotMapRotationFile = game.rotation_file
	var all_ids: Array[StringName] = catalogue.playable(PackedStringArray())
	_check(all_ids.size() > 2 and catalogue.in_rotation_fn.is_valid() == (kept_file != null and kept_file.has_rotations()),
		"the catalogue holds more maps than the rotation will", str(all_ids.size()))
	game.rotation_file = built.value
	game.apply_rotation()
	vote.call("refresh_maps")

	_check(game.in_rotation(&"ph_house") and game.in_rotation(&"ph_office"), "the listed maps are in rotation")
	_check(not game.in_rotation(&"ph_school") and catalogue.playable(PackedStringArray()).has(&"ph_school"),
		"an unlisted map is out of rotation and still installed")
	_check(not game.shuffles_maps(), "a cycle rotation does not shuffle the draw")

	_check_cycle_draws()

	var ids := (vote.get("source") as DotVoteListSource).choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(ids.has(&"ph_office") and ids.has(&"ph_house") and not ids.has(&"ph_school"),
		"a map outside the rotation is not on the ballot, one inside is", str(ids))
	var nominated := director.nominate(&"u77", &"ph_school")
	_check(not nominated.ok, "nominate refuses a map outside the rotation")
	_check(not director.nominated_ids().has(&"ph_school"), "and nothing was recorded")

	var queued := _run_command("ph_map ph_school")
	_check(_said(queued, "ph_school is next") and game.next_map_id == &"ph_school",
		"an operator can still queue it with ph_map", str(queued))
	game.next_map_id = &""

	_check(server.console.find_command("ph_map") != null and server.console.find_command("ph_maps") != null,
		"with no file at load the game's own commands keep their names")
	_check(game.command_name("ph_map", "ph_map") == "setnextis" and game.command_name("ph_maps", "ph_maps") == "maplist"
		and game.command_name("ph_reload", "ph_reload") == "ph_reload",
		"the game's own command names come from maps.yml's commands, others keep theirs")
	var rows := game.map_rows().filter(func(r: Dictionary) -> bool: return r["id"] == "ph_school")
	_check(rows.size() == 1 and str(rows[0]["detail"]).contains("not in rotation"),
		"the map menu marks a map that is not in rotation")
	_check(_said(PackedStringArray(catalogue.describe_lines()), "not in rotation"),
		"and so does the ph_maps list")

	var rtv := DotVoteCommands.new()
	rtv.director = director
	rtv.spec_fn = game.rotation_commands
	var bound := rtv.bind(server.console)
	_check(bound.ok and rtv.command_name("rtv") == "rockthevote" and server.console.find_command("rockthevote") != null,
		"a renamed rtv command is registered from maps.yml's commands")
	var vote_commands: DotVoteCommands = vote.get("commands")
	_check(vote_commands != null and vote_commands.spec_fn.is_valid(), "and the game's vote hands its commands the file")

	_rotation_switch_and_reset(vote, kept_file)
	_finished()


## The second half of the maps.yml checks: a rotation switch, then no file at all, then the file as it was.
func _rotation_switch_and_reset(vote: Node, kept_file: DotMapRotationFile) -> void:
	var catalogue := game.catalogue
	var switched := game.rotation_file.switch(game._rot, "alt")
	game.apply_rotation()
	vote.call("refresh_maps")
	_check(switched.ok and game.in_rotation(&"ph_office") and not game.in_rotation(&"ph_house"),
		"switching to the alt rotation takes effect")
	var ids := (vote.get("source") as DotVoteListSource).choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(not ids.has(&"ph_house") and ids.has(&"ph_office"), "and the ballot follows it")
	_check(not game.rotation_file.switch(game._rot, "nope").ok, "an unknown rotation is refused")

	# No file again: everything back in, as before maps.yml.
	game.rotation_file = null
	game.apply_rotation()
	vote.call("refresh_maps")
	var all_in := true
	for id in catalogue.playable(PackedStringArray()):
		all_in = all_in and game.in_rotation(id)
	_check(all_in and game.shuffles_maps() == game.config.shuffle_maps, "with no file every map is in rotation and the draw is as configured")
	_check(game.rotation_commands().is_empty() and game.command_name("ph_map", "ph_map") == "ph_map",
		"and no command is renamed")

	game.rotation_file = kept_file
	game.apply_rotation()
	vote.call("refresh_maps")



func _check_cycle_draws() -> void:
	var catalogue := game.catalogue
	var drawn: Array = []
	var previous: StringName = &""
	for _i in 6:
		var doc := catalogue.next_map(PackedStringArray(), game.shuffles_maps(), game.random.stream(&"map"), previous)
		previous = StringName(str(doc["id"]))
		drawn.append(String(previous))
	var alternates: bool = drawn.size() == 6 and drawn[0] != drawn[1] and drawn[0] == drawn[2] and drawn[1] == drawn[3] and drawn[0] == drawn[4]
	_check(alternates and drawn.all(func(d: String) -> bool: return d == "ph_house" or d == "ph_office"),
		"six draws cycle the two written maps in turn and never leave them", str(drawn))


func _module() -> DotModule:
	return server.modules.get_module("prophunt") if server != null and server.modules != null else null


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, context)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false
