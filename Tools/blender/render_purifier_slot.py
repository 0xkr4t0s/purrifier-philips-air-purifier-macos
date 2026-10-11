"""Render the purifier slots (A: native, D: glass remote) as layers.

    blender -b Assets/blender/purifier.blend -P Tools/blender/render_purifier_slot.py -- \
        --slot D --what body|flow|all [--modes sleep,auto,turbo] [--frames 1-120] [--test]

body: one still per ring state (off + mode x air)  -> .render/<slot>/body/<state>.png
flow: 120-frame white airflow mask per mode, purifier as holdout -> .render/<slot>/flow/<mode>/####.png
Colour, theme and the final clips are made by compose.py.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import purr_common as C  # noqa: E402
import purr_flow as F  # noqa: E402
from build_purifier import enable_gpu  # noqa: E402

args = C.script_args(sys.argv)


def opt(k, d=None):
    return args[args.index(k) + 1] if k in args else d


SLOT = opt("--slot", "D")
WHAT = opt("--what", "all")
MODES = opt("--modes", "sleep,auto,turbo").split(",")
FR = [int(x) for x in opt("--frames", f"1-{C.LOOP_FRAMES}").split("-")]
TEST = "--test" in args

# Per-slot framing and airflow style
CFG = {
    "D": {  # hero, centred, crisp streaks coloured by air quality
        "cam": {"loc": (0.0, -1.70, 0.98), "target": (0.0, 0.0, 0.31), "lens": 50},
        "obj_offset": (0.0, 0.0, 0.0), "obj_rot": 0.0,
        "flow": {"count": 22, "rise": 0.27, "radius": (0.0015, 0.0026), "spread": 0.95, "sway": 0.030,
                 "dashes": 1.15, "comet_power": 2.2, "fade_top": (0.35, 0.95), "soft": 1.0, "seed": 11,
                 "start_r": (0.05, 0.095)},
    },
    "A": {  # product shot, three-quarter, to one side; soft gentle wisps
        "cam": {"loc": (1.04, -1.83, 0.845), "target": (-0.15, -0.08, 0.24), "lens": 50},
        "obj_offset": (0.0, 0.0, 0.0), "obj_rot": math.radians(-20),
        "flow": {"count": 14, "rise": 0.20, "radius": (0.0035, 0.0065), "spread": 0.70, "sway": 0.022,
                 "dashes": 0.8, "comet_power": 1.6, "fade_top": (0.25, 1.0), "soft": 2.5, "seed": 5,
                 "start_r": (0.04, 0.09), "samples": 64},
    },
}[SLOT]

sc = bpy.context.scene
enable_gpu()
sc.cycles.device = "GPU"
W, H = C.slot_px(SLOT)
sc.render.resolution_x, sc.render.resolution_y = W, H
sc.render.resolution_percentage = 100
root = bpy.data.objects["PurifierRoot"]
root.location = CFG["obj_offset"]
root.rotation_euler.z = CFG["obj_rot"]

# camera
cd = bpy.data.cameras.new(f"Cam_{SLOT}")
cd.lens = CFG["cam"]["lens"]
cam = bpy.data.objects.new(f"Cam_{SLOT}", cd)
sc.collection.objects.link(cam)
tgt = bpy.data.objects.new(f"Cam_{SLOT}_T", None)
tgt.location = CFG["cam"]["target"]
sc.collection.objects.link(tgt)
cam.location = CFG["cam"]["loc"]
con = cam.constraints.new("TRACK_TO")
con.target = tgt
con.track_axis = "TRACK_NEGATIVE_Z"
con.up_axis = "UP_Y"
sc.camera = cam

# airflow
fc = CFG["flow"]
for k, v in (("flow_cycles", 2.0), ("flow_density", 1.0), ("flow_opacity", 1.0)):
    root[k] = v
flow = F.build_streaks(f"Flow_{SLOT}", count=fc["count"], seed=fc["seed"], rise=fc["rise"],
                       radius=fc["radius"], spread=fc["spread"], sway=fc["sway"],
                       start_r=fc.get("start_r", (0.03, C.R_GRILLE * 0.92)))
flow.data.materials.append(F.flow_material(f"FlowMask_{SLOT}", root, dashes=fc["dashes"],
                                           comet_power=fc["comet_power"], fade_top=fc["fade_top"],
                                           soft=fc["soft"]))
fcol = bpy.data.collections.new("Flow")
sc.collection.children.link(fcol)
fcol.objects.link(flow)
flow.parent = root

purifier_objs = [o for o in bpy.data.collections["Purifier"].all_objects if o.type == "MESH"]
catcher = bpy.data.objects["ShadowCatcher"]
base = os.path.join(C.RENDER_DIR, SLOT)


def render_to(path):
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def body_pass():
    flow.hide_render = True
    catcher.hide_render = False
    for o in purifier_objs:
        o.is_holdout = False
    sc.cycles.samples = 64 if TEST else 256
    sc.cycles.use_denoising = True
    states = [("off", None)] + [(m, a) for m in ("sleep", "auto", "turbo") for a in C.AIRS]
    if TEST:
        states = [("auto", "good")]
    for mode, air in states:
        root["aq_color"] = list(C.hex_to_linear(C.AQ[air or "good"]))
        root["display_strength"] = C.RING_STRENGTH[mode]
        name = "off" if mode == "off" else f"{mode}-{air}"
        render_to(os.path.join(base, "body", f"{name}.png"))
        print("body", name, flush=True)


def flow_pass():
    flow.hide_render = False
    catcher.hide_render = True
    for o in purifier_objs:
        o.is_holdout = True          # occludes the streaks but renders transparent
    sc.cycles.samples = fc.get("samples", 24)
    sc.cycles.use_denoising = False
    sc.cycles.transparent_max_bounces = 64
    sc.cycles.max_bounces = 2
    for mode in MODES:
        root["flow_cycles"] = float(C.FLOW_CYCLES[mode])
        root["flow_density"] = C.FLOW_DENSITY[mode]
        root["flow_opacity"] = C.FLOW_OPACITY[mode]
        frames = [1, 31, 61] if TEST else range(FR[0], FR[1] + 1)
        for f in frames:
            sc.frame_set(f)
            render_to(os.path.join(base, "flow", mode, f"{f:04d}.png"))
        print("flow", mode, "done", flush=True)


if WHAT in ("body", "all"):
    body_pass()
if WHAT in ("flow", "all"):
    flow_pass()
print("ALL DONE", flush=True)
