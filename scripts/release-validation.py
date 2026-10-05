#!/usr/bin/env python3
"""Bind passed release checks to the exact signed app and edition extensions.

Apple's review, physical-device QA, and the publisher's App Store Connect
answers remain separate requirements. No secret values are recorded here.
"""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build/apple"
DEFAULT_GROUP = "group.com.firesoftwaresolutions.FirePrivacy.protection"
UUID_PATTERN = r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}"
TARGETS = {
    "app": ("FirePrivacy", "", set(), None),
    "safari": ("SafariContentBlocker", ".SafariContentBlocker", set(), "com.apple.Safari.content-blocker"),
    "url": ("URLFilterControl", ".URLFilterControl", {"url-filter-provider"}, "com.apple.networkextension.url-filter-control"),
    "managed_data": ("ManagedFilterData", ".ManagedFilterData", {"content-filter-provider"}, "com.apple.networkextension.filter-data"),
    "managed_control": ("ManagedFilterControl", ".ManagedFilterControl", {"content-filter-provider"}, "com.apple.networkextension.filter-control"),
}
PROFILE_VARIABLES = {target: target.upper() + "_PROVISIONING_PROFILE_SPECIFIER" for target in TARGETS}
EDITIONS = {
    "consumer": ("FirePrivacy", ("app", "safari"), {"dns-settings"}),
    "url-filter": ("FirePrivacyURL", ("app", "safari", "url"), {"dns-settings", "url-filter-provider"}),
    "managed": ("FirePrivacyManaged", ("app", "safari", "managed_data", "managed_control"), {"dns-settings", "content-filter-provider"}),
}


def required_capabilities(target, config):
    return EDITIONS[config["edition"]][2] if target == "app" else TARGETS[target][2]


def check_configuration():
    base = os.environ.get("APP_BASE_BUNDLE_ID", "")
    legacy = os.environ.get("BUNDLE_ID", "")
    if base and legacy and base != legacy:
        raise SystemExit("APP_BASE_BUNDLE_ID and the legacy BUNDLE_ID alias must agree.")
    bundle = base or legacy
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
        raise SystemExit("APP_BASE_BUNDLE_ID must be the registered reverse-DNS identifier.")
    team = os.environ.get("TEAM_ID", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SystemExit("TEAM_ID must be the 10-character Apple Developer team identifier.")
    version = os.environ.get("APP_VERSION", "1.0")
    build = os.environ.get("BUILD_NUMBER", "1")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version):
        raise SystemExit("APP_VERSION must be a numeric version such as 1.0.")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise SystemExit("BUILD_NUMBER must be a positive integer, unique for this version in App Store Connect.")
    group = os.environ.get("FIREPRIVACY_APP_GROUP_ID", DEFAULT_GROUP)
    if not re.fullmatch(r"group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", group):
        raise SystemExit("FIREPRIVACY_APP_GROUP_ID must be the registered App Group identifier.")
    mode = os.environ.get("SIGNING_MODE", "automatic")
    if mode not in ("automatic", "manual"):
        raise SystemExit("SIGNING_MODE must be automatic or manual.")
    identity = os.environ.get("FIREPRIVACY_SIGNING_IDENTITY", "").upper()
    if identity and not re.fullmatch(r"[A-F0-9]{40}", identity):
        raise SystemExit("FIREPRIVACY_SIGNING_IDENTITY must be the verified certificate SHA-1 fingerprint.")
    edition = os.environ.get("APP_EDITION", "consumer")
    if edition not in EDITIONS:
        raise SystemExit("APP_EDITION must be consumer, url-filter or managed.")
    profiles = {target: os.environ.get(PROFILE_VARIABLES[target], "").upper() for target in EDITIONS[edition][1]}
    legacy_profile = os.environ.get("FIREPRIVACY_PROFILE_UUID", "").upper()
    if profiles["app"] and legacy_profile and profiles["app"] != legacy_profile:
        raise SystemExit("APP_PROVISIONING_PROFILE_SPECIFIER and the legacy FIREPRIVACY_PROFILE_UUID alias must agree.")
    profiles["app"] = profiles["app"] or legacy_profile
    for target, value in profiles.items():
        if value and not re.fullmatch(UUID_PATTERN, value):
            raise SystemExit(f"{PROFILE_VARIABLES[target]} must be a provisioning profile UUID.")
    if any(profiles.values()) and not all(profiles.values()):
        raise SystemExit("Configure provisioning profile UUIDs for the app and every selected edition extension together.")
    if all(profiles.values()) and len(set(profiles.values())) != len(profiles):
        raise SystemExit("Each selected target requires its own distinct provisioning profile UUID.")
    urls = {}
    for variable in ("PRIVACY_POLICY_URL", "SUPPORT_URL"):
        value = os.environ.get(variable, "")
        parsed = urlparse(value)
        if value and (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password):
            raise SystemExit(f"{variable} must be a public HTTPS URL without embedded credentials.")
        urls[variable] = value
    pir = {}
    if edition == "url-filter":
        for variable, key, required in (("FIREPRIVACY_PIR_SERVER_URL", "PIRServerURL", True),
                                        ("FIREPRIVACY_PRIVACY_PASS_ISSUER_URL", "PrivacyPassIssuerURL", False)):
            value = os.environ.get(variable, "")
            parsed = urlparse(value)
            if (required and not value) or (value and (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password)):
                raise SystemExit(f"{variable} must be a public HTTPS URL without embedded credentials for the URL filter edition.")
            pir[key] = value
        pir_identity = os.environ.get("FIREPRIVACY_PIR_CONFIGURATION_IDENTITY", "")
        if not pir_identity.strip() or pir_identity != pir_identity.strip():
            raise SystemExit("FIREPRIVACY_PIR_CONFIGURATION_IDENTITY must identify the registered Apple PIR configuration.")
        pir["configurationIdentity"] = pir_identity
    return {"edition": edition, "bundleIdentifier": bundle, "teamIdentifier": team, "appGroupIdentifier": group,
            "version": version, "build": build, "signingMode": mode,
            "signingIdentity": identity, "provisioningProfiles": profiles,
            "publishedURLs": urls, "pirConfiguration": pir}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_plist(path):
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        raise SystemExit(f"Missing or invalid property list: {path.name}.") from None
    if not isinstance(value, dict):
        raise SystemExit(f"Invalid property list structure: {path.name}.")
    return value


