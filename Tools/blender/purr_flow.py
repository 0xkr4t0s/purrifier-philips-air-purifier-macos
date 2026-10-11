"""Procedural airflow streaks rising from the purifier outlet.

Static tube geometry + a scrolling emission/alpha shader. Time enters only as
T = (frame - 1) / LOOP_FRAMES multiplied by a whole number of cycles, so frame
LOOP_FRAMES + 1 is identical to frame 1: every loop is seamless by construction.
The render is a white mask; colour is applied when compositing.
"""
import math
import random

import bmesh
import bpy
from mathutils import Vector

import purr_common as C


def _value_driver(node, expr, root=None, prop=None):
    fc = node.outputs[0].driver_add("default_value")
    if root is not None:
        v = fc.driver.variables.new()
        v.name = "p"
        v.targets[0].id = root
        v.targets[0].data_path = f'["{prop}"]'
    fc.driver.expression = expr
    return fc


def build_streaks(name, count=60, seed=7, rise=0.30, radius=(0.0010, 0.0018), spread=0.35,
                  sway=0.012, samples=48, sides=8, start_r=(0.03, C.R_GRILLE * 0.92)):
    """Return a mesh object with one tube per streak.
    UV.x = position along the streak (0 at the outlet, 1 at the top);
    attributes 'seed' (0..1 phase) and 'tier' (0..1, used for density culling)."""
    rnd = random.Random(seed)
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    seed_l = bm.verts.layers.float.new("seed")
    tier_l = bm.verts.layers.float.new("tier")
    for i in range(count):
        a = rnd.uniform(0, 2 * math.pi)
        r0 = math.sqrt(rnd.uniform(start_r[0] ** 2, start_r[1] ** 2))
        p0 = Vector((r0 * math.cos(a), r0 * math.sin(a), C.SLAT_TOP + 0.002))
        out = Vector((math.cos(a), math.sin(a), 0.0))
        h = rise * rnd.uniform(0.75, 1.1)
        rad = rnd.uniform(*radius)
        ph = rnd.uniform(0, 2 * math.pi)
        s_seed, s_tier = rnd.random(), rnd.random()
        pts = []
        for k in range(samples):
            s = k / (samples - 1)
            w = Vector((math.cos(a + 1.3), math.sin(a + 1.3), 0.0))
            p = p0 + out * (spread * r0 * s * s * 1.6) + Vector((0, 0, h * s)) \
                + w * (sway * math.sin(ph + s * 5.0) * s)
            pts.append(p)
        rings = []
        for k, p in enumerate(pts):
            t = (pts[min(k + 1, samples - 1)] - pts[max(k - 1, 0)]).normalized()
            n1 = t.cross(Vector((0, 0, 1)) if abs(t.z) < 0.99 else Vector((1, 0, 0))).normalized()
            n2 = t.cross(n1).normalized()
            taper = math.sin(math.pi * min(1.0, 0.15 + 0.85 * k / (samples - 1))) ** 0.35
            ring = []
            for j in range(sides):
                ang = 2 * math.pi * j / sides
                v = bm.verts.new(p + (n1 * math.cos(ang) + n2 * math.sin(ang)) * rad * max(taper, 0.3))
                v[seed_l] = s_seed
                v[tier_l] = s_tier
                ring.append(v)
            rings.append(ring)
        for k in range(samples - 1):
            for j in range(sides):
                j2 = (j + 1) % sides
                f = bm.faces.new((rings[k][j], rings[k][j2], rings[k + 1][j2], rings[k + 1][j]))
                for loop, (kk, jj) in zip(f.loops, ((k, j), (k, j2), (k + 1, j2), (k + 1, j))):
                    loop[uv].uv = (kk / (samples - 1), jj / sides)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    ob = bpy.data.objects.new(name, me)
    return ob


def flow_material(name, root, dashes=1.0, comet_power=3.0, fade_top=(0.45, 1.0), soft=1.5):
    """White emission mask. Inputs on `root` (custom props):
       flow_cycles (whole cycles per loop), flow_density (0..1), flow_opacity (0..1)."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    N = nt.nodes.new
    L = nt.links.new

    def mth(op, a, b=None):
        n = N("ShaderNodeMath")
        n.operation = op
        for i, v in ((0, a), (1, b)):
            if v is None:
                continue
            if isinstance(v, (int, float)):
                n.inputs[i].default_value = v
            else:
                L(v, n.inputs[i])
        return n.outputs[0]

    def ramp(v, a, b):
        n = N("ShaderNodeMapRange")
        n.interpolation_type = "SMOOTHSTEP"
        L(v, n.inputs["Value"])
        n.inputs["From Min"].default_value, n.inputs["From Max"].default_value = a, b
        return n.outputs["Result"]

    uvn = N("ShaderNodeUVMap")
    sep = N("ShaderNodeSeparateXYZ")
    L(uvn.outputs[0], sep.inputs[0])
    u = sep.outputs[0]
    seed = N("ShaderNodeAttribute")
    seed.attribute_name = "seed"
    tier = N("ShaderNodeAttribute")
    tier.attribute_name = "tier"

    tval = N("ShaderNodeValue")
    tval.name = tval.label = "T"
    _value_driver(tval, f"(frame - 1) / {C.LOOP_FRAMES}")
    cyc = N("ShaderNodeValue")
    cyc.name = "CYCLES"
    _value_driver(cyc, "p", root, "flow_cycles")
    den = N("ShaderNodeValue")
    den.name = "DENSITY"
    _value_driver(den, "p", root, "flow_density")
    opa = N("ShaderNodeValue")
    opa.name = "OPACITY"
    _value_driver(opa, "p", root, "flow_opacity")

    # comet-shaped pulses travelling up the streak
    phase = mth("SUBTRACT", mth("MULTIPLY", u, dashes), mth("MULTIPLY", tval.outputs[0], cyc.outputs[0]))
    phase = mth("ADD", phase, seed.outputs["Fac"])
    x = mth("FRACT", phase)
    comet = mth("MULTIPLY", mth("POWER", x, comet_power), ramp(x, 1.0, 0.9))
    env = mth("MULTIPLY", ramp(u, 0.0, 0.08), ramp(u, fade_top[1], fade_top[0]))
    # density culling per streak
    keep = mth("LESS_THAN", tier.outputs["Fac"], den.outputs[0])
    # soft edges across the tube
    lw = N("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.5
    edge = mth("POWER", mth("SUBTRACT", 1.0, lw.outputs["Facing"]), soft)
    a = mth("MULTIPLY", mth("MULTIPLY", comet, env), mth("MULTIPLY", keep, edge))
    a = mth("MULTIPLY", a, opa.outputs[0])
    a = mth("MINIMUM", a, 1.0)

    em = N("ShaderNodeEmission")
    em.inputs["Color"].default_value = (1, 1, 1, 1)
    em.inputs["Strength"].default_value = 1.0
    tr = N("ShaderNodeBsdfTransparent")
    mix = N("ShaderNodeMixShader")
    L(a, mix.inputs["Fac"])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return m
