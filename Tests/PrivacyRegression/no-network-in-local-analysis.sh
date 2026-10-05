#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
import re
import sys

roots = [Path('Sources/FirePrivacyCore'), Path('Apps/FirePrivacyApp')]
files = [p for root in roots for p in root.rglob('*.swift')]
if not files or not all(root.exists() for root in roots):
    sys.exit('FAIL: expected core and app sources are missing')
# This is a structural guard, complementary to the functional parser/store tests.
forbidden = re.compile(r'\b(?:URLConnection|NSURLConnection|NWConnection|NWListener|WKWebView|UIWebView|ASIdentifierManager|ATTrackingManager|Firebase|Sentry|TelemetryDeck)\b|^\s*import\s+(?:Network|WebKit|AdSupport|AppTrackingTransparency)\b', re.M)
network_api = re.compile(r'\bURLSession\w*\b')
approved_worker = Path('Apps/FirePrivacyApp/ApprovedHTTPTransport.swift')
failures = []
for path in files:
    source = path.read_text()
    source = re.sub(r'""".*?"""|"(?:\\.|[^"\\])*"', '', source, flags=re.S)
    # API names in comments do not constitute implementation.
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    source = re.sub(r'//[^\n]*', '', source)
    for match in forbidden.finditer(source):
        failures.append(f'{path}: prohibited API {match.group(0).strip()}')
    if path != approved_worker and network_api.search(source):
        failures.append(f'{path}: networking must use the approved HTTPS worker')
worker = approved_worker.read_text()
if 'NetworkTransmissionPermit' not in worker or 'consume' not in worker:
    failures.append('Approved HTTPS worker is missing its single-use transmission permit')
if failures:
    sys.exit('\n'.join(failures))
print(f'PASS: local analysis contains no networking; the sole HTTPS worker requires a transmission permit. Checked {len(files)} Swift files for prohibited tracking and web-view APIs.')
PY
