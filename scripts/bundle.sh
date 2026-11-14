#!/bin/bash
# Builds VisDiff and assembles build/VisDiff.app with an ad-hoc signature.
# Usage: scripts/bundle.sh [release|debug]   (UNIVERSAL=1 for arm64 + x86_64)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" --product VisDiff ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP=build/VisDiff.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VisDiff" "$APP/Contents/MacOS/VisDiff"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
