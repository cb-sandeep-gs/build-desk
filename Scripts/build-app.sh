#!/bin/bash
# Builds BuildDesk.app from the SwiftPM executable: ./Scripts/build-app.sh [debug|release] [output-directory]
# Output: <output-directory>/BuildDesk.app, by default .build/BuildDesk.app (ad-hoc signed for local use;
# Scripts/release.sh signs it with a Developer ID elsewhere, so a release never replaces the copy being used).
#
# BUILDDESK_UNIVERSAL=1 builds for both Apple Silicon and Intel. Scripts/release.sh sets it, because a zip sent
# to other people must run on every Mac; a build for this Mac alone leaves it off and is quicker.
set -euo pipefail

CONFIGURATION="${1:-release}"
OUTPUT_DIR="${2:-}"
APP_NAME="BuildDesk"
PRODUCT="BuildDeskApp"
BUNDLE_ID="com.cricbuzz.builddesk"
MIN_MACOS="14.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# One version for the app and the tools, read from the constant the code uses.
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/BuildDeskCore/BuildDeskConstants.swift")"

# A build for this Mac alone follows the host's architecture, which is what `swift build` does on its own.
# (bash 3.2, which macOS ships, treats an empty array as unset under `set -u`, hence the plain string.)
ARCHS=""
[ -z "${BUILDDESK_UNIVERSAL:-}" ] || ARCHS="--arch arm64 --arch x86_64"

cd "$ROOT"
swift build -c "$CONFIGURATION" $ARCHS --product "$PRODUCT"
BIN_DIR="$(swift build -c "$CONFIGURATION" $ARCHS --show-bin-path)"

APP="${OUTPUT_DIR:-$ROOT/.build}/$APP_NAME.app"
rm -rf "$APP"
# Only the binary, the icon and Info.plist go in the bundle: no docs, scripts or fixtures.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Build Desk</string>
  <key>CFBundleDisplayName</key><string>Build Desk</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION, $CONFIGURATION, $(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
