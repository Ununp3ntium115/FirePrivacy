#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
python3 scripts/validate-project.py
plutil -lint FirePrivacy.xcodeproj/project.pbxproj Apps/FirePrivacyApp/Info.plist Apps/FirePrivacyApp/PrivacyInfo.xcprivacy
xcodebuild -project FirePrivacy.xcodeproj -scheme FirePrivacy -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$FIREPRIVACY_BUILD/GenericSimulator" \
  CODE_SIGNING_ALLOWED=NO build
