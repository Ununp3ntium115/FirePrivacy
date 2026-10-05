#!/usr/bin/env python3
"""Select an installed iOS >=17 simulator; prefer App Store display sizes."""
import json
import re
import sys

family = sys.argv[1]
if family not in ("iphone", "ipad"):
    raise SystemExit("Simulator family must be iphone or ipad.")
data = json.load(sys.stdin)
prefix = "iPhone" if family == "iphone" else "iPad"
candidates = []
for runtime, devices in data["devices"].items():
    match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if not match or int(match[1]) < 17:
        continue
    version = tuple(int(part or 0) for part in match.groups())
    for device in devices:
        if not device.get("isAvailable", False) or not device["name"].startswith(prefix):
            continue
        name = device["name"]
        preferred = "Pro Max" in name if family == "iphone" else ("13-inch" in name or "12.9-inch" in name)
        candidates.append((preferred, version, name, device["udid"]))
if not candidates:
    raise SystemExit(f"No available {prefix} simulator with iOS >=17. Install an iOS Simulator runtime in Xcode Settings > Components.")
print(max(candidates)[-1])
