"""Shared constants for the Purrifier Blender pipeline.

Dimensions come from refs/NOTES.md (AU leaflet 250 x 250 x 367 mm, sub-dimensions
derived from official product photos, +/-5 mm). All values are metres.
Nothing here (or anywhere in the model) reproduces a logo, wordmark or badge.
"""
import os

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(REPO, "Assets", "blender", "purifier.blend")
RENDER_DIR = os.path.join(REPO, ".render")          # git-ignored intermediates
ANIM_DIR = os.path.join(REPO, "Assets", "Animations")

# --- body -------------------------------------------------------------------
H = 0.367                 # overall height
Z_BASE = 0.027            # top of the grey base ring
Z_SEAM = 0.196            # smooth upper shell / perforated lower shell split
R_AT_BASE = 0.1255        # taper-line radius at Z_BASE (before the roll-under rounds it);
                          # gives the ~250 mm widest point at Z_CURVE
R_TOP = 0.1065            # body radius at the top rim (~213 mm dia)


def body_r(z):
    """Outer radius of the body (one straight taper from floor to rim) at height z."""
    t = (z - Z_BASE) / (H - Z_BASE)
    return R_AT_BASE + (R_TOP - R_AT_BASE) * t


R_SEAM = body_r(Z_SEAM)

# Rounded bottom: the taper turns into an elliptical roll-under that starts in the
# white perforated shell and continues through the grey base to the floor (refs A1/F).
Z_CURVE = 0.030           # where the straight taper starts to round under
ROLL_A = 0.0105           # horizontal inset of the roll-under
ROLL_B = 0.029            # vertical extent (bottom of the roll at z = 0.001)


def outer_rz(phi):
    """Point on the roll-under ellipse; phi = 0 at Z_CURVE (vertical tangent),
    phi = pi/2 at the floor (horizontal tangent). Returns (r, z, nr, nz) with the outward normal."""
    import math
    rc = body_r(Z_CURVE) - ROLL_A
    r = rc + ROLL_A * math.cos(phi)
    z = Z_CURVE - ROLL_B * math.sin(phi)
    nr, nz = ROLL_B * math.cos(phi), -ROLL_A * math.sin(phi)   # gradient of the ellipse
    l = math.hypot(nr, nz)
    return r, z, nr / l, nz / l


def phi_at(z):
    import math
    return math.asin(max(0.0, min(1.0, (Z_CURVE - z) / ROLL_B)))


# Pill-shaped vent slots cut through the grey base
SLOT_COUNT = 90
SLOT_W = 0.0036           # slot width (tangential)
SLOT_TOP_GAP = 0.0050     # smooth grey band between the seam and the slot tops (along the surface)
SLOT_LEN = 0.0200         # slot length along the curved surface
RIM_W = 0.007             # white lip around the outlet grille
R_GRILLE = R_TOP - RIM_W  # outlet opening radius

# --- top / display -------------------------------------------------------------
SLAT_PITCH = 0.0095
SLAT_W = 0.0040
SLAT_H = 0.008
SLAT_TOP = H - 0.0025     # slats sit just below the rim
PUCK_R = 0.0255           # light-grey collar
GLASS_R = 0.0185          # black glass face
RING_R = 0.0102           # air-quality light ring (mid radius)
RING_W = 0.0026

# --- perforation pattern (shader) -------------------------------------------------
HOLE_COLUMNS = 64         # around the circumference
HOLE_PITCH_Z = 0.0086     # row pitch (staggered / hex)
HOLE_R = 0.0023

# --- colours (sRGB hex) -------------------------------------------------------------
BODY_WHITE = "#EEEEEB"
BASE_GREY = "#909396"
GRILLE_GREY = "#9A9A95"
INTERIOR = "#141414"
HOLE_DARK = "#161616"

# Device air-quality ring colours (owner decision: real device colours, 4 bands).
AQ = {
    "good":     "#00A4D3",   # sampled
    "fair":     "#5A63E8",   # estimated blue-purple
    "poor":     "#C2338F",   # estimated purple-red
    "verypoor": "#E7211E",   # sampled
}
# Theme-tuned tints for airflow streaks / particles over Liquid Glass.
AQ_THEME = {
    "light": {"good": "#0086B0", "fair": "#4048C9", "poor": "#A32479", "verypoor": "#C41A17"},
    "dark":  {"good": "#5FCDEB", "fair": "#9AA0F5", "poor": "#E07CBF", "verypoor": "#F47A76"},
}
NEUTRAL_THEME = {"light": "#5B6B78", "dark": "#E6EEF3"}   # used when there is no AQ (e.g. slot A wisps)

MODES = ["off", "sleep", "auto", "turbo"]
AIRS = ["good", "fair", "poor", "verypoor"]
# Ring emission strength per mode (manual: Sleep lowest, Auto mid, Turbo highest)
RING_STRENGTH = {"off": 0.0, "sleep": 0.3, "auto": 0.6, "turbo": 1.0}
# Airflow speed / density multipliers per mode
FLOW = {
    "off":   {"speed": 0.0, "density": 0.0},
    "sleep": {"speed": 0.45, "density": 0.45},
    "auto":  {"speed": 1.0, "density": 0.75},
    "turbo": {"speed": 1.9, "density": 1.0},
}

FPS = 30
LOOP_FRAMES = 120


def hex_to_linear(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def script_args(argv):
    return argv[argv.index("--") + 1:] if "--" in argv else []
