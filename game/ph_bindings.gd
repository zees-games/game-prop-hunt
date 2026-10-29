extends RefCounted

## Every key this game reads, as one [DotMenuBindings] table (action, setting, words, default, card) that the client, settings, Controls page and help screen all read.
## A prop's keys and a hunter's never share a default (reload is R, so the rotation lock is C), and nothing defaults to H, which is help in every game.
## Right mouse aims (`ZeeViewModel.aim`); B is the hunter's loadout; chat is two rows on dot-ui's chat actions (Y to all, U to your side) so the Controls page moves them.

const DISGUISE := &"ph_disguise"
const REVEAL := &"ph_reveal"
const LOCK := &"ph_lock"
const TAUNT := &"ph_taunt"
const TAUNT_MENU := &"ph_taunt_menu"
const TILT_FORWARD := &"ph_tilt_forward"
const TILT_BACK := &"ph_tilt_back"
const TILT_LEFT := &"ph_tilt_left"
const TILT_RIGHT := &"ph_tilt_right"
const STRAIGHTEN := &"ph_straighten"
const RELOAD := &"ph_reload"
## A hunter's aim down the sights (right mouse, the family's Aim row): the view model comes up
## and the lens zooms. Presentation only.
const AIM := &"ph_aim"
## A hunter's quick melee (zee's alt-fire), on F since the right mouse button aims.
const BASH := &"ph_bash"
const VIEW := &"ph_view"
## A spectator's free camera: does nothing to anybody who is playing.
const ROAM := &"ph_roam"
const SCOREBOARD := &"ph_scoreboard"
## dot-ui's chat window's actions, which dot-game's chat client leaves at their defaults.
const CHAT := &"chat_open"
const CHAT_TEAM := &"chat_open_team"
## A hunter's weapon slots, 1 to 5, as rows read through their actions so the Controls page can move them and the help screen lists them.
const SLOTS: Array[StringName] = [&"ph_slot_1", &"ph_slot_2", &"ph_slot_3", &"ph_slot_4", &"ph_slot_5"]


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement()
	var _wheel := keys.add_wheel_weapons(&"dot_menu_weapon_previous", &"dot_menu_weapon_next", "Hunters")
	keys.add(DISGUISE, &"bind_disguise", "Become what you look at", "E", "Props")
	keys.add(REVEAL, &"bind_reveal", "Show yourself / hide again", "Q", "Props")
	keys.add(LOCK, &"bind_lock", "Lock rotation", "C", "Props")
	keys.add(TAUNT, &"bind_taunt", "Taunt", "T", "Props")
	keys.add(TAUNT_MENU, &"bind_taunt_menu", "Pick a taunt", "F3", "Props")
	keys.add(TILT_FORWARD, &"bind_tilt_forward", "Tilt forward", "Up", "Props")
	keys.add(TILT_BACK, &"bind_tilt_back", "Tilt back", "Down", "Props")
	keys.add(TILT_LEFT, &"bind_tilt_left", "Lean left", "Left", "Props")
	keys.add(TILT_RIGHT, &"bind_tilt_right", "Lean right", "Right", "Props")
	keys.add(STRAIGHTEN, &"bind_straighten", "Stand upright", "Z", "Props")
	keys.add(RELOAD, &"bind_reload", "Reload", "R", "Hunters")
	keys.add(AIM, &"bind_aim", "Aim down the sights (hold)", "Mouse 2", "Hunters")
	keys.add(BASH, &"bind_bash", "Quick melee", "F", "Hunters")
	for i in range(SLOTS.size()):
		keys.add(SLOTS[i], StringName("bind_slot_%d" % (i + 1)), "Weapon slot %d" % (i + 1), str(i + 1), "Hunters")
	keys.add(CHAT, &"bind_chat", "Chat", "Y", "Communication")
	keys.add(CHAT_TEAM, &"bind_chat_team", "Chat to your side", "U", "Communication")
	keys.add(VIEW, &"bind_view", "First or third person", "F5", "General")
	keys.add(ROAM, &"bind_roam", "Free camera (spectating)", "G", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	# B is a hunter's loadout (dot-menu's `dot_menu_loadout`), where the host has it (API 6).
	if DotAddonApi.build_level("dot_menu") >= 6 and keys.has_method(&"add_loadout"):
		var _l: Variant = keys.call(&"add_loadout", "Hunters")
	return keys
