extends GSGameWorkbenchSuite

## mg-prop-hunt: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const PhConfig := preload("../game/ph_config.gd")


func _make_config() -> GSConfig:
	return PhConfig.new()


func _make_binder(config: GSConfig) -> GSGameConfigBinder:
	return PhConfig.make_binder(config)
