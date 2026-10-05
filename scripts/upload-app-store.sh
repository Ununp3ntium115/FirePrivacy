#!/usr/bin/env bash
# Uploads through Apple's authenticated exporter after exact archive validation.
set -euo pipefail
exec bash "$(dirname "$0")/export-app-store.sh" "${1:?Usage: scripts/upload-app-store.sh /path/to/FirePrivacy.xcarchive}" upload