def run(arguments, *, text=False, allow_failure=False):
    try:
        return subprocess.run(arguments, capture_output=True, text=text, check=not allow_failure)
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit(f"Required Apple validation command failed: {Path(arguments[0]).name}.") from None


def verify_apple_profile(path):
    # Reuse the Apple-specific CMS trust policy maintained by cloud signing.
    # Extracting the plist alone does not authenticate a provisioning profile.
    name = "fireprivacy_release_profile_trust"
    module = sys.modules.get(name)
    if module is None:
        spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/cloud-signing.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    try:
        module.verify_apple_profile(path)
    except module.SigningError as error:
        raise SystemExit(str(error)) from None


def signed_entitlements(bundle):
    output = run(["codesign", "--display", "--entitlements", ":-", "--xml", str(bundle)])
    for payload in (output.stdout, output.stderr):
        if payload.startswith(b"bplist00"):
            candidate = payload
        else:
            start, end = payload.find(b"<?xml"), payload.rfind(b"</plist>")
            if start < 0 or end < start:
                continue
            candidate = payload[start:end + len(b"</plist>")]
        try:
            value = plistlib.loads(candidate)
        except (ValueError, TypeError, plistlib.InvalidFileException):
            continue
        if isinstance(value, dict):
            return value
    raise SystemExit(f"Cannot read the signed entitlements for {bundle.name}.")


def check_entitlements(entitlements, target, config, app_identifier=None, *, profile_grants=False):
    bundle_id = config["bundleIdentifier"] + TARGETS[target][1]
    if entitlements.get("com.apple.developer.team-identifier") != config["teamIdentifier"]:
        raise SystemExit(f"The {target} signed entitlement team differs from TEAM_ID.")
    identifier = entitlements.get("application-identifier", "")
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Z0-9]{10}\." + re.escape(bundle_id), identifier):
        raise SystemExit(f"The {target} signed application identifier differs from its exact bundle identifier.")
    if app_identifier is not None and identifier != app_identifier:
        raise SystemExit(f"The {target} signed application identifier differs from its provisioning profile.")
    if entitlements.get("get-task-allow") is not False:
        raise SystemExit(f"The {target} archive must deny development debugger access.")
    groups = entitlements.get("com.apple.security.application-groups")
    if not isinstance(groups, list) or any(not isinstance(item, str) for item in groups) or (config["appGroupIdentifier"] not in groups if profile_grants else groups != [config["appGroupIdentifier"]]):
        raise SystemExit(f"The {target} App Group entitlement differs from FIREPRIVACY_APP_GROUP_ID.")
    capabilities = entitlements.get("com.apple.developer.networking.networkextension", [])
    valid = isinstance(capabilities, list) and all(isinstance(item, str) for item in capabilities) and len(set(capabilities)) == len(capabilities)
    if not valid or (not required_capabilities(target, config).issubset(capabilities) if profile_grants else set(capabilities) != required_capabilities(target, config)):
        raise SystemExit(f"The {target} Network Extension entitlements differ from the required target capabilities.")


