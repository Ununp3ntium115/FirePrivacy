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
forbidden = re.compile(r'\b(?:URLSession|URLConnection|NSURLConnection|NWConnection|NWListener|WKWebView|UIWebView|ASIdentifierManager|ATTrackingManager|Firebase|Sentry|TelemetryDeck)\b|^\s*import\s+(?:Network|WebKit|AdSupport|AppTrackingTransparency)\b', re.M)
failures = []
for path in files:
    source = path.read_text()
    # API names in comments do not constitute implementation.
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    source = re.sub(r'//[^\n]*', '', source)
    for match in forbidden.finditer(source):
        failures.append(f'{path}: prohibited API {match.group(0).strip()}')
if failures:
    sys.exit('\n'.join(failures))
print(f'PASS: {len(files)} Swift source files contain no network, advertising, tracking, or web-view APIs.')
PY
