#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
python3 scripts/validate-project.py
plutil -lint FirePrivacy.xcodeproj/project.pbxproj Apps/FirePrivacyApp/*.plist \
  Apps/FirePrivacyApp/*.entitlements Apps/FirePrivacyApp/PrivacyInfo.xcprivacy \
  Extensions/*/Info.plist Extensions/*/FirePrivacy.entitlements Extensions/*/PrivacyInfo.xcprivacy
# Privileged targets are engineered and compiled separately; the consumer app
# never embeds them or requests their entitlement merely to make CI compile them.
for edition_scheme in FirePrivacy FirePrivacyURL FirePrivacyManaged; do
  xcodebuild -project FirePrivacy.xcodeproj -scheme "$edition_scheme" -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$FIREPRIVACY_BUILD/GenericSimulator-$edition_scheme" \
    CODE_SIGNING_ALLOWED=NO build
done
