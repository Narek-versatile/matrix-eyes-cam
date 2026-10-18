#!/bin/bash
# Builds Matrix Eyes Cam with the virtual camera extension, signed by your Apple developer team.
#   1. Sign in to Xcode with the developer account (Xcode › Settings › Accounts).
#   2. echo 'DEVELOPMENT_TEAM = ABCDE12345' > Signing.local.xcconfig   (your 10-character Team ID)
#   3. scripts/build-signed.sh            (add INSTALL=1 to copy it into /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' Signing.local.xcconfig 2>/dev/null | tr -d '[:space:]' || true)
if [ -z "$TEAM" ]; then
    echo "No team set. Create Signing.local.xcconfig with:  DEVELOPMENT_TEAM = <your Team ID>" >&2
    exit 1
fi

./build.sh >/dev/null            # also compiles the depth model into build/
xcodegen generate >/dev/null
xcodebuild -project MatrixEyesCam.xcodeproj -scheme MatrixEyesCam -configuration Release \
    -derivedDataPath build/xcode -allowProvisioningUpdates build | grep -E "error:|warning: .*sign|BUILD"

APP="build/xcode/Build/Products/Release/Matrix Eyes Cam.app"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|Authority" | head -3

if [ "${INSTALL:-}" = "1" ]; then
    pkill -f "Matrix Eyes Cam.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "/Applications/Matrix Eyes Cam.app"
    ditto "$APP" "/Applications/Matrix Eyes Cam.app"
    echo "Installed to /Applications. Open it and click “Install virtual camera”, then approve it in System Settings."
else
    echo "Built $APP"
fi
