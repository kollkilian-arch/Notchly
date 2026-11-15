#!/usr/bin/env bash
# Builds Notchly.app into ./build and signs it.
#
# Signing uses the stable local identity created by ./setup-signing.sh, so macOS keeps your
# Accessibility / Keychain approvals across rebuilds. Without it, it falls back to an ad-hoc
# signature (which changes on every build and makes macOS ask again).
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Notchly Local Signing}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Notchly"
APP="build/Notchly.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchly"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --sign - "$APP"
    echo "warning: signing identity \"$IDENTITY\" not found; used an ad-hoc signature."
    echo "         Run ./setup-signing.sh once so macOS stops re-asking for permissions after each build."
fi
echo "Built $APP"
