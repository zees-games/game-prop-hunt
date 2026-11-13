extends DotGameCheckSuite

const PhCatalogue := preload("../game/ph_catalogue.gd")
const PhConfig := preload("../game/ph_config.gd")
const PhGame := preload("../game/ph_game.gd")
const PhVote := preload("../game/ph_vote.gd")

## What a subscribed map pack does to this game's lists, against a fixture [DotContentIndex] and never the process's shared one.
##   godot --headless --path . res://examples/headless_workshop.tscn
## A solo pack map is listed ("Name [Pack]") and can be chosen next, an online session lists none of it, a map kind the game does not accept is left out, and the game's own ids win.
## The client shell's `start_map` (`--solo-map`, a "Play map" link) is the first map laid out, from the map pack the shell mounted.

const SECTIONS := 6
const MAP := &"fixture_barn"
const DIR := "user://ws_fixture_ph/"

## A client shell's solo host as the game sees it: `start_map` and the `<pack>/maps` directories it mounted.
## [member start_map] null stands for an older shell that has no such property.
class FakeSolo:
	extends RefCounted
	var dirs := PackedStringArray()

	func map_dirs(_subdir: String) -> PackedStringArray:
		return dirs


class FakeSoloStart:
	extends FakeSolo
	var start_map: StringName = &""


var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-prop-hunt — Workshop maps")
	_write_fixture()
	_test_accepts()
	_test_solo()
	_test_online()
	_test_ids()
	await _test_vote()
	await _test_start_map()

	_report_sections(_entered, _completed, SECTIONS)


## The pack's map document: the built-in practice house under another name, which is a map this
## game certainly reads, so a refusal here is the loader's and not the fixture's.
func _write_fixture() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var doc := PhCatalogue.practice().duplicate(true)
	doc["id"] = String(MAP)
	doc["name"] = "Fixture Barn"
	var file := FileAccess.open(DIR + "barn.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(doc))
	file.close()


## A pack with a prop-hunt map, a map of a kind the game does not accept, and a map that claims
## the id of the built-in.
func _index(session: StringName) -> DotContentIndex:
	var index := DotContentIndex.new()
	index.set_session(session)
	var added := index.add_pack({
		"content_id": "fixture/barns", "version": "1.0.0", "prefix": DIR,
		"session": session, "source": &"subscription",
		"provides": {"schema": 1, "title": "Fixture Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": String(MAP), "name": "Fixture Barn", "scene": "barn.json", "map_kind": "prophunt"},
			{"kind": "map", "id": "fixture_run", "name": "Fixture Run", "scene": "barn.json", "map_kind": "surf"},
			{"kind": "map", "id": "ph_practice", "name": "Not The House", "scene": "barn.json", "map_kind": "prophunt"},
		]},
	})
	_check(added.ok, "the fixture pack registers for %s" % session)
	return index


func _catalogue(index: DotContentIndex) -> PhCatalogue:
	var catalogue := PhCatalogue.new()
	var _loaded := catalogue.load_from("maps")
	catalogue.follow_content(index, PhCatalogue.accepted_map_kinds())
	return catalogue


func _test_accepts() -> void:
	_entered += 1
	print("")
	print("what the game accepts")
	_check(PhCatalogue.accepted_map_kinds() == PackedStringArray(["prophunt"]),
		"provides.json accepts the prophunt map kind", str(PhCatalogue.accepted_map_kinds()))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://provides.json"))
	var accepts: Dictionary = (parsed as Dictionary).get("accepts", {})
	_check(accepts.get("kinds") == ["map"], "and only maps (props need a measured hull)", str(accepts))
	_completed += 1


func _test_solo() -> void:
	_entered += 1
	print("")
	print("solo")
	var catalogue := _catalogue(_index(DotContentIndex.SESSION_SOLO))
	_check(catalogue.playable(PackedStringArray()).has(MAP), "the accepted map is playable")
	_check(catalogue.label_of(MAP) == "Fixture Barn [Fixture Pack]", "its label names the pack", catalogue.label_of(MAP))
	_check(not catalogue.maps.has(&"fixture_run"), "a map kind the game does not accept is filtered out")
	_check(catalogue.maps[MAP].get("boxes", []).size() > 0, "and it is a whole document, with its boxes")
	var text := "\n".join(catalogue.describe_lines())
	_check(text.contains("Fixture Barn [Fixture Pack]"), "ph_maps lists it as Name [Pack]")
	var next := catalogue.next_map(PackedStringArray([String(MAP)]), false, null, &"")
	_check(next.get("id") == String(MAP), "and it can be drawn as the next map")
	_completed += 1


