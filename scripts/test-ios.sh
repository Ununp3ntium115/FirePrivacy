#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
family="${1:-iphone}"
device="$(select_simulator "$family")"
result="$FIREPRIVACY_BUILD/Tests-$family-$(date +%Y%m%dT%H%M%S)-$$.xcresult"
log="$FIREPRIVACY_BUILD/TestLog-$family-$(date +%Y%m%dT%H%M%S)-$$.txt"
set +e
xcodebuild -project FirePrivacy.xcodeproj -scheme FirePrivacy -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -destination-timeout 120 \
  -derivedDataPath "$FIREPRIVACY_BUILD/DerivedData-$family" -resultBundlePath "$result" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- test 2>&1 | tee "$log"
statuses=("${PIPESTATUS[@]}")
set -e
if [[ "${statuses[0]}" -ne 0 ]]; then
  python3 scripts/emit-test-failure.py "$log" "$family"
  exit "${statuses[0]}"
fi
if [[ "${statuses[1]}" -ne 0 ]]; then
  echo "Saving the native test log failed." >&2
  exit "${statuses[1]}"
fi
printf '%s\n' "$result" > "$FIREPRIVACY_BUILD/LatestTests-$family.txt"
echo "$family tests passed. Results: $result"
