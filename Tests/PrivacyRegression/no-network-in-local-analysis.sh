#!/usr/bin/env bash
#
# Privacy regression: the local-analysis path must contain no networking code.
#
# IMP-010 promises that importing and analyzing a report generates no outbound
# request. The strongest cheap proof is that the modules on that path do not
# link any networking API at all — a promise the compiler enforces, not one that
# depends on nobody adding a URLSession later.
#
# Run from the FirePrivacy directory. Exits non-zero on a violation.

set -euo pipefail

cd "$(dirname "$0")/../.."

# Modules that must never touch the network.
LOCAL_ONLY_MODULES=(
  ObservationCore
  AppActivityImportKit
  FindingEngine
  PrivacyProfileKit
  ObservationStore
  ReportKit
  ConsentKit
)

# Symbols that would mean a connection can be opened.
FORBIDDEN='URLSession|NSURLConnection|CFStream|Network\.framework|import Network$|NWConnection|NWBrowser|CFSocket|getaddrinfo|dataTask|downloadTask|uploadTask|webSocketTask'

status=0

for module in "${LOCAL_ONLY_MODULES[@]}"; do
  path="Packages/${module}/Sources/${module}"
  if [ ! -d "$path" ]; then
    echo "MISSING  ${path}"
    status=1
    continue
  fi
  if grep -rnE "$FORBIDDEN" "$path" >/dev/null 2>&1; then
    echo "FAIL     ${module} references networking API:"
    grep -rnE "$FORBIDDEN" "$path" | sed 's/^/         /'
    status=1
  else
    echo "ok       ${module} contains no networking API"
  fi
done

# The knowledge base ships as data. A rule update must never be able to change
# behaviour by shipping code (KB-008).
if grep -rnE 'NSClassFromString|dlopen|dlsym|JSContext|JavaScriptCore' Packages/KnowledgeBaseKit/Sources >/dev/null 2>&1; then
  echo "FAIL     KnowledgeBaseKit can load code at runtime"
  status=1
else
  echo "ok       KnowledgeBaseKit loads data only"
fi

# Imported values must never be concatenated into model instructions (AI-008).
if grep -rnE 'system \+= |systemPrompt \+|"\\(input\.' Packages/AdvisorKit/Sources >/dev/null 2>&1; then
  echo "FAIL     AdvisorKit interpolates input into instructions"
  status=1
else
  echo "ok       AdvisorKit keeps input out of instructions"
fi

# The App Group is for protection state only; no import data may reach it (§12.2).
if grep -rnE 'appGroup|group\.com\.firesoftwaresolutions' Packages/ObservationStore/Sources >/dev/null 2>&1; then
  echo "FAIL     ObservationStore writes to the App Group"
  status=1
else
  echo "ok       ObservationStore stays out of the App Group"
fi

exit "$status"
