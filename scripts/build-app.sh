#!/bin/bash
# Builds build/PodMouse.app. Pass --universal for an arm64 + x86_64 binary.
# Signs with an Apple Development identity when there is one, so macOS keeps its
# permissions across rebuilds; otherwise ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP=build/PodMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PodMouse" "$APP/Contents/MacOS/PodMouse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/art/airpods.mesh "$APP/Contents/Resources/"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/art/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" Resources/art/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1 || true)"
codesign --force --sign "${IDENTITY:--}" --entitlements Resources/PodMouse.entitlements "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad hoc})"
