"""Rebuilds ten of the most-used props under assets/props/ for mg-prop-hunt, as this game's own.

Run:  blender -b -P art-src/build_props.py -- [name ...] [--out DIR]
Bases: art-src/base/<kit>/<name>.glb, Kenney's Furniture, Survival and Food Kits (CC0, licences next to the models in
assets/props/<kit>/). The kits are in play as what players disguise as, so the order here is the order of use in the maps
(chair 124 placements, bottle 117, books 103, carton 93, table lamp 77, bucket 63, crate 59, barrel 59, side table 52, can 51).
Changes, for every model: every sharp edge is bevelled and the kit's palette is replaced by this game's own (stained walnut,
oxblood and navy cloth, brass, gunmetal, galvanised steel, kraft board). The Survival and Food kits are painted by one
texture atlas; here each face is given a flat material of its own from the atlas colour under it (colormap_faces) and the
atlas is no longer referenced. Then each gets parts of its own: a velvet seat pad with brass tacks on the chair, books with
recessed pages and gilt plates and bands, a taped and labelled carton, a bulb and pull chain in the lamp, a leather inlay
and brass feet on the side table, a stencilled plate, brass bungs and a hazard band on the drum, a ring-pull on the can,
water, a rolled rim and a rib on the bucket, a wax seal, brass foil and a label on the bottle, and steel corners on the crate.
Node names, the node tree, each model's origin and its bounding box are kept: after the parts are added the whole model is
refitted to the base's box (a few percent at most), because props/pieces.json (the collision, and so the hull a disguised
player gets) and props/catalogue.json (the size) are measured from the box. The material called "plant" keeps its name
(books): the loader's recolour table finds it by that name.
Blender axes: the importer turns glTF (x, y, z) into (x, -z, y), so a model's front (glTF +Z) is Blender -Y.
"""
import bpy, bmesh, sys, os, math, random
import numpy as np
from mathutils import Vector, Matrix

here = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
outdir = os.path.join(here, "..", "assets", "props")
if "--out" in argv:
    i = argv.index("--out")
    outdir = argv[i + 1]
    del argv[i:i + 2]
names = argv

PAL = {}

def mat(name, rgb, metal=0.0, rough=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*rgb, 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    return m

def palette():
    PAL.clear()
    PAL["walnut"] = mat("walnut", (0.12, 0.055, 0.03), 0.0, 0.5)
    PAL["walnutDark"] = mat("walnutDark", (0.06, 0.028, 0.016), 0.0, 0.55)
    PAL["velvet"] = mat("velvet", (0.2, 0.018, 0.035), 0.0, 0.85)
    PAL["brass"] = mat("brass", (0.55, 0.34, 0.07), 0.6, 0.4)
    PAL["steel"] = mat("steel", (0.32, 0.34, 0.37), 0.5, 0.4)
    PAL["gunmetal"] = mat("gunmetal", (0.1, 0.11, 0.125), 0.5, 0.45)
    PAL["gunmetalDark"] = mat("gunmetalDark", (0.04, 0.045, 0.05), 0.4, 0.5)
    PAL["leather"] = mat("leather", (0.015, 0.1, 0.1), 0.0, 0.55)
    PAL["kraft"] = mat("kraft", (0.4, 0.24, 0.1), 0.0, 0.8)
    PAL["kraftDark"] = mat("kraftDark", (0.3, 0.17, 0.07), 0.0, 0.8)
    PAL["tape"] = mat("tape", (0.62, 0.45, 0.22), 0.0, 0.35)
    PAL["paper"] = mat("paper", (0.8, 0.78, 0.7), 0.0, 0.9)
    PAL["red"] = mat("red", (0.5, 0.03, 0.03), 0.0, 0.7)
    PAL["slate"] = mat("slate", (0.035, 0.04, 0.045), 0.1, 0.3)
    PAL["terracotta"] = mat("terracotta", (0.42, 0.14, 0.07), 0.0, 0.8)
    PAL["soil"] = mat("soil", (0.02, 0.012, 0.008), 0.0, 1.0)
    PAL["plant"] = mat("plant", (0.07, 0.3, 0.09), 0.0, 0.6)
    PAL["cloth"] = mat("cloth", (0.015, 0.03, 0.12), 0.0, 0.85)
    PAL["ochre"] = mat("ochre", (0.5, 0.31, 0.05), 0.0, 0.8)
    PAL["linen"] = mat("linen", (0.62, 0.5, 0.3), 0.0, 0.9)
    PAL["glass"] = mat("glass", (0.28, 0.1, 0.01), 0.0, 0.12)
    PAL["cork"] = mat("cork", (0.4, 0.25, 0.12), 0.0, 0.95)
    PAL["wax"] = mat("wax", (0.38, 0.02, 0.02), 0.0, 0.35)
    PAL["water"] = mat("water", (0.03, 0.14, 0.2), 0.0, 0.05)
    PAL["galv"] = mat("galv", (0.42, 0.45, 0.48), 0.8, 0.45)
    PAL["alu"] = mat("alu", (0.7, 0.72, 0.75), 0.9, 0.3)
    PAL["enamel"] = mat("enamel", (0.4, 0.04, 0.03), 0.0, 0.25)
    PAL["drum"] = mat("drum", (0.04, 0.17, 0.12), 0.2, 0.45)
    PAL["can"] = mat("can", (0.02, 0.2, 0.42), 0.3, 0.3)
    PAL["canStripe"] = mat("canStripe", (0.75, 0.7, 0.55), 0.0, 0.4)
    PAL["crate"] = mat("crate", (0.17, 0.09, 0.04), 0.0, 0.8)
    PAL["crateDark"] = mat("crateDark", (0.09, 0.045, 0.02), 0.0, 0.85)
    PAL["hazard"] = mat("hazard", (0.75, 0.55, 0.02), 0.0, 0.5)
    PAL["blotter"] = mat("blotter", (0.02, 0.17, 0.07), 0.0, 0.7)
    PAL["porcelain"] = mat("porcelain", (0.62, 0.6, 0.54), 0.0, 0.18)
    PAL["shade"] = mat("shade", (0.55, 0.38, 0.17), 0.0, 0.8)
    PAL["screen"] = mat("screen", (0.008, 0.01, 0.014), 0.2, 0.08)
    PAL["glow"] = mat("glow", (0.05, 0.5, 0.14), 0.0, 0.4)
    PAL["oilglass"] = mat("oilglass", (0.07, 0.17, 0.015), 0.0, 0.1)
    PAL["olive"] = mat("olive", (0.1, 0.16, 0.03), 0.0, 0.7)
    PAL["enamelBlue"] = mat("enamelBlue", (0.02, 0.07, 0.2), 0.0, 0.25)
    PAL["terracottaDark"] = mat("terracottaDark", (0.3, 0.09, 0.045), 0.0, 0.85)
    PAL["coffee"] = mat("coffee", (0.05, 0.022, 0.01), 0.0, 0.1)

# Kit material name -> ours.
SWAP = {"wood": "walnut", "woodDark": "walnutDark", "metal": "brass", "metalMedium": "gunmetal",
        "metalDark": "gunmetalDark", "carpet": "velvet", "plant": "plant", "_defaultMat": "walnut",
        "metalLight": "steel", "carpetDarker": "red", "carpetWhite": "cloth", "lamp": "linen"}

def meshes():
    return [o for o in bpy.data.objects if o.type == "MESH"]

def world_box(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    return Vector(min(p[i] for p in pts) for i in range(3)), Vector(max(p[i] for p in pts) for i in range(3))

FRIDGE = {"metalLight": "porcelain", "metalMedium": "steel", "metal": "steel", "metalDark": "gunmetalDark", "glass": "gunmetalDark"}
OVERRIDES = {"kitchenFridgeLarge": FRIDGE, "kitchenFridgeSmall": FRIDGE, "toaster": {"metalMedium": "alu", "metal": "gunmetalDark"},
             "kitchenCabinet": {"metal": "steel"}, "speaker": {"metalMedium": "gunmetalDark"}, "lampSquareTable": {"metal": "brass"},
             "computerKeyboard": {"metalDark": "gunmetalDark", "metalMedium": "gunmetal"}, "loungeSofa": {"carpet": "cloth"},
"trashcan": {"metal": "galv", "metalMedium": "galv", "_defaultMat": "galv"}, "cardboardBoxClosed": {"wood": "kraft", "woodDark": "kraftDark"}, "lampRoundTable": {"metal": "brass"},
             "pot_small": {"wood": "terracotta", "woodBarkDark": "soil", "_defaultMat": "walnutDark"}}

def reskin(o, overrides=None):
    overrides = overrides or {}
    for i, s in enumerate(o.material_slots):
        k = s.material.name.split(".")[0]
        if k in PAL:
            continue  # already one of ours (set by the model's pre_ step)
        o.material_slots[i].material = PAL[overrides.get(k, SWAP.get(k, "walnut"))]

def bevel(o, width=0.004):
    sc = sum(o.matrix_world.to_scale()) / 3
    bm = bmesh.new()
    bm.from_mesh(o.data)
    edges = [e for e in bm.edges if len(e.link_faces) == 2 and e.calc_face_angle(0) > math.radians(35)]
    bmesh.ops.bevel(bm, geom=edges, offset=width / sc, segments=2, affect="EDGES")
    bm.to_mesh(o.data)
    bm.free()
    o.data.update()

def slot(o, key):
    m = PAL[key]
    for i, s in enumerate(o.material_slots):
        if s.material == m:
            return i
    o.data.materials.append(m)
    return len(o.material_slots) - 1

def add_box(host, lo, hi, key, rot=0.0):
    """A box from world-space corner lo to hi (rotated rot rad about Z through its centre), joined into host."""
    lo, hi = Vector(lo), Vector(hi)
    c = (lo + hi) / 2
    bpy.ops.mesh.primitive_cube_add(size=1, location=c, rotation=(0, 0, rot))
    p = bpy.context.active_object
    p.scale = (hi - lo)
    bpy.ops.object.transform_apply(scale=True)
    join(host, p, key)

def add_cyl(host, c, r, h, key, axis="Z", verts=16, r2=None, sy=1.0):
    rot = {"Z": (0, 0, 0), "X": (0, math.pi / 2, 0), "Y": (math.pi / 2, 0, 0)}[axis]
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r, radius2=r if r2 is None else r2, depth=h, location=c, rotation=rot)
    p = bpy.context.active_object
    if sy != 1.0:
        p.scale.y = sy
        bpy.ops.object.transform_apply(scale=True)
    join(host, p, key)

def add_sphere(host, c, r, key, sq=1.0):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=6, radius=r, location=c)
    p = bpy.context.active_object
    p.scale.z = sq
    bpy.ops.object.transform_apply(scale=True)
    join(host, p, key)

