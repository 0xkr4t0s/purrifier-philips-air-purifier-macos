"""Slot C: the purifier with a cat curled up against it.

Uses "Toon Cat FREE" by Omabuarts Studio (CC BY 4.0, see
Assets/blender/third_party/toon-cat/CREDITS.md), imported from the unmodified GLB,
scaled, posed and animated entirely in code. (Fallback, all-procedural cat:
render_cat_simple.py.)

    blender -b Assets/blender/purifier.blend -P Tools/blender/render_cat.py -- [--clips off,auto,...] [--test] [--inspect]

Loops (120 f): off (asleep), sleep, auto, turbo (awake, idle).
One-shots: off-to-<mode>-stretch (45 f), <m0>-to-<m1>-twitch (15 f).
Pose = function of loop phase T = (frame-1)/120 with whole-number cycles -> seamless.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import purr_common as C  # noqa: E402
from build_purifier import enable_gpu  # noqa: E402

args = C.script_args(sys.argv)


def opt(k, d=None):
    return args[args.index(k) + 1] if k in args else d


TEST = "--test" in args
GLB = os.path.join(C.REPO, "Assets", "blender", "third_party", "toon-cat", "toon_cat_free.glb")
CAT_HEIGHT = 0.27          # standing height to the ear tips, next to the 0.367 m purifier
STRETCH_N, TWITCH_N = 45, 15

sc = bpy.context.scene
enable_gpu()
sc.cycles.device = "GPU"
W, H = C.slot_px("C")
sc.render.resolution_x, sc.render.resolution_y = W, H
sc.cycles.samples = 48 if TEST else 128
sc.cycles.use_denoising = True
sc.cycles.seed = 0
root = bpy.data.objects["PurifierRoot"]
root["display_strength"] = 0.0
pcol = bpy.data.collections["Purifier"]

# --- import -----------------------------------------------------------------------
before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=GLB)
new = [o for o in bpy.data.objects if o not in before]
for o in [o for o in new if o.type == "MESH" and not o.vertex_groups and o.parent is None]:
    new.remove(o)                                  # importer's bone-display shape (Icosphere)
    bpy.data.objects.remove(o)
arm = next(o for o in new if o.type == "ARMATURE")
meshes = [o for o in new if o.type == "MESH" and o.vertex_groups]
cat_col = bpy.data.collections.new("Cat")
pcol.children.link(cat_col)                       # studio lights are linked to the Purifier collection
for o in new:
    for c in list(o.users_collection):
        c.objects.unlink(o)
    cat_col.objects.link(o)
if arm.animation_data:                            # drop the bundled walk cycle; we pose in code
    arm.animation_data.action = None
    for t in list(arm.animation_data.nla_tracks):
        arm.animation_data.nla_tracks.remove(t)
for pb in arm.pose.bones:
    pb.matrix_basis = Matrix.Identity(4)
top = next(o for o in new if o.parent is None)

# scale to CAT_HEIGHT and stand on the floor
bpy.context.view_layer.update()


def world_bbox(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx


PB = arm.pose.bones


def bone_head_world(name):
    return arm.matrix_world @ PB[name].head


# orient: measure the cat's forward (torso -> head) and up (torso -> between the ears)
# from the rig, then rotate so it faces -Y with up = +Z (robust to the GLB's nested
# FBX/glTF axis conversions)
torso = bone_head_world("torso_02")
fwd = (bone_head_world("head_018") - torso).normalized()
up = ((bone_head_world("ear.L_019") + bone_head_world("ear.R_020")) / 2 - torso)
up = (up - fwd * up.dot(fwd)).normalized()
side = fwd.cross(up)
Ms = Matrix((side, fwd, up)).transposed()
# target basis columns: side = fwd x up, fwd = -Y, up = +Z
Mt = Matrix(((-1, 0, 0), (0, -1, 0), (0, 0, 1))).transposed()
top.matrix_world = (Mt @ Ms.inverted()).to_4x4() @ top.matrix_world
bpy.context.view_layer.update()
mn, mx = world_bbox(meshes)
s = CAT_HEIGHT / (mx.z - mn.z)
top.matrix_world = Matrix.Scale(s, 4) @ top.matrix_world
bpy.context.view_layer.update()
mn, mx = world_bbox(meshes)
top.matrix_world = Matrix.Translation(Vector((-(mn.x + mx.x) / 2, -(mn.y + mx.y) / 2, -mn.z))) @ top.matrix_world
bpy.context.view_layer.update()
REST_BBOX = world_bbox(meshes)
for m in meshes:                                   # smooth deformation of the low-poly mesh
    sub = m.modifiers.new("Smooth", "SUBSURF")
    sub.levels, sub.render_levels = 1, 2
    sub.boundary_smooth = "PRESERVE_CORNERS"
    for poly in m.data.polygons:
        poly.use_smooth = True


if "--inspect" in args:
    for o in new:
        print("OBJ", o.name, o.type, "parent", o.parent.name if o.parent else None, "ptype", o.parent_type,
              "pbone", o.parent_bone, "scale", tuple(round(v, 4) for v in o.matrix_world.to_scale()),
              "mods", [m.type for m in o.modifiers], "vgs", len(o.vertex_groups) if o.type == "MESH" else "-",
              "verts", len(o.data.vertices) if o.type == "MESH" else "-")
    ad = arm.animation_data
    print("ANIM", ad and ad.action, ad and [t.name for t in ad.nla_tracks])
    # rest-pose look: cat beside the purifier, side-on and three-quarter
    top.matrix_world = Matrix.Translation((-0.32, -0.05, 0)) @ top.matrix_world
    for nm, loc in (("side", (-0.32, -1.1, 0.14)), ("tq", (0.30, -0.95, 0.35))):
        cd = bpy.data.cameras.new(nm)
        cd.lens = 50
        cam = bpy.data.objects.new(nm, cd)
        sc.collection.objects.link(cam)
        t = bpy.data.objects.new(nm + "_t", None)
        t.location = (-0.18, -0.05, 0.13)
        sc.collection.objects.link(t)
        cam.location = loc
        c = cam.constraints.new("TRACK_TO")
        c.target = t
        c.track_axis = "TRACK_NEGATIVE_Z"
        c.up_axis = "UP_Y"
        sc.camera = cam
        sc.cycles.samples = 32
        sc.render.filepath = os.path.join(C.RENDER_DIR, "C2", f"inspect_{nm}.png")
        bpy.ops.render.render(write_still=True)
    sys.exit(0)
    print("BBOX", [tuple(round(v, 3) for v in REST_BBOX[0]), tuple(round(v, 3) for v in REST_BBOX[1])])
    for b in arm.data.bones:
        y = (arm.matrix_world.to_3x3() @ (b.matrix_local.to_3x3() @ Vector((0, 1, 0)))).normalized()
        print("BONE", b.name, tuple(round(v, 3) for v in bone_head_world(b.name)), "y-axis", tuple(round(v, 2) for v in y))
    for m in meshes:
        print("MESH", m.name, [vg.name for vg in m.vertex_groups][:40])

# --- posing -------------------------------------------------------------------------
# Cat-relative axes in ARMATURE space (valid whatever the object transform):
# LEFT = cat's left (+X at rest), FWD = nose direction (-Y), UP (+Z).
_A = arm.matrix_world.inverted().to_3x3()
LEFT = (_A @ Vector((1, 0, 0))).normalized()
FWD = (_A @ Vector((0, -1, 0))).normalized()
UP = (_A @ Vector((0, 0, 1))).normalized()
ARM_SCALE = arm.matrix_world.to_scale().x
REST_TORSO_Z = bone_head_world("torso_02").z


def reset_pose():
    for pb in PB:
        pb.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()


def rot(name, axis, deg):
    """Rotate a bone (and everything below it) about an armature-space axis through its joint."""
    if abs(deg) < 1e-6:
        return
    pb = PB[name]
    h = pb.head.copy()
    R = Matrix.Translation(h) @ Quaternion(axis, math.radians(deg)).to_matrix().to_4x4() @ Matrix.Translation(-h)
    pb.matrix = R @ pb.matrix
    bpy.context.view_layer.update()


def aim(name, fwd, left, up):
    """Point a bone (head->tail) along a direction given in the cat's own frame, by the
    smallest rotation about its joint; children follow."""
    pb = PB[name]
    cur = (pb.tail - pb.head).normalized()
    want = (FWD * fwd + LEFT * left + UP * up).normalized()
    q = cur.rotation_difference(want)
    h = pb.head.copy()
    pb.matrix = Matrix.Translation(h) @ q.to_matrix().to_4x4() @ Matrix.Translation(-h) @ pb.matrix
    bpy.context.view_layer.update()


def move(name, metres_vec_world):
    pb = PB[name]
    v = _A @ Vector(metres_vec_world)
    pb.matrix = Matrix.Translation(v) @ pb.matrix
    bpy.context.view_layer.update()


def squash(name, k):
    """Scale a bone along its local axis that best matches the cat's UP (eyes -> eyelid blink)."""
    pb = PB[name]
    m = pb.bone.matrix_local.to_3x3()
    idx = max(range(3), key=lambda i: abs(m.col[i].normalized().dot(UP)))
    sv = [1.0, 1.0, 1.0]
    sv[idx] = max(k, 0.06)
    pb.scale = sv
    bpy.context.view_layer.update()


