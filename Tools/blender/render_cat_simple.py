"""Slot C: a simple stylised cat curled around the purifier (no copyrighted character).

    blender -b Assets/blender/purifier.blend -P Tools/blender/render_cat.py -- [--clips off,auto,...] [--test]

Loops (120 f): off (asleep), sleep, auto, turbo (awake idle; breathing, blinks, tail).
One-shots: off-to-<mode>-stretch (stretching awake when the purifier turns on, 45 f)
           <m0>-to-<m1>-twitch    (ear twitch on a mode change, 15 f).
Every frame is posed in code from T = (frame-1)/120 with whole-number cycles -> seamless loops.
Output: .render/C/<clip>/####.png (full frames, transparent background).
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import purr_common as C  # noqa: E402
from build_purifier import enable_gpu, fillet_polyline, lathe  # noqa: E402

args = C.script_args(sys.argv)


def opt(k, d=None):
    return args[args.index(k) + 1] if k in args else d


TEST = "--test" in args
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
pcol = bpy.data.collections["Purifier"]          # studio lights are linked to this collection

# --- materials ----------------------------------------------------------------


def mat(name, hexcol, rough=0.7, sheen=0.0, coat=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*C.hex_to_linear(hexcol), 1)
    b.inputs["Roughness"].default_value = rough
    if sheen:
        b.inputs["Sheen Weight"].default_value = sheen
        b.inputs["Sheen Roughness"].default_value = 0.4
    if coat:
        b.inputs["Coat Weight"].default_value = coat
        b.inputs["Coat Roughness"].default_value = 0.05
    return m


def fur_mat():
    """Ginger fur with soft darker stripes along the body and a cream underside."""
    m = mat("Cat_Fur", "#E59A52", 0.75, sheen=0.6)
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    # stripes: bands around the purifier axis (angle), soft
    ang = nt.nodes.new("ShaderNodeMath")
    ang.operation = "ARCTAN2"
    nt.links.new(sep.outputs[1], ang.inputs[0])
    nt.links.new(sep.outputs[0], ang.inputs[1])
    wave = nt.nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.inputs["Scale"].default_value = 2.2
    wave.inputs["Distortion"].default_value = 6.0
    wave.inputs["Detail"].default_value = 1.0
    comb = nt.nodes.new("ShaderNodeCombineXYZ")
    nt.links.new(ang.outputs[0], comb.inputs[0])
    nt.links.new(sep.outputs[2], comb.inputs[1])
    nt.links.new(comb.outputs[0], wave.inputs["Vector"])
    st = nt.nodes.new("ShaderNodeMapRange")
    nt.links.new(wave.outputs["Fac"], st.inputs["Value"])
    st.inputs["From Min"].default_value = 0.55
    st.inputs["From Max"].default_value = 0.9
    # cream underside: low z
    belly = nt.nodes.new("ShaderNodeMapRange")
    belly.interpolation_type = "SMOOTHSTEP"
    nt.links.new(sep.outputs[2], belly.inputs["Value"])
    belly.inputs["From Min"].default_value = 0.045
    belly.inputs["From Max"].default_value = 0.02
    m1 = nt.nodes.new("ShaderNodeMix")
    m1.data_type = "RGBA"
    nt.links.new(st.outputs["Result"], m1.inputs["Factor"])
    m1.inputs["A"].default_value = (*C.hex_to_linear("#E59A52"), 1)
    m1.inputs["B"].default_value = (*C.hex_to_linear("#DA8C46"), 1)
    m2 = nt.nodes.new("ShaderNodeMix")
    m2.data_type = "RGBA"
    nt.links.new(belly.outputs["Result"], m2.inputs["Factor"])
    nt.links.new(m1.outputs["Result"], m2.inputs["A"])
    m2.inputs["B"].default_value = (*C.hex_to_linear("#F6E3C8"), 1)
    nt.links.new(m2.outputs["Result"], b.inputs["Base Color"])
    return m


M_FUR = fur_mat()
M_CREAM = mat("Cat_Cream", "#F6E3C8", 0.75, sheen=0.5)
M_TAIL = mat("Cat_Tail", "#DE9049", 0.75, sheen=0.6)
M_EAR_IN = mat("Cat_EarInner", "#E8A99A", 0.7, sheen=0.3)
M_EYE = mat("Cat_Eye", "#16120F", 0.45)
M_GLINT = mat("Cat_EyeGlint", "#FFFFFF", 0.3)
M_GLINT.node_tree.nodes["Principled BSDF"].inputs["Emission Color"].default_value = (1, 1, 1, 1)
M_GLINT.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 0.6
M_NOSE = mat("Cat_Nose", "#D9877E", 0.4)

# --- cat geometry ---------------------------------------------------------------
cat_col = bpy.data.collections.new("Cat")
pcol.children.link(cat_col)                       # inside Purifier so the studio lights reach it

mb = bpy.data.metaballs.new("CatBody")
mb.resolution = 0.006
mb.render_resolution = 0.0035
mb.threshold = 0.6
body = bpy.data.objects.new("CatBody", mb)
cat_col.objects.link(body)
body.data.materials.append(M_FUR)


def el(kind="ELLIPSOID"):
    e = mb.elements.new()
    e.type = kind
    return e


# cat lies on a ring around the purifier base (radius RR), front-left of the camera view
RR = 0.178                         # centre-line radius of the curled body
BODY_ELS = [el() for _ in range(3)]
NECK = el("BALL")
CHEST = el("BALL")
HEAD = el("BALL")
CHEEKS = [el("BALL") for _ in range(2)]
MUZZLE = el("BALL")
PAWS = [el() for _ in range(2)]
ARMS = [el() for _ in range(2)]
HAUNCH = el("BALL")
tail_cu = bpy.data.curves.new("Tail", "CURVE")
tail_cu.dimensions = "3D"
tail_cu.bevel_depth = 0.0135
tail_cu.bevel_resolution = 6
tail_cu.use_fill_caps = True
TAIL_N = 24
tail_sp = tail_cu.splines.new("NURBS")
tail_sp.points.add(TAIL_N - 1)
tail_sp.order_u = 4
tail_sp.use_endpoint_u = True
tail = bpy.data.objects.new("Tail", tail_cu)
tail.data.materials.append(M_TAIL)


def mesh_obj(name, bm, material, parent=None):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    ob = bpy.data.objects.new(name, me)
    ob.data.materials.append(material)
    cat_col.objects.link(ob)
    if parent:
        ob.parent = parent
    return ob


def ear_mesh(name, inner=False):
    """Pointed triangular cat ear: a thin rounded-triangle plate, slightly cupped."""
    s = 0.78 if inner else 1.0
    w, h, t = 0.034 * s, 0.040 * s, 0.006 if not inner else 0.003
    bm = bmesh.new()
    outline = []
    for k in range(13):                        # rounded base, straight sides to a soft tip
        a = math.pi * k / 12
        outline.append((-w / 2 * math.cos(a), 0.0, -0.004 * math.sin(a)))
    pts_front = [Vector(p) for p in outline] + [Vector((0.0, 0.0, h))]
    front = [bm.verts.new(p + Vector((0, -t / 2, 0))) for p in pts_front]
    back = [bm.verts.new(p + Vector((0, t / 2, 0)) * Vector((1, 1, 1))) for p in pts_front]
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    n = len(front)
    for i in range(n):
        bm.faces.new((front[i], back[i], back[(i + 1) % n], front[(i + 1) % n]))
    for v in front + back:                     # cup the ear: centre pushed back a little
        v.co.y += 0.006 * (1 - abs(v.co.x) / (w / 2)) * min(1.0, v.co.z / h + 0.3)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    o = mesh_obj(name, bm, M_EAR_IN if inner else M_FUR)
    sub = o.modifiers.new("S", "SUBSURF")
    sub.levels = sub.render_levels = 1
    return o


head_ctrl = bpy.data.objects.new("HeadCtrl", None)
cat_col.objects.link(head_ctrl)
ears = []
for side in (-1, 1):
    piv = bpy.data.objects.new(f"EarPivot{side}", None)
    cat_col.objects.link(piv)
    piv.parent = head_ctrl
    piv.location = (side * 0.036, 0.006, 0.040)
    piv.rotation_euler = (0, side * math.radians(-26), 0)
    outer = ear_mesh(f"Ear{side}")
    outer.parent = piv
    inner = ear_mesh(f"EarIn{side}", inner=True)
    inner.parent = piv
    inner.location = (0, -0.0045, 0.003)
    ears.append(piv)

eyes = []
for side in (-1, 1):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=0.0085)
    e = mesh_obj(f"Eye{side}", bm, M_EYE, head_ctrl)
    e.location = (side * 0.024, -0.050, 0.010)
    e.rotation_euler = (0, 0, side * math.radians(-12))
    eyes.append(e)
glints = []
for side in (-1, 1):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=6, radius=0.0026)
    g = mesh_obj(f"EyeGlint{side}", bm, M_GLINT, head_ctrl)
    g.location = (side * 0.024 + 0.003, -0.0565, 0.0135)
    glints.append(g)
bm = bmesh.new()
bmesh.ops.create_uvsphere(bm, u_segments=16, v_segments=8, radius=0.006)
for v in bm.verts:
    v.co.z *= 0.6
nose = mesh_obj("Nose", bm, M_NOSE, head_ctrl)
nose.location = (0, -0.066, -0.005)

cat_col.objects.link(tail)

# --- pose ---------------------------------------------------------------------------


def ring(theta_deg, r=RR, z=0.0):
    t = math.radians(theta_deg)
    return Vector((r * math.cos(t), r * math.sin(t), z))


def tangent(theta_deg):
    t = math.radians(theta_deg)
    return Vector((-math.sin(t), math.cos(t), 0))


POSES = {
    #          head lift, head turn, eye open, ear back, breath rate, breath amp, tail flick cycles, tail amp
    "off":   dict(lift=0.0, look=0.0, eye=0.0, ear=12, br=2, ba=0.035, tf=1, ta=0.15, blink=False),
    "sleep": dict(lift=0.75, look=1.0, eye=0.45, ear=4, br=2, ba=0.025, tf=1, ta=0.35, blink=True),
    "auto":  dict(lift=1.0, look=1.0, eye=0.95, ear=0, br=3, ba=0.022, tf=2, ta=0.5, blink=True),
    "turbo": dict(lift=1.0, look=1.0, eye=1.0, ear=-14, br=3, ba=0.022, tf=3, ta=0.7, blink=True),
}


def lerp(a, b, t):
    return a + (b - a) * t


def blend_pose(p0, p1, t):
    return {k: (lerp(p0[k], p1[k], t) if isinstance(p0[k], (int, float)) and not isinstance(p0[k], bool) else (p1[k] if t > 0.5 else p0[k]))
            for k in p0}


CAM_LOC = Vector((-0.36, -0.98, 0.21))


def apply(p, T, extra=None):
    """Pose the cat. p: pose dict, T: loop phase 0..1. extra: one-shot overrides
    (stretch: 0..1 front-paw reach / head arch; twitch: 0..1 ear twitch)."""
    extra = extra or {}
    br = math.sin(2 * math.pi * p["br"] * T)
    breath = 1 + p["ba"] * br
    stretch = extra.get("stretch", 0.0)
    # compact loaf body hugging the front-left of the base: rump (th=206) -> chest (th=258)
    for i, (e, th, rad) in enumerate(zip(BODY_ELS, (220, 233, 246), (0.082, 0.084, 0.080))):
        e.co = ring(th, r=RR + 0.014, z=0.066)
        e.radius = rad
        e.size_x = 0.95
        e.size_y = 1.0 * breath
        e.size_z = 1.0 * breath
        e.rotation = Euler((0, 0, math.radians(th) + math.pi / 2)).to_quaternion()
    HAUNCH.co = ring(211, r=RR + 0.020, z=0.072)
    HAUNCH.radius = 0.088 * (1 + 0.5 * (breath - 1))
    chest = ring(256, r=RR + 0.032, z=0.066)
    CHEST.co = chest
    CHEST.radius = 0.074 * (1 + 0.5 * (breath - 1))
    # head: resting on the paws in front of the chest when asleep; lifted and turned to camera when awake
    lift = min(1.0, p["lift"] + 0.3 * stretch)
    hp = lerp(ring(265, r=RR + 0.078, z=0.074), ring(259, r=RR + 0.052, z=0.128), lift)
    hp += Vector((0, 0, 0.003 * br))
    HEAD.co = hp
    HEAD.radius = 0.074
    NECK.co = chest.lerp(hp, 0.5) + Vector((0, 0, 0.006))
    NECK.radius = lerp(0.046, 0.058, lift)
    to_cam = CAM_LOC - hp
    yaw_cam = math.atan2(to_cam.x, -to_cam.y)
    yaw = lerp(yaw_cam + math.radians(28), yaw_cam, p["look"])
    pitch = math.radians(lerp(26, -2, lift) - 25 * stretch)
    roll = math.radians(lerp(-14, 0, lift))
    rot = Euler((pitch, roll, yaw), "XYZ")
    head_ctrl.location = hp
    head_ctrl.rotation_euler = rot
    R = rot.to_matrix()
    for side, ch in zip((-1, 1), CHEEKS):
        ch.co = hp + R @ Vector((side * 0.032, -0.022, -0.020))
        ch.radius = 0.040
    MUZZLE.co = hp + R @ Vector((0, -0.046, -0.020))
    MUZZLE.radius = 0.024
    # front paws in front of the chest, pointing at the camera; reach forward in the stretch
    for side, pw in zip((-1, 1), PAWS):
        th = 262 + side * 6
        pw.co = ring(th, r=RR + 0.044 + 0.09 * stretch, z=0.022 + 0.004 * stretch)
        pw.radius = 0.028
        pw.size_x, pw.size_y, pw.size_z = 0.75, 1.5 + 0.7 * stretch, 0.62
        pw.rotation = Euler((0, 0, math.radians(th) + math.pi / 2)).to_quaternion()
    for side, arm, pw in zip((-1, 1), ARMS, PAWS):
        sh = ring(262 + side * 5, r=RR + 0.030, z=0.040)          # shoulder, inside the chest
        pv = Vector(pw.co)
        arm.co = sh.lerp(pv, 0.55)
        d = pv - sh
        arm.radius = 0.030
        arm.size_x, arm.size_y, arm.size_z = 0.8, max(1.0, d.length / 0.03), 0.8
        arm.rotation = d.to_track_quat("Y", "Z")
    # ears
    tw = extra.get("twitch", 0.0)
    for side, piv in zip((-1, 1), ears):
        twitch = math.radians(30) * math.sin(math.pi * tw) * (1 if side > 0 else 0.2)
        piv.rotation_euler = (math.radians(p["ear"]) + twitch, side * math.radians(-26), side * twitch * 0.4)
    # eyes: open amount, one slow blink per loop when awake
    op = p["eye"]
    if p["blink"]:
        op *= 1 - 0.92 * math.exp(-((T - 0.62) / 0.018) ** 2)
    op *= 1 - 0.2 * stretch
    for e in eyes:
        e.scale = (1.0, 0.55, max(0.12, op))
    for g in glints:
        g.scale = (1, 1, 1) if op > 0.35 else (0, 0, 0)
    # tail: from the rump round the front of the body towards the paws; tip flicks
    for i, pt in enumerate(tail_sp.points):
        s_ = i / (TAIL_N - 1)
        flick = p["ta"] * s_ ** 2.2 * math.sin(2 * math.pi * p["tf"] * T - 2.0 * s_)
        th = 204 + 44 * s_ + 8 * flick
        r = RR + 0.080 + 0.030 * s_ ** 2.5
        z = 0.016 + 0.004 * s_ + 0.030 * s_ ** 3 + 0.02 * max(0.0, flick) * s_
        v = ring(th, r=r, z=z)
        pt.co = (v.x, v.y, v.z, 1.0)
        pt.radius = lerp(1.0, 0.7, s_)


# --- camera -------------------------------------------------------------------------
cd = bpy.data.cameras.new("CamC")
cd.lens = 50
camC = bpy.data.objects.new("CamC", cd)
sc.collection.objects.link(camC)
tC = bpy.data.objects.new("CamC_T", None)
tC.location = (-0.03, -0.12, 0.115)
sc.collection.objects.link(tC)
camC.location = tuple(CAM_LOC)
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


clips = opt("--clips", "off,sleep,auto,turbo,stretch,twitch").split(",")
for mode in ("off", "sleep", "auto", "turbo"):
    if mode in clips:
        render_clip(mode, C.LOOP_FRAMES, lambda f, m=mode: apply(POSES[m], (f - 1) / C.LOOP_FRAMES))
if "stretch" in clips:
    for m1 in ("sleep", "auto", "turbo"):
        def pf(f, m1=m1):
            t = (f - 1) / (STRETCH_N - 1)
            wake = ss(t / 0.55)                       # head lifts, eyes open
            reach = math.sin(math.pi * ss(t / 0.85)) # paws reach out and back
            p = blend_pose(POSES["off"], POSES[m1], wake)
            p["blink"] = False
            apply(p, 0.0, {"stretch": reach})
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
                apply(p, 0.0, {"twitch": math.sin(math.pi * t) if t < 1 else 0.0})
            render_clip(f"{m0}-to-{m1}-twitch", TWITCH_N, pf)
if "--save-blend" in args:
    apply(POSES["auto"], 0.0)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(C.REPO, "Assets", "blender", "cat.blend"), compress=True)
print("ALL DONE", flush=True)
