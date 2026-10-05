#!/usr/bin/env python3
"""Expose native test diagnostics through GitHub's check annotations API.

This avoids dependence on signed log-download URLs. Test data is synthetic.
Preserve the xcodebuild exit status in the calling shell.
"""
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit, urlunsplit


def sanitized_url(match):
    value = urlsplit(match[0])
    return urlunsplit((value.scheme, value.hostname or "", value.path, "", ""))


def diagnostic(text):
    lines = text.splitlines()
    relevant = [line for line in lines if re.search(
        r"error:|failed|failure|XCTAssert|timed out|boot|CoreSimulator|Unable to", line, re.IGNORECASE
    )]
    # The tail retains launch/runner context when XCTest never reached a test.
    chosen = relevant[-35:] + ["--- final native test output ---"] + lines[-45:]
    value = "\n".join(chosen)[-20_000:]
    value = re.sub(r"https?://\S+", sanitized_url, value)
    return "".join(character for character in value if character in "\n\t" or ord(character) >= 32)


if __name__ == "__main__":
    log = Path(sys.argv[1])
    family = sys.argv[2]
    message = diagnostic(log.read_text(errors="replace"))
    if os.environ.get("GITHUB_ACTIONS") == "true":
        escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title=Native {family} test diagnostics::{escaped}")
    else:
        print(message, file=sys.stderr)
