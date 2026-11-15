extends "ph_module_commands.gd"

## The map vote half of [code]ph_module.gd[/code]: the ballot, its cvars and the hooks that open and close it.

const PhPlayer := preload("ph_player.gd")
const PhVote := preload("ph_vote.gd")
## The players' vote for the next map; null when it could not be built.
var vote: PhVote = null
## The drawn ballot's notice topic. The client shell draws one menu per topic.
const MAP_BALLOT_TOPIC := &"map_ballot"


## A number as an operator would type it: `34`, not `34.000000`.
## Not `%g`: the parser accepts it but it fails at RUNTIME ("unsupported format character"), inside `_game_load`,
## which unwinds the module sequence above it.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## What the ballot asks the game: the maps, the voters, who may change the map and where a ballot goes.
func _set_vote_hooks(world: PhGame) -> void:
	vote.commands_spec_fn = world.rotation_commands
	vote.in_rotation_fn = func(id: StringName) -> bool: return world.catalogue.in_rotation(id)
	vote.rotation_order_fn = func() -> Array: return world.catalogue.rotation_order
	vote.maps_fn = func() -> Array:
		var out: Array = []

		# The game's own maps only: the Workshop's come from the source's own follow, which
		# reads the index on every ballot and so shows none of them online.
		for id in world.catalogue.playable(world.config.map_ids):
			# maps.yml: a map outside the active rotation is not balloted or nominated.
			if not world.catalogue.is_workshop(id) and world.catalogue.in_rotation(id):
				out.append([id, str((world.catalogue.maps.get(id, {}) as Dictionary).get("name", id))])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_map_id = id
		return DotResult.success(id)
	vote.due_fn = func() -> bool:
		return world.rounds_left_on_map() <= 1
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: PhPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := PhNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, PhServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()


## The players' vote for the next map, over dot-vote: `!vote`, `!rtv`, `!nominate`.
## Opened [member PhVote.open_after_sec] into the last round and applied when it ends; configured in
## `user://cfg/prophunt_vote.json` or `game.yml`. A vote that cannot be built is a WARN, never a server that won't start.
func _build_vote(world: PhGame) -> void:
	if world.catalogue == null:
		return

	vote = PhVote.new()
	vote.name = "MapVote"
	_set_vote_hooks(world)

	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the map vote; the rotation alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the map vote's commands", commanded)

	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# map now, not after its rounds, and sees the same rows a solo player does. Read by name,
	# because a server on a dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_map_now)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.map_rows())

	var vote_after := add_cvar("ph_vote_after", _number(vote.open_after_sec),
		"Seconds into the last round on a map before the vote for the next one opens")
	if vote_after != null:
		vote_after.changed.connect(func(_old: String, new_value: String) -> void:
			if vote != null:
				vote.open_after_sec = maxf(new_value.to_float(), 0.0))

	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.map != null:
			vote.note_map(world.map.id())
	)
	world.round_began.connect(func(_number: int, _map: StringName) -> void:
		if vote != null:
			vote.note_round_start()
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)
