"""Render still turnaround views (front, three-quarter, top) for review.

    blender -b Assets/blender/purifier.blend -P Tools/blender/render_turnaround.py -- [--air good] [--mode auto] [--res 1200]
Writes .render/turnaround/<view>.png (RGBA, transparent background).
"""
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import purr_common as C  # noqa: E402
from build_purifier import enable_gpu  # noqa: E402

args = C.script_args(sys.argv)
def opt(k, d):
    return args[args.index(k) + 1] if k in args else d

air, mode, res = opt("--air", "good"), opt("--mode", "auto"), int(opt("--res", "1200"))
sc = bpy.context.scene
enable_gpu()
sc.cycles.device = "GPU"
root = bpy.data.objects["PurifierRoot"]
root["aq_color"] = list(C.hex_to_linear(C.AQ[air]))
root["display_strength"] = C.RING_STRENGTH[mode]
sc.render.resolution_x = sc.render.resolution_y = res
if "--view" in args:
    sc.view_settings.view_transform = opt("--view", "AgX")
    sc.view_settings.look = "None"
    sc.view_settings.exposure = float(opt("--exposure", "0"))
out = os.path.join(C.RENDER_DIR, "turnaround")
os.makedirs(out, exist_ok=True)
VIEWS = () if ("--swatches-only" in args or "--closeup-only" in args) else (("front", "Cam_Front"), ("threequarter", "Cam_ThreeQuarter"), ("top", "Cam_Top"),
                  ("back", "Cam_Front"))
for view, cam in VIEWS:
    camob = bpy.data.objects[cam]
    root.rotation_euler.z = 3.14159265 if view == "back" else 0.0
    sc.camera = camob
    sc.render.filepath = os.path.join(out, f"{view}.png")
    bpy.ops.render.render(write_still=True)
    print("wrote", sc.render.filepath, flush=True)
root.rotation_euler.z = 0.0

# --- ring swatches: display close-up in each air-quality colour at each mode brightness
if "--swatches" in args or "--swatches-only" in args:
    import math
    cd = bpy.data.cameras.new("Cam_Display")
    cd.lens = 100
    cam = bpy.data.objects.new("Cam_Display", cd)
    sc.collection.objects.link(cam)
    tgt = bpy.data.objects.new("Cam_Display_T", None)
    tgt.location = (0, 0, C.H)
    sc.collection.objects.link(tgt)
    cam.location = (0.0, -0.22, C.H + 0.20)
    con = cam.constraints.new("TRACK_TO")
    con.target = tgt
    con.track_axis = "TRACK_NEGATIVE_Z"
    con.up_axis = "UP_Y"
    sc.camera = cam
    sc.render.resolution_x = sc.render.resolution_y = 400
    sc.cycles.samples = 64
    for air in C.AIRS:
        for mode in ("sleep", "auto", "turbo"):
            root["aq_color"] = list(C.hex_to_linear(C.AQ[air]))
            root["display_strength"] = C.RING_STRENGTH[mode]
            sc.render.filepath = os.path.join(out, "swatch", f"{air}-{mode}.png")
            bpy.ops.render.render(write_still=True)
    root["display_strength"] = 0.0
    sc.render.filepath = os.path.join(out, "swatch", "off.png")
    bpy.ops.render.render(write_still=True)
    print("swatches done", flush=True)

# --- close-up of the rounded base and vent slots (compare with refs F_front / A1)
if "--closeup" in args or "--closeup-only" in args:
    for nm, loc, tgt_loc in (("base_side", (0.33, -0.62, 0.17), (0.08, -0.07, 0.03)),
                             ("base_front", (0.0, -0.72, 0.11), (0.0, 0.0, 0.032)),
                             ("seam", (0.30, -0.62, 0.26), (0.03, -0.06, 0.196))):
        cd = bpy.data.cameras.new("Cam_" + nm)
        cd.lens = 85
        cam = bpy.data.objects.new("Cam_" + nm, cd)
        sc.collection.objects.link(cam)
        tgt = bpy.data.objects.new("Cam_T_" + nm, None)
        tgt.location = tgt_loc
        sc.collection.objects.link(tgt)
        cam.location = loc
        con = cam.constraints.new("TRACK_TO")
        con.target = tgt
        con.track_axis = "TRACK_NEGATIVE_Z"
        con.up_axis = "UP_Y"
        sc.camera = cam
        sc.render.resolution_x, sc.render.resolution_y = 1200, 700
        root["display_strength"] = 0.0
        sc.render.filepath = os.path.join(out, f"{nm}.png")
        bpy.ops.render.render(write_still=True)
        print("wrote", sc.render.filepath, flush=True)
