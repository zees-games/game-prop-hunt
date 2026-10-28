extends DotGameModule

## The console commands of PhModule that read the world and change nothing else; ph_module.gd adds the load, the wiring and the rest.

const PhNetBridge := preload("net/ph_net_bridge.gd")
const PhServices := preload("ph_services.gd")
const PhGame := preload("ph_game.gd")


func _cmd_wish(ctx: DotCmdContext, side: int) -> void:
	var world := game as PhGame
	if world == null or ctx.session == null:
		ctx.reply("Only a player can choose a side.")
		return
	if not world.config.allow_side_choice:
		ctx.reply("Sides are drawn on this server.")
		return
	world.wish_side(PhNetBridge.player_key(ctx.session.userid), side)
	ctx.reply(
		"You will be picked to hunt first." if side == PhGame.HUNTERS
		else ("You will only hunt if nobody else can." if side == PhGame.PROPS else "Either side.")
	)


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, PhServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as PhGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


func _cmd_maps(ctx: DotCmdContext) -> void:
	var world := game as PhGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines())
	ctx.reply("playing: %s" % str(world.map_doc.get("id", "-")))


func _cmd_map(ctx: DotCmdContext) -> void:
	var world := game as PhGame
	var id := StringName(ctx.arg(0)) if ctx.argc() > 0 else &""

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	if id == &"" or not world.catalogue.playable(world.config.map_ids).has(id):
		ctx.reply("Which map? %s" % ", ".join(world.catalogue.playable(world.config.map_ids)))
		return

	world.next_map_id = id
	ctx.reply("%s is next, from the end of this round." % String(id))


func _cmd_taunts(ctx: DotCmdContext) -> void:
	var world := game as PhGame

	if world == null or world.taunts == null:
		ctx.reply("No world.")
		return

	for id in world.taunt_ids():
		var entry := world.taunts.entry(id)
		ctx.reply("  %-18s %-20s %.1f s" % [String(id), str(entry.get("title", "")), float(entry.get("seconds", 0.0))])

	ctx.reply(str(world.taunts.describe()))
