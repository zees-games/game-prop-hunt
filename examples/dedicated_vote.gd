extends "dedicated_rotation.gd"
## The map vote and rock-the-vote checks of the dedicated suite; dedicated.gd extends this.


## The players' vote decides the next map: a ballot over the server's maps, one vote, and the round's end puts the winner on the next round.
## Driven by hand because stand-ins are not voters; hibernation: the director follows the server's and the ballot's timer waits with it.
func _vote_sleeps_with_the_server(vote: Node) -> void:
	var sleeper: GSVoteDirector = vote.get("director")
	_check(server.hibernation_changed.is_connected(sleeper.set_hibernating),
		"the vote follows the server's hibernation without a line of this game's")
	vote.set("_opened_this_map", true)
	server.console.execute("sv_hibernate_when_empty 1")
	_check(server.is_hibernating() and sleeper.hibernating, "an empty server sleeps, and the vote with it",
		server.state_name())
	var on_map: float = vote.get("_on_map_sec")
	vote.call("advance", 600.0)
	_check(is_equal_approx(vote.get("_on_map_sec"), on_map), "ten minutes asleep do not count towards the ballot")
	server.console.execute("sv_hibernate_when_empty 0")
	_check(not sleeper.hibernating, "waking wakes the vote")
	_check(is_zero_approx(vote.get("_on_map_sec")) and not vote.get("_opened_this_map"),
		"and the map ballot is owed again from the top")


func _test_the_map_vote() -> void:
	_section("the map vote")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null, "the module built a map vote")

	if vote == null:
		_finished()
		return

	_check(server.console.find_command("vote") != null if server.console.has_method("find_command") else true,
		"and registered dot-vote's vote command")

	_vote_sleeps_with_the_server(vote)

	# Every map in the directory, not only this suite's practice house.
	game.config.map_ids = PackedStringArray()
	vote.call("refresh_maps")
	var ids: Array = []

	for choice: GSVoteChoice in (vote.get("source") as GSVoteListSource).entries:
		ids.append(String(choice.id))

	_check(ids.has("ph_school") and ids.has("ph_house"), "it offers the delivered maps", str(ids))

	# The map menu's server half (M): the owner's flag changes the map now, anybody else
	# gets a nomination and a rock-the-vote. Contexts as gs-server makes them for a chat line.
	var menu_half: Object = vote.get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the map now")
	var staff := GSCmdContext.new()
	staff.source = GSCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := GSCmdContext.new()
	player.source = GSCmdContext.Source.CHAT
	var offered: Dictionary = menu_half.call("offer", player)
	_check((offered["maps"] as Array).size() > 1 and not bool(offered["allowed"]) and bool(offered["vote"]),
		"a player is offered every map, as a vote")
	var target: StringName = &""
	for row: Dictionary in offered["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var menu_changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(menu_changed["ok"]) and StringName(str(game.map_doc.get("id", ""))) == target, "staff choosing one changes the map on the spot",
		"%s: %s" % [target, menu_changed.get("text", "")])

	vote.set("voters_fn", func() -> Array: return [&"7"])
	var director: GSVoteDirector = vote.get("director")
	var opened := director.open_vote(GSVoteClock.REASON_MANUAL)
	_check(opened.ok and director.is_voting(), "a ballot opens", opened.error.message if not opened.ok else "")

	# The ballot is a sample of the maps, so the vote goes to one that is on it: a fixed id fell off
	# the ballot when a twenty-fourth map joined the list.
	var pick: StringName = &"ph_house"
	for oid in director.ballot.option_ids():
		if StringName(str(oid)) != StringName(str(game.map_doc.get("id", ""))):
			pick = StringName(str(oid))
			break
	var cast := director.cast_one(&"7", pick)
	# Everybody has voted; the director closes on its next advance, which is the server's tick.
	director.advance(0.05)
	_check(cast.ok and director.pending_id() == pick, "one vote decides it, waiting for the round's end",
		"%s %s" % [cast.ok, director.pending_id()])

	# No frame between these: the stand-ins' rounds are still running, and one that started in
	# between would lay the voted map itself and leave this check reading the rotation's.
	vote.call("note_round_end")
	_check(game.next_map_id == pick, "the round's end hands it to the world", str(game.next_map_id))

	game.call("_lay_out_map")
	_check(str(game.map_doc.get("id", "")) == str(pick) and game.next_map_id == &"",
		"and the next map laid is the one voted for, once", "%s / %s" % [game.map_doc.get("id", ""), game.next_map_id])

	_test_rock_the_vote(vote, director)
	_finished()


## Rock the vote, typed at the console, on the director the map vote built.
func _test_rock_the_vote(vote: Node, director: GSVoteDirector) -> void:
		# Rock the vote, typed at the console as a player's !rtv reaches it. Under MANUAL a passed rtv answered "Rocked. 1 of 1." and no ballot came.
		# Past gs-vote's cooldown, on the director alone so the map's own ballot timer does not open one first.
	var laid := StringName(str(game.map_doc.get("id", "")))
	_check(director.current_id() == laid and not director.is_voting(),
		"the new map starts the vote over", "%s / %s" % [director.current_id(), laid])
	vote.set("voters_fn", func() -> Array: return [&"console"])
	director.rules.rtv_delay_sec = 0.0
	director.rules.min_players_to_vote = 1
	director.rules.rtv_min_players = 1
	director.rules.allow_single_voter_auto = true
	director.advance(director.rules.vote_cooldown_sec + 0.1)
	var opened_count := [0]
	var counter := func(_options: Array, _seconds: float) -> void: opened_count[0] += 1
	director.vote_opened.connect(counter)
	var rocked := _run_command("rtv")
	vote.call("advance", 0.05)
	_check(director.is_voting(), "and a passing rock-the-vote opens a ballot", str(rocked))
		# The director opens it under MANUAL; this game must not also open it from clock.expired.
	_check(opened_count[0] == 1, "and opens exactly one rtv ballot, not a second from the game", str(opened_count[0]))
	director.vote_opened.disconnect(counter)