def profile_details(bundle, target, config, identity, entitlements, keychain):
    path = bundle / "embedded.mobileprovision"
    verify_apple_profile(path)
    payload = run(["/usr/bin/security", "cms", "-D", "-k", str(keychain), "-i", str(path)]).stdout
    try:
        data = plistlib.loads(payload)
    except (ValueError, TypeError, plistlib.InvalidFileException):
        raise SystemExit(f"The {target} verified provisioning profile is invalid.") from None
    if not isinstance(data, dict):
        raise SystemExit(f"The {target} provisioning profile has an invalid structure.")
    uuid = data.get("UUID", "")
    if not isinstance(uuid, str) or not re.fullmatch(UUID_PATTERN, uuid):
        raise SystemExit(f"The {target} provisioning profile has an invalid UUID.")
    expected = config["provisioningProfiles"][target]
    if expected and uuid.upper() != expected:
        raise SystemExit(f"The {target} provisioning profile differs from {PROFILE_VARIABLES[target]}.")
    expiration = data.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime):
        raise SystemExit(f"The {target} provisioning profile has no expiration date.")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= datetime.datetime.now(datetime.timezone.utc):
        raise SystemExit(f"The {target} provisioning profile has expired.")
    team = config["teamIdentifier"]
    grants = data.get("Entitlements")
    teams, platforms, prefixes = data.get("TeamIdentifier"), data.get("Platform"), data.get("ApplicationIdentifierPrefix")
    if not isinstance(teams, list) or team not in teams or not isinstance(platforms, list) or "iOS" not in platforms or not isinstance(grants, dict):
        raise SystemExit(f"The {target} provisioning profile must grant this Apple team access on iOS.")
    identifier = grants.get("application-identifier")
    bundle_id = config["bundleIdentifier"] + TARGETS[target][1]
    if not isinstance(prefixes, list) or not prefixes or any(not isinstance(prefix, str) or not re.fullmatch(r"[A-Z0-9]{10}", prefix) for prefix in prefixes) or not any(identifier == f"{prefix}.{bundle_id}" for prefix in prefixes):
        raise SystemExit(f"The {target} requires an explicit provisioning profile for its exact bundle identifier.")
    if "ProvisionedDevices" in data or "ProvisionsAllDevices" in data:
        raise SystemExit(f"The {target} requires an App Store distribution provisioning profile.")
    check_entitlements(grants, target, config, identifier, profile_grants=True)
    check_entitlements(entitlements, target, config, identifier)
    certificates = data.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates or any(not isinstance(item, bytes) for item in certificates) or identity not in {hashlib.sha1(item).hexdigest().upper() for item in certificates}:
        raise SystemExit(f"The {target} provisioning profile does not authorize the signed distribution certificate.")
    return {"uuid": uuid.upper(), "expirationUTC": expiration.isoformat(), "applicationIdentifier": identifier}


def bundle_paths(archive, config):
    product, selected, _ = EDITIONS[config["edition"]]
    applications = archive / "Products/Applications"
    app = applications / (product + ".app")
    if app.is_symlink() or not app.is_dir() or sorted(path.name for path in applications.glob("*.app")) != [product + ".app"]:
        raise SystemExit(f"The archive must contain exactly the {product} application for the selected edition.")
    expected = {TARGETS[target][0] + ".appex": target for target in selected if target != "app"}
    paths = {"app": app}
    for extension in app.rglob("*.appex"):
        relative = extension.relative_to(app)
        target = expected.get(extension.name)
        if target is None or target in paths or extension.is_symlink() or not extension.is_dir() or len(relative.parts) != 2:
            raise SystemExit("The archive contains an unexpected or duplicate embedded extension.")
        allowed = ("Extensions", "FoundationExtensions") if target == "url" else ("PlugIns",)
        if relative.parts[0] not in allowed:
            raise SystemExit(f"The {target} extension is embedded in the wrong archive directory.")
        paths[target] = extension
    if set(paths) != set(selected):
        raise SystemExit("The archive must embed exactly the extensions required by APP_EDITION.")
    return app, paths


