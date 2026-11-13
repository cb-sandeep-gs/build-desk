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
#   1. Install the team's "Developer ID Application" certificate in the login keychain. Only the team's Account
#      Holder can create one; anyone else sends them a request file made in Keychain Access.
#   2. Save notarization credentials in the keychain, under the name this script looks for by default:
#        xcrun notarytool store-credentials builddesk-notary
#      It asks for an Apple ID on the team, the team id, and an app-specific password from account.apple.com.
#
# Neither step is repeated, and nothing about the team is written into this repository: the signing identity is
# read from the keychain and the notarization credentials stay there too. This script never handles a password.
#
# Set BUILDDESK_SIGN_IDENTITY when the keychain holds more than one Developer ID Application certificate, and
# BUILDDESK_NOTARY_PROFILE when the credentials were saved under another name.

set -euo pipefail

readonly APP_NAME="BuildDesk"
readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly DIST="$ROOT/dist"
# The app is built inside dist, not in .build: a release must never replace the copy someone is running.
readonly STAGE="$DIST/stage"
readonly APP="$STAGE/$APP_NAME.app"
readonly ADHOC_FLAG="--adhoc"
readonly DEFAULT_NOTARY_PROFILE="builddesk-notary"

fail() {
  echo "error: $*" >&2
  exit 1
}

MODE="${1:-}"
[ -z "$MODE" ] || [ "$MODE" = "$ADHOC_FLAG" ] || fail "unknown option $MODE (the only option is $ADHOC_FLAG)"

# The certificate is found in the keychain, so no team name or id is kept in this repository.
readonly DEVELOPER_ID="Developer ID Application:"
installed_identities() {
  security find-identity -v -p codesigning | sed -n "s/.*\"\($DEVELOPER_ID .*\)\"/\1/p"
}

if [ "$MODE" != "$ADHOC_FLAG" ]; then
  IDENTITY="${BUILDDESK_SIGN_IDENTITY:-}"
  PROFILE="${BUILDDESK_NOTARY_PROFILE:-$DEFAULT_NOTARY_PROFILE}"
  if [ -z "$IDENTITY" ]; then
    FOUND="$(installed_identities)"
    COUNT="$(printf '%s' "$FOUND" | grep -c . || true)"
    [ "$COUNT" -ne 0 ] || fail "no \"$DEVELOPER_ID\" certificate in the keychain. See the setup steps at the top of this script, or use $ADHOC_FLAG."
    [ "$COUNT" -eq 1 ] || fail "$COUNT \"$DEVELOPER_ID\" certificates in the keychain. Set BUILDDESK_SIGN_IDENTITY to the one to use."
    IDENTITY="$FOUND"
  else
    installed_identities | grep -qxF "$IDENTITY" || fail "no signing identity named \"$IDENTITY\" in the keychain."
  fi
  # A missing profile is worth saying before a release build, not after it.
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "no notarization credentials named \"$PROFILE\". Run: xcrun notarytool store-credentials $PROFILE"
  echo "Signing as: $IDENTITY"
fi

mkdir -p "$STAGE"
# Everyone's Mac, not just this one: the zip holds both Apple Silicon and Intel code.
BUILDDESK_UNIVERSAL=1 "$ROOT/Scripts/build-app.sh" release "$STAGE"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
# The two kinds of zip never share a name: an ad hoc build must not overwrite, or be taken for, a notarized one.
if [ "$MODE" = "$ADHOC_FLAG" ]; then
  ZIP="$DIST/$APP_NAME-$VERSION-adhoc.zip"
else
  ZIP="$DIST/$APP_NAME-$VERSION.zip"
fi
mkdir -p "$DIST"
rm -f "$ZIP"

# Every zip here is made to be shared, so none may leave a kind of Mac out.
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
for arch in arm64 x86_64; do
  echo "$ARCHS_BUILT" | grep -qw "$arch" \
    || fail "the build is missing $arch; a shared build must run on every Mac (got: $ARCHS_BUILT)."
done

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
rm -rf "$STAGE"

echo "Built $ZIP (Developer ID signed and notarized)."
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "To publish it:"
echo "  gh release create v$VERSION \"$ZIP\" --title \"Build Desk $VERSION\" --notes \"See docs/PLAN.md\""
