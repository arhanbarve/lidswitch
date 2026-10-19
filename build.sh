#!/bin/bash
# Build build/Lidswitch.app, signed with your Apple Development certificate. Run as your normal user.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Lidswitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Lidswitch "$APP/Contents/MacOS/Lidswitch"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # from design/make-icon.sh
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.arhanbarve.lidswitch</string>
    <key>CFBundleName</key><string>Lidswitch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>Lidswitch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocationUsageDescription</key><string>macOS only shows Wi-Fi network names to apps with Location Services. Lidswitch uses that to find your iPhone hotspot and never reads your location.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>macOS only shows Wi-Fi network names to apps with Location Services. Lidswitch uses that to find your iPhone hotspot and never reads your location.</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# A real certificate keeps the app's identity the same across rebuilds, so the saved hotspot
# password (Keychain) and the Location Services grant survive ./update.sh. Ad hoc would work
# but ask again after every build. Override with LIDSWITCH_SIGN="<identity>".
SIGN="${LIDSWITCH_SIGN:-Apple Development}"
if ! security find-identity -v -p codesigning | grep -q "$SIGN"; then
    echo "warning: no \"$SIGN\" certificate; signing ad hoc (hotspot password must be re-entered after each build)" >&2
    SIGN=-
fi
codesign --force --sign "$SIGN" "$APP"
echo "built $APP"
