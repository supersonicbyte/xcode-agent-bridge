#!/usr/bin/env bash
# Builds "Xcode Agent Bridge.app" into ./build.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  copy to ~/Applications and launch
#
# The app is signed with your first "Apple Development" identity (override with
# CODESIGN_IDENTITY). A stable signature keeps the Accessibility permission across
# rebuilds; ad-hoc signing ("-") works but macOS asks again after every build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Xcode Agent Bridge"
APP="build/$APP_NAME.app"

swift build -c "$CONFIGURATION" --product XcodeAgentBridge
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/XcodeAgentBridge" "$APP/Contents/MacOS/XcodeAgentBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc identity})"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    pkill -x XcodeAgentBridge 2>/dev/null || true
    rm -rf "$HOME/Applications/$APP_NAME.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/$APP_NAME.app"
    echo "Installed to ~/Applications and launched."
fi
