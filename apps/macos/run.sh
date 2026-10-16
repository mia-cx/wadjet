#!/bin/bash
# Build, codesign and launch Wadjet.app.
set -euo pipefail
cd "$(dirname "$0")"

# Xcode 27 (beta) toolchain, unless the caller picked another one
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

APP=build/Wadjet.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Wadjet" "$APP/Contents/MacOS/Wadjet"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Apple Development identity keeps the Screen Recording grant across rebuilds;
# ad-hoc works but re-prompts for permissions every build.
IDENTITY="${WADJET_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/"Apple Development/ { print $2; exit }')"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP"

if [[ "${WADJET_NO_OPEN:-0}" == "1" ]]; then
    echo "Built $APP (WADJET_NO_OPEN=1, not launching)"
else
    # a running copy keeps the ⌘⇧ hotkeys, so it must go first
    pkill -x Wadjet 2>/dev/null || true
    pkill -x WadjetPrototype 2>/dev/null || true
    sleep 0.5
    open "$APP"
fi