LR = (("L", 1), ("R", -1))
FRONT = {"L": ("leg.upper.F.L_014", "leg.lower.FL_015", "foot.F.L_016"),
         "R": ("leg.upper.F.R_024", "leg.lower.F.R_00", "foot.F.R_025")}
HIND = {"L": ("thigh.B.L_03", "leg.upper.B.L_04", "leg.lower.B.L_05", "foot.B.L_06"),
        "R": ("thigh.B.R_026", "leg.upper.B.R_027", "leg.lower.B.R_028", "foot.B.R_029")}
TAIL = ("tail_07", "tail.01_08", "tail.02_09", "tail.03_010", "tail.end_011")

POSES = {
    #          lift  look  eye   ear  br  ba     tail-flick cycles, amp(deg)
    "off":   dict(lift=0.0, look=0.0, eye=0.0, ear=8,  br=2, ba=1.0, tf=1, ta=4,  blink=False),
    "sleep": dict(lift=0.8, look=0.8, eye=0.5, ear=4,  br=2, ba=0.8, tf=1, ta=10, blink=True),
    "auto":  dict(lift=1.0, look=1.0, eye=1.0, ear=0,  br=3, ba=0.7, tf=2, ta=14, blink=True),
    "turbo": dict(lift=1.0, look=1.0, eye=1.0, ear=-16, br=3, ba=0.7, tf=3, ta=18, blink=True),
}


