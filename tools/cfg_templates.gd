extends SceneTree

## Rewrites cfg/game/mg-prop-hunt/config_*/game.yml from PhConfig's fields: godot --headless --path . --script tools/cfg_templates.gd

const PhConfig := preload("../game/ph_config.gd")


func _init() -> void:
	var binder := PhConfig.make_binder(PhConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
