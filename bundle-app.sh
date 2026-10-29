#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release

APP_DIR="dist/VantaShot.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/VantaShot" "$APP_DIR/Contents/MacOS/VantaShot"
chmod +x "$APP_DIR/Contents/MacOS/VantaShot"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>VantaShot</string>
    <key>CFBundleExecutable</key>
    <string>VantaShot</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.vantashot.macos</string>
    <key>CFBundleName</key>
    <string>VantaShot</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.0</string>
    <key>CFBundleVersion</key>
    <string>6</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>يستخدم VantaShot الميكروفون فقط عند اختيار تضمينه في تسجيل الفيديو.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>يحتاج VantaShot إلى إذن التقاط الشاشة لتصوير المناطق والنوافذ وتسجيل الفيديو.</string>
</dict>
</plist>
PLIST

CERT_HASH=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [ -n "${CERT_HASH:-}" ]; then
    codesign --force --deep --sign "$CERT_HASH" "$APP_DIR"
    echo "Signed with Apple Development certificate: $CERT_HASH"
else
    codesign --force --deep --sign - "$APP_DIR"
    echo "Signed with ad-hoc signature"
fi
echo "Built: $(pwd)/$APP_DIR"
