#!/bin/zsh
# Runs `swift` with a toolchain new enough for FluidAudio (Swift 6 and a macOS 15+ SDK).
#
# Order of preference:
# 1. The system's Command Line Tools or Xcode, once they ship Swift 6.
# 2. A swift.org toolchain in ~/Library/Developer/Toolchains plus a macOS 15 SDK in
#    ~/Library/Developer/SDKs (unpacked from Apple's Command Line Tools 16.4 package; no admin needed).
#
# Usage: scripts/swift.sh build -c release
set -e
setopt null_glob

system_major=$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)
system_sdk_major=$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)

if [[ "${system_major:-0}" -ge 6 && "${system_sdk_major:-0}" -ge 15 ]]; then
  exec swift "$1" --disable-keychain "${@:2}"
fi

toolchain=$(ls -d ~/Library/Developer/Toolchains/swift-6*.xctoolchain 2>/dev/null | sort -V | tail -1)
sdk=$(ls -d ~/Library/Developer/SDKs/MacOSX1[5-9]*.sdk ~/Library/Developer/SDKs/MacOSX2*.sdk 2>/dev/null | sort -V | tail -1)
if [[ -z "$toolchain" || -z "$sdk" ]]; then
  echo "Need Swift 6 and a macOS 15+ SDK. Install the Command Line Tools for your macOS, or see NOTES.md." >&2
  exit 1
fi
export SDKROOT="$sdk"
exec "$toolchain/usr/bin/swift" "$1" --disable-keychain "${@:2}"