def archive_details(archive, config):
    app, paths = bundle_paths(archive, config)
    if config["signingMode"] == "manual" and (not config["signingIdentity"] or not all(config["provisioningProfiles"].values())):
        raise SystemExit("Manual archive validation requires a verified distribution identity and every selected edition profile UUID.")
    # Valid-only code-signing policy checks current certificate trust/expiry and
    # private-key availability for export, in both automatic and manual modes.
    # Hashing a profile-authorized certificate or codesign --verify alone does
    # not establish that its certificate is currently trusted for code signing.
    identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], text=True).stdout
    trusted_identities = {match.upper() for match in re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"', identities, re.MULTILINE)}
    details = {}
    with tempfile.TemporaryDirectory(prefix="fireprivacy-release-validation-") as directory:
        keychain = Path(directory) / "profiles.keychain-db"
        password = secrets.token_urlsafe(32)
        original_search_list = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"], text=True).stdout)
        attempted_creation = False
        try:
            # The native command can create/register the keychain before it
            # reports failure; record the attempt before calling it.
            attempted_creation = True
            run(["/usr/bin/security", "create-keychain", "-p", password, str(keychain)])
            # create-keychain adds itself to the user search list. Restore it
            # immediately; cms uses the owned keychain explicitly through -k.
            run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original_search_list])
            run(["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)])
            for target in EDITIONS[config["edition"]][1]:
                bundle = paths[target]
                info = read_plist(bundle / "Info.plist")
                expected_id = config["bundleIdentifier"] + TARGETS[target][1]
                if info.get("CFBundleIdentifier") != expected_id:
                    raise SystemExit(f"The {target} bundle identifier differs from APP_BASE_BUNDLE_ID and its target suffix.")
                if str(info.get("CFBundleShortVersionString", "")) != config["version"] or str(info.get("CFBundleVersion", "")) != config["build"]:
                    raise SystemExit(f"The {target} archive version/build differs from APP_VERSION or BUILD_NUMBER.")
                sdk = info.get("DTSDKName", "")
                if not isinstance(sdk, str) or not re.fullmatch(r"iphoneos[0-9]+(?:\.[0-9]+){0,2}", sdk) or int(sdk.removeprefix("iphoneos").split(".")[0]) < 26:
                    raise SystemExit(f"The {target} must be built with an iOS 26 or newer device SDK.")
                families = info.get("UIDeviceFamily")
                if not isinstance(families, list) or any(type(family) is not int for family in families) or sorted(families) != [1, 2]:
                    raise SystemExit(f"The {target} archive must support both iPhone and iPad.")
                if target == "app" and info.get("FirePrivacyDistributionEdition") != config["edition"]:
                    raise SystemExit("The host application distribution edition differs from APP_EDITION.")
                if target == "app" and config["edition"] == "url-filter":
                    pir = info.get("NSPIRConfiguration")
                    expected_pir = config["pirConfiguration"]
                    if not isinstance(pir, dict) or pir.get("PIRServerURL") != expected_pir["PIRServerURL"] or pir.get("PrivacyPassIssuerURL", "") != expected_pir["PrivacyPassIssuerURL"] or info.get("FirePrivacyApplePIRConfigurationIdentity") != expected_pir["configurationIdentity"]:
                        raise SystemExit("The compiled Apple PIR service configuration differs from the required URL filter release configuration.")
                if info.get("CFBundlePackageType") != ("APPL" if target == "app" else "XPC!"):
                    raise SystemExit(f"The {target} has the wrong bundle package type.")
                if info.get("FirePrivacyAppGroup") != config["appGroupIdentifier"]:
                    raise SystemExit(f"The {target} Info.plist App Group differs from FIREPRIVACY_APP_GROUP_ID.")
                if target != "app":
                    key, point = ("EXAppExtensionAttributes", "EXExtensionPointIdentifier") if target == "url" else ("NSExtension", "NSExtensionPointIdentifier")
                    attributes = info.get(key)
                    if not isinstance(attributes, dict) or attributes.get(point) != TARGETS[target][3]:
                        raise SystemExit(f"The {target} has the wrong extension point identifier.")
                executable = info.get("CFBundleExecutable")
                if not isinstance(executable, str) or executable in ("", ".", "..") or Path(executable).name != executable or "/" in executable or "\\" in executable:
                    raise SystemExit(f"The {target} bundle executable name is invalid.")
                files = (executable, "Info.plist", "PrivacyInfo.xcprivacy", "embedded.mobileprovision")
                if any((bundle / name).is_symlink() or not (bundle / name).is_file() for name in files):
                    raise SystemExit(f"The {target} archive is missing a required executable, manifest, plist or provisioning profile.")
                privacy = read_plist(bundle / "PrivacyInfo.xcprivacy")
                if privacy.get("NSPrivacyTracking") or privacy.get("NSPrivacyCollectedDataTypes"):
                    raise SystemExit(f"The {target} privacy manifest no longer matches the local-only data collection declarations; update the release documentation before proceeding.")
                run(["codesign", "--verify", "--strict", str(bundle)])
                signature = run(["codesign", "--display", "--verbose=4", str(bundle)], text=True)
                signature_team = re.search(r"^TeamIdentifier=(.+)$", signature.stderr, re.MULTILINE)
                signature_id = re.search(r"^Identifier=(.+)$", signature.stderr, re.MULTILINE)
                if signature_team is None or signature_team[1] != config["teamIdentifier"] or signature_id is None or signature_id[1] != expected_id:
                    raise SystemExit(f"The {target} code signature team or bundle identifier differs from the release configuration.")
                certificate_prefix = Path(directory) / (target + "-certificate-")
                run(["codesign", "--display", "--extract-certificates", str(certificate_prefix), str(bundle)])
                certificate = Path(str(certificate_prefix) + "0")
                if not certificate.is_file():
                    raise SystemExit(f"The {target} signed distribution certificate could not be extracted.")
                identity = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
                if identity not in trusted_identities:
                    raise SystemExit(f"The {target} distribution certificate is not a trusted valid code-signing identity in the current keychains.")
                if config["signingIdentity"] and identity != config["signingIdentity"]:
                    raise SystemExit(f"The {target} distribution identity differs from FIREPRIVACY_SIGNING_IDENTITY.")
                entitlements = signed_entitlements(bundle)
                check_entitlements(entitlements, target, config)
                profile = profile_details(bundle, target, config, identity, entitlements, keychain)
                details[target] = {"path": bundle.relative_to(app).as_posix(), "bundleIdentifier": expected_id,
                                   "teamIdentifier": signature_team[1], "version": str(info["CFBundleShortVersionString"]),
                                   "build": str(info["CFBundleVersion"]), "sdk": sdk, "deviceFamilies": sorted(info["UIDeviceFamily"]),
                                   "signingIdentity": identity, "signedEntitlements": entitlements, "provisioningProfile": profile,
                                   "hashes": {name: digest(bundle / name) for name in files}}
            if len({value["signingIdentity"] for value in details.values()}) != 1:
                raise SystemExit("The app and its selected edition extensions must use the same distribution signing identity.")
            if len({value["provisioningProfile"]["uuid"] for value in details.values()}) != len(details):
                raise SystemExit("Every selected archive target must use its own distinct provisioning profile UUID.")
            for variable, key in (("PRIVACY_POLICY_URL", "FirePrivacyPrivacyURL"), ("SUPPORT_URL", "FirePrivacySupportURL")):
                value = config["publishedURLs"][variable]
                info = read_plist(app / "Info.plist")
                if info.get(key, "") != value:
                    raise SystemExit(f"The app's {key} differs from {variable}. Rebuild with the published URL.")
        finally:
            try:
                run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original_search_list])
            finally:
                if attempted_creation:
                    deleted = run(["/usr/bin/security", "delete-keychain", str(keychain)], allow_failure=True)
                    # A failed creation may leave no keychain to delete. Its
                    # search-list entry was removed by the restoration above.
                    if deleted.returncode != 0 and keychain.exists():
                        raise SystemExit("The owned profile-decoding keychain could not be deleted safely.")
    return app, read_plist(app / "Info.plist"), details


