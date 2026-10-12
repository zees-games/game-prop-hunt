# Drawing a map

How a map document becomes something drawn and lit. The maps themselves, and the bugs rendering found in them, are in mg-prop-hunt-maps' CLAUDE.md.

A map is hundreds of boxes and props. Boxes are batched by material, tint and 12 m chunk into one mesh each, because the Compatibility renderer lights a mesh with at most eight omni lights and a school as one mesh would be lit by eight of its fifty-two. Props are one `MultiMeshInstance3D` per model part. Generated textures are 128 px images made in code, laid in world space (as is the grid) so boxes of a material meet without a seam.

**Colour and light: rooms are pastel, furniture is Kenney's.** Every building surface (floor, wall, ceiling, roof, ground) is Kenney's prototype grid, or his tiles on a floor, under a pastel per surface (`PhMaterials.PASTELS`), the map's tint paled halfway to white on top; glass, boards, lockers, lines, metal and lamps keep their generated look, and furniture keeps its own colours. The light is a dot-lighting document from the map's `environment` (`PhMap.light_document`: its sun angle and colour, sky, horizon as fog from 120 m) with a near-neutral fill at the map's `ambient_energy` and glow only above white, turned down under Compatibility (`PhMap.light_profile`); a cool fill or arena's flat 1.0 fill turned rooms into a lavender haze. Check both renderers (`GODOT=<wrapper adding --rendering-method forward_plus> tools/shot.sh`).

**Kenney's Nature Kit is teal and coral by design**, and beside realistic rooms it read as a cartoon (the first school render had cyan trees with pink trunks). `props/kits.json` gives a kit a `recolour` table, material name to colour, which `PhProps` applies to a copy of each mesh as it loads. Furniture keeps its own colours except the plant.

## Cameras

A prop starts in third person and a hunter in first, under the server's `mp_forceview` (dot-player-controller's `DotPlayerViewRules`, bound REPLICATED by the module and followed through the link; `_follow_side` and F5 both ask it). The third-person camera is a dot-core `DotCameraBoom` swept from the eye or the prop's middle with `CHASE_UP` as `lift`, as far back as the prop is big, stopping against the building and the furniture; a `DotCameraFade` on the camera is handed the other players and hides one at the lens. dot-spectate is handed the level for its chase and death cameras. No `mp_solidplayers` here: a disguised player is the shape of their prop, and the rule's standing hull would be the wrong one. `tools/camera_check.sh [--render]` flies both cameras round the house (armed), checks the rule, and draws both views and the walk-in before and after.

