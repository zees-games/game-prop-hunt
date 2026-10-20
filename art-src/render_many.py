"""Renders glb files (three-quarter and back three-quarter views) with Cycles on a GPU.

Run:  blender -b -P render_many.py -- <outdir> <file.glb> [...]
Writes <outdir>/<name>_a.png and <name>_b.png for each file. Used for the before/after contact sheets (stock beside rebuilt).
"""
import bpy, sys, os
from mathutils import Vector

out = sys.argv[sys.argv.index("--") + 1]
files = sys.argv[sys.argv.index("--") + 2:]

def world_box():
    pts = [o.matrix_world @ Vector(c) for o in bpy.data.objects if o.type == "MESH" for c in o.bound_box]
    return Vector(min(p[i] for p in pts) for i in range(3)), Vector(max(p[i] for p in pts) for i in range(3))

for f in files:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "CUDA"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    sc.cycles.device = "GPU"
    sc.cycles.samples = 64
    sc.render.resolution_x = sc.render.resolution_y = 480
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.62, 0.68, 0.76, 1)
    sc.world = w
    bpy.ops.object.light_add(type="SUN", rotation=(0.9, 0.2, 0.7))
    bpy.context.active_object.data.energy = 3.5
    bpy.ops.import_scene.gltf(filepath=f)
    lo, hi = world_box()
    bpy.ops.mesh.primitive_plane_add(size=3)
    fl = bpy.context.active_object
    fm = bpy.data.materials.new("floor")
    fm.use_nodes = True
    next(n for n in fm.node_tree.nodes if n.type == "BSDF_PRINCIPLED").inputs["Base Color"].default_value = (0.45, 0.45, 0.45, 1)
    fl.data.materials.append(fm)
    fl.location.z = lo.z - 0.0005
    ctr = (lo + hi) / 2
    dist = max(hi - lo) * 2.6
    name = os.path.splitext(os.path.basename(f))[0]
    for tag, d in (("a", (-0.8, -0.9, 0.55)), ("b", (0.9, 0.8, 0.6))):
        bpy.ops.object.camera_add(location=ctr + Vector(d).normalized() * dist)
        cam = bpy.context.active_object
        cam.rotation_euler = (ctr - cam.location).to_track_quat("-Z", "Y").to_euler()
        cam.data.angle = 0.6
        sc.camera = cam
        sc.render.filepath = os.path.join(out, "%s_%s.png" % (name, tag))
        bpy.ops.render.render(write_still=True)
