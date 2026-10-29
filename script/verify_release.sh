#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/VantaShot.app"
PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST"
codesign --verify --deep --strict "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = dev.vantashot.macos
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = 13.0
test -s "$APP/Contents/Resources/AppIcon.icns"
test -x "$APP/Contents/MacOS/VantaShot"
file "$APP/Contents/MacOS/VantaShot"
otool -l "$APP/Contents/MacOS/VantaShot" | sed -n '/LC_BUILD_VERSION/,+5p'
printf '%s\n' 'Bundle verification passed. Runtime and hardware acceptance are separate.'
