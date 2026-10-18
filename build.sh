#!/bin/bash
# Builds "Matrix Eyes Cam.app" (the studio app) next to this script. The virtual camera extension
# needs signing with a developer team; see PLAN.md and scripts/build-signed.sh.
set -euo pipefail
cd "$(dirname "$0")"

APP="Matrix Eyes Cam.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(Sources/Engine/*.swift Sources/Shared/*.swift Sources/main.swift)
[ "${ENGINE_ONLY:-}" = "1" ] || SOURCES+=(Sources/Studio/*.swift)
FLAGS=()
[ "${ENGINE_ONLY:-}" = "1" ] || FLAGS+=(-D STUDIO)

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 ${FLAGS[@]+"${FLAGS[@]}"} "${SOURCES[@]}" \
    -o "$APP/Contents/MacOS/MatrixEyesCam"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Shaders/*.msl Resources/AppIcon.icns "$APP/Contents/Resources/"

# Depth model: fetched into Models/ (or reused from a Matrix Eyes checkout next door), compiled once.
MODEL=Models/DepthAnythingV2SmallF16.mlpackage
if [ ! -d "$MODEL" ]; then
    if [ -d ../Models/DepthAnythingV2SmallF16.mlpackage ]; then
        MODEL=../Models/DepthAnythingV2SmallF16.mlpackage
    else
        scripts/fetch-model.sh
    fi
fi
mkdir -p build
if [ ! -d build/DepthAnythingV2SmallF16.mlmodelc ]; then
    xcrun coremlcompiler compile "$MODEL" build/ >/dev/null
fi
cp -R build/DepthAnythingV2SmallF16.mlmodelc "$APP/Contents/Resources/"

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
