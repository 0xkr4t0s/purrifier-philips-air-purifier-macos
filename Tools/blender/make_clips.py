"""Composite rendered layers into final clips and encode them.

    blender -b --factory-startup -P Tools/blender/make_clips.py -- --slot D [--only loops|transitions] [--limit N] [--preview]

Runs inside Blender's Python (numpy only; no extra packages). For each clip:
composite RGBA frames -> temp PNGs -> HEVC-with-alpha .mov (VideoToolbox),
animated .webp (img2webp) and a -poster.png. Output: Assets/Animations/<slot>/.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import purr_common as C  # noqa: E402

args = C.script_args(sys.argv)


def opt(k, d=None):
    return args[args.index(k) + 1] if k in args else d


SLOT = opt("--slot", "D")
ONLY = opt("--only")
LIMIT = int(opt("--limit", "0"))
PREVIEW = "--preview" in args
MATCH = opt("--match")                       # only clips whose name contains this text
WEBP_Q = opt("--webp-q", "60")
BIN = "/opt/homebrew/bin"
ENV = dict(os.environ, PATH=f"{BIN}:/usr/bin:/bin")
SRC = os.path.join(C.RENDER_DIR, SLOT)
OUT = os.path.join(C.ANIM_DIR, SLOT)

_cache = {}


def load(path):
    """RGBA float array (sRGB-encoded, straight alpha), top row first."""
    if path in _cache:
        return _cache[path]
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    a = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(a)
    bpy.data.images.remove(img)
    a = a.reshape(h, w, 4)[::-1].copy()
    if len(_cache) < 64:
        _cache[path] = a
    return a


def save(a, path):
    h, w = a.shape[:2]
    img = bpy.data.images.new("out", w, h, alpha=True)
    img.alpha_mode = "STRAIGHT"
    img.pixels.foreach_set(np.ascontiguousarray(a[::-1]).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


def hex_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], np.float32)


def over(top, bot):
    """Straight-alpha 'over' (sRGB space, as Core Animation composites)."""
    at, ab = top[..., 3:4], bot[..., 3:4]
    ao = at + ab * (1 - at)
    rgb = np.where(ao > 1e-6, (top[..., :3] * at + bot[..., :3] * ab * (1 - at)) / np.maximum(ao, 1e-6), 0)
    return np.concatenate([rgb, ao], -1)


def tinted(mask_rgba, color, gain=1.0):
    a = np.clip(mask_rgba[..., 3:4] * gain, 0, 1)
    rgb = np.broadcast_to(color, a.shape[:2] + (3,))
    return np.concatenate([rgb, a], -1)


def flow_tint(air, theme):
    if SLOT == "A":
        return hex_rgb(C.NEUTRAL_THEME[theme])
    return hex_rgb(C.AQ_THEME[theme][air])


FLOW_GAIN = {"A": 0.55, "B": 1.0, "D": 1.0}
THEME_GAIN = {"light": 1.0, "dark": 1.25}        # brighter masks read better on dark glass


def body(mode, air):
    return load(os.path.join(SRC, "body", "off.png" if mode == "off" else f"{mode}-{air}.png"))


def flow(mode, f):
    """f is 1-based loop frame; wraps."""
    f = (f - 1) % C.LOOP_FRAMES + 1
    return load(os.path.join(SRC, "flow", mode, f"{f:04d}.png"))


def loop_frame(mode, air, theme, f):
    if SLOT == "B":
        if mode == "off":
            m = load(os.path.join(SRC, "off", "0001.png"))
            return tinted(m, hex_rgb(C.NEUTRAL_THEME[theme]), THEME_GAIN[theme])
        f = (f - 1) % C.LOOP_FRAMES + 1
        m = load(os.path.join(SRC, f"{mode}-{air}", f"{f:04d}.png"))
        return tinted(m, hex_rgb(C.AQ_THEME[theme][air]), THEME_GAIN[theme])
    if SLOT == "C":
        return load(os.path.join(SRC, mode, f"{f:04d}.png"))
    b = body(mode, air)
    if mode == "off":
        return b
    return over(tinted(flow(mode, f), flow_tint(air, theme), FLOW_GAIN[SLOT] * THEME_GAIN[theme]), b)


def ease(t):
    return t * t * (3 - 2 * t)


def transition_frame(m0, m1, air, theme, k, n):
    """Frame k of n: crossfade ring + airflow from loop m0 (from its frame 1) into
    loop m1 so that the clip ends exactly where m1's loop frame 1 begins."""
    t = ease((k + 1) / n)
    b0, b1 = body(m0, air), body(m1, air)
    b = b0 * (1 - t) + b1 * t
    col = flow_tint(air, theme)
    layers = []
    if m0 != "off":
        layers.append(tinted(flow(m0, 1 + k), col, FLOW_GAIN[SLOT] * THEME_GAIN[theme] * (1 - t)))
    if m1 != "off":
        layers.append(tinted(flow(m1, C.LOOP_FRAMES - n + 1 + k), col, FLOW_GAIN[SLOT] * THEME_GAIN[theme] * t))
    for L in layers:
        b = over(L, b)
    return b


