"""Build the AC0850-style purifier model from scratch and save purifier.blend.

    blender -b --factory-startup -P Tools/blender/build_purifier.py -- [--out PATH] [--no-shadow]

Shape, materials and lights only: no text, logos, wordmarks or badges anywhere.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import purr_common as C  # noqa: E402

SEG = 192  # radial segments for lathed parts


# ----------------------------------------------------------------------------- utils
def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.name = "Purrifier"
    sc.unit_settings.system = "METRIC"
    sc.unit_settings.scale_length = 1.0
    return sc


def collection(name, parent=None):
    col = bpy.data.collections.new(name)
    (parent or bpy.context.scene.collection).children.link(col)
    return col


def link(obj, col):
    col.objects.link(obj)
    return obj


def fillet_polyline(pts, radii, steps=6):
    """Round the interior corners of a 2D polyline. radii[i] applies to pts[i]."""
    out = [Vector(pts[0])]
    for i in range(1, len(pts) - 1):
        p0, p1, p2 = Vector(pts[i - 1]), Vector(pts[i]), Vector(pts[i + 1])
        r = radii[i]
        if r <= 0:
            out.append(p1)
            continue
        a = (p0 - p1).normalized()
        b = (p2 - p1).normalized()
        ang = a.angle(b)
        if ang < 1e-3 or abs(ang - math.pi) < 1e-3:
            out.append(p1)
            continue
        d = r / math.tan(ang / 2)
        d = min(d, (p0 - p1).length * 0.49, (p2 - p1).length * 0.49)
        s, e = p1 + a * d, p1 + b * d
        for k in range(steps + 1):  # quadratic Bezier approximates the arc nicely
            t = k / steps
            out.append((1 - t) ** 2 * s + 2 * (1 - t) * t * p1 + t ** 2 * e)
    out.append(Vector(pts[-1]))
    return [(v.x, v.y) for v in out]


def lathe(name, profile, seg=SEG):
    """Revolve a list of (r, z) around Z. A point with r == 0 becomes a single pole
    vertex (triangle fan), so caps close cleanly. Returns a smooth-shaded mesh object."""
    bm = bmesh.new()
    rings = []
    for (r, z) in profile:
        if r <= 1e-9:
            rings.append([bm.verts.new((0.0, 0.0, z))])
            continue
        rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / seg),
                                    r * math.sin(2 * math.pi * i / seg), z)) for i in range(seg)])
    for j in range(len(rings) - 1):
        a, b = rings[j], rings[j + 1]
        for i in range(seg):
            i2 = (i + 1) % seg
            if len(a) == 1 and len(b) == 1:
                continue
            if len(a) == 1:
                bm.faces.new((a[0], b[i2], b[i]))
            elif len(b) == 1:
                bm.faces.new((a[i], a[i2], b[0]))
            else:
                bm.faces.new((a[i], a[i2], b[i2], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    return bpy.data.objects.new(name, me)


def cone_patch(name, width, height, corner, z_center, angle_center, offset, rings=6, arc_steps=6):
    """A rounded-rectangle panel wrapped onto the tapered body surface.
    width is the arc length (m), height in z, corner radius in m."""
    w2, h2 = width / 2, height / 2
    corner = min(corner, w2, h2)
    outline = []
    for cx, cy, a0 in ((w2 - corner, h2 - corner, 0), (-w2 + corner, h2 - corner, 90),
                       (-w2 + corner, -h2 + corner, 180), (w2 - corner, -h2 + corner, 270)):
        for k in range(arc_steps + 1):
            a = math.radians(a0 + 90 * k / arc_steps)
            outline.append((cx + corner * math.cos(a), cy + corner * math.sin(a)))
    bm = bmesh.new()
    grid = []
    for j in range(1, rings + 1):
        f = j / rings
        row = []
        for (s, t) in outline:
            s2, t2 = s * f, t * f
            z = z_center + t2
            r = C.body_r(z) + offset
            a = angle_center + s2 / r
            row.append(bm.verts.new((r * math.cos(a), r * math.sin(a), z)))
        grid.append(row)
    centre = bm.verts.new((0, 0, 0))
    z = z_center
    r = C.body_r(z) + offset
    centre.co = (r * math.cos(angle_center), r * math.sin(angle_center), z)
    n = len(outline)
    for i in range(n):
        bm.faces.new((centre, grid[0][i], grid[0][(i + 1) % n]))
    for j in range(rings - 1):
        for i in range(n):
            i2 = (i + 1) % n
            bm.faces.new((grid[j][i], grid[j + 1][i], grid[j + 1][i2], grid[j][i2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    ob = bpy.data.objects.new(name, me)
    so = ob.modifiers.new("Thickness", "SOLIDIFY")
    so.thickness = 0.0015
    so.offset = -1.0
    so.use_even_offset = True
    bv = ob.modifiers.new("Bevel", "BEVEL")
    bv.width = 0.0006
    bv.segments = 2
    bv.limit_method = "ANGLE"
    return ob


def ensure_outward(ob):
    """Flip a lathed open surface so its normals point away from the Z axis."""
    me = ob.data
    out = 0.0
    for p in me.polygons:
        c = p.center
        out += p.normal.x * c.x + p.normal.y * c.y
    if out < 0:
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
        bm.to_mesh(me)
        bm.free()


def bake_modifiers(ob):
    """Apply all modifiers (no operator context needed)."""
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
    old = ob.data
    ob.modifiers.clear()
    ob.data = me
    bpy.data.meshes.remove(old)


def roll_profile(phi0, phi1, steps):
    return [C.outer_rz(phi0 + (phi1 - phi0) * k / steps)[:2] for k in range(steps + 1)]


def slot_cutters(name):
    """Closed pill-shaped cutters that follow the curved base surface, one per vent slot."""
    import math as m
    # arc-length parameterisation of the roll-under below the seam
    phis = [C.phi_at(C.Z_BASE) + (m.pi / 2 - C.phi_at(C.Z_BASE)) * k / 400 for k in range(401)]
    pts = [C.outer_rz(p) for p in phis]
    acc = [0.0]
    for a, b in zip(pts, pts[1:]):
        acc.append(acc[-1] + m.hypot(b[0] - a[0], b[1] - a[1]))

    def at(sarc):
        for i in range(1, len(acc)):
            if acc[i] >= sarc:
                t = (sarc - acc[i - 1]) / (acc[i] - acc[i - 1])
                return [pts[i - 1][k] + (pts[i][k] - pts[i - 1][k]) * t for k in range(4)]
        return list(pts[-1])

    w, L = C.SLOT_W, C.SLOT_LEN
    s_mid = C.SLOT_TOP_GAP + L / 2
    outline = []
    n_end = 10
    for k in range(n_end + 1):                       # top cap (towards the seam)
        a = m.pi * k / n_end
        outline.append((w / 2 * m.cos(a), -(L / 2 - w / 2) - w / 2 * m.sin(a)))
    for k in range(n_end + 1):                       # bottom cap
        a = m.pi + m.pi * k / n_end
        outline.append((w / 2 * m.cos(a), (L / 2 - w / 2) - w / 2 * m.sin(a)))
    bm = bmesh.new()
    depth = 0.006
    for i in range(C.SLOT_COUNT):
        th = 2 * m.pi * (i + 0.5) / C.SLOT_COUNT
        ring_in, ring_out = [], []
        for (tx, ty) in outline:
            r, z, nr, nz = at(s_mid + ty)
            a = th + tx / r
            base = Vector((r * m.cos(a), r * m.sin(a), z))
            nrm = Vector((nr * m.cos(a), nr * m.sin(a), nz))
            ring_out.append(bm.verts.new(base + nrm * depth * 0.5))
            ring_in.append(bm.verts.new(base - nrm * depth))
        n = len(outline)
        for k in range(n):
            k2 = (k + 1) % n
            bm.faces.new((ring_out[k], ring_out[k2], ring_in[k2], ring_in[k]))
        for ring, rev in ((ring_out, True), (ring_in, False)):
            c = bm.verts.new(sum((v.co for v in ring), Vector()) / n)
            for k in range(n):
                f = (c, ring[k], ring[(k + 1) % n])
                bm.faces.new(tuple(reversed(f)) if rev else f)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return bpy.data.objects.new(name, me)


def box(name, sx, sy, sz, loc):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * sx, v.co.y * sy, v.co.z * sz)) + Vector(loc)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return bpy.data.objects.new(name, me)


def add_bevel(ob, width, segments=3):
    m = ob.modifiers.new("Bevel", "BEVEL")
    m.width = width
    m.segments = segments
    m.limit_method = "ANGLE"
    m.harden_normals = False
    for p in ob.data.polygons:
        p.use_smooth = True
    return m


# ------------------------------------------------------------------------- materials
def new_mat(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    return m, nt, bsdf


def setc(bsdf, hexcol, rough=0.45):
    bsdf.inputs["Base Color"].default_value = (*C.hex_to_linear(hexcol), 1.0)
    bsdf.inputs["Roughness"].default_value = rough


def math_node(nt, op, a=None, b=None, label=None, x=0, y=0):
    n = nt.nodes.new("ShaderNodeMath")
    n.operation = op
    n.location = (x, y)
    if label:
        n.label = label
    for idx, v in ((0, a), (1, b)):
        if v is None:
            continue
        if isinstance(v, (int, float)):
            n.inputs[idx].default_value = v
        else:
            nt.links.new(v, n.inputs[idx])
    return n.outputs[0]


def mat_body():
    m, nt, b = new_mat("Body_WhiteSatin")
    setc(b, C.BODY_WHITE, 0.42)
    b.inputs["Coat Weight"].default_value = 0.08
    b.inputs["Coat Roughness"].default_value = 0.25
    return m


def mat_perforated():
    """White shell with a staggered hole pattern (holes reveal the dark filter)."""
    m, nt, b = new_mat("Body_Perforated")
    setc(b, C.BODY_WHITE, 0.42)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    x, y, z = sep.outputs
    ang = math_node(nt, "ARCTAN2", y, x)
    u = math_node(nt, "MULTIPLY", ang, C.HOLE_COLUMNS / (2 * math.pi))
    z0 = C.Z_BASE + 0.0065
    v = math_node(nt, "DIVIDE", math_node(nt, "SUBTRACT", z, z0), C.HOLE_PITCH_Z)
    row = math_node(nt, "FLOOR", v)
    odd = math_node(nt, "FLOORED_MODULO", row, 2.0)
    u2 = math_node(nt, "ADD", u, math_node(nt, "MULTIPLY", odd, 0.5))
    cell_w = 2 * math.pi * C.R_SEAM / C.HOLE_COLUMNS
    du = math_node(nt, "MULTIPLY", math_node(nt, "SUBTRACT", math_node(nt, "FRACT", u2), 0.5), cell_w)
    dv = math_node(nt, "MULTIPLY", math_node(nt, "SUBTRACT", math_node(nt, "FRACT", v), 0.5), C.HOLE_PITCH_Z)
    d = math_node(nt, "SQRT", math_node(nt, "ADD", math_node(nt, "MULTIPLY", du, du), math_node(nt, "MULTIPLY", dv, dv)))
    # holes shrink over the bottom rows (and a little under the top seam), as in the refs
    def ramp(val, a, b, lo, hi):
        n = nt.nodes.new("ShaderNodeMapRange")
        n.interpolation_type = "SMOOTHSTEP"
        nt.links.new(val, n.inputs["Value"])
        n.inputs["From Min"].default_value, n.inputs["From Max"].default_value = a, b
        n.inputs["To Min"].default_value, n.inputs["To Max"].default_value = lo, hi
        return n.outputs["Result"]
    zt = C.Z_SEAM - 0.0065
    scale = math_node(nt, "MULTIPLY", ramp(z, z0, z0 + 0.032, 0.32, 1.0), ramp(z, zt, zt - 0.02, 0.6, 1.0))
    d = math_node(nt, "DIVIDE", d, scale)
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.interpolation_type = "SMOOTHSTEP"
    nt.links.new(d, mr.inputs["Value"])
    mr.inputs["From Min"].default_value = C.HOLE_R + 0.00025
    mr.inputs["From Max"].default_value = C.HOLE_R - 0.00025
    hole = mr.outputs["Result"]
    # no holes in a margin band at the top and bottom of the perforated shell
    lo = math_node(nt, "GREATER_THAN", z, z0 - 0.0005)
    hi = math_node(nt, "LESS_THAN", z, C.Z_SEAM - 0.0065)
    hole = math_node(nt, "MULTIPLY", hole, math_node(nt, "MULTIPLY", lo, hi))
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    nt.links.new(hole, mix.inputs["Factor"])
    mix.inputs["A"].default_value = (*C.hex_to_linear(C.BODY_WHITE), 1)
    mix.inputs["B"].default_value = (*C.hex_to_linear(C.HOLE_DARK), 1)
    nt.links.new(mix.outputs["Result"], b.inputs["Base Color"])
    rough = math_node(nt, "ADD", 0.42, math_node(nt, "MULTIPLY", hole, 0.45))
    nt.links.new(rough, b.inputs["Roughness"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.8
    bump.inputs["Distance"].default_value = 0.0015
    nt.links.new(math_node(nt, "MULTIPLY", hole, -1.0), bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    b.inputs["Coat Weight"].default_value = 0.08
    return m


def mat_base():
    """Grey base: a smooth band under the seam, then deep vertical vent slots that
    run down and round the roll-under (refs F_front / A1)."""
    m, nt, b = new_mat("Base_GreyVented")
    setc(b, C.BASE_GREY, 0.5)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    x, y, z = sep.outputs
    u = math_node(nt, "MULTIPLY", math_node(nt, "ARCTAN2", y, x), 140 / (2 * math.pi))
    u = math_node(nt, "ADD", u, math_node(nt, "MULTIPLY", z, 0.6 / 0.02))   # slight slant
    f = math_node(nt, "ABSOLUTE", math_node(nt, "SUBTRACT", math_node(nt, "FRACT", u), 0.5))
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.interpolation_type = "SMOOTHSTEP"
    nt.links.new(f, mr.inputs["Value"])
    mr.inputs["From Min"].default_value = 0.25
    mr.inputs["From Max"].default_value = 0.33
    slot = mr.outputs["Result"]                       # 1 inside a slot
    band = nt.nodes.new("ShaderNodeMapRange")          # slots stop ~6 mm under the seam
    band.interpolation_type = "SMOOTHSTEP"
    nt.links.new(z, band.inputs["Value"])
    band.inputs["From Min"].default_value = C.Z_BASE - 0.0055
    band.inputs["From Max"].default_value = C.Z_BASE - 0.0075
    floor = nt.nodes.new("ShaderNodeMapRange")         # and fade out on the underside
    floor.interpolation_type = "SMOOTHSTEP"
    nt.links.new(z, floor.inputs["Value"])
    floor.inputs["From Min"].default_value = 0.0015
    floor.inputs["From Max"].default_value = 0.004
    slot = math_node(nt, "MULTIPLY", slot, math_node(nt, "MULTIPLY", band.outputs["Result"], floor.outputs["Result"]))
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    nt.links.new(slot, mix.inputs["Factor"])
    mix.inputs["A"].default_value = (*C.hex_to_linear(C.BASE_GREY), 1)
    mix.inputs["B"].default_value = (*C.hex_to_linear("#4E5153"), 1)
    nt.links.new(mix.outputs["Result"], b.inputs["Base Color"])
    nt.links.new(math_node(nt, "ADD", 0.5, math_node(nt, "MULTIPLY", slot, 0.35)), b.inputs["Roughness"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 1.0
    bump.inputs["Distance"].default_value = 0.002
    nt.links.new(math_node(nt, "MULTIPLY", slot, -1.0), bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    return m


def mat_simple(name, hexcol, rough, coat=0.0):
    m, nt, b = new_mat(name)
    setc(b, hexcol, rough)
    if coat:
        b.inputs["Coat Weight"].default_value = coat
        b.inputs["Coat Roughness"].default_value = 0.03
    return m


def mat_ring(root):
    """Emissive air-quality ring, driven by root['aq_color'] and root['display_strength']."""
    m, nt, b = new_mat("Display_AQRing")
    rgb = nt.nodes.new("ShaderNodeRGB")
    rgb.name = rgb.label = "AQ_COLOR"
    val = nt.nodes.new("ShaderNodeValue")
    val.name = val.label = "AQ_STRENGTH"
    b.inputs["Roughness"].default_value = 0.2
    dim = nt.nodes.new("ShaderNodeMix")
    dim.data_type = "RGBA"
    dim.inputs["Factor"].default_value = 0.25
    dim.inputs["A"].default_value = (0.008, 0.008, 0.008, 1)
    nt.links.new(rgb.outputs[0], dim.inputs["B"])
    # unlit ring is near-black glass; lit ring tints its own base colour slightly
    lit = nt.nodes.new("ShaderNodeMath")
    lit.operation = "MINIMUM"
    lit.inputs[1].default_value = 1.0
    nt.links.new(val.outputs[0], lit.inputs[0])
    nt.links.new(lit.outputs[0], dim.inputs["Factor"])
    nt.links.new(dim.outputs["Result"], b.inputs["Base Color"])
    nt.links.new(rgb.outputs[0], b.inputs["Emission Color"])
    nt.links.new(val.outputs[0], b.inputs["Emission Strength"])
    # drivers: one colour input + one strength input on the root empty
    for i in range(3):
        fc = rgb.outputs[0].driver_add("default_value", i)
        dv = fc.driver.variables.new()
        dv.name = "c"
        dv.targets[0].id = root
        dv.targets[0].data_path = f'["aq_color"][{i}]'
        fc.driver.expression = "c"
    fc = val.outputs[0].driver_add("default_value")
    dv = fc.driver.variables.new()
    dv.name = "s"
    dv.targets[0].id = root
    dv.targets[0].data_path = '["display_strength"]'
    fc.driver.expression = "s"
    return m


def mat_shadow_catcher():
    m, nt, b = new_mat("ShadowCatcher")
    setc(b, "#FFFFFF", 1.0)
    return m


# ---------------------------------------------------------------------------- build
def build(no_shadow=False):
    sc = reset_scene()
    col_p = collection("Purifier")
    col_l = collection("Lights")
    col_c = collection("Cameras")
    col_s = collection("Stage")

    root = bpy.data.objects.new("PurifierRoot", None)
    root.empty_display_type = "PLAIN_AXES"
    root.empty_display_size = 0.05
    link(root, col_p)
    root["aq_color"] = list(C.hex_to_linear(C.AQ["good"]))
    root.id_properties_ui("aq_color").update(subtype="COLOR", min=0.0, max=1.0,
                                             description="Air-quality ring colour (linear RGB)")
    root["display_strength"] = C.RING_STRENGTH["auto"]
    root.id_properties_ui("display_strength").update(min=0.0, max=50.0,
                                                     description="Ring brightness: 0 off, sleep < auto < turbo")

    M = {
        "body": mat_body(), "perf": mat_perforated(), "base": mat_simple("Base_Grey", C.BASE_GREY, 0.45),
        "grille": mat_simple("Grille_Grey", C.GRILLE_GREY, 0.5),
        "slotwall": mat_simple("Base_SlotWall", "#3C3E40", 0.7),
        "interior": mat_simple("Interior_Dark", C.INTERIOR, 0.8),
        "collar": mat_simple("Display_Collar", "#D5D5D1", 0.4),
        "glass": mat_simple("Display_Glass", "#030303", 0.18, coat=0.6),
        "ring": mat_ring(root),
        "dot": mat_simple("Display_Button", "#2A2A2A", 0.3),
        "panel": mat_simple("Back_SensorPanel", "#E9E9E6", 0.35),
        "panel_dark": mat_simple("Back_Dark", "#3A3A3A", 0.35),
        "pill": mat_simple("Back_Pill", "#D9D9D6", 0.4),
    }

    def add(ob, mat):
        ob.data.materials.append(M[mat])
        link(ob, col_p)
        ob.parent = root
        return ob

    # --- rounded bottom: grey base ring with pill-shaped vent slots --------------
    import math as m
    zb = C.Z_BASE
    ph_seam = C.phi_at(zb)
    # outer surface: fine seam groove at the top, then the roll-under to the floor, then the underside
    base_prof = [(C.outer_rz(ph_seam)[0] - 0.0005, zb)]          # shared crease with the white shell
    base_prof += roll_profile(ph_seam + 0.012, m.pi / 2, 40)
    base_prof += [(C.outer_rz(m.pi / 2)[0] - 0.01, 0.001), (0.0, 0.001)]
    base = lathe("Base", list(reversed(base_prof)))
    ensure_outward(base)
    base.data.materials.append(M["base"])
    base.data.materials.append(M["interior"])
    so = base.modifiers.new("Shell", "SOLIDIFY")
    so.thickness = 0.0022
    so.offset = -1.0
    so.use_even_offset = True
    so.material_offset = 1          # inner faces are dark (seen through the slots)
    so.material_offset_rim = 1
    cutters = slot_cutters("BaseSlotCutters")
    link(cutters, col_p)
    cutters.data.materials.append(M["slotwall"])
    bo = base.modifiers.new("Slots", "BOOLEAN")
    bo.operation = "DIFFERENCE"
    bo.solver = "EXACT"
    bo.object = cutters
    bo.material_mode = "TRANSFER"
    link(base, col_p)
    bake_modifiers(base)
    bpy.data.objects.remove(cutters)
    for p in base.data.polygons:
        p.use_smooth = True
    base.parent = root
    # dark core behind the vents (bottom of the filter / chassis)
    add(lathe("BaseCore", [(0.0, 0.004), (0.097, 0.004), (0.103, 0.010), (0.106, 0.034)], seg=96), "interior")

    # --- perforated lower shell: straight taper above, rounding under below ------
    low_prof = [(C.outer_rz(ph_seam)[0] - 0.0005, zb)]
    low_prof += roll_profile(ph_seam - 0.012, 0.0, 12)
    low_prof += fillet_polyline([(C.body_r(C.Z_CURVE), C.Z_CURVE), (C.body_r(C.Z_CURVE + 0.01), C.Z_CURVE + 0.01),
                                 (C.R_SEAM, C.Z_SEAM - 0.0011), (C.R_SEAM - 0.0006, C.Z_SEAM)],
                                [0, 0, 0.0009, 0])[1:]   # ends in the bottom of the shared seam crease
    add(lathe("ShellLower", low_prof), "perf")

    # --- smooth upper shell, rim and inner wall ---------------------------------
    up_prof = fillet_polyline(
        [(C.R_SEAM - 0.0006, C.Z_SEAM), (C.R_SEAM, C.Z_SEAM + 0.0011),   # starts in the same crease: no gap
         (C.R_TOP, C.H), (C.R_GRILLE, C.H), (C.R_GRILLE, C.H - 0.022)],
        [0, 0.0009, 0.0045, 0.0015, 0])
    add(lathe("ShellUpper", up_prof), "body")

    # dark interior below the grille (fan shroud + hub)
    inner_prof = [(0.0, C.H - 0.024), (C.R_GRILLE - 0.0005, C.H - 0.024), (C.R_GRILLE - 0.0005, C.H - 0.0035)]
    add(lathe("Interior", inner_prof, seg=96), "interior")
    hub = fillet_polyline([(0.0, C.H - 0.016), (0.045, C.H - 0.016), (0.045, C.H - 0.024)], [0, 0.003, 0])
    add(lathe("FanHub", hub, seg=96), "interior")

    # --- outlet grille: parallel slats + a centre spine -------------------------
    n = int((2 * C.R_GRILLE) / C.SLAT_PITCH)
    y0 = -(n - 1) / 2 * C.SLAT_PITCH
    slats = []
    zc = C.SLAT_TOP - C.SLAT_H / 2
    for i in range(n):
        yy = y0 + i * C.SLAT_PITCH
        half = math.sqrt(max(C.R_GRILLE ** 2 - (abs(yy) + C.SLAT_W / 2) ** 2, 0)) - 0.0004
        if half < 0.01:
            continue
        s = box(f"Slat_{i:02d}", 2 * half, C.SLAT_W, C.SLAT_H, (0, yy, zc))
        slats.append(s)
    spine = box("Spine", 0.0042, 2 * C.R_GRILLE - 0.001, C.SLAT_H + 0.001, (0, 0, zc - 0.0005))
    slats.append(spine)
    # join slats into one mesh
    bm = bmesh.new()
    for s in slats:
        bm.from_mesh(s.data)
        bpy.data.meshes.remove(s.data)
    me = bpy.data.meshes.new("Grille")
    bm.to_mesh(me)
    bm.free()
    grille = bpy.data.objects.new("Grille", me)
    # slats run left-right as seen from the front (-Y), spine runs front-to-back (A2 top view)
    add_bevel(grille, 0.0013, 3)
    add(grille, "grille")

    frame = lathe("GrilleFrame", fillet_polyline(
        [(C.R_GRILLE - 0.0045, C.SLAT_TOP - C.SLAT_H), (C.R_GRILLE - 0.0045, C.SLAT_TOP),
         (C.R_GRILLE + 0.0002, C.SLAT_TOP), (C.R_GRILLE + 0.0002, C.SLAT_TOP - C.SLAT_H)], [0, 0.001, 0.0005, 0]))
    add(frame, "grille")

    # --- display puck ------------------------------------------------------------
    zt = C.SLAT_TOP + 0.0025
    collar = fillet_polyline([(0.0, C.H - 0.014), (C.PUCK_R, C.H - 0.014), (C.PUCK_R, zt),
                              (C.GLASS_R + 0.0008, zt), (C.GLASS_R + 0.0008, zt - 0.0005)],
                             [0, 0, 0.0018, 0.0006, 0])
    add(lathe("DisplayCollar", collar, seg=128), "collar")
    glass = fillet_polyline([(0.0, zt + 0.0003), (C.GLASS_R - 0.0012, zt + 0.0003), (C.GLASS_R, zt - 0.0008),
                             (C.GLASS_R + 0.0008, zt - 0.0008)], [0, 0.002, 0, 0])
    add(lathe("DisplayGlass", glass, seg=128), "glass")
    zr = zt + 0.00034
    ring = lathe("AQRing", [(C.RING_R - C.RING_W / 2, zr), (C.RING_R + C.RING_W / 2, zr)], seg=128)
    add(ring, "ring")
    dot = lathe("ModeButtonDot", [(0.0, zr), (0.0016, zr)], seg=48)
    add(dot, "dot")

    # --- back details (+Y is the back; front faces -Y) ---------------------------
    back = math.radians(90)
    add(cone_patch("SensorPanel", 0.070, 0.047, 0.006, C.Z_SEAM + 0.012, back, 0.0008), "panel")
    add(cone_patch("SensorWindow", 0.040, 0.020, 0.002, C.Z_SEAM + 0.012, back, 0.0018), "panel_dark")
    add(cone_patch("PowerPill", 0.019, 0.046, 0.0095, 0.052, back, 0.0008), "pill")
    add(cone_patch("PowerButton", 0.012, 0.012, 0.006, 0.062, back, 0.0018), "panel_dark")
    add(cone_patch("PowerSocket", 0.011, 0.011, 0.0055, 0.041, back, 0.0018), "panel_dark")

    # --- stage: shadow catcher ---------------------------------------------------
    bpy.ops.mesh.primitive_plane_add(size=3.0, location=(0, 0, 0))
    plane = bpy.context.active_object
    plane.name = "ShadowCatcher"
    for c in plane.users_collection:
        c.objects.unlink(plane)
    col_s.objects.link(plane)
    plane.data.materials.append(mat_shadow_catcher())
    plane.is_shadow_catcher = True
    plane.visible_glossy = False
    plane.hide_render = no_shadow
    plane["note"] = "Contact shadow only. Hide in render (or pass --no-shadow) to switch off."

    # --- lights: soft three-light studio ----------------------------------------
    def area(name, loc, energy, size, color=(1, 1, 1), purifier_only=True):
        ld = bpy.data.lights.new(name, "AREA")
        ld.shape = "DISK"
        ld.size = size
        ld.energy = energy
        ld.color = color
        ob = bpy.data.objects.new(name, ld)
        ob.location = loc
        link(ob, col_l)
        con = ob.constraints.new("TRACK_TO")
        con.target = root
        con.track_axis = "TRACK_NEGATIVE_Z"
        con.up_axis = "UP_Y"
        if purifier_only:
            # Light linking: studio lights shade the product but never reach the floor,
            # so the shadow catcher only records the soft overhead contact shadow.
            ob.light_linking.receiver_collection = col_p
        return ob

    area("Key", (-0.75, -0.95, 0.95), 60.0, 0.9, (1.0, 0.985, 0.96))
    area("Fill", (0.95, -0.55, 0.35), 18.0, 1.2, (0.96, 0.98, 1.0))
    area("Rim", (0.45, 0.95, 0.85), 55.0, 0.6)
    area("Top", (0.0, 0.0, 1.1), 14.0, 1.0, purifier_only=False)   # soft contact shadow

    # world: soft neutral fill for reflections (background itself is transparent)
    w = bpy.data.worlds.new("Studio")
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (0.78, 0.8, 0.82, 1)
    bg.inputs["Strength"].default_value = 0.35
    sc.world = w

    # --- cameras (turnaround; animation scripts add their own) -------------------
    def cam(name, loc, lens=85, ortho=None):
        cd = bpy.data.cameras.new(name)
        cd.lens = lens
        cd.sensor_width = 36
        if ortho:
            cd.type = "ORTHO"
            cd.ortho_scale = ortho
        ob = bpy.data.objects.new(name, cd)
        ob.location = loc
        link(ob, col_c)
        tgt = bpy.data.objects.new(name + "_Target", None)
        tgt.location = (0, 0, C.H * 0.5 if "Top" not in name else C.H)
        link(tgt, col_c)
        con = ob.constraints.new("TRACK_TO")
        con.target = tgt
        con.track_axis = "TRACK_NEGATIVE_Z"
        con.up_axis = "UP_Y"
        return ob

    cam("Cam_Front", (0, -1.25, 0.24), lens=70)
    cam("Cam_ThreeQuarter", (0.78, -0.95, 0.66), lens=70)
    cam("Cam_Top", (0, -0.0001, 1.08), lens=70)
    sc.camera = bpy.data.objects["Cam_ThreeQuarter"]

    # --- render settings ----------------------------------------------------------
    sc.render.engine = "CYCLES"
    sc.cycles.device = "GPU"
    sc.cycles.samples = 128
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 6
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.image_settings.color_depth = "8"
    sc.render.fps = C.FPS
    sc.frame_start, sc.frame_end = 1, C.LOOP_FRAMES
    # Khronos PBR Neutral keeps the ring's hue/saturation intact (AgX turned it pastel)
    sc.view_settings.view_transform = "Khronos PBR Neutral"
    sc.view_settings.look = "None"
    sc.view_settings.exposure = -0.55
    sc.render.resolution_x, sc.render.resolution_y = 1200, 1200
    return sc


def enable_gpu():
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for t in ("METAL", "OPTIX", "CUDA", "HIP"):
        try:
            prefs.compute_device_type = t
            prefs.refresh_devices()
            if any(d.type == t for d in prefs.devices):
                for d in prefs.devices:
                    d.use = d.type == t
                return t
        except TypeError:
            continue
    return "CPU"


if __name__ == "__main__":
    args = C.script_args(sys.argv)
    out = C.BLEND_PATH
    if "--out" in args:
        out = args[args.index("--out") + 1]
    build(no_shadow="--no-shadow" in args)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    bpy.context.preferences.filepaths.save_version = 0      # no .blend1 backups
    bpy.ops.wm.save_as_mainfile(filepath=out, compress=True)
    print("saved", out)
