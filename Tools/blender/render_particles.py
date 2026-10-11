"""Slot B: abstract airflow particles (no product), rendered as white masks.

    blender -b --factory-startup -P Tools/blender/render_particles.py -- [--modes sleep,auto,turbo] [--airs ...] [--test]

Each particle drifts along its own short wavy path and fades in/out; its phase advances
by a whole number of cycles per loop, so frame 121 == frame 1 (seamless).
Density follows air quality (more particles when air is worse); speed follows the mode.
The bottom-left ~45% of the slot is kept calm for the large PM2.5 number.
Output: .render/B/<mode>-<air>/####.png and .render/B/off/0001.png
"""
import math
import os
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import purr_common as C  # noqa: E402
from build_purifier import enable_gpu  # noqa: E402

args = C.script_args(sys.argv)


def opt(k, d=None):
    return args[args.index(k) + 1] if k in args else d


MODES = opt("--modes", "sleep,auto,turbo").split(",")
AIRS = opt("--airs", ",".join(C.AIRS)).split(",")
TEST = "--test" in args
W, H = C.slot_px("B")
ASPECT = W / H
WORLD_W = 2.0                       # scene units across the slot
WORLD_H = WORLD_W / ASPECT

N = 520                             # max particles (verypoor)
DENSITY = {"good": 0.22, "fair": 0.42, "poor": 0.68, "verypoor": 1.0}
SPEED = {"sleep": 1, "auto": 2, "turbo": 3}          # whole cycles per loop
STRETCH = {"sleep": 0.6, "auto": 1.0, "turbo": 1.8}  # streak length factor
GAIN = {"sleep": 0.6, "auto": 0.85, "turbo": 1.0}

rng = np.random.default_rng(20261012)
P = {
    "x0": rng.uniform(-0.65, 0.35, N) * WORLD_W,      # start x (relative to centre)
    "y0": rng.uniform(-0.62, 0.62, N) * WORLD_H,
    "L": rng.uniform(0.35, 0.75, N) * WORLD_W,        # distance travelled per life
    "rise": rng.uniform(0.02, 0.22, N) * WORLD_H,     # gentle upward drift per life
    "amp": rng.uniform(0.01, 0.05, N) * WORLD_H,      # wave amplitude
    "m": rng.integers(1, 3, N),                       # wave cycles per loop (integer)
    "phi": rng.uniform(0, 1, N),
    "psi": rng.uniform(0, 1, N),
    "size": rng.uniform(0.0022, 0.0055, N) * WORLD_W,
    "bright": rng.uniform(0.6, 1.0, N),
    "tier": rng.uniform(0, 1, N),
}


def calm(x, y):
    """1 inside the calm bottom-left zone (soft edge), 0 elsewhere. x, y in slot fractions 0..1 (y up)."""
    cx, cy, rx, ry = 0.0, 0.0, 0.67, 0.67          # ellipse anchored at the bottom-left corner
    d = np.sqrt((x - cx) ** 2 / rx ** 2 + (y - cy) ** 2 / ry ** 2)
    return np.clip((1.15 - d) / 0.35, 0, 1)


def state(T, mode):
    k = SPEED[mode]
    u = np.mod(k * T + P["phi"], 1.0)                # life phase 0..1
    x = P["x0"] + P["L"] * u
    y = P["y0"] + P["rise"] * u + P["amp"] * np.sin(2 * np.pi * (P["m"] * T + P["psi"]))
    # velocity direction (for streak orientation)
    dx = P["L"] * k
    dy = P["rise"] * k + P["amp"] * 2 * np.pi * P["m"] * np.cos(2 * np.pi * (P["m"] * T + P["psi"]))
    ang = np.arctan2(dy, dx)
    life = np.sin(np.pi * u) ** 0.9
    fx, fy = x / WORLD_W + 0.5, y / WORLD_H + 0.5
    edge = np.clip(np.minimum.reduce([fx, 1 - fx, fy, 1 - fy]) / 0.06, 0, 1)
    alpha = life * edge * (1 - calm(fx, fy)) * P["bright"] * GAIN[mode]
    return x, y, ang, alpha


# --- scene -------------------------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
enable_gpu()
sc.render.engine = "CYCLES"
sc.cycles.device = "GPU"
sc.cycles.samples = 32
sc.cycles.use_denoising = False
sc.cycles.max_bounces = 0
sc.cycles.transparent_max_bounces = 32
sc.render.film_transparent = True
sc.render.resolution_x, sc.render.resolution_y = W, H
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA"
sc.view_settings.view_transform = "Standard"
sc.render.fps = C.FPS

cd = bpy.data.cameras.new("CamB")
cd.type = "ORTHO"
cd.ortho_scale = WORLD_W
cam = bpy.data.objects.new("CamB", cd)
cam.location = (0, 0, 5)
sc.collection.objects.link(cam)
sc.camera = cam

