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

configure_dataset_trust() {
  export FIREPRIVACY_KB_PUBLIC_KEYS_JSON="${FIREPRIVACY_KB_PUBLIC_KEYS_JSON-}"
  export FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON="${FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON-}"
  python3 "$FIREPRIVACY_ROOT/scripts/dataset-public-keys.py" validate
  DATASET_TRUST_ARGS=("FIREPRIVACY_KB_PUBLIC_KEYS_JSON=$FIREPRIVACY_KB_PUBLIC_KEYS_JSON"
    "FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON=$FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON")
}

configure_bundle_identifiers() {
  if [[ -n "${APP_BASE_BUNDLE_ID:-}" && -n "${BUNDLE_ID:-}" && "$APP_BASE_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
    echo "APP_BASE_BUNDLE_ID and its legacy BUNDLE_ID alias must match when both are set." >&2
    exit 1
  fi
  APP_BASE_BUNDLE_ID="${APP_BASE_BUNDLE_ID:-${BUNDLE_ID:-}}"
  : "${APP_BASE_BUNDLE_ID:?Set APP_BASE_BUNDLE_ID to the registered App Store Connect app bundle identifier}"
  BUNDLE_ID="$APP_BASE_BUNDLE_ID"
  FIREPRIVACY_APP_GROUP_ID="${FIREPRIVACY_APP_GROUP_ID:-group.com.firesoftwaresolutions.FirePrivacy.protection}"
  APP_EDITION="${APP_EDITION:-consumer}"
  FIREPRIVACY_PROFILE_VARIABLES=(APP_PROVISIONING_PROFILE_SPECIFIER SAFARI_PROVISIONING_PROFILE_SPECIFIER)
  case "$APP_EDITION" in
    consumer)
      FIREPRIVACY_SCHEME=FirePrivacy
      FIREPRIVACY_PRODUCT=FirePrivacy.app
      ;;
    url-filter)
      FIREPRIVACY_SCHEME=FirePrivacyURL
      FIREPRIVACY_PRODUCT=FirePrivacyURL.app
      FIREPRIVACY_PROFILE_VARIABLES+=(URL_PROVISIONING_PROFILE_SPECIFIER)
      ;;
    managed)
      FIREPRIVACY_SCHEME=FirePrivacyManaged
      FIREPRIVACY_PRODUCT=FirePrivacyManaged.app
      FIREPRIVACY_PROFILE_VARIABLES+=(MANAGED_DATA_PROVISIONING_PROFILE_SPECIFIER MANAGED_CONTROL_PROVISIONING_PROFILE_SPECIFIER)
      ;;
    *)
      echo "APP_EDITION must be consumer, url-filter or managed." >&2
      exit 1
      ;;
  esac
  python3 - "$APP_BASE_BUNDLE_ID" "$FIREPRIVACY_APP_GROUP_ID" <<'PY'
import re, sys
bundle, group = sys.argv[1:]
pattern = r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+'
if not re.fullmatch(pattern, bundle):
    raise SystemExit('APP_BASE_BUNDLE_ID must be the registered reverse-DNS app identifier.')
if not group.startswith('group.') or not re.fullmatch(pattern, group):
    raise SystemExit('FIREPRIVACY_APP_GROUP_ID must be a registered group. identifier.')
PY
  export APP_BASE_BUNDLE_ID BUNDLE_ID FIREPRIVACY_APP_GROUP_ID APP_EDITION FIREPRIVACY_SCHEME FIREPRIVACY_PRODUCT
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

configure_signing() {
  SIGNING_MODE="${SIGNING_MODE:-automatic}"
  APPLE_SIGN_ARGS=(CODE_SIGN_STYLE=Automatic)
  if [[ "$SIGNING_MODE" == manual ]]; then
    if [[ -n "${APP_PROVISIONING_PROFILE_SPECIFIER:-}" && -n "${FIREPRIVACY_PROFILE_UUID:-}" && "$APP_PROVISIONING_PROFILE_SPECIFIER" != "$FIREPRIVACY_PROFILE_UUID" ]]; then
      echo "APP_PROVISIONING_PROFILE_SPECIFIER and its legacy FIREPRIVACY_PROFILE_UUID alias must match when both are set." >&2
      exit 1
    fi
    APP_PROVISIONING_PROFILE_SPECIFIER="${APP_PROVISIONING_PROFILE_SPECIFIER:-${FIREPRIVACY_PROFILE_UUID:-}}"
    : "${APP_PROVISIONING_PROFILE_SPECIFIER:?Manual signing requires the verified app profile UUID}"
    : "${FIREPRIVACY_SIGNING_IDENTITY:?Manual signing requires the verified distribution identity}"
    local variable profile
    local profile_args=()
    for variable in "${FIREPRIVACY_PROFILE_VARIABLES[@]}"; do
      profile="${!variable:-}"
      if [[ -z "$profile" ]]; then
        echo "Manual signing for $APP_EDITION requires verified $variable." >&2
        exit 1
      fi
      profile_args+=("$variable" "$profile")
    done
    python3 - "$FIREPRIVACY_SIGNING_IDENTITY" "${profile_args[@]}" <<'PY'
import re, sys
for variable, profile in zip(sys.argv[2::2], sys.argv[3::2]):
    if not re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', profile):
        raise SystemExit(f'Invalid manual provisioning profile UUID for {variable}.')
if not re.fullmatch(r'[A-Fa-f0-9]{40}', sys.argv[1]):
    raise SystemExit('Invalid verified distribution identity fingerprint.')
PY
    FIREPRIVACY_PROFILE_UUID="$APP_PROVISIONING_PROFILE_SPECIFIER"
    export FIREPRIVACY_PROFILE_UUID FIREPRIVACY_SIGNING_IDENTITY
    APPLE_SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$FIREPRIVACY_SIGNING_IDENTITY")
    for variable in "${FIREPRIVACY_PROFILE_VARIABLES[@]}"; do
      export "$variable"
      APPLE_SIGN_ARGS+=("$variable=${!variable}")
    done
  elif [[ "$SIGNING_MODE" != automatic ]]; then
    echo "SIGNING_MODE must be automatic or manual." >&2
    exit 1
  fi
  export SIGNING_MODE
}
