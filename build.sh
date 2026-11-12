#!/bin/bash
# Builds CloseQuit.app (Apple silicon / arm64 only) into ./build
# Requires Xcode or the Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="build/CloseQuit.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -target arm64-apple-macos12 main.swift -o "$APP/Contents/MacOS/CloseQuit"

cp Info.plist "$APP/Contents/Info.plist"

echo "Signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "Done: $APP"
echo "Move it to /Applications, open it, and allow it under"
echo "System Settings → Privacy & Security → Accessibility."
