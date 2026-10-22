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

# The update feed. dist/updates keeps every Sparkle-era DMG, so the appcast lists them all;
# generate_appcast signs each with the EdDSA key from the keychain (account "speech-key").
# Release notes: release-notes/<version>.html, shown in Sparkle's update window.
UPD=dist/updates
mkdir -p "$UPD"
cp "$DMG" "$UPD/"
[[ -f "release-notes/$VERSION.html" ]] && cp "release-notes/$VERSION.html" "$UPD/Speech-Key-$VERSION.html"
# generate_keys created the key, so it can read it without a keychain prompt; the copy lives only
# for this command.
# (generate_keys won't export over an existing file, so it gets a fresh path in a private folder.)
KEYDIR=$(mktemp -d -t speechkey-ed)
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account speech-key -x "$KEYDIR/key" >/dev/null
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file "$KEYDIR/key" \
  --download-url-prefix https://speechkeyapp.com/ "$UPD" || { rm -rf "$KEYDIR"; exit 1; }
rm -rf "$KEYDIR"
echo "Ready: $DMG and $UPD/appcast.xml"
echo "To ship: copy both into utter-site/site, point DOWNLOAD_URL and the redirects at the new DMG, and deploy."
