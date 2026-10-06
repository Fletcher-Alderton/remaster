#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$ROOT_DIR/ios/Music/Music.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DerivedData-iPhone-SE-iOS-26.5"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Music.app"
BUNDLE_ID="com.fletcher.MusicPrototype"
SIMULATOR_UDID="ACA127D2-7208-41B9-9612-182BF150BA12"
SIMULATOR_NAME="iPhone SE (3rd generation) - small-screen testing"
IOS_VERSION="26.5"

if ! xcrun simctl list devices available | grep -F "$SIMULATOR_UDID" >/dev/null; then
    printf 'Simulator not found: %s (%s, iOS %s)\n' "$SIMULATOR_NAME" "$SIMULATOR_UDID" "$IOS_VERSION" >&2
    printf 'Check that this simulator is installed in Xcode, or update SIMULATOR_UDID in this script.\n' >&2
    exit 1
fi

if ! xcrun simctl list devices booted | grep -F "$SIMULATOR_UDID" >/dev/null; then
    xcrun simctl boot "$SIMULATOR_UDID"
fi
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
open -a Simulator --args -CurrentDeviceUDID "$SIMULATOR_UDID"

xcodebuild \
    -project "$PROJECT" \
    -scheme Music \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID,OS=$IOS_VERSION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID"
