#!/bin/zsh
# Renders the Mac App Store screenshots (2880×1800) from appstore/screenshots/shot.html, whose images
# come from `SpeechKey --render-pill` (the app's real views with made-up content).
set -e
cd "$(dirname "$0")/../appstore/screenshots"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for n in 1 2 3 4; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=1440,900 \
    --allow-file-access-from-files --screenshot="$PWD/screenshot-$n.png" "file://$PWD/shot.html?n=$n" >/dev/null 2>&1
done
sips -g pixelWidth -g pixelHeight screenshot-*.png | grep -E "pixel" | paste - - | sort -u