def lerp(a, b, t):
    return a + (b - a) * t


def blend_pose(p0, p1, t):
    return {k: (lerp(p0[k], p1[k], t) if not isinstance(p0[k], bool) else (p1[k] if t > 0.5 else p0[k])) for k in p0}


def pose(p, T, extra=None):
    extra = extra or {}
    st = extra.get("stretch", 0.0)
    tw = extra.get("twitch", 0.0)
    yawn = extra.get("yawn", 0.0)
    br = math.sin(2 * math.pi * p["br"] * T)
    reset_pose()
    # lie down: drop the whole body, breathe
    move("root_01", (0, 0, -(REST_TORSO_Z - 0.070) + 0.0012 * p["ba"] * br))
    # body curls towards the purifier (cat's left); stretch straightens and arches it
    for b, d in (("torso_02", 10), ("spine.01_012", 12), ("spine.02_013", 10)):
        rot(b, UP, d * (1 - 0.6 * st))
    rot("spine.01_012", LEFT, 1.2 * p["ba"] * br - 6 * st)
    # front legs forward along the floor (sphinx); the stretch reaches further
    for side, sg in LR:
        up_, low, foot = FRONT[side]
        rot(up_, LEFT, -78 - 14 * st)
        rot(up_, UP, sg * -6)
        rot(low, LEFT, 8 - 8 * st)
        rot(foot, LEFT, -70)
    # hind legs folded the way a lying cat's are: thigh forward and down the flank, shin back
    # to the hock on the floor, foot and toes forward and flat beside the belly
    for side, sg in LR:
        th, up_, low, foot = HIND[side]
        aim(th, 0.55, 0.12 * sg, -0.83)
        aim(up_, -0.78, 0.05 * sg, -0.62)
        aim(low, 0.93, 0.03 * sg, -0.20)
        aim(foot, 0.97, -0.05 * sg, 0.0)
    # tail: lowered to the floor, wrapping forward round the cat's right (camera) side; tip flicks
    flick = p["ta"] * math.sin(2 * math.pi * p["tf"] * T)
    # rest tail points straight back at torso height: tip it down to the floor, then curl it
    # forward round the cat's right (camera) side
    rot(TAIL[0], LEFT, -24)
    rot(TAIL[0], UP, 22)
    for i, b in enumerate(TAIL[1:], 1):
        rot(b, LEFT, 5 if i == 1 else 2)
        rot(b, UP, 33 + (flick * (i / 4) ** 1.5 if i >= 2 else 0))
    # head: asleep = resting low on the paws; awake = up and turned to the camera
    lift = min(1.0, p["lift"] + 0.3 * st)
    rot("neck_017", LEFT, lerp(38, 4, lift) - 16 * st)
    rot("neck_017", UP, -lerp(30, 38, p["look"]))
    rot("head_018", LEFT, lerp(12, -4, lift) - 10 * st)
    rot("head_018", UP, -lerp(26, 36, p["look"]))
    rot("head_018", FWD, lerp(-12, 4, lift))
    rot("mouth_021", LEFT, 22 * yawn)
    # ears
    for side, sg in LR:
        e = "ear.L_019" if side == "L" else "ear.R_020"
        twitch = (28 if side == "R" else 6) * math.sin(math.pi * tw)
        rot(e, FWD, sg * (p["ear"] + twitch))
    # eyes: open amount with one slow blink per loop when awake
    op = p["eye"] * (1 - 0.3 * yawn)
    if p["blink"]:
        op *= 1 - 0.95 * math.exp(-((T - 0.62) / 0.018) ** 2)
    for e in ("eye.L_022", "eye.R_023"):
        squash(e, op)


