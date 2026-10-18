#!/bin/bash
# Matrix Eyes and Matrix Eyes Cam share one engine (Sources/Engine, Resources/Shaders). It's edited
# here and copied into a Matrix Eyes checkout with this script.
#   scripts/sync-to-matrix-eyes.sh [path to matrix-eyes-macos]     (default: the folder above this repo)
set -euo pipefail
cd "$(dirname "$0")/.."
ME="${1:-..}"
if [ ! -f "$ME/Sources/App/AppDelegate.swift" ]; then
    echo "Not a Matrix Eyes checkout: $ME" >&2
    exit 1
fi
mkdir -p "$ME/Sources/Engine" "$ME/Resources/Shaders"
rsync -a --delete Sources/Engine/ "$ME/Sources/Engine/"
rsync -a --delete --include='*.msl' --exclude='*' Resources/Shaders/ "$ME/Resources/Shaders/"
echo "Shared engine copied into $(cd "$ME" && pwd)"
