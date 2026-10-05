#!/usr/bin/env bash
# Captures the actual running native app, using its clearly labeled demo report.
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
output="$FIREPRIVACY_BUILD/Screenshots"
mkdir -p "$output"
for family in iphone ipad; do
  device="$(select_simulator "$family")"
  derived="$FIREPRIVACY_BUILD/DerivedData-$family"
  xcodebuild -project FirePrivacy.xcodeproj -scheme FirePrivacy -configuration Debug \
    -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- build
  app="$derived/Build/Products/Debug-iphonesimulator/FirePrivacy.app"
  bundle="$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleIdentifier"])' "$app/Info.plist")"
  xcrun simctl boot "$device" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device" -b
  xcrun simctl status_bar "$device" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
  xcrun simctl install "$device" "$app"
  xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl ui "$device" appearance dark
  xcrun simctl launch "$device" "$bundle" --demo
  # Demo parsing is entirely local; allow the initial layout/animation to settle.
  sleep 3
  xcrun simctl io "$device" screenshot "$output/$family-overview.png"
  xcrun simctl status_bar "$device" clear
done
echo "Native overview screenshots: $output. XCTest result bundles contain additional navigation screenshots."
