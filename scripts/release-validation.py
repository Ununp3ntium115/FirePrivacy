#!/usr/bin/env python3
"""Bind a successful local release check to the exact signed archive.

This checks concrete prerequisites; it never substitutes for Apple's review
or the publisher's answers in App Store Connect.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build/apple"


def check_configuration():
    bundle = os.environ.get("BUNDLE_ID", "")
    team = os.environ.get("TEAM_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
        raise SystemExit("BUNDLE_ID must be the registered reverse-DNS identifier.")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SystemExit("TEAM_ID must be the 10-character Apple Developer team identifier.")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", os.environ.get("APP_VERSION", "1.0")):
        raise SystemExit("APP_VERSION must be a numeric version such as 1.0.")
    if not re.fullmatch(r"[1-9][0-9]*", os.environ.get("BUILD_NUMBER", "1")):
        raise SystemExit("BUILD_NUMBER must be a positive integer, unique for this version in App Store Connect.")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def app_details(archive):
    app = archive / "Products/Applications/FirePrivacy.app"
    with (app / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info["CFBundleIdentifier"] != os.environ["BUNDLE_ID"]:
        raise SystemExit("The archive bundle identifier differs from BUNDLE_ID.")
    if int(str(info.get("DTSDKName", "iphoneos0")).removeprefix("iphoneos").split(".")[0]) < 26:
        raise SystemExit("The archive must be built with an iOS 26 or newer SDK.")
    if sorted(info.get("UIDeviceFamily", [])) != [1, 2]:
        raise SystemExit("The archive must support both iPhone and iPad.")
    with (app / "PrivacyInfo.xcprivacy").open("rb") as file:
        privacy = plistlib.load(file)
    if privacy.get("NSPrivacyTracking") or privacy.get("NSPrivacyCollectedDataTypes"):
        raise SystemExit("The privacy manifest no longer matches this local-only release workflow; update the release documentation before proceeding.")
    if not (app / "embedded.mobileprovision").is_file():
        raise SystemExit("The device archive has no provisioning profile.")
    signature = subprocess.run(["codesign", "--display", "--verbose=4", str(app)], capture_output=True, text=True, check=True)
    signature_team = re.search(r"^TeamIdentifier=(.+)$", signature.stderr, re.MULTILINE)
    if signature_team is None or signature_team[1] != os.environ["TEAM_ID"]:
        raise SystemExit("The archive signing identity differs from TEAM_ID.")
    return app, info


def main():
    check_configuration()
    mode = sys.argv[1]
    if mode == "configuration":
        print("Release bundle, team, version and build number are structurally valid.")
        return
    archive = Path(sys.argv[2]).resolve()
    app, info = app_details(archive)
    stamp_path = archive / "FirePrivacyValidation.json"
    hashes = {name: digest(app / name) for name in (info["CFBundleExecutable"], "Info.plist", "PrivacyInfo.xcprivacy", "embedded.mobileprovision")}
    if mode == "stamp":
        results = {}
        for family in ("iphone", "ipad"):
            result = Path((BUILD / f"LatestTests-{family}.txt").read_text().strip())
            if not result.is_dir():
                raise SystemExit(f"Missing successful {family} XCTest result bundle.")
            summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], text=True))
            if summary.get("result") != "Passed" or summary.get("totalTestCount", 0) < 1 or summary.get("failedTests", 1) != 0:
                raise SystemExit(f"The {family} XCTest result must contain passed tests without failures.")
            results[family] = str(result)
        stamp = {"timestampUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                 "bundleIdentifier": info["CFBundleIdentifier"], "teamIdentifier": os.environ["TEAM_ID"],
                 "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                 "sdk": info["DTSDKName"], "hashes": hashes, "xctestResults": results,
                 "coreTests": "passed", "privacyRegression": "passed"}
        stamp_path.write_text(json.dumps(stamp, indent=2) + "\n")
        return
    if mode != "verify":
        raise SystemExit("Usage: release-validation.py configuration|stamp|verify [archive]")
    stamp = json.loads(stamp_path.read_text())
    if stamp.get("hashes") != hashes or stamp.get("bundleIdentifier") != info["CFBundleIdentifier"]:
        raise SystemExit("The archive changed after validation. Run archive-ios.sh again.")
    if stamp.get("teamIdentifier") != os.environ["TEAM_ID"]:
        raise SystemExit("The archive team differs from TEAM_ID.")
    for env, key in (("PRIVACY_POLICY_URL", "FirePrivacyPrivacyURL"), ("SUPPORT_URL", "FirePrivacySupportURL")):
        value = os.environ.get(env, "")
        if not value:
            if info.get(key):
                raise SystemExit(f"The archive contains {key}; set {env} to that published URL to verify it.")
            continue
        parsed = urlparse(value)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise SystemExit(f"{env} must be a public HTTPS URL without embedded credentials.")
        if info.get(key) != value:
            raise SystemExit(f"The app's {key} differs from {env}. Rebuild with the published URL.")
    print("The signed archive matches its passed checks, bundle, team and published-page configuration.")


if __name__ == "__main__":
    main()
