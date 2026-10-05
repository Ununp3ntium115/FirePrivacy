#!/usr/bin/env bash
# Shared by Apple build scripts. Source this file; do not execute it directly.
set -euo pipefail

FIREPRIVACY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIREPRIVACY_BUILD="$FIREPRIVACY_ROOT/.build/apple"
export PRIVACY_POLICY_URL="${PRIVACY_POLICY_URL-https://github.com/Ununp3ntium115/FirePrivacy/blob/gh-pages/privacy-policy.md}"
export SUPPORT_URL="${SUPPORT_URL-https://github.com/Ununp3ntium115/FirePrivacy/issues}"
mkdir -p "$FIREPRIVACY_BUILD"

require_apple_toolchain() {
  if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
    echo "This step needs a Mac with Xcode 26 or newer; Linux cannot build, sign or upload an iOS app." >&2
    exit 1
  fi
  local xcode_version sdk_version
  xcode_version="$(xcodebuild -version | awk '/^Xcode / {print $2}')"
  sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
  python3 - "$xcode_version" "$sdk_version" <<'PY'
import sys
xcode, sdk = sys.argv[1:]
if int(xcode.split('.')[0]) < 26 or int(sdk.split('.')[0]) < 26:
    raise SystemExit(f"Need Xcode >=26 and iOS SDK >=26; selected Xcode {xcode}, SDK {sdk}.")
print(f"Using Xcode {xcode}; iOS SDK {sdk}. Deployment target remains iOS 17.")
PY
}

select_simulator() {
  local family="${1:?Specify iphone or ipad}"
  xcrun simctl list devices available --json | python3 "$FIREPRIVACY_ROOT/scripts/select-simulator.py" "$family"
}

configure_apple_auth() {
  APPLE_AUTH_ARGS=()
  if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
    : "${ASC_KEY_PATH:?Set ASC_KEY_PATH to the local private .p8 file}"
    : "${ASC_KEY_ID:?Set ASC_KEY_ID for the same App Store Connect key}"
    : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID for that key}"
    [[ -r "$ASC_KEY_PATH" ]] || { echo "ASC_KEY_PATH is not readable." >&2; exit 1; }
    APPLE_AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  fi
  # With no API key, xcodebuild uses the Apple account already signed in to Xcode.
}
