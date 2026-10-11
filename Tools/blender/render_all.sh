#!/bin/sh
# Rebuild the model and regenerate every animation asset from scratch (macOS, Blender 4.2+).
#   Tools/blender/render_all.sh            # everything (~1.5 h on an M4 Pro)
#   SKIP_RENDER=1 Tools/blender/render_all.sh   # only re-composite/encode from existing .render/ layers
set -e
cd "$(dirname "$0")/../.."
R=Tools/blender/run.sh
B=Assets/blender/purifier.blend
if [ -z "$SKIP_RENDER" ]; then
  $R build_purifier.py -
  $R render_purifier_slot.py $B -- --slot A --what all
  $R render_purifier_slot.py $B -- --slot D --what all
  $R render_particles.py -
  $R render_cat.py $B
fi
for S in A B C D; do $R make_clips.py - -- --slot $S; done
$R make_manifest.py -
