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

# Licenses that must travel with the app: our credits, then FluidAudio's Apache license and
# every third-party notice it carries (Settings › Licenses opens this file).
NOTICES="$APP/Contents/Resources/Acknowledgements.txt"
FA=.build/checkouts/FluidAudio
{
  cat Resources/Credits.txt
  printf '\n------------------------------------------------------------------------\nFluidAudio (https://github.com/FluidInference/FluidAudio)\n------------------------------------------------------------------------\n\n'
  cat "$FA/LICENSE"
  for f in $(find "$FA/ThirdPartyLicenses" -type f | sort); do
    printf '\n------------------------------------------------------------------------\nFluidAudio third-party notice: %s\n------------------------------------------------------------------------\n\n' "${f#$FA/ThirdPartyLicenses/}"
    cat "$f"
  done
} > "$NOTICES"

# Regenerate with: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# UTTER_IDENTITY overrides the certificate (scripts/release.sh passes the Developer ID one).
# The hardened runtime is always on, so local builds behave like the notarized release.
IDENTITY="${UTTER_IDENTITY:-Local Dictation Dev}"
security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY" || IDENTITY="-"
NESTED_FLAGS=(--force --options runtime)
[[ "$IDENTITY" == Developer\ ID* ]] && NESTED_FLAGS+=(--timestamp)

# Sparkle (website build only) goes in Contents/Frameworks. Speech Key isn't sandboxed, so
# Sparkle's XPC services aren't needed; its pieces are signed inside out, before the app.
SPARKLE=.build/release/Sparkle.framework
if [[ -d "$SPARKLE" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
  codesign "${NESTED_FLAGS[@]}" --sign "$IDENTITY" "$FW/Versions/B/Autoupdate"
  codesign "${NESTED_FLAGS[@]}" --sign "$IDENTITY" "$FW/Versions/B/Updater.app"
  codesign "${NESTED_FLAGS[@]}" --sign "$IDENTITY" "$FW"
fi

# Local builds are signed with a self-signed certificate, which has no team ID, so the hardened
# runtime would refuse to load Sparkle. Only those builds may load it anyway; the Developer ID
# release signs both with the same team, so it keeps full library validation.
ENTITLEMENTS=Resources/Utter.entitlements
if [[ "$IDENTITY" != Developer\ ID* && -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  ENTITLEMENTS=$(mktemp -t speechkey).plist
  cp Resources/Utter.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
codesign "${NESTED_FLAGS[@]}" --entitlements "$ENTITLEMENTS" --identifier com.seanblundin.utter --sign "$IDENTITY" "$APP"
if [[ "$IDENTITY" == "-" ]]; then
  echo "Ad-hoc signed (no \"${UTTER_IDENTITY:-Local Dictation Dev}\" certificate yet). Accessibility will need re-granting after each rebuild."
else
  echo "Signed with \"$IDENTITY\"."
fi

if [[ "$1" != "--no-install" ]]; then
  pkill -x Utter 2>/dev/null || true; pkill -x SpeechKey 2>/dev/null || true; sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/Utter.app ~/Applications/SpeechKey.app "$HOME/Applications/Speech Key.app"   # older names
  ditto "$APP" "$HOME/Applications/Speech Key.app"
  echo "Installed to ~/Applications/Speech Key.app"
fi
