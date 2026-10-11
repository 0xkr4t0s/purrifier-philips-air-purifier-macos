"""Merge per-slot clip lists into Assets/Animations/manifest.json and write preview.html.

    blender -b --factory-startup -P Tools/blender/make_manifest.py      (or: python3 Tools/blender/make_manifest.py)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import purr_common as C  # noqa: E402

clips = []
for s in ("A", "B", "C", "D"):
    p = os.path.join(C.RENDER_DIR, f"manifest_{s}.json")
    if os.path.exists(p):
        clips += json.load(open(p))
for c in clips:
    for k in ("mov", "webp", "poster"):          # refresh sizes from disk
        c["bytes"][k] = os.path.getsize(os.path.join(C.ANIM_DIR, c[k]))
    c["points"] = list(C.SLOTS[c["slot"]]["pt"])
    c["slot_name"] = C.SLOTS[c["slot"]]["name"]
    c["kind"] = c.get("kind", "loop")
    c["loop"] = bool(c["loop"])
    if c.get("theme") is None:
        c["theme"] = "any"                       # one render that works on light and dark
manifest = {
    "version": 1,
    "fps": C.FPS,
    "scale": 2,
    "slots": {k: {"name": v["name"], "points": list(v["pt"]), "pixels": list(C.slot_px(k))} for k, v in C.SLOTS.items()},
    "air_bands": {"good": "PM2.5 <= 12", "fair": "13-35", "poor": "36-55", "verypoor": "> 55"},
    "ring_colours": C.AQ,
    "notes": [
        "theme 'any' = a single render that reads on both light and dark Liquid Glass.",
        "Transitions (D) start from loop frame 1 of from_mode and end where loop frame 1 of mode begins.",
        "C one-shots: kind 'stretch' plays when the purifier turns on; 'ear-twitch' on a mode change.",
    ],
    "clips": sorted(clips, key=lambda c: (c["slot"], c["kind"], c["name"])),
    "totals": {"clips": len(clips),
               "mov_bytes": sum(c["bytes"]["mov"] for c in clips),
               "webp_bytes": sum(c["bytes"]["webp"] for c in clips),
               "poster_bytes": sum(c["bytes"]["poster"] for c in clips)},
}
os.makedirs(C.ANIM_DIR, exist_ok=True)
with open(os.path.join(C.ANIM_DIR, "manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=1)

HTML = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Purrifier Animations</title>
<style>
:root{--bg:#f3f4f6;--fg:#15171a;--muted:#5d6570;--line:#d9dde3;--chip:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#121417;--fg:#eceef1;--muted:#9aa3ad;--line:#2a2e34;--chip:#1c1f24}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
header{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(12px);border-bottom:1px solid var(--line);padding:14px 16px}
h1{font-size:18px;margin:0 0 8px}.row{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.row b{font-weight:600;color:var(--muted);margin-right:4px;min-width:42px}
button{font:inherit;border:1px solid var(--line);background:var(--chip);color:var(--fg);border-radius:999px;padding:3px 10px;cursor:pointer}
button[aria-pressed=true]{background:var(--fg);color:var(--bg);border-color:var(--fg)}
.meta{color:var(--muted);font-size:12px;margin-top:6px}
main{padding:16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,330px),1fr));gap:16px}
.card{border:1px solid var(--line);border-radius:14px;overflow:hidden;background:var(--chip)}
.stage{display:grid;grid-template-columns:1fr 1fr}
.wall{position:relative;padding:14px 10px;display:flex;justify-content:center;align-items:center;min-height:120px;overflow:hidden}
.wall.light{background:radial-gradient(120% 90% at 10% 0%,#ffd9b8 0,#c7d8ff 45%,#e9f0ff 100%)}
.wall.dark{background:radial-gradient(120% 90% at 90% 0%,#3a2a62 0,#16233d 50%,#0b0f17 100%)}
.glass{border-radius:16px;padding:6px;backdrop-filter:blur(18px) saturate(1.6);-webkit-backdrop-filter:blur(18px) saturate(1.6);box-shadow:inset 0 0 0 1px rgba(255,255,255,.35),0 8px 24px rgba(0,0,0,.12)}
.light .glass{background:rgba(255,255,255,.45)}.dark .glass{background:rgba(30,32,40,.45);box-shadow:inset 0 0 0 1px rgba(255,255,255,.12),0 8px 24px rgba(0,0,0,.4)}
.glass img,.glass video{display:block;width:100%;height:auto}
.blob{position:absolute;border-radius:50%;filter:blur(18px);opacity:.7}
.cap{padding:8px 10px;font-size:12px;display:flex;justify-content:space-between;gap:8px;border-top:1px solid var(--line)}
.cap code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}.cap span{color:var(--muted);white-space:nowrap}
.empty{padding:40px;color:var(--muted)}
</style></head><body>
<header><h1>Purrifier animations · review sheet</h1>
<div class="row" id="f-slot"><b>Slot</b></div>
<div class="row" id="f-kind" style="margin-top:6px"><b>Kind</b></div>
<div class="row" id="f-mode" style="margin-top:6px"><b>Mode</b></div>
<div class="row" id="f-air" style="margin-top:6px"><b>Air</b></div>
<div class="row" style="margin-top:6px"><b>Player</b><button id="fmt" aria-pressed="false">WebP (all browsers)</button></div>
<div class="meta" id="meta"></div></header>
<main id="grid"></main>
<script>
const M = __MANIFEST__;
const state = {slot:"D", kind:"loop", mode:"all", air:"all", mov:false};
const opts = {slot:Object.keys(M.slots), kind:["loop","transition","stretch","ear-twitch"], mode:["all","off","sleep","auto","turbo"], air:["all","good","fair","poor","verypoor"]};
function chips(key){const el=document.getElementById("f-"+key);opts[key].forEach(v=>{const b=document.createElement("button");
 b.textContent = key==="slot" ? v+" · "+M.slots[v].name : v; b.dataset.v=v; b.onclick=()=>{state[key]=v;sync();render();}; el.appendChild(b);});}
function sync(){for(const k of ["slot","kind","mode","air"])document.querySelectorAll("#f-"+k+" button").forEach(b=>b.setAttribute("aria-pressed",b.dataset.v===state[k]));
 const f=document.getElementById("fmt");f.setAttribute("aria-pressed",state.mov);f.textContent=state.mov?"HEVC .mov (Safari)":"WebP (all browsers)";}
document.getElementById("fmt").onclick=()=>{state.mov=!state.mov;sync();render();};
function kb(n){return (n/1024).toFixed(0)+" KB"}
function media(c){if(state.mov){const v=document.createElement("video");v.src=c.mov;v.muted=true;v.autoplay=true;v.loop=c.loop;v.playsInline=true;v.poster=c.poster;return v;}
 const i=document.createElement("img");i.src=c.webp;i.alt=c.name;i.loading="lazy";return i;}
function wall(theme,c){const w=document.createElement("div");w.className="wall "+theme;
 for(let k=0;k<3;k++){const b=document.createElement("div");b.className="blob";const s=60+k*30;Object.assign(b.style,{width:s+"px",height:s+"px",left:(10+k*35)+"%",top:(k*30)+"%",background:theme==="light"?["#ffb4a2","#9ec5ff","#c9f2d0"][k]:["#7b5cff","#1f6feb","#00b3a4"][k]});w.appendChild(b);}
 const g=document.createElement("div");g.className="glass";g.style.width=Math.min(100,c.points[0]/3.4)+"%";g.appendChild(media(c));w.appendChild(g);return w;}
function render(){const grid=document.getElementById("grid");grid.innerHTML="";
 const list=M.clips.filter(c=>c.slot===state.slot&&c.kind===state.kind&&(state.mode==="all"||c.mode===state.mode)&&(state.air==="all"||c.air===state.air||c.air===null));
 // group light/dark variants of the same state into one card
 const groups=new Map();for(const c of list){const key=c.name.replace(/-(light|dark)$/,"");if(!groups.has(key))groups.set(key,{});groups.get(key)[c.theme]=c;}
 for(const [key,g] of groups){const card=document.createElement("div");card.className="card";const st=document.createElement("div");st.className="stage";
  const L=g.light||g.any, D=g.dark||g.any; st.appendChild(wall("light",L)); st.appendChild(wall("dark",D)); card.appendChild(st);
  const cap=document.createElement("div");cap.className="cap";const any=L||D;
  cap.innerHTML="<code>"+key+"</code><span>"+any.frames+" f · "+(any.loop?"loop":"one-shot")+" · "+(g.any?"one render for both themes":"light / dark")+" · "+kb(any.bytes.mov)+"</span>";
  card.appendChild(cap);grid.appendChild(card);}
 if(!groups.size)grid.innerHTML='<div class="empty">No clips for this filter.</div>';
 const t=M.totals;document.getElementById("meta").textContent=M.clips.length+" clips · "+(t.mov_bytes/1048576).toFixed(1)+" MB .mov · "+(t.webp_bytes/1048576).toFixed(1)+" MB .webp · slot "+state.slot+": "+M.slots[state.slot].points.join("×")+" pt @2x";}
["slot","kind","mode","air"].forEach(chips);sync();render();
</script></body></html>
"""
with open(os.path.join(C.ANIM_DIR, "preview.html"), "w") as fh:
    fh.write(HTML.replace("__MANIFEST__", json.dumps(manifest)))
print("manifest:", len(clips), "clips;", manifest["totals"])