# template: a soft elongated disc (12-gon) in the XY plane, length along +X
SEG = 12
tpl = np.array([[math.cos(2 * math.pi * i / SEG), math.sin(2 * math.pi * i / SEG)] for i in range(SEG)])
me = bpy.data.meshes.new("Particles")
verts, faces = [], []
for i in range(N):
    c = len(verts)
    verts.append((0, 0, 0))
    verts += [(0, 0, 0)] * SEG
    for j in range(SEG):
        faces.append((c, c + 1 + j, c + 1 + (j + 1) % SEG))
me.from_pydata(verts, [], faces)
uvl = me.uv_layers.new(name="UVMap")
luv = np.zeros((len(me.loops), 2), np.float32)
lv = np.empty(len(me.loops), np.int32)
me.loops.foreach_get("vertex_index", lv)
k = lv % (SEG + 1)
rim = k > 0
luv[rim, 0] = tpl[k[rim] - 1, 0]
luv[rim, 1] = tpl[k[rim] - 1, 1]
uvl.data.foreach_set("uv", luv.ravel())
alpha_attr = me.color_attributes.new("pa", "FLOAT_COLOR", "POINT")
ob = bpy.data.objects.new("Particles", me)
sc.collection.objects.link(ob)

mat = bpy.data.materials.new("ParticleMask")
mat.use_nodes = True
nt = mat.node_tree
nt.nodes.clear()
o = nt.nodes.new("ShaderNodeOutputMaterial")
attr = nt.nodes.new("ShaderNodeAttribute")
attr.attribute_name = "pa"
em = nt.nodes.new("ShaderNodeEmission")
tr = nt.nodes.new("ShaderNodeBsdfTransparent")
mix = nt.nodes.new("ShaderNodeMixShader")
sep = nt.nodes.new("ShaderNodeSeparateColor")
nt.links.new(attr.outputs["Color"], sep.inputs[0])
uvn = nt.nodes.new("ShaderNodeUVMap")
vl = nt.nodes.new("ShaderNodeVectorMath")
vl.operation = "LENGTH"
nt.links.new(uvn.outputs[0], vl.inputs[0])
fall = nt.nodes.new("ShaderNodeMapRange")
fall.interpolation_type = "SMOOTHSTEP"
nt.links.new(vl.outputs["Value"], fall.inputs["Value"])
fall.inputs["From Min"].default_value = 1.0
fall.inputs["From Max"].default_value = 0.15
mul = nt.nodes.new("ShaderNodeMath")
mul.operation = "MULTIPLY"
nt.links.new(sep.outputs[0], mul.inputs[0])
nt.links.new(fall.outputs["Result"], mul.inputs[1])
nt.links.new(mul.outputs[0], mix.inputs["Fac"])        # per-particle alpha x radial falloff
nt.links.new(tr.outputs[0], mix.inputs[1])
nt.links.new(em.outputs[0], mix.inputs[2])
nt.links.new(mix.outputs[0], o.inputs["Surface"])
me.materials.append(mat)


def update(T, mode, density, freeze_gain=None):
    x, y, ang, alpha = state(T, mode)
    vis = P["tier"] < density
    alpha = np.where(vis, alpha, 0.0)
    if freeze_gain is not None:
        alpha = alpha * freeze_gain
    L = P["size"] * (1.5 + 4.0 * STRETCH[mode])
    Wd = P["size"]
    co = np.zeros((N, SEG + 1, 3), np.float32)
    ca, sa = np.cos(ang)[:, None], np.sin(ang)[:, None]
    lx = tpl[None, :, 0] * L[:, None]
    ly = tpl[None, :, 1] * Wd[:, None]
    co[:, 1:, 0] = x[:, None] + lx * ca - ly * sa
    co[:, 1:, 1] = y[:, None] + lx * sa + ly * ca
    co[:, 0, 0], co[:, 0, 1] = x, y
    me.vertices.foreach_set("co", co.ravel())
    col = np.zeros((N, SEG + 1, 4), np.float32)
    col[:, :, 0] = alpha[:, None]        # per-particle alpha; radial falloff comes from the UVs
    col[:, :, 3] = 1
    alpha_attr.data.foreach_set("color", col.ravel())
    me.update()


out = os.path.join(C.RENDER_DIR, "B")
frames = [1, 41, 81] if TEST else list(range(1, C.LOOP_FRAMES + 1))
for mode in MODES:
    for air in AIRS:
        d = os.path.join(out, f"{mode}-{air}")
        os.makedirs(d, exist_ok=True)
        for f in frames:
            update((f - 1) / C.LOOP_FRAMES, mode, DENSITY[air])
            sc.render.filepath = os.path.join(d, f"{f:04d}.png")
            bpy.ops.render.render(write_still=True)
        print("B", mode, air, "done", flush=True)
# off: frozen, sparse and faint (no airflow)
update(0.0, "sleep", DENSITY["good"], freeze_gain=0.5)
sc.render.filepath = os.path.join(out, "off", "0001.png")
bpy.ops.render.render(write_still=True)
print("ALL DONE", flush=True)
