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
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
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
    <string>VantaShot uses the microphone only when you choose to include it in a video recording.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>VantaShot needs screen recording permission to capture areas and windows and to record video.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>VantaShot Project</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>dev.vantashot.project</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
                <string>public.data</string>
            </array>
            <key>UTTypeDescription</key>
            <string>VantaShot Project</string>
            <key>UTTypeIdentifier</key>
            <string>dev.vantashot.project</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>vantashot</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Screen Recording permission is tied to the signing identity. Prefer the stable
# Developer ID already used for release so a rebuild does not clear the switch.
# Fall back to Apple Development, then an ad-hoc signature.
CERT_HASH=$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ {print $2; exit}')
SIGN_LABEL="Developer ID Application"
if [ -z "${CERT_HASH:-}" ]; then
    CERT_HASH=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
    SIGN_LABEL="Apple Development"
fi
if [ -n "${CERT_HASH:-}" ]; then
    codesign --force --sign "$CERT_HASH" --options runtime \
        --entitlements Resources/Distribution.entitlements "$APP_DIR"
    echo "Signed with ${SIGN_LABEL}: $CERT_HASH"
else
    codesign --force --deep --sign - "$APP_DIR"
    echo "Signed with ad-hoc signature"
    SIGN_LABEL="ad-hoc"
fi

# macOS keeps old grants under the previous signature. The switch then looks on
# in System Settings, but every check fails. Clear them once after a change.
LAST_SIGN_FILE="dist/.signing-identity"
if [ -f "$LAST_SIGN_FILE" ] && [ "$(cat "$LAST_SIGN_FILE")" != "$SIGN_LABEL" ]; then
    echo "warning: signing identity changed from '$(cat "$LAST_SIGN_FILE")' to '$SIGN_LABEL'."
    echo "warning: run: tccutil reset ScreenCapture dev.vantashot.macos" \
        "&& tccutil reset Accessibility dev.vantashot.macos" \
        "&& tccutil reset ListenEvent dev.vantashot.macos"
fi
echo "$SIGN_LABEL" > "$LAST_SIGN_FILE"
echo "Built: $(pwd)/$APP_DIR"
