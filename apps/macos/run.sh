#!/bin/bash
# Build, codesign and launch Wadjet.app.
# Extra arguments go to xcodebuild (e.g. ./run.sh SWIFT_TREAT_WARNINGS_AS_ERRORS=YES).
set -euo pipefail
cd "$(dirname "$0")"

# Xcode 27 (beta) toolchain, unless the caller picked another one
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

APP=build/Wadjet.app

# Apple Development identity keeps the Screen Recording grant across rebuilds;
# ad-hoc works but re-prompts for permissions every build.
IDENTITY="${WADJET_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/"Apple Development/ { print $2; exit }')"
fi
IDENTITY="${IDENTITY:--}"

# the private clear-glass lens patch; WADJET_CLEAR_GLASS=0 builds the store variant without it
CONDITIONS='$(inherited)'
[[ "${WADJET_CLEAR_GLASS:-1}" == "1" ]] && CONDITIONS+=' CLEAR_GLASS_PATCH'

# package products (e.g. KeyboardShortcuts' resource bundle) sign automatically:
# they take the generic "Apple Development" identity plus the team, not a
# specific cert — and a manually-specified cert conflicts with that
if [[ "$IDENTITY" == *"Apple Development"* ]]; then
    # a specific cert conflicts with package targets' automatic signing —
    # the generic name resolves to it anyway when only one is installed
    IDENTITY="Apple Development"
    TEAM_ARG="DEVELOPMENT_TEAM=${WADJET_TEAM:-VJKBGC9AMK}"
else
    TEAM_ARG=""
fi

xcodebuild -project Wadjet.xcodeproj -scheme Wadjet -configuration Release \
    -derivedDataPath build/DerivedData -destination "platform=macOS,arch=$(uname -m)" \
    ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY="$IDENTITY" $TEAM_ARG \
    MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)" \
    CURRENT_PROJECT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" -quiet "$@" build

rm -rf "$APP"
ditto build/DerivedData/Build/Products/Release/Wadjet.app "$APP"

if [[ "${WADJET_NO_OPEN:-0}" == "1" ]]; then
    echo "Built $APP (WADJET_NO_OPEN=1, not launching)"
else
    # a running copy keeps the ⌘⇧ hotkeys, so it must go first
    pkill -x Wadjet 2>/dev/null || true
    pkill -x WadjetPrototype 2>/dev/null || true
    sleep 0.5
    open "$APP"
fi