def add_torus(host, c, R, r, key, sy=1.0):
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, major_segments=20, minor_segments=6, location=c)
    p = bpy.context.active_object
    if sy != 1.0:
        p.scale.y = sy
        bpy.ops.object.transform_apply(scale=True)
    join(host, p, key)

def join(host, p, key):
    for f in p.data.polygons:
        f.use_smooth = False
    p.data.materials.clear()
    p.data.materials.append(PAL[key])
    # Match the host's slot for this material so joining does not add a duplicate.
    idx = slot(host, key)
    bpy.ops.object.select_all(action="DESELECT")
    p.select_set(True)
    host.select_set(True)
    bpy.context.view_layer.objects.active = host
    bpy.ops.object.join()
    # The joined faces carry the slot index of the parts' own single material (0); remap by material.
    remap_new_faces(host)

def remap_new_faces(host):
    # After a join Blender appends the part's material to the host's slots when it is not there yet and points the
    # part's faces at it, so nothing is needed except dropping duplicate slots, which export merges anyway.
    pass

def top_levels(o, min_area=0.002):
    """z levels (world) of upward faces of o with their areas: shelves and seats."""
    bm = bmesh.new()
    bm.from_mesh(o.data)
    out = {}
    for f in bm.faces:
        n = (o.matrix_world.to_3x3() @ f.normal).normalized()
        if n.z > 0.95:
            z = round((o.matrix_world @ f.calc_center_median()).z, 3)
            out[z] = out.get(z, 0) + f.calc_area()
    bm.free()
    return sorted((z, a) for z, a in out.items() if a > min_area)

def knob(host, c):
    add_sphere(host, c, 0.011, "brass", 0.8)


# ---- helpers for this game's models -----------------------------------------------------------------------

def radius_at(o, z0, z1, fn=max):
    """Largest (or fn of) radius about the model's vertical axis of the vertices between world heights z0 and z1; low-poly
    models may have none there, then it is the ring of vertices nearest the middle of the band."""
    lo, hi = world_box([o])
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
    pts = [o.matrix_world @ v.co for v in o.data.vertices]
    rs = [math.hypot(w.x - cx, w.y - cy) for w in pts if z0 <= w.z <= z1]
    if not rs:
        zc = (z0 + z1) / 2
        zn = min(pts, key=lambda w: abs(w.z - zc)).z
        rs = [math.hypot(w.x - cx, w.y - cy) for w in pts if abs(w.z - zn) < 0.0015]
    return fn(rs)

def up_faces(o, z0, z1, down=False):
    """World-space (centre, bbox lo, bbox hi) of every face looking up (or down) whose centre is between z0 and z1."""
    out = []
    for f in o.data.polygons:
        n = o.matrix_world.to_3x3() @ f.normal
        c = o.matrix_world @ f.center
        if (n.z < -0.95 if down else n.z > 0.95) and z0 <= c.z <= z1:
            pts = [o.matrix_world @ o.data.vertices[i].co for i in f.vertices]
            out.append((c, Vector(min(p[i] for p in pts) for i in range(3)), Vector(max(p[i] for p in pts) for i in range(3))))
    return out

def add_obox(host, c, e0, e1, e2, s0, s1, s2, key):
    """A box centred on c, with edge lengths s0, s1, s2 along the orthonormal axes e0, e1, e2."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=c)
    p = bpy.context.active_object
    p.matrix_world = Matrix.Translation(c) @ Matrix(((e0.x, e1.x, e2.x, 0), (e0.y, e1.y, e2.y, 0), (e0.z, e1.z, e2.z, 0), (0, 0, 0, 1))) @ Matrix.Diagonal((s0, s1, s2, 1))
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    join(host, p, key)

def colormap_faces(o, classify):
    """Replaces the kit's single texture-atlas material by this game's own: each face is given the material that
    classify(rgb, world z, polygon) names, after the atlas colour under the face's UV centre."""
    img = next(n.image for s in o.material_slots for n in s.material.node_tree.nodes if n.type == "TEX_IMAGE")
    W, H = img.size
    px = np.array(img.pixels[:]).reshape(H, W, 4)
    uv = o.data.uv_layers.active.data
    keys = []
    seen = {}
    for p in o.data.polygons:
        u = sum(uv[l].uv[0] for l in p.loop_indices) / p.loop_total
        v = sum(uv[l].uv[1] for l in p.loop_indices) / p.loop_total
        rgb = px[min(H - 1, max(0, int(v * H))), min(W - 1, max(0, int(u * W))), :3]
        keys.append(classify(rgb, (o.matrix_world @ p.center).z, p))
        seen.setdefault(tuple(int(v * 20) / 20 for v in rgb), []).append(round((o.matrix_world @ p.center).z, 2))
    used = sorted(set(keys))
    o.data.materials.clear()
    for k in used:
        o.data.materials.append(PAL[k])
    for p, k in zip(o.data.polygons, keys):
        p.material_index = used.index(k)
    print("atlas", o.name, {k: (len(v), min(v), max(v)) for k, v in seen.items()})
    print("faces", o.name, {k: keys.count(k) for k in used})

