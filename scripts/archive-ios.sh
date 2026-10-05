#!/usr/bin/env bash
# Runs meaningful checks and makes a signed archive. Does not upload anything.
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
: "${BUNDLE_ID:?Set BUNDLE_ID to the registered App Store Connect bundle identifier}"
TEAM_ID="${TEAM_ID:-LYDVWU62G4}"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
export BUNDLE_ID TEAM_ID APP_VERSION BUILD_NUMBER
python3 scripts/release-validation.py configuration
configure_apple_auth
python3 scripts/validate-project.py
swift test
bash Tests/PrivacyRegression/no-network-in-local-analysis.sh
bash scripts/test-ios.sh iphone
bash scripts/test-ios.sh ipad
archive="$FIREPRIVACY_BUILD/FirePrivacy-$APP_VERSION-$BUILD_NUMBER-$(date +%Y%m%dT%H%M%S).xcarchive"
xcodebuild -project FirePrivacy.xcodeproj -scheme FirePrivacy -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -derivedDataPath "$FIREPRIVACY_BUILD/ReleaseDerivedData" \
  -allowProvisioningUpdates "${APPLE_AUTH_ARGS[@]}" DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  FIREPRIVACY_PRIVACY_URL="${PRIVACY_POLICY_URL:-}" FIREPRIVACY_SUPPORT_URL="${SUPPORT_URL:-}" archive
codesign --verify --deep --strict "$archive/Products/Applications/FirePrivacy.app"
python3 scripts/release-validation.py stamp "$archive"
printf '%s\n' "$archive" > "$FIREPRIVACY_BUILD/LatestArchive.txt"
echo "Signed and locally validated archive: $archive"
echo "Use scripts/upload-app-store.sh with this archive to upload the build to App Store Connect."
