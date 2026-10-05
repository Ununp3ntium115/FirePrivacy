#!/usr/bin/env bash
# The CI checks available in Linux; native Apple checks use test-ios.sh.
set -euo pipefail
FP_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$FP_PROJECT_ROOT"
if command -v swift >/dev/null; then
  FP_SWIFT="$(command -v swift)"
else
  FP_SWIFT="${FP_TOOL_ROOT:-/workspace/toolchains}/swift-6.2.3-RELEASE-debian12/usr/bin/swift"
fi
[[ -x "$FP_SWIFT" ]] || { echo 'Install Swift with scripts/install-swift-linux.sh first.' >&2; exit 1; }
FP_CACHE="$FP_PROJECT_ROOT/.build/tooling"
mkdir -p "$FP_CACHE"
export CLANG_MODULE_CACHE_PATH="$FP_CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$FP_CACHE/modules"
FP_SWIFT_ARGS=(--jobs "${FP_JOBS:-4}" --cache-path "$FP_CACHE/cache" --config-path "$FP_CACHE/config" --security-path "$FP_CACHE/security")
"$FP_SWIFT" build "${FP_SWIFT_ARGS[@]}"
"$FP_SWIFT" test "${FP_SWIFT_ARGS[@]}"
python3 -m unittest discover -s Tests/CloudRelease -p 'test_*.py'
python3 scripts/validate-project.py
bash Tests/PrivacyRegression/no-network-in-local-analysis.sh