def reddish(rgb):
    return rgb[0] > rgb[2] + 0.2

# ---- survival and food kits: the texture atlas goes, flat materials of our own come ------------------------

def pre_barrel(by):
    o = by["barrel"]
    colormap_faces(o, lambda c, z, p: ("drum" if reddish(c) else ("hazard" if 0.1 < z < 0.25 else "galv")))

def do_barrel(by):
    o = by["barrel"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    # The drum is an octagon with flats to the front: Rn is the flat's distance (the corners are further out).
    Rn = radius_at(o, lo.z + 0.14, lo.z + 0.2, min)
    # Two bungs in the lid, and a stencilled plate on the front of the yellow band.
    for dx in (-0.055, 0.055):
        add_cyl(o, (c.x + dx, c.y + 0.04, hi.z - 0.012), 0.013, 0.012, "brass", verts=10)
    add_box(o, (c.x - 0.035, c.y - Rn - 0.003, lo.z + 0.15), (c.x + 0.035, c.y - Rn + 0.003, lo.z + 0.2), "paper")
    add_box(o, (c.x - 0.028, c.y - Rn - 0.0036, lo.z + 0.17), (c.x + 0.028, c.y - Rn + 0.004, lo.z + 0.18), "red")

def pre_sodacan(by):
    o = by["soda-can"]
    colormap_faces(o, lambda c, z, p: "can" if reddish(c) else "alu")

def do_sodacan(by):
    o = by["soda-can"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    Rn = radius_at(o, lo.z + 0.1, lo.z + 0.25, min)
    add_box(o, (c.x - 0.045, c.y - Rn - 0.003, lo.z + 0.1), (c.x + 0.045, c.y - Rn + 0.003, lo.z + 0.24), "canStripe")
    add_box(o, (c.x - 0.03, c.y - Rn - 0.0036, lo.z + 0.15), (c.x + 0.03, c.y - Rn + 0.004, lo.z + 0.2), "can")
    # The ring-pull sits in the recessed lid: a tab with its finger ring, and its rivet.
    add_box(o, (c.x - 0.02, c.y - 0.012, hi.z - 0.034), (c.x + 0.045, c.y + 0.012, hi.z - 0.03), "steel", rot=0.0)
    add_torus(o, (c.x - 0.03, c.y, hi.z - 0.03), 0.015, 0.0035, "steel")
    add_cyl(o, (c.x + 0.012, c.y, hi.z - 0.031), 0.006, 0.006, "brass", verts=8)

def pre_bucket(by):
    o = by["bucket"]
    colormap_faces(o, lambda c, z, p: "gunmetal" if reddish(c) else "galv")

def do_bucket(by):
    o = by["bucket"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    # The kit's bail arches above the body, so the body's own top is the highest vertex of the pail's (galvanised) faces.
    zt = max((o.matrix_world @ o.data.vertices[i].co).z for p in o.data.polygons if o.material_slots[p.material_index].material.name == "galv" for i in p.vertices)
    hb = zt - lo.z
    rt = radius_at(o, zt - 0.012, zt, min)
    inner = radius_at(o, lo.z + hb * 0.78, lo.z + hb * 0.82, min)
    add_torus(o, (c.x, c.y, zt - 0.004), rt - 0.0035, 0.0045, "steel")
    add_torus(o, (c.x, c.y, lo.z + hb * 0.45), radius_at(o, lo.z + hb * 0.43, lo.z + hb * 0.47, min) - 0.002, 0.003, "gunmetal")
    add_cyl(o, (c.x, c.y, lo.z + hb * 0.8), inner * 0.97, 0.004, "water", verts=14)
    add_cyl(o, (c.x, c.y, lo.z + 0.004), radius_at(o, lo.z, lo.z + 0.012, min), 0.008, "gunmetal", verts=14)

def pre_bottle(by):
    o = by["bottle"]
    colormap_faces(o, lambda c, z, p: "paper" if min(c) > 0.7 else ("glass" if c[1] > c[0] + 0.1 else "wax"))

def do_bottle(by):
    o = by["bottle"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    rn = radius_at(o, hi.z - 0.04, hi.z - 0.03, min)
    add_torus(o, (c.x, c.y, hi.z - 0.034), rn - 0.0004, 0.0022, "brass")
    add_torus(o, (c.x, c.y, lo.z + 0.004), radius_at(o, lo.z, lo.z + 0.01, min) - 0.0012, 0.0025, "gunmetal")

def pre_box(by):
    o = by["box"]
    colormap_faces(o, lambda c, z, p: "crateDark" if c[0] > 0.86 else "crate")

def do_box(by):
    o = by["box"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    s = 0.034
    for sx in (lo.x, hi.x - s):
        for sy in (lo.y, hi.y - s):
            for z in (lo.z, hi.z - s):
                add_box(o, (sx - 0.001 * (sx == lo.x), sy - 0.001 * (sy == lo.y), z - 0.001 * (z == lo.z)),
                        (sx + s + 0.001 * (sx != lo.x), sy + s + 0.001 * (sy != lo.y), z + s + 0.001 * (z != lo.z)), "gunmetal")
    add_box(o, (c.x - 0.05, lo.y - 0.002, c.z - 0.03), (c.x + 0.05, lo.y + 0.001, c.z + 0.04), "paper")
    add_box(o, (c.x - 0.04, lo.y - 0.003, c.z + 0.01), (c.x + 0.04, lo.y + 0.001, c.z + 0.025), "hazard")
    add_box(o, (c.x - 0.04, lo.y - 0.003, c.z - 0.02), (c.x + 0.01, lo.y + 0.001, c.z - 0.012), "gunmetalDark")

# ---- furniture ----------------------------------------------------------------------------------------------

def do_chair(by):
    o = by["chair(Clone)"]
    lo, hi = world_box([o])
    seat = max(up_faces(o, 0.12, 0.3), key=lambda f: (f[2].x - f[1].x) * (f[2].y - f[1].y))
    z = seat[0].z
    same = [f for f in up_faces(o, z - 0.004, z + 0.004)]
    slo = Vector(min(f[1][i] for f in same) for i in range(3))
    shi = Vector(max(f[2][i] for f in same) for i in range(3))
    add_box(o, (slo.x + 0.012, slo.y + 0.012, z), (shi.x - 0.012, shi.y - 0.012, z + 0.016), "velvet")
    for sx in (slo.x + 0.03, shi.x - 0.03):
        for sy in (slo.y + 0.02, shi.y - 0.02):
            add_sphere(o, (sx, sy, z + 0.016), 0.0045, "brass", 0.6)
    rail = up_faces(o, hi.z - 0.004, hi.z + 0.001)
    rlo = Vector(min(f[1][i] for f in rail) for i in range(3))
    rhi = Vector(max(f[2][i] for f in rail) for i in range(3))
    add_box(o, (rlo.x, rlo.y, hi.z - 0.003), (rhi.x, rhi.y, hi.z), "brass")

def pre_books(by):
    """The kit's books are open shells (only the sides that show), a leaning one and a row, as one mesh with four materials.
    The shell is cleared and do_books builds closed books in the same places, spines to the front (-Y), the leaning one at
    the kit's 14 degrees, inside the kit's box."""
    o = by["books(Clone)"]
    bm = bmesh.new()
    bm.to_mesh(o.data)
    bm.free()
    layout = []
    w = 0.094
    s, c = math.sin(math.radians(14)), math.cos(math.radians(14))
    layout.append((Vector((0.034, w / 2, 0.049)), Vector((s, 0, c)), Vector((0, -1, 0)), Vector((c, 0, -s)), (0.098, w, 0.022), "carpetDarker"))
    x = 0.05
    for t, h, k in ((0.018, 0.092, "carpetWhite"), (0.022, 0.1, "plant"), (0.016, 0.086, "metal"), (0.024, 0.104, "leather"), (0.02, 0.095, "carpetDarker")):
        layout.append((Vector((x + t / 2, w / 2, h / 2)), Vector((0, 0, 1)), Vector((0, -1, 0)), Vector((1, 0, 0)), (h, w, t), k))
        x += t
    by["_books"] = layout

BOOK_COVER = {"metalLight": "steel", "carpetDarker": "red", "carpetWhite": "cloth", "plant": "plant", "metal": "ochre", "leather": "leather"}

def do_books(by):
    o = by["books(Clone)"]
    for ctr, e0, e1, e2, (h, w, t), mname in by["_books"]:
        cover = BOOK_COVER.get(mname, "red")
        b = 0.0028
        # Spine board, two cover boards (a little proud of the pages at head, tail and fore-edge) and the page block,
        # which is set back from the three open edges.
        add_obox(o, ctr + e1 * (w / 2 - b / 2), e0, e1, e2, h, b, t, cover)
        for sgn in (1, -1):
            add_obox(o, ctr + e2 * sgn * (t / 2 - b / 2), e0, e1, e2, h, w, b, cover)
        add_obox(o, ctr - e1 * ((b - 0.0025) / 2), e0, e1, e2, h - 2 * 0.0025, w - b - 0.0025, t - 2 * b + 0.001, "paper")
    bevel(o, 0.0012)
    for ctr, e0, e1, e2, (h, w, t), mname in by["_books"]:
        # A title plate and a rule on both covers, and the spine's gilt bands.
        for sgn in (1, -1):
            add_obox(o, ctr + e2 * sgn * (t / 2) + e0 * h * 0.16, e0, e1, e2, h * 0.26, w * 0.5, 0.0016, "brass")
            add_obox(o, ctr + e2 * sgn * (t / 2) - e0 * h * 0.24, e0, e1, e2, h * 0.035, w * 0.5, 0.0016, "brass")
        for k in (0.3, 0.0, -0.3):
            add_obox(o, ctr + e1 * (w / 2) + e0 * h * k, e0, e1, e2, h * 0.04, 0.0016, t * 0.9, "brass")

def do_cardboardBoxClosed(by):
    o = by["cardboardBoxClosed(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.016, lo.y - 0.001, hi.z - 0.002), (c.x + 0.016, hi.y + 0.001, hi.z + 0.002), "tape")
    add_box(o, (c.x - 0.016, lo.y - 0.001, lo.z + 0.02), (c.x + 0.016, lo.y + 0.001, hi.z), "tape")
    add_box(o, (lo.x + 0.03, lo.y - 0.002, hi.z * 0.35), (lo.x + 0.085, lo.y, hi.z * 0.62), "paper")
    add_box(o, (hi.x - 0.07, lo.y - 0.002, hi.z * 0.25), (hi.x - 0.03, lo.y, hi.z * 0.32), "red")

def do_lampRoundTable(by):
    o = by["lampRoundTable(Clone)"]
    lo, hi = world_box([o])
    shade = [f for f in o.data.polygons if o.material_slots[f.material_index].material.name == "linen"]
    zs = [(o.matrix_world @ o.data.vertices[i].co).z for f in shade for i in f.vertices]
    zmin = min(zs)
    xs = [(o.matrix_world @ o.data.vertices[i].co) for f in shade for i in f.vertices]
    c = Vector((sum(p.x for p in xs) / len(xs), sum(p.y for p in xs) / len(xs), 0))
    r = max(math.hypot(p.x - c.x, p.y - c.y) for p in xs)
    add_sphere(o, (c.x, c.y, hi.z - 0.05), 0.026, "paper", 1.0)
    add_cyl(o, (c.x, c.y, zmin + 0.02), 0.006, 0.04, "brass", r2=0.0, verts=8)
    ang = 0.6
    px, py = c.x + math.cos(ang) * r * 0.78, c.y + math.sin(ang) * r * 0.78
    add_cyl(o, (px, py, zmin - 0.012), 0.0014, 0.06, "brass", verts=5)
    add_sphere(o, (px, py, zmin - 0.045), 0.006, "brass", 1.0)
    add_cyl(o, (c.x, c.y, lo.z + 0.006), 0.05, 0.004, "gunmetalDark", verts=14)

def do_sideTable(by):
    o = by["sideTable(Clone)"]
    lo, hi = world_box([o])
    top = [f for f in up_faces(o, hi.z - 0.004, hi.z + 0.001)]
    tlo = Vector(min(f[1][i] for f in top) for i in range(3))
    thi = Vector(max(f[2][i] for f in top) for i in range(3))
    add_box(o, (tlo.x + 0.03, tlo.y + 0.025, hi.z - 0.002), (thi.x - 0.03, thi.y - 0.025, hi.z + 0.002), "leather")
    add_box(o, (tlo.x + 0.034, tlo.y + 0.029, hi.z + 0.002), (thi.x - 0.034, thi.y - 0.029, hi.z + 0.0032), "slate")
    feet = {}
    for f in up_faces(o, lo.z - 0.01, lo.z + 0.012, down=True):
        feet.setdefault((round(f[0].x, 2), round(f[0].y, 2)), []).append(f)
    for fs in feet.values():
        flo = Vector(min(f[1][i] for f in fs) for i in range(3))
        fhi = Vector(max(f[2][i] for f in fs) for i in range(3))
        add_box(o, (flo.x - 0.002, flo.y - 0.002, lo.z), (fhi.x + 0.002, fhi.y + 0.002, lo.z + 0.012), "brass")

# ---- pass 2: the next twelve by use in the maps ---------------------------------------------------------------

def pre_bottleoil(by):
    colormap_faces(by["bottle-oil"], lambda c, z, p: "paper" if c[0] > 0.9 else ("brass" if c[0] > 0.7 else "oilglass"))

def do_bottleoil(by):
    o = by["bottle-oil"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    Rn = radius_at(o, lo.z + 0.24, lo.z + 0.28, min)
    add_box(o, (c.x - 0.03, c.y - Rn - 0.002, lo.z + 0.23), (c.x + 0.03, c.y - Rn + 0.002, lo.z + 0.285), "olive")
    add_box(o, (c.x - 0.02, c.y - Rn - 0.0026, lo.z + 0.25), (c.x + 0.02, c.y - Rn + 0.003, lo.z + 0.262), "ochre")
    add_torus(o, (c.x, c.y, lo.z + 0.52), radius_at(o, lo.z + 0.5, lo.z + 0.54, min) - 0.001, 0.004, "gunmetal")
    add_torus(o, (c.x, c.y, lo.z + 0.006), radius_at(o, lo.z, lo.z + 0.01, min) - 0.0015, 0.004, "gunmetal")

def pre_mug(by):
    colormap_faces(by["mug"], lambda c, z, p: "porcelain" if c[2] > c[0] + 0.1 else "enamelBlue")

def do_mug(by):
    o = by["mug"]
    lo, hi = world_box([o])
    cx, cy = 0.0, 0.0
    add_cyl(o, (cx, cy, hi.z - 0.075), 0.115, 0.004, "coffee", verts=16)
    add_torus(o, (cx, cy, hi.z - 0.004), 0.133, 0.006, "porcelain")

def pre_carton(by):
    colormap_faces(by["carton"], lambda c, z, p: "paper" if c[0] > 0.78 else "cloth")

def do_carton(by):
    o = by["carton"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.075, lo.y - 0.002, lo.z + 0.2), (c.x + 0.075, lo.y + 0.003, lo.z + 0.31), "red")
    add_box(o, (c.x - 0.05, lo.y - 0.0028, lo.z + 0.23), (c.x + 0.05, lo.y + 0.003, lo.z + 0.24), "paper")
    add_box(o, (c.x - 0.05, lo.y - 0.0028, lo.z + 0.265), (c.x + 0.02, lo.y + 0.003, lo.z + 0.275), "paper")
    for x in (lo.x, hi.x):
        add_box(o, (x - 0.002, lo.y + 0.01, lo.z + 0.14), (x + 0.002, hi.y - 0.01, lo.z + 0.146), "gunmetal")

def pre_cartonsmall(by):
    colormap_faces(by["carton-small"], lambda c, z, p: "paper" if c[1] > 0.7 else "wax")

def do_cartonsmall(by):
    o = by["carton-small"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.07, lo.y - 0.002, lo.z + 0.14), (c.x + 0.07, lo.y + 0.003, lo.z + 0.24), "olive")
    add_box(o, (c.x - 0.045, lo.y - 0.0028, lo.z + 0.18), (c.x + 0.045, lo.y + 0.003, lo.z + 0.19), "paper")
    add_box(o, (c.x - 0.045, lo.y - 0.0028, lo.z + 0.2), (c.x + 0.01, lo.y + 0.003, lo.z + 0.208), "paper")
    for x in (lo.x, hi.x):
        add_box(o, (x - 0.002, lo.y + 0.01, lo.z + 0.1), (x + 0.002, hi.y - 0.01, lo.z + 0.106), "gunmetal")

def pre_plate(by):
    colormap_faces(by["plate"], lambda c, z, p: "porcelain")

def do_plate(by):
    o = by["plate"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_torus(o, (c.x, c.y, hi.z - 0.009), 0.38, 0.007, "enamelBlue")
    add_torus(o, (c.x, c.y, hi.z - 0.009), 0.35, 0.003, "brass")

# ---- furniture, the same parts as the other kit users' versions of these models ---------------------------------

def knob_in(host, c):
    add_sphere(host, (c.x, c.y + 0.009, c.z), 0.011, "brass", 0.8)

def do_pottedPlant(by):
    pot, plant = by["pottedPlant(Clone)"], by["plant"]
    lo, hi = world_box([pot])
    c = (lo + hi) / 2
    top = hi.z
    add_cyl(pot, (c.x, c.y, top - 0.012), 0.092, 0.012, "soil")
    add_torus(pot, (c.x, c.y, top - 0.004), 0.092, 0.006, "terracotta")
    add_cyl(pot, (c.x, c.y, lo.z + 0.018), 0.075, 0.012, "walnutDark")
    for k in range(4):
        a = k * math.pi / 2 + 0.5
        add_cyl(plant, (c.x + math.cos(a) * 0.05, c.y + math.sin(a) * 0.05, top + 0.1), 0.012, 0.2, "plant", r2=0.0, verts=6)

def do_trashcan(by):
    o = by["trashcan(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    r = min(hi.x - lo.x, hi.y - lo.y) / 2 - 0.006
    add_torus(o, (c.x, c.y, hi.z - 0.006), r, 0.007, "brass")
    for f in (0.3, 0.62):
        add_torus(o, (c.x, c.y, lo.z + (hi.z - lo.z) * f), r * 0.96, 0.005, "gunmetal")
    add_cyl(o, (c.x, c.y, lo.z + 0.006), r * 0.9, 0.012, "gunmetal")

def do_chairDesk(by):
    chair = by["chair"]
    lo, hi = world_box([chair])
    lv = [z for z, a in top_levels(chair) if 0.15 < z < hi.z - 0.05]
    seat = min(lv) if lv else lo.z + 0.2
    for x in (lo.x + 0.012, hi.x - 0.012):
        add_box(chair, (x - 0.008, lo.y + 0.045, seat + 0.012), (x + 0.008, hi.y - 0.045, seat + 0.026), "gunmetal")
        add_box(chair, (x - 0.006, hi.y - 0.075, seat), (x + 0.006, hi.y - 0.063, seat + 0.026), "gunmetal")
        add_box(chair, (x - 0.006, lo.y + 0.06, seat), (x + 0.006, lo.y + 0.072, seat + 0.026), "gunmetal")
    c = (lo + hi) / 2
    add_sphere(chair, (c.x, hi.y - 0.004, hi.z - 0.05), 0.009, "brass", 0.5)

def do_table(by):
    o = by["table(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x, lo.y, hi.z - 0.012), (hi.x, hi.y, hi.z), "walnutDark")
    add_box(o, (lo.x + 0.02, lo.y + 0.02, hi.z - 0.003), (hi.x - 0.02, hi.y - 0.02, hi.z + 0.0), "walnut")
    for x in (lo.x + 0.02, hi.x - 0.02):
        for y in (lo.y + 0.02, hi.y - 0.02):
            add_cyl(o, (x, y, lo.z + 0.004), 0.012, 0.008, "brass", verts=8)

def do_sideTableDrawers(by):
    o = by["sideTableDrawers(Clone)"]
    lo, hi = world_box([o])
    for k in ("drawerLeft", "drawerRight"):
        d = by[k]
        dlo, dhi = world_box([d])
        c = (dlo + dhi) / 2
        knob_in(d, Vector((c.x, dlo.y, c.z)))
        add_box(d, (dlo.x + 0.012, dlo.y - 0.001, dhi.z - 0.03), (dhi.x - 0.012, dlo.y + 0.001, dhi.z - 0.026), "brass")
    add_box(o, (lo.x + 0.01, lo.y + 0.01, lo.z), (hi.x - 0.01, hi.y - 0.01, lo.z + 0.02), "walnutDark")
    add_box(o, (lo.x + 0.03, lo.y + 0.06, hi.z - 0.002), (lo.x + 0.15, lo.y + 0.16, hi.z + 0.012), "red", rot=0.15)
    add_cyl(o, (hi.x - 0.1, lo.y + 0.12, hi.z + 0.002), 0.045, 0.006, "brass")

def do_bench(by):
    o = by["bench(Clone)"]
    lo, hi = world_box([o])
    lv = [(a, z) for z, a in top_levels(o) if z > hi.z * 0.5]
    seat = max(lv)[1] if lv else hi.z
    add_box(o, (lo.x + 0.02, lo.y + 0.02, seat - 0.002), (hi.x - 0.02, hi.y - 0.02, seat + 0.012), "velvet")
    for x in (lo.x + 0.012, hi.x - 0.012):
        for y in (lo.y + 0.012, hi.y - 0.012):
            add_cyl(o, (x, y, lo.z + 0.004), 0.013, 0.008, "brass", verts=8)
    add_box(o, (lo.x + 0.02, lo.y + 0.02, seat + 0.012), (hi.x - 0.02, lo.y + 0.024, seat + 0.014), "brass")

def do_computerScreen(by):
    o = by["computerScreen(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + hi.x) / 2
    z0, z1 = lo.z + 0.085, hi.z - 0.02
    add_box(o, (lo.x + 0.02, lo.y - 0.0008, z0), (hi.x - 0.02, lo.y + 0.003, z1), "screen")
    for i in range(5):
        w = (hi.x - lo.x - 0.1) * (0.9 if i % 2 == 0 else 0.55)
        z = z1 - 0.03 - i * 0.03
        add_box(o, (lo.x + 0.05, lo.y - 0.0016, z), (lo.x + 0.05 + w, lo.y - 0.0006, z + 0.008), "glow")
    add_box(o, (c + 0.05, lo.y - 0.0008, lo.z + 0.062), (c + 0.062, lo.y + 0.002, lo.z + 0.07), "red")

# ---- pass 6: the next most-placed furniture-kit models ---------------------------------------------------------

def books_on(o, z, x0, x1, y0, y1, seed=1, gap=0.1):
    """A row of books standing on shelf height z between the x range, in this game's cloth colours."""
    rnd = random.Random(seed)
    x = x0 + 0.01
    cols = ["velvet", "cloth", "olive", "ochre", "red", "leather"]
    while x < x1 - 0.03:
        w = rnd.uniform(0.014, 0.026)
        h = rnd.uniform(0.6, 0.9) * gap
        add_box(o, (x, y0 + 0.015, z), (x + w, y1 - 0.015, z + h), rnd.choice(cols))
        x += w + 0.003

def front_panel(d):
    dlo, dhi = world_box([d])
    add_box(d, (dlo.x + 0.012, dlo.y - 0.0015, dlo.z + 0.012), (dhi.x - 0.012, dlo.y, dhi.z - 0.012), "walnutDark")
    return dlo, dhi

def add_torus_y(host, c, R, r, key):
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, major_segments=20, minor_segments=6, location=c, rotation=(math.pi / 2, 0, 0))
    join(host, bpy.context.active_object, key)

def bedside(by, name, parts):
    o = by[name]
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.02, lo.y + 0.02, hi.z - 0.002), (hi.x - 0.02, hi.y - 0.02, hi.z + 0.006), "leather")
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.014), "walnutDark")
    for k in parts:
        dlo, dhi = front_panel(by[k])
        c = (dlo + dhi) / 2
        add_sphere(by[k], (c.x, dlo.y, c.z), 0.009, "brass", 0.6)

def do_cabinetBed(by):
    bedside(by, "cabinetBed(Clone)", ["door"])

def do_cabinetBedDrawer(by):
    bedside(by, "cabinetBedDrawer(Clone)", ["door", "drawer"])

def do_computerKeyboard(by):
    o = by["computerKeyboard(Clone)"]
    lo, hi = world_box([o])
    z = hi.z
    rh = (hi.y - lo.y - 0.024) / 5
    x0, x1 = lo.x + 0.012, hi.x - 0.012
    for r in range(5):
        y = lo.y + 0.012 + r * rh
        if r == 4:
            add_box(o, (lo.x + 0.07, y, z - 0.008), (hi.x - 0.07, y + rh - 0.004, z + 0.0005), "steel")
            continue
        w = (x1 - x0) / 14
        for i in range(14):
            add_box(o, (x0 + i * w + 0.0015, y, z - 0.008), (x0 + (i + 1) * w - 0.0015, y + rh - 0.004, z + 0.0005), "steel" if (i + r) % 5 else "gunmetalDark")
    add_box(o, (hi.x - 0.03, lo.y + 0.003, z - 0.002), (hi.x - 0.024, lo.y + 0.006, z + 0.001), "glow")

def do_desk(by):
    o = by["desk(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.03, lo.y + 0.03, hi.z - 0.002), (hi.x - 0.03, hi.y - 0.03, hi.z + 0.006), "blotter")
    add_box(o, (lo.x + 0.05, lo.y + 0.04, hi.z + 0.006), (lo.x + 0.1, lo.y + 0.12, hi.z + 0.009), "paper", rot=0.2)
    for x in (lo.x + 0.015, hi.x - 0.015):
        for y in (lo.y + 0.015, hi.y - 0.015):
            add_cyl(o, (x, y, lo.z + 0.004), 0.012, 0.008, "brass", verts=8)
    dlo, dhi = front_panel(by["drawer"])
    c = (dlo + dhi) / 2
    add_box(by["drawer"], (c.x - 0.03, dlo.y - 0.008, c.z - 0.004), (c.x + 0.03, dlo.y, c.z + 0.004), "brass")

def do_chairRounded(by):
    o = by["chairRounded(Clone)"]
    lo, hi = world_box([o])
    seat = max(up_faces(o, 0.12, 0.3), key=lambda f: (f[2].x - f[1].x) * (f[2].y - f[1].y))
    z = seat[0].z
    same = up_faces(o, z - 0.004, z + 0.004)
    slo = Vector(min(f[1][i] for f in same) for i in range(3))
    shi = Vector(max(f[2][i] for f in same) for i in range(3))
    add_box(o, (slo.x + 0.01, slo.y + 0.01, z), (shi.x - 0.01, shi.y - 0.01, z + 0.014), "cloth")
    for sx in (slo.x + 0.025, shi.x - 0.025):
        for sy in (slo.y + 0.02, shi.y - 0.02):
            add_sphere(o, (sx, sy, z + 0.014), 0.0045, "brass", 0.6)
    rail = up_faces(o, hi.z - 0.004, hi.z + 0.001)
    rlo = Vector(min(f[1][i] for f in rail) for i in range(3))
    rhi = Vector(max(f[2][i] for f in rail) for i in range(3))
    add_box(o, (rlo.x, rlo.y, hi.z - 0.003), (rhi.x, rhi.y, hi.z), "brass")

def do_kitchenCabinet(by):
    o = by["kitchenCabinet(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x - 0.004, lo.y - 0.004, hi.z - 0.002), (hi.x + 0.004, hi.y + 0.004, hi.z + 0.012), "slate")
    add_box(o, (lo.x + 0.01, lo.y + 0.01, lo.z), (hi.x - 0.01, hi.y - 0.002, lo.z + 0.06), "gunmetalDark")
    d = by["door"]
    dlo, dhi = front_panel(d)
    add_box(d, (dhi.x - 0.04, dlo.y - 0.012, dhi.z - 0.1), (dhi.x - 0.032, dlo.y, dhi.z - 0.03), "steel")

def do_toaster(by):
    o = by["toaster(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    for sy in (-0.016, 0.016):
        add_box(o, (lo.x + 0.025, c.y + sy - 0.006, hi.z - 0.003), (hi.x - 0.025, c.y + sy + 0.006, hi.z + 0.001), "screen")
    add_box(o, (hi.x - 0.003, c.y - 0.004, hi.z - 0.05), (hi.x + 0.012, c.y + 0.004, hi.z - 0.04), "red")
    for dx in (-0.04, 0.04):
        add_cyl(o, (c.x + dx, lo.y - 0.004, hi.z * 0.45), 0.012, 0.008, "brass", axis="Y", verts=10)
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.008), "gunmetalDark")

def do_kitchenFridgeLarge(by):
    o = by["kitchenFridgeLarge(Clone)"]
    for k, side in (("doorLeft", 1), ("doorRight", -1)):
        d = by[k]
        dlo, dhi = front_panel_alu(d)
        x = dhi.x - 0.025 if side == 1 else dlo.x + 0.025
        add_box(d, (x - 0.007, dlo.y - 0.016, dhi.z - 0.35), (x + 0.007, dlo.y, dhi.z - 0.04), "steel")
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.01, lo.y - 0.004, lo.z), (hi.x - 0.01, lo.y, lo.z + 0.07), "gunmetalDark")

def front_panel_alu(d):
    dlo, dhi = world_box([d])
    add_box(d, (dlo.x + 0.012, dlo.y - 0.0015, dlo.z + 0.012), (dhi.x - 0.012, dlo.y, dhi.z - 0.012), "alu")
    return dlo, dhi

def do_bookcaseOpenLow(by):
    o = by["bookcaseOpenLow(Clone)"]
    lo, hi = world_box([o])
    lv = [z for z, a in top_levels(o, 0.004) if z < hi.z - 0.02]
    add_box(o, (lo.x, lo.y, hi.z - 0.002), (hi.x, hi.y, hi.z + 0.006), "walnutDark")
    add_box(o, (lo.x + 0.01, lo.y, lo.z), (hi.x - 0.01, hi.y, lo.z + 0.02), "walnutDark")
    for i, z in enumerate(lv[:3]):
        books_on(o, z, lo.x + 0.02, hi.x - 0.02, lo.y, hi.y, seed=3 + i, gap=((lv + [hi.z])[i + 1] - z) - 0.02)

def do_bookcaseClosed(by):
    o = by["bookcaseClosed(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x - 0.004, lo.y - 0.004, hi.z - 0.002), (hi.x + 0.004, hi.y + 0.004, hi.z + 0.01), "walnutDark")
    add_box(o, (lo.x + 0.01, lo.y, lo.z), (hi.x - 0.01, hi.y, lo.z + 0.03), "walnutDark")
    lv = [z for z, a in top_levels(o, 0.004) if lo.z + 0.05 < z < hi.z - 0.02]
    for i, z in enumerate(lv[:5]):
        books_on(o, z, lo.x + 0.025, hi.x - 0.025, lo.y, hi.y, seed=11 + i, gap=((lv + [hi.z])[i + 1] - z) - 0.02)

def do_speaker(by):
    o = by["speaker(Clone)"]
    lo, hi = world_box([o])
    cx, fy = (lo.x + hi.x) / 2, lo.y
    h = hi.z - lo.z
    for zf, r, rr in ((0.28, 0.046, 0.052), (0.62, 0.022, 0.027)):
        z = lo.z + h * zf
        add_cyl(o, (cx, fy - 0.003, z), r, 0.008, "screen", axis="Y", verts=20)
        add_torus_y(o, (cx, fy - 0.004, z), rr, 0.004, "brass")
    add_box(o, (cx - 0.012, fy - 0.002, lo.z + h * 0.92), (cx + 0.012, fy, lo.z + h * 0.94), "brass")
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.012), "gunmetalDark")

def do_loungeSofa(by):
    o = by["loungeSofa(Clone)"]
    lo, hi = world_box([o])
    seat_z = max(z for z, a in top_levels(o, 0.01) if z < hi.z * 0.8)
    for f in (1 / 3, 2 / 3):
        x = lo.x + (hi.x - lo.x) * f
        add_box(o, (x - 0.002, lo.y - 0.002, seat_z - 0.05), (x + 0.002, lo.y + 0.18, seat_z + 0.002), "gunmetalDark")
    for x in (lo.x + 0.04, hi.x - 0.04):
        for y in (lo.y + 0.04, hi.y - 0.04):
            add_cyl(o, (x, y, lo.z + 0.004), 0.016, 0.008, "brass", verts=8)
    for k in range(6):
        add_sphere(o, (lo.x + 0.03 + k * (hi.x - lo.x - 0.06) / 5, hi.y - 0.004, hi.z - 0.04), 0.006, "brass", 0.6)

def do_lampSquareTable(by):
    o = by["lampSquareTable(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_sphere(o, (c.x, c.y, hi.z), 0.008, "brass", 0.5)
    add_box(o, (lo.x - 0.002, lo.y - 0.002, hi.z * 0.62), (hi.x + 0.002, hi.y + 0.002, hi.z * 0.62 + 0.008), "brass")
    add_cyl(o, (c.x, c.y, lo.z + 0.006), 0.05, 0.012, "walnutDark", verts=16)

def do_kitchenFridgeSmall(by):
    o = by["kitchenFridgeSmall(Clone)"]
    d = by["doorFridge"]
    dlo, dhi = front_panel_alu(d)
    add_box(d, (dhi.x - 0.04, dlo.y - 0.014, dhi.z - 0.3), (dhi.x - 0.028, dlo.y, dhi.z - 0.04), "steel")
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.01, lo.y - 0.004, lo.z), (hi.x - 0.01, lo.y, lo.z + 0.07), "gunmetalDark")

# ---- pass 7: the food, pots and jug ------------------------------------------------------------------------

def lum(c):
    return (c[0] + c[1] + c[2]) / 3

def floor_z(o, rmax, zmax):
    """Height of the highest upward face within rmax of the model's middle below zmax: the inside bottom of a pan or box."""
    lo, hi = world_box([o])
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
    zs = [c.z for c, _, _ in up_faces(o, lo.z, zmax) if math.hypot(c.x - cx, c.y - cy) < rmax]
    return max(zs) if zs else lo.z

def pre_fryingpan(by):
    colormap_faces(by["frying-pan"], lambda c, z, p: "walnutDark" if c[0] > 0.7 else ("gunmetalDark" if lum(c) < 0.42 else "gunmetal"))

def do_fryingpan(by):
    o = by["frying-pan"]
    lo, hi = world_box([o])
    fz = floor_z(o, 0.2, 0.08)
    print("panfloor", fz, hi.z)
    add_cyl(o, (0, 0, fz + 0.002), 0.23, 0.004, "gunmetalDark", verts=20)
    add_cyl(o, (0.04, 0.02, fz + 0.007), 0.16, 0.006, "paper", verts=14)
    add_sphere(o, (0.07, 0.0, fz + 0.012), 0.06, "hazard", 0.5)
    for k in (0.36, 0.5):
        add_cyl(o, (0, k + 0.2, hi.z - 0.012), 0.014, 0.012, "brass", verts=8)
    add_torus(o, (0, 0.62, hi.z - 0.012), 0.02, 0.006, "steel")

def pre_pizzabox(by):
    f = lambda c, z, p: "paper" if lum(c) > 0.82 else "kraft"
    colormap_faces(by["pizza-box"], f)
    colormap_faces(by["lid"], f)

def do_pizzabox(by):
    o = by["pizza-box"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    fz = floor_z(o, 0.3, hi.z)
    r = min(hi.x - lo.x, hi.y - lo.y) / 2 - 0.07
    add_cyl(o, (c.x, c.y, fz + 0.012), r, 0.024, "ochre", verts=20)
    add_cyl(o, (c.x, c.y, fz + 0.03), r - 0.04, 0.012, "hazard", verts=20)
    rnd = random.Random(7)
    for k in range(7):
        a = k * 2 * math.pi / 7 + 0.3
        d = r * 0.5 if k else 0.0
        add_cyl(o, (c.x + math.cos(a) * d, c.y + math.sin(a) * d, fz + 0.04), 0.06, 0.008, "red", verts=10)
    add_box(o, (c.x - 0.14, lo.y - 0.002, lo.z + 0.01), (c.x + 0.14, lo.y + 0.003, lo.z + 0.05), "red")

def pre_cupcoffee(by):
    colormap_faces(by["cup-coffee"], lambda c, z, p: "coffee" if lum(c) < 0.4 else "porcelain")

def do_cupcoffee(by):
    o = by["cup-coffee"]
    lo, hi = world_box([o])
    add_torus(o, (0, 0, hi.z - 0.003), 0.104, 0.004, "porcelain")
    add_cyl(o, (0, 0, lo.z + 0.05), 0.109, 0.016, "enamelBlue", verts=16)
    add_cyl(o, (0, 0, lo.z + 0.012), 0.109, 0.012, "porcelain", verts=16)

def pre_loafround(by):
    colormap_faces(by["loaf-round"], lambda c, z, p: "linen" if c[1] > 0.5 else ("kraftDark" if z < 0.07 else "kraft"))

def do_loafround(by):
    o = by["loaf-round"]
    lo, hi = world_box([o])
    rnd = random.Random(3)
    tops = [o.matrix_world @ v.co for v in o.data.vertices if (o.matrix_world @ v.co).z > hi.z * 0.82]
    for w in rnd.sample(tops, min(14, len(tops))):
        add_sphere(o, (w.x * 0.97, w.y * 0.97, w.z - 0.004), 0.016, "cork", 0.5)

def pre_pot(by):
    colormap_faces(by["pot"], lambda c, z, p: "alu" if lum(c) > 0.7 else ("gunmetalDark" if lum(c) < 0.42 else "enamelBlue"))

def do_pot(by):
    o = by["pot"]
    lo, hi = world_box([o])
    add_sphere(o, (0, 0, hi.z - 0.022), 0.035, "brass", 0.8)
    add_torus(o, (0, 0, lo.z + 0.1), radius_at(o, lo.z + 0.08, lo.z + 0.12, max) + 0.001, 0.008, "steel")

def band_xy(o, z0, z1):
    """Half-extents along x and y of the vertices between two world heights: for models that are ovals, not circles."""
    pts = [o.matrix_world @ v.co for v in o.data.vertices]
    ps = [w for w in pts if z0 <= w.z <= z1]
    return max(abs(w.x) for w in ps), max(abs(w.y) for w in ps)

def do_potsmall(by):
    o = by["pot_small"]
    lo, hi = world_box([o])
    rx, ry = band_xy(o, hi.z - 0.05, hi.z)
    add_torus(o, (0, 0, hi.z - 0.012), rx - 0.01, 0.012, "terracotta", sy=ry / rx)
    rx, ry = band_xy(o, lo.z + 0.14, lo.z + 0.2)
    add_torus(o, (0, 0, lo.z + 0.168), rx - 0.002, 0.007, "terracottaDark", sy=ry / rx)

def pre_bottlelarge(by):
    colormap_faces(by["bottle-large"], lambda c, z, p: "enamelBlue" if z > 0.12 else "water")

def do_bottlelarge(by):
    o = by["bottle-large"]
    lo, hi = world_box([o])
    r, e = 0.036, 0.042 / 0.036
    add_cyl(o, (0, 0, lo.z + 0.06), r + 0.0008, 0.034, "paper", verts=16, sy=e)
    add_cyl(o, (0, 0, lo.z + 0.06), r + 0.0012, 0.008, "red", verts=16, sy=e)
    add_torus(o, (0, 0, hi.z - 0.024), 0.02, 0.0025, "enamelBlue", sy=e)

MODELS = {"chair": "furniture", "books": "furniture", "cardboardBoxClosed": "furniture", "lampRoundTable": "furniture",
          "sideTable": "furniture", "bottle": "survival", "bucket": "survival", "box": "survival", "barrel": "survival",
          "soda-can": "food", "bottle-oil": "food", "mug": "food", "carton": "food", "carton-small": "food",
          "plate": "food", "pottedPlant": "furniture", "trashcan": "furniture", "chairDesk": "furniture", "table": "furniture",
          "sideTableDrawers": "furniture", "bench": "furniture", "computerScreen": "furniture",
          "cabinetBed": "furniture", "cabinetBedDrawer": "furniture", "computerKeyboard": "furniture", "desk": "furniture", "chairRounded": "furniture", "kitchenCabinet": "furniture", "toaster": "furniture", "kitchenFridgeLarge": "furniture", "bookcaseOpenLow": "furniture", "bookcaseClosed": "furniture", "speaker": "furniture", "loungeSofa": "furniture", "lampSquareTable": "furniture", "kitchenFridgeSmall": "furniture",
          "frying-pan": "food", "pizza-box": "food", "cup-coffee": "food", "loaf-round": "food", "pot": "food", "pot_small": "nature", "bottle-large": "survival"}
BEVEL = {"bottle": 0.0015, "soda-can": 0.002, "barrel": 0.003, "bucket": 0.003, "books": 0.0025, "lampRoundTable": 0.003}

def build(name):
    kit = MODELS[name]
    fn = name.replace("-", "").replace("_", "")
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    for m in list(bpy.data.materials):
        bpy.data.materials.remove(m)
    palette()
    bpy.ops.import_scene.gltf(filepath=os.path.join(here, "base", kit, name + ".glb"))
    objs = meshes()
    by = {o.name: o for o in bpy.data.objects}
    # Bounds are taken before anything is added, from the stock model.
    lo0, hi0 = world_box(objs)
    names0 = sorted(o.name for o in bpy.data.objects)
    if "pre_" + fn in globals():
        globals()["pre_" + fn](by)
    for o in objs:
        reskin(o, OVERRIDES.get(name))
        bevel(o, BEVEL.get(name, 0.004))
        for f in o.data.polygons:
            f.use_smooth = False
    globals()["do_" + fn](by)
    objs = meshes()
    lo, hi = world_box(objs)
    # Refit to the stock box: every axis is scaled about the box's own corner.
    s = Vector(((hi0[i] - lo0[i]) / (hi[i] - lo[i]) if hi[i] - lo[i] > 1e-6 else 1.0) for i in range(3))
    print("grown", name, [round(v, 4) for v in lo], [round(v, 4) for v in hi], "stock", [round(v, 4) for v in lo0], [round(v, 4) for v in hi0])
    print("refit", name, [round(v, 4) for v in s])
    roots = [o for o in bpy.data.objects if o.parent is None]
    for o in roots:
        o.matrix_world = Matrix.Translation(lo0) @ Matrix.Diagonal((*s, 1)) @ Matrix.Translation(-lo) @ o.matrix_world
    assert names0 == sorted(o.name for o in bpy.data.objects), "node names changed"
    bpy.ops.object.select_all(action="DESELECT")
    os.makedirs(os.path.join(outdir, kit), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(outdir, kit, name + ".glb"), export_format="GLB", export_yup=True,
                              export_apply=False, export_cameras=False, export_lights=False)

for n in (names or list(MODELS)):
    build(n)
