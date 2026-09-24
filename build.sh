#!/bin/bash
# Build build/Lidswitch.app (ad-hoc signed). Run as your normal user.
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
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP"
echo "built $APP"
