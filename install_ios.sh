#!/bin/bash
# Build FocusPad and install it on every connected iPhone/iPad.
# First time for a new device: plug it in, unlock it, trust this Mac, turn on
# Settings → Privacy & Security → Developer Mode. Xcode must be signed in
# (Settings → Accounts) so new devices and capabilities get provisioned.
set -e
if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
cd "$(dirname "$0")/FocusPad"
DD=/tmp/focuspad-dd
APP="$DD/Build/Products/Debug-iphoneos/FocusPad.app"
xcodegen generate >/dev/null

# "<coredevice id> <hardware udid>" per reachable iOS device.
DEVICES=$(xcrun devicectl list devices --json-output /tmp/focuspad-devices.json >/dev/null 2>&1; python3 -c '
import json
for d in json.load(open("/tmp/focuspad-devices.json"))["result"]["devices"]:
    if d.get("connectionProperties", {}).get("tunnelState") != "unavailable" and d.get("hardwareProperties", {}).get("platform") == "iOS":
        print(d["identifier"], d["hardwareProperties"]["udid"])
')
if [ -z "$DEVICES" ]; then
    echo "No connected iPhone/iPad. Plug one in (or same Wi-Fi with wireless debugging) and rerun."
    exit 1
fi

set -o pipefail
while read -r id udid; do
    # Building for the specific device is what registers it in the team profile.
    rm -rf "$APP"
    xcodebuild -project FocusPad.xcodeproj -scheme FocusPad -configuration Debug \
        -destination "id=$udid" -derivedDataPath "$DD" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration build | grep -E "error:|BUILD" \
        || { echo "Build failed for $id (locked? unlock it and rerun)"; failed=1; continue; }
    echo "Installing on $id…"
    xcrun devicectl device install app --device "$id" "$APP" || failed=1
done <<< "$DEVICES"
exit ${failed:-0}
