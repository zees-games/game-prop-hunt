extends RefCounted

## Every key this game reads, as one [DotMenuBindings] table: the action, the setting that
## stores it, the words a player sees, the default, and the card it goes on.
##
## [b]A table, because four things read it:[/b] the client matches events against the actions,
## the settings document stores one binding per row, the menu's Controls page draws a key per
## row, and the help screen lists them with the key each is on now.
##
## [b]A prop's keys and a hunter's never share a default.[/b] Reload is R for a hunter, so the
## prop's rotation lock is C; a player who is a prop this round and a hunter the next must not
## find that the key they reloaded with now does something else in the same round.
##
## [b]H is help, in every game of the family[/b] (dot-menu adds the row), so nothing here
## may default to it.
##
## [b]The right mouse button aims[/b] (zee's `ZeeViewModel.aim`), as in the arena; it was zee's
## quick melee until 2026-10-12, which moved to F. [b]B is the hunter's loadout[/b] (dot-menu).
##
## [b]Chat is two rows[/b] on dot-ui's chat window's own actions (Y to all, U to your side), so
## the help screen lists them and the Controls page moves them; until 2026-10-12 they were the
## window's defaults, on no page.

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
## A hunter's weapon slots, 1 to 5. Rows, read through their actions, so the Controls page can
## move them and the help screen lists them; they were keycodes in the client until 2026-10-11.
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
