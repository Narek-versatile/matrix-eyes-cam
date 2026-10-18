#!/bin/bash
# Downloads Apple's Depth Anything V2 Small (Core ML, Float16, Apache-2.0) into Models/
# and checks it against the published SHA-256 hashes.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage"
DEST="Models/DepthAnythingV2SmallF16.mlpackage"
FILES=(
    "Manifest.json"
    "Data/com.apple.CoreML/model.mlmodel 44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"
    "Data/com.apple.CoreML/weights/weight.bin fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"
)

for entry in "${FILES[@]}"; do
    read -r path sha <<<"$entry"
    mkdir -p "$DEST/$(dirname "$path")"
    echo "Downloading $path"
    curl -sfL -o "$DEST/$path" "$BASE/$path"
    if [ -n "${sha:-}" ]; then
        echo "$sha  $DEST/$path" | shasum -a 256 -c - >/dev/null
    fi
    sha=""
done
echo "Model ready in $DEST"
