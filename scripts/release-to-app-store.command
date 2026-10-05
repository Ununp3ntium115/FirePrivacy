#!/usr/bin/env bash
# Run on your authenticated Mac, or double-click after setting the environment.
# --upload uploads a validated signed build; final review submission is in ASC.
set -euo pipefail
cd "$(dirname "$0")/.."
export TEAM_ID="${TEAM_ID:-LYDVWU62G4}"
export BUNDLE_ID="${BUNDLE_ID:-com.firesoftwaresolutions.FirePrivacy}"
export PRIVACY_POLICY_URL="${PRIVACY_POLICY_URL:-https://github.com/Ununp3ntium115/FirePrivacy/blob/gh-pages/privacy-policy.md}"
export SUPPORT_URL="${SUPPORT_URL:-https://github.com/Ununp3ntium115/FirePrivacy/issues}"
if [[ "${1:-}" != "" && "${1:-}" != "--upload" ]]; then
  echo "Usage: scripts/release-to-app-store.command [--upload]" >&2
  exit 1
fi
echo "Configured bundle: $BUNDLE_ID; Apple team: $TEAM_ID. This bundle must be registered and match the App Store Connect app record."
bash scripts/archive-ios.sh
archive="$(cat .build/apple/LatestArchive.txt)"
if [[ "${1:-}" == "--upload" ]]; then
  bash scripts/upload-app-store.sh "$archive"
else
  open -a Xcode "$archive"
  echo "Xcode Organizer opened the signed archive. Choose Distribute App > App Store Connect."
fi