func _test_online() -> void:
	_entered += 1
	print("")
	print("online")
	var index := _index(DotContentIndex.SESSION_SOLO)
	var catalogue := _catalogue(index)
	_check(catalogue.playable(PackedStringArray()).has(MAP), "listed while the index is solo")
	index.set_session(DotContentIndex.SESSION_ONLINE)
	_check(not catalogue.playable(PackedStringArray()).has(MAP), "gone from the same catalogue when the session turns online")
	_check(not catalogue.maps.has(MAP), "and from its documents")
	index.set_session(DotContentIndex.SESSION_SOLO)
	_check(catalogue.playable(PackedStringArray()).has(MAP), "back when it turns solo again")
	var late := _index(DotContentIndex.SESSION_SOLO)
	late.set_session(DotContentIndex.SESSION_ONLINE)
	_check(not _catalogue(late).playable(PackedStringArray()).has(MAP), "a catalogue built online never lists it")
	_completed += 1


func _test_ids() -> void:
	_entered += 1
	print("")
	print("the game's own ids")
	var catalogue := _catalogue(_index(DotContentIndex.SESSION_SOLO))
	_check(catalogue.maps[PhCatalogue.PRACTICE].get("name") == "Practice House" and not catalogue.is_workshop(PhCatalogue.PRACTICE),
		"a pack map claiming ph_practice does not replace the built-in")
	_completed += 1


func _labels(vote: PhVote) -> PackedStringArray:
	var out := PackedStringArray()
	for choice in vote.source.choices():
		out.append(choice.label())
	return out


func _vote(index: DotContentIndex, catalogue: PhCatalogue) -> PhVote:
	var vote := PhVote.new()
	vote.config_path = ""
	vote.content_index = index
	vote.maps_fn = func() -> Array:
		var out: Array = []
		for id in catalogue.playable(PackedStringArray()):
			if not catalogue.is_workshop(id):
				out.append([id, str(catalogue.maps[id].get("name", id))])
		return out
	add_child(vote)
	var _set_up := vote.setup()
	return vote


func _test_vote() -> void:
	_entered += 1
	print("")
	print("the ballot")
	var index := _index(DotContentIndex.SESSION_SOLO)
	var catalogue := _catalogue(index)
	var vote := _vote(index, catalogue)
	# The game's own map the ballot must still carry: whatever the catalogue plays first. A checkout
	# without `maps/` has only the practice house, which a ballot never offers (see PhCatalogue.playable).
	var own := ""
	for id in catalogue.playable(PackedStringArray()):
		if not catalogue.is_workshop(id):
			own = str(catalogue.maps[id].get("name", id))
			break
	var labels := _labels(vote)
	_check(labels.has("Fixture Barn [Fixture Pack]"), "the solo ballot lists the pack map as Name [Pack]", str(labels))
	_check(labels.has(own), "beside the game's own maps, unlabelled", "%s in %s" % [own, str(labels)])
	_check(not labels.has("Fixture Run [Fixture Pack]"), "and not a kind the game does not accept")
	_check(labels.count("Fixture Barn [Fixture Pack]") == 1, "once")
	index.set_session(DotContentIndex.SESSION_ONLINE)
	labels = _labels(vote)
	_check(not labels.has("Fixture Barn [Fixture Pack]"), "online the same ballot lists none of it", str(labels))
	_check(labels.has(own), "and still has the game's own")
	vote.queue_free()
	await get_tree().process_frame
	_completed += 1


## A world laid out with [param host] as the `dot_solo` service (none when null): the id of its first map.
func _first_map(host: Object) -> String:
	if host != null:
		DotRegistry.register(PhGame.SOLO_SERVICE, host)
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.shuffle_maps = false
	var game := PhGame.new()
	game.config = config
	game.tick_rate = 60
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	var id := str(game.map_doc.get("id", ""))
	remove_child(game)
	game.free()
	if host != null:
		DotRegistry.unregister_instance(PhGame.SOLO_SERVICE, host)
	await get_tree().process_frame
	return id


func _test_start_map() -> void:
	_entered += 1
	print("")
	print("the shell's start map")
	var plain := await _first_map(null)
	_check(plain != "" and plain != String(MAP), "with no solo host the first map is the game's own", plain)
	_check(PhGame.solo_start_map() == &"", "and there is no start map")
	# The fallbacks mount no pack: a pack map can be the first of a checkout without `maps/`.
	_check(await _first_map(FakeSolo.new()) == plain, "a shell with no start_map changes nothing")
	var asked := FakeSoloStart.new()
	asked.start_map = &"ph_not_a_map"
	_check(await _first_map(asked) == plain, "a start map nobody has falls back to the game's own")
	asked.start_map = &""
	_check(await _first_map(asked) == plain, "an empty one changes nothing")
	asked.dirs = PackedStringArray([DIR])
	asked.start_map = MAP
	_check(await _first_map(asked) == String(MAP), "a start map from the mounted pack is the first map laid out")
	_completed += 1
