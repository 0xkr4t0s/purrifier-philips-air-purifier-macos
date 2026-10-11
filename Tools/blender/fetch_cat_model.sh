#!/bin/sh
# Re-download "Toon Cat FREE" (Omabuarts Studio, CC BY 4.0) from Sketchfab.
# The GLB is already committed under Assets/blender/third_party/toon-cat/, so this is only
# needed to verify or refresh it. Reads SKETCHFAB_API_TOKEN from .env (git-ignored); the
# token is never printed. Needs network access to api.sketchfab.com and
# sketchfab-prod-media.s3.amazonaws.com.
set -e
cd "$(dirname "$0")/../.."
UID_CAT=b2bd1ee7858444bda366110a2d960386
OUT=Assets/blender/third_party/toon-cat/toon_cat_free.glb
TOKEN=$(grep -E '^SKETCHFAB_API_TOKEN=' .env | cut -d= -f2- | tr -d '\r\n ')
[ -n "$TOKEN" ] || { echo "Set SKETCHFAB_API_TOKEN in .env (see .env.example)"; exit 1; }
URL=$(curl -fsS -H "Authorization: Token $TOKEN" "https://api.sketchfab.com/v3/models/$UID_CAT/download" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["glb"]["url"])')
curl -fsS -o "$OUT" "$URL"
echo "saved $OUT ($(wc -c < "$OUT") bytes)"
