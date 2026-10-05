#!/usr/bin/env bash
# Uploads a validated signed archive through Apple's authenticated tooling.
# App Store metadata and submission for review are separate App Store Connect steps.
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
: "${BUNDLE_ID:?Set BUNDLE_ID to the registered App Store Connect bundle identifier}"
TEAM_ID="${TEAM_ID:-LYDVWU62G4}"
export BUNDLE_ID TEAM_ID
configure_apple_auth
archive="${1:?Usage: scripts/upload-app-store.sh /path/to/FirePrivacy.xcarchive}"
python3 scripts/release-validation.py verify "$archive"
codesign --verify --deep --strict "$archive/Products/Applications/FirePrivacy.app"
for public_url in "${PRIVACY_POLICY_URL:-}" "${SUPPORT_URL:-}"; do
  if [[ -n "$public_url" ]]; then
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 30 --output /dev/null "$public_url"
  fi
done
if [[ -z "${PRIVACY_POLICY_URL:-}" || -z "${SUPPORT_URL:-}" ]]; then
  echo "Public privacy/support URLs are still pending. This can upload a build; publish and configure those pages before final App Store submission."
fi
export_path="$FIREPRIVACY_BUILD/Upload-$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$export_path"
export FIREPRIVACY_EXPORT_PATH="$export_path"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
options = {"method": "app-store-connect", "destination": "upload", "teamID": os.environ["TEAM_ID"],
           "signingStyle": "automatic", "uploadSymbols": True, "manageAppVersionAndBuildNumber": False}
with (Path(os.environ["FIREPRIVACY_EXPORT_PATH"]) / "ExportOptions.plist").open('wb') as file:
    plistlib.dump(options, file)
PY
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$export_path/ExportOptions.plist" \
  -exportPath "$export_path" -allowProvisioningUpdates "${APPLE_AUTH_ARGS[@]}"
echo "Apple accepted the upload command. Wait for App Store Connect processing, attach screenshots and metadata, then submit the processed build for review."
