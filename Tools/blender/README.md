# Purrifier animation pipeline (Blender)

Everything here is plain `bpy` run headless on macOS. Reference images live in the
git-ignored `refs/` folder and are never needed to rebuild.

```sh
Tools/blender/render_all.sh                 # model + every layer + every clip (~1.5 h, M4 Pro)
SKIP_RENDER=1 Tools/blender/render_all.sh   # re-composite / re-encode from .render/ only
```

Requirements: Blender 4.2+ (built with 5.2.2), Homebrew `ffmpeg` (for `hevc_videotoolbox`)
and `webp` (`img2webp`). `BLENDER=/path/to/Blender` overrides the app location.

| Script | Does |
|---|---|
| `purr_common.py` | All dimensions (from `refs/NOTES.md`), colours, slot sizes, mode speeds |
| `build_purifier.py` | Builds `Assets/blender/purifier.blend` from scratch. `--no-shadow` drops the contact shadow |
| `render_turnaround.py` | Review stills (`--swatches`, `--closeup`) into `.render/turnaround/` |
| `purr_flow.py` | Airflow streak tubes + scrolling mask shader (seamless by construction) |
| `render_purifier_slot.py` | Slots A and D: one still per ring state + airflow masks per mode |
| `render_particles.py` | Slot B: abstract particles, density = air quality, speed = mode |
| `render_cat.py` | Slot C: "Toon Cat FREE" (Omabuarts Studio, CC BY 4.0) posed and animated in code against the purifier; loops + one-shots |
| `render_cat_simple.py` | Fallback slot C cat built from metaballs (no third-party asset) |
| `fetch_cat_model.sh` | Re-downloads the cat GLB with `SKETCHFAB_API_TOKEN` from `.env` (not needed to rebuild) |
| `make_clips.py` | Composites layers (Blender's Python + numpy), encodes HEVC-alpha `.mov`, `.webp`, poster |
| `make_manifest.py` | `Assets/Animations/manifest.json` + `preview.html` review sheet |
| `check_clips.swift` | Decodes every clip through AVFoundation: size, fps, frames, alpha, loop seam |

## How the loops stay seamless
Every moving thing is a function of `T = (frame - 1) / 120` multiplied by a whole number of
cycles, so frame 121 would be identical to frame 1. `check_clips.swift` confirms it on the
encoded files.

## Model control
`PurifierRoot` carries two custom properties that drive the display through drivers:
`aq_color` (linear RGB) and `display_strength` (0 off; Sleep < Auto < Turbo, see `RING_STRENGTH`).

## Third-party asset
`Assets/blender/third_party/toon-cat/` holds the unmodified GLB of "Toon Cat FREE" by
Omabuarts Studio under CC BY 4.0, with `CREDITS.md`. Keep that credit with the model and in
the app's README / About screen.

## Not modelled, on purpose
No Philips logo, wordmark, badges or display icons anywhere. The renders are of the shape only.
