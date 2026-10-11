#!/bin/sh
# Run a Blender pipeline step headless on macOS. Usage: Tools/blender/run.sh <script.py> [blend|-] [-- args]
set -e
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
cd "$(dirname "$0")/../.."
S="$1"; shift
if [ "${1:-}" = "-" ] || [ -z "${1:-}" ]; then [ -n "${1:-}" ] && shift; exec "$BLENDER" -b --factory-startup -P "Tools/blender/$S" "$@"; fi
B="$1"; shift
exec "$BLENDER" -b "$B" -P "Tools/blender/$S" "$@"
