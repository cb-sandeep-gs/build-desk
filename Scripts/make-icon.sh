#!/bin/bash
# Renders the app icon from its SwiftUI drawing (AppIconView) and builds Resources/AppIcon.icns.
# Run it after changing the drawing; the .icns is checked in, so building the app does not need this.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t builddesk-icon)"
ICONSET="$WORK/AppIcon.iconset"
MASTER="$WORK/icon-1024.png"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
swift build --product BuildDeskApp
"$(swift build --show-bin-path)/BuildDeskApp" --icon "$MASTER"

# The sizes macOS asks for: each point size at 1x and 2x.
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "Built $ROOT/Resources/AppIcon.icns"
