#!/usr/bin/env bash
# Builds an optimised, signed Notchly.app and packages it for sharing:
#
#   dist/Notchly-<version>.zip         the app, zipped the way macOS expects (keeps the signature intact)
#   dist/Notchly-<version>.zip.sha256  checksum, so the recipient can verify the download
#
# The version comes from Resources/Info.plist (CFBundleShortVersionString).
# Signing uses the stable local identity from ./setup-signing.sh: with a fixed signature, the
# recipient's macOS keeps their Accessibility / Calendar / Automation approvals across updates.
# An ad-hoc signature would change every release, so this script refuses to use one.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Notchly Local Signing}"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "error: signing identity \"$IDENTITY\" not found. Run ./setup-signing.sh first." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="build/Notchly.app"
ZIP="dist/Notchly-$VERSION.zip"

echo "Building Notchly $VERSION (release)…"
./build.sh

# Sanity checks on the exact bundle that ships.
codesign --verify --strict "$APP"
[ -x "$APP/Contents/MacOS/Notchly" ] || { echo "error: executable missing from the bundle" >&2; exit 1; }
BUNDLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUNDLED" = "$VERSION" ] || { echo "error: bundle says $BUNDLED, expected $VERSION" >&2; exit 1; }

mkdir -p dist
rm -f "$ZIP" "$ZIP.sha256"
# ditto (not zip) preserves the code signature and extended attributes.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
( cd dist && shasum -a 256 "Notchly-$VERSION.zip" > "Notchly-$VERSION.zip.sha256" )

echo
echo "Release $VERSION ready:"
ls -lh "$ZIP" | awk '{print "  " $9 "  (" $5 ")"}'
echo "  $(cat "$ZIP.sha256")"
echo
echo "Send the zip (AirDrop, or attach it to a GitHub release for tag v$VERSION)."
echo "It is signed with a local certificate and is not notarized, so macOS blocks it on first launch."
echo "The recipient allows it once in System Settings → Privacy & Security → Open Anyway, or by running"
echo "xattr -dr com.apple.quarantine /Applications/Notchly.app. See \"Install a release\" in README.md."
