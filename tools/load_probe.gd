extends DotLoadProbe

## The load probe: dot-game's [DotLoadProbe] on this game's offline solo client, with the map
## column(s) before player/cam/hud. Needs xvfb-run, never --headless:
##   xvfb-run -a godot --path . res://tools/load_probe.tscn -- [--frames=90] [--shot=N]
const PhClient := preload("../game/ph_client.gd")


func _make_client() -> Node:
	var c := PhClient.new()
	c.set("force_offline", true)
	return c


func _columns(gate: Object) -> String:
	return "map=%s %s" % [client.get("game").map != null, super(gate)]
