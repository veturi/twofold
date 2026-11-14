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

# Optional version stamping, e.g. VERSION=1.2.0 BUILD=42 (used by the release workflow).
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD:-1}" "$APP/Contents/Info.plist"
fi

# Ad-hoc signature by default; SIGN_IDENTITY="Developer ID Application: …" signs for notarization.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
fi
echo "Built $APP"
