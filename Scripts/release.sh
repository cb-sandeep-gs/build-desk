#!/bin/bash
#
# Builds a copy of Build Desk that other Macs will open: signed with a Developer ID, notarized by
# Apple and zipped. Output: dist/BuildDesk-<version>.zip
#
# Usage:
#   ./Scripts/release.sh                 # needs BUILDDESK_SIGN_IDENTITY and BUILDDESK_NOTARY_PROFILE
#   ./Scripts/release.sh --adhoc         # no Developer ID: a zip for teammates who clear quarantine themselves
#
# One-time setup on the Mac that makes releases:
#   1. Install the team's "Developer ID Application" certificate in the login keychain.
#   2. Save notarization credentials in the keychain under a profile name of your choice:
#        xcrun notarytool store-credentials <profile-name>
#   3. export BUILDDESK_SIGN_IDENTITY="Developer ID Application: <Team Name> (<TEAMID>)"
#      export BUILDDESK_NOTARY_PROFILE=<profile-name>
#
# This script never reads or stores a password; notarytool reads the credentials from the keychain.

set -euo pipefail

readonly APP_NAME="BuildDesk"
readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly APP="$ROOT/.build/$APP_NAME.app"
readonly DIST="$ROOT/dist"
readonly ADHOC_FLAG="--adhoc"

fail() {
  echo "error: $*" >&2
  exit 1
}

MODE="${1:-}"
[ -z "$MODE" ] || [ "$MODE" = "$ADHOC_FLAG" ] || fail "unknown option $MODE (the only option is $ADHOC_FLAG)"

"$ROOT/Scripts/build-app.sh" release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
mkdir -p "$DIST"
rm -f "$ZIP"

# ditto keeps the bundle's signature and extended attributes intact; plain zip does not.
make_zip() {
  ditto -c -k --keepParent "$APP" "$ZIP"
}

if [ "$MODE" = "$ADHOC_FLAG" ]; then
  make_zip
  echo "Built $ZIP (ad-hoc signed, not notarized)."
  echo "On another Mac, macOS will refuse to open it until its quarantine flag is cleared:"
  echo "  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
  exit 0
fi

IDENTITY="${BUILDDESK_SIGN_IDENTITY:-}"
PROFILE="${BUILDDESK_NOTARY_PROFILE:-}"
[ -n "$IDENTITY" ] || fail "BUILDDESK_SIGN_IDENTITY is not set. See the setup steps at the top of this script, or use $ADHOC_FLAG."
[ -n "$PROFILE" ] || fail "BUILDDESK_NOTARY_PROFILE is not set. See the setup steps at the top of this script, or use $ADHOC_FLAG."
security find-identity -v -p codesigning | grep -qF "$IDENTITY" \
  || fail "no signing identity named \"$IDENTITY\" in the keychain."

# The hardened runtime and a secure timestamp are both required for notarization.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

make_zip
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Attach the notarization ticket to the app, so it opens on a Mac that is offline, then zip again
# because the stapled app is what must ship.
xcrun stapler staple "$APP"
rm -f "$ZIP"
make_zip
spctl --assess --type execute --verbose=2 "$APP"

echo "Built $ZIP (Developer ID signed and notarized)."
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "To publish it:"
echo "  gh release create v$VERSION \"$ZIP\" --title \"Build Desk $VERSION\" --notes \"See docs/PLAN.md\""
