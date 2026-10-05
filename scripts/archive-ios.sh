#!/usr/bin/env bash
# Runs meaningful checks and makes a signed archive. Does not upload anything.
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
configure_bundle_identifiers
TEAM_ID="${TEAM_ID:-LYDVWU62G4}"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
export BUNDLE_ID TEAM_ID APP_VERSION BUILD_NUMBER
python3 scripts/release-validation.py configuration
configure_apple_auth
configure_signing
python3 scripts/validate-project.py
swift test
python3 -m unittest discover -s Tests/CloudRelease -p 'test_*.py'
bash Tests/PrivacyRegression/no-network-in-local-analysis.sh
bash scripts/test-ios.sh iphone
bash scripts/test-ios.sh ipad
archive="$FIREPRIVACY_BUILD/$FIREPRIVACY_SCHEME-$APP_VERSION-$BUILD_NUMBER-$(date +%Y%m%dT%H%M%S)-$$.xcarchive"
archive_args=(-project FirePrivacy.xcodeproj -scheme "$FIREPRIVACY_SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -derivedDataPath "$FIREPRIVACY_BUILD/ReleaseDerivedData" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  APP_BASE_BUNDLE_ID="$APP_BASE_BUNDLE_ID" FIREPRIVACY_APP_GROUP_ID="$FIREPRIVACY_APP_GROUP_ID" \
  MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  FIREPRIVACY_PRIVACY_URL="${PRIVACY_POLICY_URL:-}" FIREPRIVACY_SUPPORT_URL="${SUPPORT_URL:-}")
if [[ "$APP_EDITION" == url-filter ]]; then
  archive_args+=("FIREPRIVACY_PIR_SERVER_URL=${FIREPRIVACY_PIR_SERVER_URL:-}" \
    "FIREPRIVACY_PRIVACY_PASS_ISSUER_URL=${FIREPRIVACY_PRIVACY_PASS_ISSUER_URL:-}" \
    "FIREPRIVACY_PIR_CONFIGURATION_IDENTITY=${FIREPRIVACY_PIR_CONFIGURATION_IDENTITY:-}")
fi
archive_args+=("${APPLE_SIGN_ARGS[@]}")
if [[ "$SIGNING_MODE" == automatic ]]; then archive_args+=(-allowProvisioningUpdates); fi
if [[ -n "${ASC_KEY_PATH:-}" ]]; then archive_args+=("${APPLE_AUTH_ARGS[@]}"); fi
xcodebuild "${archive_args[@]}" archive
codesign --verify --deep --strict "$archive/Products/Applications/$FIREPRIVACY_PRODUCT"
python3 scripts/release-validation.py stamp "$archive"
printf '%s\n' "$archive" > "$FIREPRIVACY_BUILD/LatestArchive.txt"
echo "Signed and locally validated archive: $archive"
echo "Use scripts/upload-app-store.sh with this archive to upload the build to App Store Connect."