def valid_test_summary(summary):
    keys = ("passedTests", "skippedTests", "totalTestCount", "failedTests")
    return (isinstance(summary, dict) and summary.get("result") == "Passed"
            and all(type(summary.get(key)) is int and summary[key] >= 0 for key in keys)
            and summary["passedTests"] > 0 and summary["failedTests"] == 0
            and summary["passedTests"] + summary["skippedTests"] == summary["totalTestCount"])


def xctest_results():
    results = {}
    for family in ("iphone", "ipad"):
        try:
            result = Path((BUILD / f"LatestTests-{family}.txt").read_text().strip())
        except OSError:
            raise SystemExit(f"Missing successful {family} XCTest result bundle.") from None
        if not result.is_dir():
            raise SystemExit(f"Missing successful {family} XCTest result bundle.")
        try:
            summary = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], text=True).stdout)
        except (ValueError, TypeError):
            raise SystemExit(f"Invalid {family} XCTest result summary.") from None
        if not valid_test_summary(summary):
            raise SystemExit(f"The {family} XCTest result must contain passed tests without failures.")
        results[family] = {"path": str(result), "result": "Passed", "passedTests": summary["passedTests"],
                           "skippedTests": summary["skippedTests"], "totalTests": summary["totalTestCount"], "failedTests": 0}
    return results


