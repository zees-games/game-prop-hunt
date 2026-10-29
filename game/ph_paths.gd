extends RefCounted

## Where this game's own files are, wherever this copy of it lives.
## A delivered pack mounts at `res://dot_cloud/<id>/<version>/`, so an absolute `res://` reference to its OWN files resolves against the HOST root; the root here is this script's directory minus `game/`.
## Paths held from here are a `static var`, not a `const`, which folds at parse time: `load(PhPaths.rebase("res://textures/deck.png"))`.

const _SELF := preload("ph_paths.gd")


## This game's content root: `res://` built in, the mount prefix delivered.
static func root() -> String:
	# Through [Resource], because a const-preloaded script is typed as its own class and
	# `resource_path` is not reachable on that — "Cannot find member resource_path in
	# base res://…". The cast costs nothing and is the only spelling that compiles.
	var here: Resource = _SELF
	return here.resource_path.get_base_dir().get_base_dir()


## Moves one `res://` path onto [method root]; anything else comes back untouched, so it is safe around a possibly absolute or `user://` value.
## Format specifiers survive, since only the prefix is replaced: `rebase("res://textures/%s.png") % name` works.
static func rebase(path: String) -> String:
	return rebase_onto(path, root())


## [method rebase], against a root given rather than discovered.
## So the mounted case can be TESTED from a build: built in, [method root] is `res://` and every property that matters only in a pack is a tautology.
## A suite asserting them passed (101, 0 failed) with the bug put back; a check that cannot fail needs a real mount prefix.
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path

		# Idempotent: the publisher rewrites `res://` strings in a `.tscn`, `.tres` and `.import` onto the mount prefix but not those in a `.gd`.
		# So a game holds both kinds, and rebasing an already rewritten path doubles the prefix into a load that fails with a path long enough to hide it.
		# Built in, [param here] is `res://`, so this returns its argument unchanged. Other delivery forms: ../dot-server-deploy/docs/delivery-constraint.md.
	if path.begins_with(here):
		return path

	return here.path_join(path.substr(6))
