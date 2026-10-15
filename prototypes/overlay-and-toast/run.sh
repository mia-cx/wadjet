#!/bin/bash
# Build and run the throwaway overlay + toast prototype (wadjet #12, #13).
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
APP=build/WadjetPrototype.app
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WadjetPrototype "$APP/Contents/MacOS/WadjetPrototype"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>cx.mia.wadjet.prototype</string>
    <key>CFBundleName</key><string>WadjetPrototype</string>
    <key>CFBundleExecutable</key><string>WadjetPrototype</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSScreenCaptureUsageDescription</key><string>The prototype captures a Freeze Frame of the screen.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" "$APP"
open "$APP"
