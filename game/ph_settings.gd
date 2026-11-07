extends DotMenuGameSettings

const PhBindings := preload("ph_bindings.gd")

## A player's own settings and the menu that changes them: dot-menu's `DotMenuGameSettings` with this game's spec (names, field of view, keys, help).
## Scopes are the family's: `sensitivity` is ACCOUNT (`tmc_account`), `field_of_view` SERVER_CLAMPED (a server may cap a wide view but cannot READ it), volumes this machine's.
## Use: `add_child(s); s.setup(); s.bind_look(...); s.bind_camera(...); s.bind_audio(...); s.open()`.

const SCHEMA_VERSION := 1

## Where this game's own document lives. The shared account document is dot-settings'.
const SETTINGS_DIR := "user://prophunt_settings"

## The app's namespace. ACCOUNT settings are shared under dot-menu's `tmc_account`.
const APP_NAMESPACE := &"prophunt"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 92

## Stock keys nothing here applies: every sound is on the SFX bus, the client binds no
## effects, and the chat box has no switch.
const NOT_APPLIED: Array[StringName] = [
	&"ui_volume", &"shake_scale", &"allow_flashes", &"fx_quality", &"chat_window",
]


func _init() -> void:
	super(spec_for())


## The game's settings as data: names, field of view, extra settings, keys and the help screen's goal and rules.
static func spec_for() -> DotMenuGameSpec:
	var s := DotMenuGameSpec.new()
	s.schema_version = SCHEMA_VERSION
	s.brand_name = "Prop Hunt"
	s.settings_dir = SETTINGS_DIR
	s.app_namespace = APP_NAMESPACE
	s.default_fov = DEFAULT_FOV
	s.reduce_motion_text = "The end-of-round announcement appears at once, with nothing sliding, rising or bursting."
	s.comfort_row_text = "The end-of-round announcement appears at once."
	s.ambient_text = "Quiet sounds under the map."
	s.not_applied = NOT_APPLIED
	s.bindings_maker = func() -> DotMenuBindings: return PhBindings.make()
	s.help_about = "Most players are props: look at something on the map, press E to become it, and keep still. The rest are hunters, blindfolded while the props hide, then given a few minutes to find them. Props win if anybody is left when the clock runs out."
	s.help_cards = [
		["Props", "Your health is the size of what you became. Taunt for points, lock your rotation so you stop turning with the view, and tilt to sit the way the real ones do. A prop that keeps quiet too long taunts on its own."],
		["Hunters", "Shooting real furniture costs you health, so read the room for the thing that is slightly wrong before you fire. Near the end the last props give themselves away with a beacon."],
	]
	s.help_sections = [["Mouse", [["Left", "Fire (hunters); watch the next player while out"], ["Right", "Alternate fire; watch the one before while out"]], &"keys"]]
	return s
