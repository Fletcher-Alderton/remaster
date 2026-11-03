#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$ROOT_DIR/ios/Music/Music.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DerivedData-Simulator"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Music.app"
BUNDLE_ID="com.fletcher.MusicPrototype"

SIMULATOR_UDID="${SIMULATOR_UDID:-}"
SIMULATOR_SELECTION="$(python3 - "$SIMULATOR_UDID" <<'PY'
import json
import subprocess
import sys

requested_udid = sys.argv[1]

try:
    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        text=True,
    ))["devices"]
except (KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
    print(f"Unable to list available iOS simulators: {error}", file=sys.stderr)
    sys.exit(1)

candidates = []
for runtime, runtime_devices in devices.items():
    if not runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
        continue
    version = runtime.rsplit("iOS-", 1)[1].replace("-", ".")
    version_key = tuple(int(part) for part in version.split(".") if part.isdigit())
    for device in runtime_devices:
        if not device.get("isAvailable", True):
            continue
        if requested_udid and device["udid"] != requested_udid:
            continue
        name = device["name"]
        is_ipod_touch = name.startswith("iPod touch")
        if not name.startswith("iPhone") and not is_ipod_touch:
            continue

        # These device profiles match the iPod touch 6's 320 x 568-point viewport.
        exact_viewport = name in ("iPod touch (7th generation)", "iPhone SE (1st generation)")
        if exact_viewport:
            size_rank = 0
        elif name in ("iPhone SE (2nd generation)", "iPhone SE (3rd generation)", "iPhone 17e", "iPhone 16e") or "mini" in name.lower():
            size_rank = 1
        else:
            size_rank = 2
        candidates.append((size_rank, tuple(-part for part in version_key), name, device["udid"], version, exact_viewport))

if not candidates:
    if requested_udid:
        print(f"Requested simulator is not an available iPhone or iPod touch: {requested_udid}", file=sys.stderr)
    else:
        print("No available iPhone or iPod touch simulators found. Install one in Xcode or set SIMULATOR_UDID.", file=sys.stderr)
    sys.exit(1)

_, _, name, udid, version, exact_viewport = sorted(candidates)[0]
print(f"{udid}\t{version}\t{int(exact_viewport)}\t{name}")
PY
)"
read -r SIMULATOR_UDID IOS_VERSION EXACT_VIEWPORT SIMULATOR_NAME <<< "$SIMULATOR_SELECTION"
printf 'Using simulator: %s (%s, iOS %s)\n' "$SIMULATOR_NAME" "$SIMULATOR_UDID" "$IOS_VERSION"
LAUNCH_ARGUMENTS=()
if [[ "$EXACT_VIEWPORT" != "1" ]]; then
    LAUNCH_ARGUMENTS+=("-ipod-preview")
    printf 'Using a centered 320 x 568-point portrait app window on this simulator.\n'
    printf 'The surrounding device is not an iPod; the app viewport retains the iPod dimensions.\n'
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
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" "${LAUNCH_ARGUMENTS[@]}"
