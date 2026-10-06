#!/usr/bin/env bash
# Install a pinned, signature-verified portable toolchain without root access.
set -euo pipefail
if [[ "$(uname -s)" != Linux ]]; then
  echo 'Use the Swift toolchain bundled with Xcode on macOS.'
  exit 0
fi
if [[ "$(uname -m)" != x86_64 ]]; then
  echo 'This helper supports x86_64 Linux only.' >&2
  exit 1
fi
FP_TOOL_ROOT="${FP_TOOL_ROOT:-/workspace/toolchains}"
FP_RELEASE=swift-6.2.3-RELEASE-debian12
FP_ARCHIVE="$FP_TOOL_ROOT/downloads/swift.tar.gz"
FP_BASE=https://download.swift.org/swift-6.2.3-release/debian12/swift-6.2.3-RELEASE
FP_SHA=d47b7416f68e75b3b8ed538c939dc6e5a9e9a8de2d605389661d2ef31e75b772
FP_SIGNER=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
mkdir -p "$FP_TOOL_ROOT/downloads" "$FP_TOOL_ROOT/gnupg"
chmod 700 "$FP_TOOL_ROOT/gnupg"
if [[ ! -x "$FP_TOOL_ROOT/$FP_RELEASE/usr/bin/swift" ]]; then
  if [[ ! -f "$FP_ARCHIVE" ]]; then
    curl --fail --location --silent --show-error --retry 2 "$FP_BASE/$FP_RELEASE.tar.gz" -o "$FP_ARCHIVE.part"
    mv "$FP_ARCHIVE.part" "$FP_ARCHIVE"
  fi
  printf '%s  %s\n' "$FP_SHA" "$FP_ARCHIVE" | sha256sum --check --status
  curl --fail --location --silent --show-error "$FP_BASE/$FP_RELEASE.tar.gz.sig" -o "$FP_ARCHIVE.sig"
  curl --fail --location --silent --show-error https://raw.githubusercontent.com/swiftlang/swift-org-website/1268dc96e77d9bf37da25f6d538bece4e46006a5/keys/all-keys.asc -o "$FP_TOOL_ROOT/downloads/swift-signing-keys.asc"
  gpg --homedir "$FP_TOOL_ROOT/gnupg" --batch --import "$FP_TOOL_ROOT/downloads/swift-signing-keys.asc"
  gpg --homedir "$FP_TOOL_ROOT/gnupg" --batch --status-fd 1 --verify "$FP_ARCHIVE.sig" "$FP_ARCHIVE" > "$FP_TOOL_ROOT/downloads/signature-status.txt"
  # GPG verifies the historical release signature. Its key is now expired;
  # signature time was within its validity. Pin both the signer and artifact.
  if ! rg --quiet "^\[GNUPG:\] VALIDSIG $FP_SIGNER " "$FP_TOOL_ROOT/downloads/signature-status.txt"; then
    echo 'Unexpected Swift release signer.' >&2
    exit 1
  fi
  tar -xzf "$FP_ARCHIVE" -C "$FP_TOOL_ROOT"
fi
"$FP_TOOL_ROOT/$FP_RELEASE/usr/bin/swift" --version
printf 'Use: export PATH="%s/%s/usr/bin:$PATH"\n' "$FP_TOOL_ROOT" "$FP_RELEASE"
