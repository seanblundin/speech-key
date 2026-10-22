#!/bin/zsh
# Builds Speech Key.app, signs it, and installs it to ~/Applications.
#
# Signing: uses the "Local Dictation Dev" certificate when it exists, so macOS keeps the
# Microphone and Accessibility permissions across rebuilds. Without it the app is ad-hoc
# signed, and macOS forgets Accessibility after every rebuild.
#
# Usage: scripts/build-app.sh [--no-install]
set -e
cd "$(dirname "$0")/.."

scripts/swift.sh build -c release --product SpeechKey

APP="dist/Speech Key.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpeechKey "$APP/Contents/MacOS/SpeechKey"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Regenerate with: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# UTTER_IDENTITY overrides the certificate (scripts/release.sh passes the Developer ID one).
# The hardened runtime is always on, so local builds behave like the notarized release.
IDENTITY="${UTTER_IDENTITY:-Local Dictation Dev}"
SIGN_FLAGS=(--force --options runtime --entitlements Resources/Utter.entitlements --identifier com.seanblundin.utter)
[[ "$IDENTITY" == Developer\ ID* ]] && SIGN_FLAGS+=(--timestamp)
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\"."
else
  codesign "${SIGN_FLAGS[@]}" --sign - "$APP"
  echo "Ad-hoc signed (no \"$IDENTITY\" certificate yet). Accessibility will need re-granting after each rebuild."
fi

if [[ "$1" != "--no-install" ]]; then
  pkill -x Utter 2>/dev/null || true; pkill -x SpeechKey 2>/dev/null || true; sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/Utter.app ~/Applications/SpeechKey.app "$HOME/Applications/Speech Key.app"   # older names
  ditto "$APP" "$HOME/Applications/Speech Key.app"
  echo "Installed to ~/Applications/Speech Key.app"
fi