# --- place the cat against the purifier; camera ------------------------------------
TH = math.radians(236)
P = Vector((0.192 * math.cos(TH), 0.192 * math.sin(TH), 0.0))
psi = math.atan2(-P.y, -P.x)                 # cat's left (+X) points at the purifier axis
top.matrix_world = Matrix.Translation(P) @ Matrix.Rotation(psi, 4, "Z") @ top.matrix_world
bpy.context.view_layer.update()

CAM_LOC = Vector((-0.40, -1.02, 0.22))
cd = bpy.data.cameras.new("CamC")
cd.lens = 50
camC = bpy.data.objects.new("CamC", cd)
sc.collection.objects.link(camC)
tC = bpy.data.objects.new("CamC_T", None)
tC.location = (-0.06, -0.12, 0.105)
sc.collection.objects.link(tC)
camC.location = CAM_LOC
con = camC.constraints.new("TRACK_TO")
con.target = tC
con.track_axis = "TRACK_NEGATIVE_Z"
con.up_axis = "UP_Y"
sc.camera = camC
bpy.data.objects["ShadowCatcher"].hide_render = False


def render_clip(name, n, posefn):
    d = os.path.join(C.RENDER_DIR, "C", name)
    os.makedirs(d, exist_ok=True)
    frames = [1, n // 2 + 1] if TEST else range(1, n + 1)
    for f in frames:
        posefn(f)
        sc.render.filepath = os.path.join(d, f"{f:04d}.png")
        bpy.ops.render.render(write_still=True)
    print("C", name, "done", flush=True)


def ss(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


if "--debug-legs" in args:
    Rw = arm.matrix_world.to_3x3() @ Matrix((LEFT, FWD, UP)).transposed()   # cat axes in world
    Rw.normalize()

    def cat_local(v):
        d = v - bone_head_world("torso_02")
        return tuple(round(x * 100, 1) for x in (Rw.col[1].dot(d), Rw.col[0].dot(d), Rw.col[2].dot(d)))

    def dump(tag):
        for side, _ in LR:
            chain = HIND[side]
            pts = [cat_local(arm.matrix_world @ PB[b].head) for b in chain]
            pts.append(cat_local(arm.matrix_world @ PB[chain[-1]].tail))
            print("HIND", tag, side, "(fwd,left,up cm from torso)", pts)
        print("FLOOR_UP_cm", round(-bone_head_world("torso_02").z * 100, 1))
    reset_pose()
    dump("rest")
    pose(POSES["auto"], 0.0)
    dump("posed")
    for nm, loc, tgt in (("haunch_cam", tuple(CAM_LOC), (-0.17, -0.12, 0.05)), ("haunch_top", (-0.15, -0.16, 0.6), (-0.15, -0.15, 0.0))):
        cd2 = bpy.data.cameras.new(nm)
        cd2.lens = 120 if nm == "haunch_cam" else 60
        c2 = bpy.data.objects.new(nm, cd2)
        sc.collection.objects.link(c2)
        t2 = bpy.data.objects.new(nm + "_t", None)
        t2.location = tgt
        sc.collection.objects.link(t2)
        c2.location = loc
        k = c2.constraints.new("TRACK_TO")
        k.target = t2
        k.track_axis = "TRACK_NEGATIVE_Z"
        k.up_axis = "UP_Y"
        sc.camera = c2
        sc.cycles.samples = 32
        sc.render.filepath = os.path.join(C.RENDER_DIR, "C2", f"{nm}.png")
        bpy.ops.render.render(write_still=True)
    sys.exit(0)
if "--debug-tail" in args:
    def dump(tag):
        pts = [tuple(round(v, 3) for v in (arm.matrix_world @ PB[b].head)) for b in TAIL]
        tail_end = tuple(round(v, 3) for v in (arm.matrix_world @ PB[TAIL[-1]].tail))
        print("TAIL", tag, pts, "end", tail_end, "torso", tuple(round(v, 3) for v in bone_head_world("torso_02")))
    reset_pose()
    dump("rest")
    pose(POSES["off"], 0.0)
    dump("posed")
    print("CATPOS", tuple(round(v, 3) for v in P), "psi", round(math.degrees(psi), 1))
    sys.exit(0)
clips = opt("--clips", "off,sleep,auto,turbo,stretch,twitch").split(",")
for mode in ("off", "sleep", "auto", "turbo"):
    if mode in clips:
        render_clip(mode, C.LOOP_FRAMES, lambda f, m=mode: pose(POSES[m], (f - 1) / C.LOOP_FRAMES))
if "stretch" in clips:
    for m1 in ("sleep", "auto", "turbo"):
        def pf(f, m1=m1):
            t = (f - 1) / (STRETCH_N - 1)
            p = blend_pose(POSES["off"], POSES[m1], ss(t / 0.55))
            p["blink"] = False
            reach = math.sin(math.pi * ss(t / 0.85))
            yawn = math.sin(math.pi * ss((t - 0.15) / 0.5)) if 0.15 < t < 0.65 else 0.0
            pose(p, 0.0, {"stretch": reach, "yawn": yawn})
        render_clip(f"off-to-{m1}-stretch", STRETCH_N, pf)
if "twitch" in clips:
    for m0 in ("sleep", "auto", "turbo"):
        for m1 in ("sleep", "auto", "turbo"):
            if m0 == m1:
                continue
            def pf(f, m0=m0, m1=m1):
                t = (f - 1) / (TWITCH_N - 1)
                p = blend_pose(POSES[m0], POSES[m1], ss(t))
                p["blink"] = False
                pose(p, 0.0, {"twitch": math.sin(math.pi * t)})
            render_clip(f"{m0}-to-{m1}-twitch", TWITCH_N, pf)
print("ALL DONE", flush=True)