def verify_checks(stamp):
    if stamp.get("coreTests") != "passed" or stamp.get("privacyRegression") != "passed":
        raise SystemExit("The archive has no passed core and privacy regression validation.")
    results = stamp.get("xctestResults")
    if not isinstance(results, dict) or set(results) != {"iphone", "ipad"}:
        raise SystemExit("The archive requires passed iPhone and iPad XCTest validation.")
    for family, result in results.items():
        if not isinstance(result, dict) or not isinstance(result.get("path"), str):
            raise SystemExit(f"Invalid saved {family} XCTest validation.")
        summary = dict(result, totalTestCount=result.get("totalTests"))
        if not valid_test_summary(summary):
            raise SystemExit(f"The saved {family} XCTest validation contains missing or failed tests.")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("configuration", "stamp", "verify") or (sys.argv[1] != "configuration" and len(sys.argv) != 3):
        raise SystemExit("Usage: release-validation.py configuration|stamp|verify [archive]")
    config = check_configuration()
    mode = sys.argv[1]
    if mode == "configuration":
        print("Release app, extension identifiers, team, group, version and build configuration are structurally valid.")
        return
    archive = Path(sys.argv[2]).resolve()
    app, info, targets = archive_details(archive, config)
    stamp_path = archive / "FirePrivacyValidation.json"
    if mode == "stamp":
        stamp = {"schemaVersion": 2, "timestampUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                 "configuration": config, "targets": targets,
                 "bundleIdentifier": info["CFBundleIdentifier"], "teamIdentifier": config["teamIdentifier"],
                 "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                 "sdk": info["DTSDKName"], "hashes": targets["app"]["hashes"], "xctestResults": xctest_results(),
                 "physicalDeviceProtection": "requires physical device and locked-state QA; simulator cannot prove hardware Data Protection",
                 "coreTests": "passed", "privacyRegression": "passed"}
        stamp_path.write_text(json.dumps(stamp, indent=2) + "\n")
        return
    try:
        stamp = json.loads(stamp_path.read_text())
    except (OSError, ValueError, TypeError):
        raise SystemExit("The archive has no valid release validation stamp. Run archive-ios.sh again.") from None
    if not isinstance(stamp, dict) or stamp.get("schemaVersion") != 2 or stamp.get("configuration") != config or stamp.get("targets") != targets or stamp.get("hashes") != targets["app"]["hashes"]:
        raise SystemExit("The signed app, embedded extensions or release configuration changed after validation. Run archive-ios.sh again.")
    for key, expected in (("bundleIdentifier", config["bundleIdentifier"]), ("teamIdentifier", config["teamIdentifier"]), ("version", config["version"]), ("build", config["build"]), ("sdk", info["DTSDKName"])):
        if stamp.get(key) != expected:
            raise SystemExit("The saved archive metadata differs from its validated release configuration.")
    verify_checks(stamp)
    print("The signed app and selected edition extensions match their passed checks and release configuration.")


if __name__ == "__main__":
    main()
