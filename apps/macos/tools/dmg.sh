#!/bin/bash
# Build a Release Wadjet.app and wrap it in a DMG for GitHub pre-releases:
# Apple Development-signed, not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

# same build as daily runs: release config, development signing, glass patch
WADJET_NO_OPEN=1 ./run.sh "$@"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Wadjet.app/Contents/Info.plist)
DMG="build/Wadjet-$VERSION.dmg"

# stage: the app plus the classic /Applications symlink
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto build/Wadjet.app "$stage/Wadjet.app"
ln -s /Applications "$stage/Applications"

hdiutil create -volname "Wadjet" -srcfolder "$stage" -ov -format UDZO "$DMG"
echo "$DMG"
shasum -a 256 "$DMG"
