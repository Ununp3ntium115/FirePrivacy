#!/usr/bin/env bash
# Export an IPA or upload a validated signed archive through Apple tooling.
# Final App Store metadata and submission for review are separate ASC steps.
set -euo pipefail
source "$(dirname "$0")/apple-common.sh"
cd "$FIREPRIVACY_ROOT"
require_apple_toolchain
configure_bundle_identifiers
TEAM_ID="${TEAM_ID:-LYDVWU62G4}"
export BUNDLE_ID TEAM_ID
configure_apple_auth
configure_signing
archive="${1:?Usage: scripts/export-app-store.sh /path/to/FirePrivacy.xcarchive [export|upload]}"
destination="${2:-export}"
if [[ "$destination" != export && "$destination" != upload ]]; then
  echo "Destination must be export or upload." >&2
  exit 1
fi
python3 scripts/release-validation.py verify "$archive"
codesign --verify --deep --strict "$archive/Products/Applications/$FIREPRIVACY_PRODUCT"
for public_url in "${PRIVACY_POLICY_URL:-}" "${SUPPORT_URL:-}"; do
  if [[ -n "$public_url" ]]; then
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 30 --output /dev/null "$public_url"
  fi
done
if [[ -z "${PRIVACY_POLICY_URL:-}" || -z "${SUPPORT_URL:-}" ]]; then
  echo "Public privacy/support URLs are pending. Publish and configure those pages before final App Store submission."
fi
export_path="$FIREPRIVACY_BUILD/Export-$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$export_path"
export FIREPRIVACY_EXPORT_PATH="$export_path" FIREPRIVACY_EXPORT_DESTINATION="$destination"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
options = {'method':'app-store-connect','destination':os.environ['FIREPRIVACY_EXPORT_DESTINATION'],
           'teamID':os.environ['TEAM_ID'],'signingStyle':os.environ['SIGNING_MODE'],
           'uploadSymbols':True,'manageAppVersionAndBuildNumber':False}
if os.environ['SIGNING_MODE']=='manual':
    options['signingCertificate']=os.environ['FIREPRIVACY_SIGNING_IDENTITY']
    base = os.environ['APP_BASE_BUNDLE_ID']
    targets = [('', 'APP_PROVISIONING_PROFILE_SPECIFIER'),
               ('.SafariContentBlocker', 'SAFARI_PROVISIONING_PROFILE_SPECIFIER')]
    if os.environ['APP_EDITION'] == 'url-filter':
        targets += [('.URLFilterControl', 'URL_PROVISIONING_PROFILE_SPECIFIER')]
    elif os.environ['APP_EDITION'] == 'managed':
        targets += [('.ManagedFilterData', 'MANAGED_DATA_PROVISIONING_PROFILE_SPECIFIER'),
                    ('.ManagedFilterControl', 'MANAGED_CONTROL_PROVISIONING_PROFILE_SPECIFIER')]
    options['provisioningProfiles'] = {base + suffix: os.environ[variable] for suffix, variable in targets}
with (Path(os.environ['FIREPRIVACY_EXPORT_PATH'])/'ExportOptions.plist').open('wb') as file:
    plistlib.dump(options,file)
PY
export_args=(-exportArchive -archivePath "$archive" -exportOptionsPlist "$export_path/ExportOptions.plist" -exportPath "$export_path")
if [[ "$SIGNING_MODE" == automatic ]]; then export_args+=(-allowProvisioningUpdates); fi
if [[ -n "${ASC_KEY_PATH:-}" ]]; then export_args+=("${APPLE_AUTH_ARGS[@]}"); fi
xcodebuild "${export_args[@]}"
python3 - "$archive" <<'PY'
import json,os,sys
from pathlib import Path
archive=Path(sys.argv[1])
summary=json.loads((archive/'FirePrivacyValidation.json').read_text())
summary['exportDestination']=os.environ['FIREPRIVACY_EXPORT_DESTINATION']
summary['exportPath']=os.environ['FIREPRIVACY_EXPORT_PATH']
summary['appStoreReviewSubmitted']=False
Path('.build/apple/ReleaseSummary.json').write_text(json.dumps(summary,indent=2)+'\n')
Path('.build/apple/LatestExport.txt').write_text(os.environ['FIREPRIVACY_EXPORT_PATH']+'\n')
PY
if [[ "$destination" == upload ]]; then
  echo "Apple accepted the upload command. Wait for App Store Connect processing, attach screenshots and metadata, then submit the processed build for review."
else
  echo "Signed App Store IPA export: $export_path. This build has not been uploaded."
fi
