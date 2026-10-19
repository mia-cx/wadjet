#!/bin/bash
# Check the built extensions without registering them or opening a preview.
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/Wadjet.app
for name in CanvasThumbnail CanvasPreview; do
    extension="$app/Contents/PlugIns/$name.appex"
    plist="$extension/Contents/Info.plist"
    plutil -lint "$plist"
    test "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:QLSupportedContentTypes:0' "$plist")" = cx.mia.wadjet.canvas
    for key in CFBundleShortVersionString CFBundleVersion; do
        test "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")" = "$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")"
    done
    codesign -d --entitlements - --xml "$extension" 2>/dev/null | plutil -extract 'com\.apple\.security\.app-sandbox' raw - | grep -qx true
done
plutil -lint "$app/Contents/Info.plist"
codesign --verify --strict --deep "$app"
