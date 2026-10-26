#!/bin/zsh
# Builds the Mac App Store version, signs it for Apple, packages it and uploads it to App Store
# Connect, where it then waits to be added to a version and submitted for review.
#
# Needs, once: `scripts/asc.py setup` (certificates and the provisioning profile) and the App Store
# Connect API key that script describes.
#
# Usage: scripts/release-appstore.sh [--no-upload]
set -e
cd "$(dirname "$0")/.."

APP_ID=$(security find-identity -v -p codesigning | sed -nE 's/.*"((3rd Party Mac Developer Application|Apple Distribution): [^"]+)".*/\1/p' | head -1)
PKG_ID=$(security find-identity -v | sed -nE 's/.*"((3rd Party Mac Developer Installer|Mac Installer Distribution): [^"]+)".*/\1/p' | head -1)
PROFILE=dist/appstore/SpeechKey_MAS.provisionprofile
[[ -n "$APP_ID" && -n "$PKG_ID" && -f "$PROFILE" ]] || { echo "Run scripts/asc.py setup first." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "Building Speech Key $VERSION for the Mac App Store, signed by: $APP_ID"
SPEECHKEY_APPSTORE=1 APPSTORE_PROFILE="$PROFILE" UTTER_IDENTITY="$APP_ID" scripts/build-app.sh
APP="dist/appstore/Speech Key.app"
codesign --verify --strict --deep --verbose=2 "$APP"

PKG="dist/appstore/Speech-Key-$VERSION.pkg"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_ID" "$PKG"
echo "Packaged: $PKG"
[[ "$1" == "--no-upload" ]] && exit 0

source ~/.appstoreconnect/asc.env 2>/dev/null || source ~/.config/speech-key/asc.env 2>/dev/null || true
: ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID}
xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
perl -e 'alarm 1800; exec @ARGV' xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "Uploaded. App Store Connect processes the build for a few minutes before it can be submitted."
