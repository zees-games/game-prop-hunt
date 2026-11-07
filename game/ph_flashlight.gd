extends RefCounted

## The flashlight's config and the server's start rule (the beam, the click and the replication helpers are dot-flashlight's).

const PhMapDoc := preload("ph_map_doc.gd")

const GAME_ID := "mg-prop-hunt"


## A config with this game's defaults: L (F is the hunter's quick melee), off on a lit map.
static func make_config() -> DotFlashlightConfig:
	var cfg := DotFlashlightConfig.new()
	cfg.key = "L"
	return cfg


## The binder: `ph_flashlight_<field>` cvars, `cfg/game/mg-prop-hunt/flashlight/game.yml`, a workbench set.
static func make_binder(cfg: DotFlashlightConfig) -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(cfg, GAME_ID, "ph_flashlight")
	b.profile_kind = "flashlight"
	return b


## Whether a player starts the map with the light on: its ambient energy against the config's dark floor.
static func starts_on(cfg: DotFlashlightConfig, map_id: String, doc: Dictionary) -> bool:
	var env: Dictionary = doc.get("environment", {})
	var ambient := float(env.get("ambient_energy", PhMapDoc.DEFAULT_ENV["ambient_energy"]))
	return DotFlashlightRules.start_on(cfg, map_id, ambient)
