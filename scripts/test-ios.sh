#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
family="${1:-iphone}"
device="$(select_simulator "$family")"
result="$FIREPRIVACY_BUILD/Tests-$family-$(date +%Y%m%dT%H%M%S)-$$.xcresult"
xcodebuild -project FirePrivacy.xcodeproj -scheme FirePrivacy -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -destination-timeout 120 \
  -derivedDataPath "$FIREPRIVACY_BUILD/DerivedData-$family" -resultBundlePath "$result" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
printf '%s\n' "$result" > "$FIREPRIVACY_BUILD/LatestTests-$family.txt"
echo "$family tests passed. Results: $result"