def encode(frames_dir, n, out_base, loop=True):
    mov, webp = out_base + ".mov", out_base + ".webp"
    subprocess.run([f"{BIN}/ffmpeg", "-y", "-loglevel", "error", "-framerate", str(C.FPS),
                    "-i", os.path.join(frames_dir, "%04d.png"),
                    "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.75", "-q:v", "55",
                    "-tag:v", "hvc1", "-pix_fmt", "bgra", "-movflags", "+faststart", mov],
                   check=True, env=ENV)
    # Animated WebP: per-frame cwebp with lossy alpha (img2webp keeps alpha lossless, ~3x bigger),
    # assembled with webpmux; frames replace each other (no blending) so soft alpha never accumulates.
    wdir = os.path.join(frames_dir, "webp")
    os.makedirs(wdir, exist_ok=True)
    mux = [f"{BIN}/webpmux"]
    dur = round(1000 / C.FPS)
    for i in range(1, n + 1):
        w = os.path.join(wdir, f"{i:04d}.webp")
        subprocess.run([f"{BIN}/cwebp", "-quiet", "-q", WEBP_Q, "-alpha_q", "50", "-m", "4",
                        os.path.join(frames_dir, f"{i:04d}.png"), "-o", w], check=True, env=ENV)
        mux += ["-frame", w, f"+{dur}+0+0+0-b"]
    mux += ["-loop", "0" if loop else "1", "-o", webp]
    subprocess.run(mux, check=True, env=ENV, capture_output=True)
    return mov, webp


def make_clip(name, frame_fn, n, loop, meta, poster_frame=1):
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=f"purr_{SLOT}_")
    try:
        for i in range(1, n + 1):
            save(frame_fn(i), os.path.join(tmp, f"{i:04d}.png"))
        base = os.path.join(OUT, name)
        if PREVIEW:
            shutil.copy(os.path.join(tmp, f"{poster_frame:04d}.png"), base + "-preview.png")
            return
        mov, webp = encode(tmp, n, base, loop)
        shutil.copy(os.path.join(tmp, f"{poster_frame:04d}.png"), base + "-poster.png")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    meta.update({"name": name, "slot": SLOT, "loop": loop, "frames": n, "fps": C.FPS,
                 "width": C.slot_px(SLOT)[0], "height": C.slot_px(SLOT)[1],
                 "mov": os.path.relpath(mov, C.ANIM_DIR), "webp": os.path.relpath(webp, C.ANIM_DIR),
                 "poster": os.path.relpath(base + "-poster.png", C.ANIM_DIR),
                 "bytes": {"mov": os.path.getsize(mov), "webp": os.path.getsize(webp),
                           "poster": os.path.getsize(base + "-poster.png")}})
    print("clip", name, meta["bytes"], flush=True)


def jobs():
    themes = ("light", "dark")
    js = []

    def lf(m, a, t):
        return lambda i: loop_frame(m, a, t, i)

    if SLOT == "C":
        # the cat reads on both light and dark glass: rendered once per state
        if ONLY in (None, "loops"):
            for m in C.MODES:
                js.append((m, lf(m, None, None), C.LOOP_FRAMES, True,
                           {"mode": m, "air": None, "theme": None, "kind": "loop"}))
        if ONLY in (None, "oneshots", "transitions"):
            src = os.path.join(SRC)
            for d in sorted(os.listdir(src)):
                if "-to-" not in d:
                    continue
                n = len([x for x in os.listdir(os.path.join(src, d)) if x.endswith(".png")])
                m0, rest = d.split("-to-")
                m1, kind = rest.rsplit("-", 1)
                js.append((d, (lambda dd: (lambda i: load(os.path.join(SRC, dd, f"{i:04d}.png"))))(d), n, False,
                           {"mode": m1, "from_mode": m0, "air": None, "theme": None,
                            "kind": "stretch" if kind == "stretch" else "ear-twitch"}))
        return js
    if ONLY in (None, "loops"):
        if SLOT == "B":
            for th in themes:
                js.append((f"off-{th}", lf("off", None, th), C.LOOP_FRAMES, True,
                           {"mode": "off", "air": None, "theme": th, "kind": "loop"}))
        else:
            js.append(("off", lf("off", None, None), C.LOOP_FRAMES, True,
                       {"mode": "off", "air": None, "theme": None, "kind": "loop"}))
        for mode in ("sleep", "auto", "turbo"):
            for air in C.AIRS:
                for th in themes:
                    js.append((f"{mode}-{air}-{th}", lf(mode, air, th), C.LOOP_FRAMES, True,
                               {"mode": mode, "air": air, "theme": th, "kind": "loop"}))
    if SLOT == "D" and ONLY in (None, "transitions"):
        n = C.TRANSITION_FRAMES
        for m0 in C.MODES:
            for m1 in C.MODES:
                if m0 == m1:
                    continue
                for air in C.AIRS:
                    for th in themes:
                        js.append((f"{m0}-to-{m1}-{air}-{th}",
                                   (lambda a0, a1, a, t: (lambda i: transition_frame(a0, a1, a, t, i - 1, n)))(m0, m1, air, th),
                                   n, False, {"mode": m1, "from_mode": m0, "air": air, "theme": th,
                                              "kind": "transition", "into_loop_frame": 1}))
    return js


manifest_part = []
for k, (name, fn, n, loop, meta) in enumerate(j for j in jobs() if not MATCH or MATCH in j[0]):
    if LIMIT and k >= LIMIT:
        break
    make_clip(name, fn, n, loop, meta, poster_frame=1 if loop else n)
    if not PREVIEW:
        manifest_part.append(meta)
if not PREVIEW:
    mp = os.path.join(C.RENDER_DIR, f"manifest_{SLOT}.json")
    if (MATCH or LIMIT) and os.path.exists(mp):
        old = {c["name"]: c for c in json.load(open(mp))}
        old.update({c["name"]: c for c in manifest_part})
        manifest_part = list(old.values())
    with open(mp, "w") as fh:
        json.dump(manifest_part, fh, indent=1)
print("ALL DONE", flush=True)
