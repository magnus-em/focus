#!/bin/bash
# Build FocusPad and install it on every connected iPhone/iPad.
# First time for a new device: plug it in, unlock it, trust this Mac, turn on
# Settings → Privacy & Security → Developer Mode, and open FocusPad.xcodeproj
# in Xcode once so it registers the device with your team.
set -e
if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
cd "$(dirname "$0")/FocusPad"
DD=/tmp/focuspad-dd
xcodegen generate >/dev/null
rm -rf "$DD/Build/Products/Debug-iphoneos/FocusPad.app"
set -o pipefail
xcodebuild -project FocusPad.xcodeproj -scheme FocusPad -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build | grep -E "error:|BUILD" \
    || { echo "Build failed"; exit 1; }
APP="$DD/Build/Products/Debug-iphoneos/FocusPad.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

DEVICES=$(xcrun devicectl list devices --json-output /tmp/focuspad-devices.json >/dev/null 2>&1; python3 -c '
import json
for d in json.load(open("/tmp/focuspad-devices.json"))["result"]["devices"]:
    if d.get("connectionProperties", {}).get("tunnelState") != "unavailable" and d.get("hardwareProperties", {}).get("platform") == "iOS":
        print(d["identifier"])
')
if [ -z "$DEVICES" ]; then
    echo "No connected iPhone/iPad. Plug one in (or same Wi-Fi with wireless debugging) and rerun."
    exit 1
fi
for d in $DEVICES; do
    echo "Installing on $d…"
    xcrun devicectl device install app --device "$d" "$APP"
done
