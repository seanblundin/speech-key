#!/bin/zsh
# Builds a notarized, stapled Speech-Key-<version>.dmg in dist/, ready to put on the website.
#
# Needs, once (no secrets live in this repo):
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. Notarization credentials saved in the keychain under the profile name "utter-notary":
#        xcrun notarytool store-credentials utter-notary --apple-id <apple id> --team-id <team id>
#      (it asks for an app-specific password from account.apple.com).
#
# Usage: scripts/release.sh
set -e
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate in the keychain. See the top of this script." >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "Building Speech Key $VERSION, signed by: $IDENTITY"

UTTER_IDENTITY="$IDENTITY" scripts/build-app.sh --no-install
APP="dist/Speech Key.app"
codesign --verify --strict --deep --verbose=2 "$APP"

# A disk image with the app and a shortcut to Applications, the usual drag-to-install layout.
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Speech Key.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Speech-Key-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Speech Key" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# Notarize with a time limit, so a stuck upload can't hang forever (macOS has no `timeout`).
echo "Submitting to Apple's notary service…"
perl -e 'alarm 1800; exec @ARGV' xcrun notarytool submit "$DMG" --keychain-profile utter-notary --wait
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Ready: $DMG"
