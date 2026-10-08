#!/usr/bin/env python3
"""Prepare temporary manual Apple signing on an isolated GitHub macOS runner.

Credentials are read only from environment bindings. All subprocess output is
captured, and failures intentionally omit command arguments and tool output.
Run ``cleanup`` from an always() step, including after a failed ``prepare``.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import ctypes
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile


PREFIX = "fireprivacy-signing-"
STATE_NAME = "state.json"
UUID_PATTERN = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
APPLE_ID_PATTERN = re.compile(r"[A-Z0-9]{10}")
KEY_ID_PATTERN = re.compile(r"[A-Za-z0-9]{1,64}")
BUNDLE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+")
ASC_BINDINGS = ("ASC_PRIVATE_KEY_BASE64", "ASC_KEY_ID", "ASC_ISSUER_ID")
APP_GROUP_DEFAULT = "group.com.firesoftwaresolutions.FirePrivacy.protection"
NETWORK_ENTITLEMENT = "com.apple.developer.networking.networkextension"
GROUP_ENTITLEMENT = "com.apple.security.application-groups"
EXTENSION_BINDINGS = {
    "SafariContentBlocker": ("APPLE_SAFARI_PROVISION_PROFILE_BASE64", "SAFARI_PROVISIONING_PROFILE_SPECIFIER", frozenset()),
    "URLFilterControl": ("APPLE_URL_PROVISION_PROFILE_BASE64", "URL_PROVISIONING_PROFILE_SPECIFIER", frozenset({"url-filter-provider"})),
    "ManagedFilterData": ("APPLE_MANAGED_DATA_PROVISION_PROFILE_BASE64", "MANAGED_DATA_PROVISIONING_PROFILE_SPECIFIER", frozenset({"content-filter-provider"})),
    "ManagedFilterControl": ("APPLE_MANAGED_CONTROL_PROVISION_PROFILE_BASE64", "MANAGED_CONTROL_PROVISIONING_PROFILE_SPECIFIER", frozenset({"content-filter-provider"})),
}
EDITION_EXTENSIONS = {
    "consumer": ("SafariContentBlocker",),
    "url-filter": ("SafariContentBlocker", "URLFilterControl"),
    "managed": ("SafariContentBlocker", "ManagedFilterData", "ManagedFilterControl"),
}
EDITION_CAPABILITIES = {
    "consumer": frozenset({"dns-settings"}),
    "url-filter": frozenset({"dns-settings", "url-filter-provider"}),
    "managed": frozenset({"dns-settings", "content-filter-provider"}),
}


class SigningError(Exception):
    """A safe, authored error message containing no credential values."""


def check_bindings(environment=None) -> dict:
    """Inventory presence only; never decode, sign, create files or call tools.

    Keep this before release identifier validation so an unconfigured bundle
    does not hide absent credentials. Existing prepare/configuration gates
    remain responsible for validity, registration and exact profile coverage.
    """
    environment = os.environ if environment is None else environment
    summary = {"schemaVersion": 1, "readOnly": True,
        "credentialValidityVerified": False, "identifierRegistrationVerified": False,
        "note": "Presence only. Existing release gates validate identifiers, credentials and profiles. "
                "APPLE_EXTENSION_PROFILES_BASE64 can replace selected individual extension profiles; "
                "its target coverage is not checked here."}
    mode = environment.get("RELEASE_MODE", "")
    edition = environment.get("APP_EDITION") or "consumer"
    if mode not in ("archive", "upload"):
        return {**summary, "status": "invalidMode", "invalidBindingNames": ["RELEASE_MODE"]}
    if edition not in EDITION_EXTENSIONS:
        return {**summary, "status": "invalidEdition", "invalidBindingNames": ["APP_EDITION"]}
    required_bindings = []
    if not (environment.get("APP_BASE_BUNDLE_ID") or environment.get("BUNDLE_ID")):
        required_bindings.append("APP_BASE_BUNDLE_ID")
    required_bindings.extend(("APPLE_DISTRIBUTION_P12_BASE64", "APPLE_DISTRIBUTION_P12_PASSWORD",
                              "APPLE_PROVISION_PROFILE_BASE64"))
    if not environment.get("APPLE_EXTENSION_PROFILES_BASE64"):
        required_bindings.extend(EXTENSION_BINDINGS[target][0] for target in EDITION_EXTENSIONS[edition])
    if mode == "upload" or any(environment.get(name) for name in ASC_BINDINGS):
        required_bindings.extend(ASC_BINDINGS)
    if edition == "url-filter":
        required_bindings.extend(("FIREPRIVACY_PIR_SERVER_URL", "FIREPRIVACY_PIR_CONFIGURATION_IDENTITY"))
    missing = [name for name in required_bindings if not environment.get(name)]
    return {**summary, "mode": mode, "edition": edition, "missingBindings": missing,
            "status": "missingBindings" if missing else "bindingsPresent"}


def require_runner() -> Path:
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise SigningError("Cloud signing requires an isolated GitHub macOS runner.")
    value = os.environ.get("RUNNER_TEMP", "")
    if not value or "\n" in value or "\r" in value:
        raise SigningError("RUNNER_TEMP must name the runner's temporary directory.")
    root = Path(value)
    if not root.is_absolute() or not root.is_dir():
        raise SigningError("RUNNER_TEMP must be an existing absolute directory.")
    root = root.resolve()
    checkout = Path(__file__).resolve().parents[1]
    if root == checkout or checkout in root.parents:
        raise SigningError("Signing material must be stored outside the checkout.")
    return root


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SigningError(f"Required environment binding {name} is missing or empty.")
    return value


def publish(name: str, value: str) -> None:
    if "\n" in value or "\r" in value:
        raise SigningError("A generated signing setting contains an invalid newline.")
    destination = Path(required("GITHUB_ENV"))
    if not destination.is_absolute() or not destination.is_file() or destination.is_symlink():
        raise SigningError("GITHUB_ENV must name the runner's existing environment file.")
    with destination.open("a", encoding="utf-8") as stream:
        stream.write(f"{name}={value}\n")


def private_write(path: Path, content: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)


def save_state(directory: Path, state: dict) -> None:
    temporary = directory / ".state.tmp"
    if temporary.exists():
        temporary.unlink()
    private_write(temporary, json.dumps(state).encode("utf-8"))
    temporary.replace(directory / STATE_NAME)


def decode_base64_value(encoded: str, name: str, maximum: int) -> bytes:
    if not isinstance(encoded, str) or not encoded:
        raise SigningError(f"Required profile binding {name} is missing or empty.")
    if len(encoded) > maximum * 2:
        raise SigningError(f"Environment binding {name} exceeds the expected size.")
    try:
        decoded = base64.b64decode("".join(encoded.split()), validate=True)
    except (ValueError, binascii.Error):
        raise SigningError(f"Environment binding {name} must contain valid base64.") from None
    if not decoded or len(decoded) > maximum:
        raise SigningError(f"Environment binding {name} has an invalid decoded size.")
    return decoded


def decode_binding(name: str, maximum: int) -> bytes:
    return decode_base64_value(required(name), name, maximum)


def selected_configuration() -> tuple[str, str, str]:
    base = os.environ.get("APP_BASE_BUNDLE_ID") or os.environ.get("BUNDLE_ID", "")
    legacy = os.environ.get("BUNDLE_ID", "")
    if not base or not BUNDLE_PATTERN.fullmatch(base) or (legacy and legacy != base):
        raise SigningError("APP_BASE_BUNDLE_ID must be a valid registered bundle identifier and agree with any BUNDLE_ID alias.")
    edition = os.environ.get("APP_EDITION") or "consumer"
    if edition not in EDITION_EXTENSIONS:
        raise SigningError("APP_EDITION must be consumer, url-filter, or managed.")
    group = os.environ.get("FIREPRIVACY_APP_GROUP_ID") or APP_GROUP_DEFAULT
    if not group.startswith("group.") or not BUNDLE_PATTERN.fullmatch(group):
        raise SigningError("FIREPRIVACY_APP_GROUP_ID must be a registered App Group identifier.")
    return base, edition, group


def extension_profiles(edition: str) -> dict[str, bytes]:
    """Decode only the selected edition's profiles, never privilege extras.

    Prefer individual secrets to stay within GitHub's per-secret size limit.
    The optional aggregate binding is a raw JSON object whose exact target-name
    keys map to base64 profiles; the JSON itself is not base64 encoded.
    """
    selected = EDITION_EXTENSIONS[edition]
    aggregate = os.environ.get("APPLE_EXTENSION_PROFILES_BASE64", "")
    if aggregate:
        if len(aggregate) > 40 * 1024 * 1024:
            raise SigningError("The extension profile map exceeds its expected size.")
        def unique_pairs(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise SigningError("The extension profile map contains duplicate target names.")
                result[key] = value
            return result
        try:
            values = json.loads(aggregate, object_pairs_hook=unique_pairs)
        except (ValueError, TypeError):
            raise SigningError("APPLE_EXTENSION_PROFILES_BASE64 must be a raw JSON target-name to base64-profile object.") from None
        if not isinstance(values, dict) or not set(values).issubset(EXTENSION_BINDINGS):
            raise SigningError("The extension profile map contains unknown target names.")
        if any(os.environ.get(EXTENSION_BINDINGS[name][0]) for name in selected):
            raise SigningError("Choose either an aggregate profile map or individual profiles for the selected edition.")
        return {name: decode_base64_value(values.get(name), name, 5 * 1024 * 1024) for name in selected}
    return {name: decode_binding(EXTENSION_BINDINGS[name][0], 5 * 1024 * 1024) for name in selected}


def run(arguments: list[str], description: str, *, allow_failure: bool = False) -> bytes | None:
    try:
        result = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        if allow_failure:
            return None
        raise SigningError(f"Unable to {description}; credential details were suppressed.") from None
    if result.returncode:
        if allow_failure:
            return None
        raise SigningError(f"Unable to {description}; credential details were suppressed.")
    return result.stdout


def apple_security_api():
    """Load the platform's Apple provisioning-profile verification policy.

    The policy identifier is defined in Apple's SecPolicyPriv.h; the CMSDecoder
    and SecPolicyCreateWithProperties functions are public macOS APIs. This
    runner-only use never links private policy identifiers into the app.
    Fail closed if the selected macOS runtime does not provide the policy.
    """
    try:
        security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        policy_identifier = ctypes.c_void_p.in_dll(security, "kSecPolicyAppleiPhoneProvisioningProfileSigning").value
        signatures = {
            "SecPolicyCreateWithProperties": ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_void_p),
            "CMSDecoderCreate": ([ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int32),
            "CMSDecoderUpdateMessage": ([ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t], ctypes.c_int32),
            "CMSDecoderFinalizeMessage": ([ctypes.c_void_p], ctypes.c_int32),
            "CMSDecoderGetNumSigners": ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
            "CMSDecoderCopySignerStatus": (
                [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_ubyte,
                 ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int32)],
                ctypes.c_int32,
            ),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(security, name)
            function.argtypes = arguments
            function.restype = result
        core.CFRelease.argtypes = [ctypes.c_void_p]
        core.CFRelease.restype = None
        if not policy_identifier:
            raise ValueError
        return security, core, policy_identifier
    except (OSError, AttributeError, ValueError):
        raise SigningError("macOS does not expose the required Apple provisioning-profile trust policy.") from None


def verify_apple_profile(profile: Path) -> None:
    # Unlike `security cms -D` process success, CMSDecoder signer status with
    # evaluateSecTrust=true proves both the CMS signature and certificate trust.
    # Apple's provisioning-profile policy pins Apple root anchors and requires
    # its designated intermediate and profile-signing leaf certificate chain.
    # Source: apple-oss-distributions/Security header_symlinks/Security/
    # SecPolicyPriv.h and CMSDecoder.h; OSX/sec/Security/SecPolicy.c.
    security, core, policy_identifier = apple_security_api()
    decoder = ctypes.c_void_p()
    policy = security.SecPolicyCreateWithProperties(policy_identifier, None)
    if not policy:
        raise SigningError("The Apple provisioning-profile trust policy could not be created.")
    try:
        content = profile.read_bytes()
        buffer = ctypes.create_string_buffer(content)
        if (
            security.CMSDecoderCreate(ctypes.byref(decoder)) != 0
            or not decoder.value
            or security.CMSDecoderUpdateMessage(decoder, buffer, len(content)) != 0
            or security.CMSDecoderFinalizeMessage(decoder) != 0
        ):
            raise SigningError("The provisioning profile CMS signature could not be decoded.")
        count = ctypes.c_size_t()
        if security.CMSDecoderGetNumSigners(decoder, ctypes.byref(count)) != 0 or not 1 <= count.value <= 16:
            raise SigningError("The provisioning profile must contain a verifiable Apple signer.")
        for index in range(count.value):
            signer_status = ctypes.c_uint32()
            trust = ctypes.c_void_p()
            certificate_status = ctypes.c_int32()
            try:
                result = security.CMSDecoderCopySignerStatus(
                    decoder, index, policy, True, ctypes.byref(signer_status),
                    ctypes.byref(trust), ctypes.byref(certificate_status),
                )
                # kCMSSignerValid == 1, and errSecSuccess == 0.
                if result != 0 or signer_status.value != 1 or certificate_status.value != 0 or not trust.value:
                    raise SigningError("The provisioning profile signature or Apple signer trust could not be verified.")
            finally:
                if trust.value:
                    core.CFRelease(trust)
    finally:
        if decoder.value:
            core.CFRelease(decoder)
        core.CFRelease(policy)


def profile_metadata(profile: Path, keychain: Path, team: str, bundle: str,
                     app_group: str | None = None,
                     required_network_capabilities: frozenset[str] = frozenset()) -> tuple[str, set[str]]:
    verify_apple_profile(profile)
    # -k confines security cms embedded certificate imports to our temporary
    # keychain. Never replace prior Apple-policy verification with plist extraction.
    payload = run(
        ["/usr/bin/security", "cms", "-D", "-k", str(keychain), "-i", str(profile)],
        "decode the verified provisioning profile",
    )
    try:
        data = plistlib.loads(payload)
    except (ValueError, TypeError, plistlib.InvalidFileException):
        raise SigningError("The verified provisioning profile is not a valid property list.") from None
    if not isinstance(data, dict):
        raise SigningError("The provisioning profile has an invalid structure.")
    identifier = data.get("UUID")
    if not isinstance(identifier, str) or not UUID_PATTERN.fullmatch(identifier):
        raise SigningError("The provisioning profile UUID must use the standard 36-character format.")
    identifier = identifier.upper()
    expiration = data.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        raise SigningError("The provisioning profile has no valid expiration date.")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    if expiration <= dt.datetime.now(dt.timezone.utc):
        raise SigningError("The provisioning profile has expired.")
    platforms = data.get("Platform")
    teams = data.get("TeamIdentifier")
    entitlements = data.get("Entitlements")
    if not isinstance(platforms, list) or "iOS" not in platforms:
        raise SigningError("The provisioning profile must support iOS.")
    if not isinstance(teams, list) or team not in teams or not isinstance(entitlements, dict):
        raise SigningError("The provisioning profile does not match the configured Apple team.")
    if entitlements.get("com.apple.developer.team-identifier") != team:
        raise SigningError("The provisioning profile entitlement does not match the Apple team.")
    prefixes = data.get("ApplicationIdentifierPrefix")
    if (
        not isinstance(prefixes, list)
        or not prefixes
        or not all(isinstance(prefix, str) and APPLE_ID_PATTERN.fullmatch(prefix) for prefix in prefixes)
        or not any(entitlements.get("application-identifier") == f"{prefix}.{bundle}" for prefix in prefixes)
    ):
        # Older or transferred apps may retain an App ID prefix that differs
        # from TeamIdentifier; verify the signed prefix and exact bundle while
        # retaining the independent team checks above.
        raise SigningError("An explicit provisioning profile matching the configured team and bundle is required.")
    if (
        "ProvisionedDevices" in data
        or "ProvisionsAllDevices" in data
        or entitlements.get("get-task-allow") is not False
    ):
        raise SigningError("An App Store distribution profile without device or development access is required.")
    if app_group is not None:
        groups = entitlements.get(GROUP_ENTITLEMENT)
        if not isinstance(groups, list) or app_group not in groups or not all(isinstance(group, str) for group in groups):
            raise SigningError("The provisioning profile does not grant the configured registered App Group.")
    if required_network_capabilities:
        capabilities = entitlements.get(NETWORK_ENTITLEMENT)
        if not isinstance(capabilities, list) or not all(isinstance(value, str) for value in capabilities) or not required_network_capabilities.issubset(capabilities):
            raise SigningError("The provisioning profile is missing the target's required Network Extension capabilities.")
    certificates = data.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates or not all(isinstance(item, bytes) for item in certificates):
        raise SigningError("The provisioning profile contains no valid distribution certificates.")
    return identifier, {hashlib.sha1(item).hexdigest().upper() for item in certificates}


def profile_directory() -> Path:
    # Xcode 16+ canonical location; Xcode also supports the legacy MobileDevice
    # directory, but installing one owned copy avoids duplicate-profile state.
    return Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"


def install_profile(directory: Path, source: Path, identifier: str, state: dict) -> None:
    destination_root = profile_directory()
    destination_root.mkdir(parents=True, exist_ok=True)
    destination = destination_root / f"{identifier}.mobileprovision"
    content = source.read_bytes()
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_file() or destination.read_bytes() != content:
            raise SigningError("An existing provisioning profile conflicts with the supplied UUID; it was preserved.")
        return
    # Keep an owned marker on the same filesystem. A hard link provides an
    # exact inode ownership check even if prepare is interrupted just after
    # installation, without ever overwriting an existing UUID path.
    descriptor, marker_name = tempfile.mkstemp(prefix=f".{PREFIX}", suffix=".mobileprovision", dir=destination_root)
    marker = Path(marker_name)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)
    owned = {"profile_uuid": identifier, "profile_marker": str(marker), "profile_target": str(destination),
             "profile_sha256": hashlib.sha256(content).hexdigest()}
    state.setdefault("profiles", []).append(owned)
    try:
        save_state(directory, state)
    except Exception:
        marker.unlink(missing_ok=True)
        raise
    try:
        os.link(marker, destination)
    except FileExistsError:
        raise SigningError("A provisioning profile appeared during setup; the existing file was preserved.") from None


def prepare() -> None:
    root = require_runner()
    mode = required("RELEASE_MODE")
    if mode not in {"archive", "upload"}:
        raise SigningError("RELEASE_MODE must be archive or upload.")
    team = os.environ.get("TEAM_ID", "LYDVWU62G4")
    bundle, edition, app_group = selected_configuration()
    if not APPLE_ID_PATTERN.fullmatch(team):
        raise SigningError("TEAM_ID has an invalid format.")
    password = required("APPLE_DISTRIBUTION_P12_PASSWORD")
    p12_data = decode_binding("APPLE_DISTRIBUTION_P12_BASE64", 10 * 1024 * 1024)
    profile_data = decode_binding("APPLE_PROVISION_PROFILE_BASE64", 5 * 1024 * 1024)
    extension_data = extension_profiles(edition)
    # GitHub workflow env declarations resolve absent secrets to empty values.
    # Empty ASC declarations do not turn an archive-only run into an upload.
    needs_asc = mode == "upload" or any(os.environ.get(name) for name in ASC_BINDINGS)
    asc_data = None
    key_id = None
    if needs_asc:
        key_id = required("ASC_KEY_ID")
        issuer_id = required("ASC_ISSUER_ID")
        if not KEY_ID_PATTERN.fullmatch(key_id) or not UUID_PATTERN.fullmatch(issuer_id):
            raise SigningError("ASC_KEY_ID or ASC_ISSUER_ID has an invalid format.")
        asc_data = decode_binding("ASC_PRIVATE_KEY_BASE64", 256 * 1024)

    directory = Path(tempfile.mkdtemp(prefix=PREFIX, dir=root))
    directory.chmod(0o700)
    # Publish before creating credentials or mutating the user's keychains so
    # the workflow's always() cleanup can recover from any subsequent failure.
    os.environ["FIREPRIVACY_SIGNING_DIR"] = str(directory)
    publish("FIREPRIVACY_SIGNING_DIR", str(directory))
    state: dict = {"version": 2, "profiles": []}
    save_state(directory, state)
    p12 = directory / "distribution.p12"
    profile = directory / "distribution.mobileprovision"
    private_write(p12, p12_data)
    private_write(profile, profile_data)
    profile_sources = {"app": profile}
    for name, content in extension_data.items():
        source = directory / f"{name}.mobileprovision"
        private_write(source, content)
        profile_sources[name] = source
    if asc_data is not None:
        asc_path = directory / f"AuthKey_{key_id}.p8"
        private_write(asc_path, asc_data)
        run(["/usr/bin/openssl", "pkey", "-in", str(asc_path), "-noout", "-check"], "validate the App Store Connect private key")

    original = run(["/usr/bin/security", "list-keychains", "-d", "user"], "read the existing keychain search list")
    try:
        keychains = shlex.split(original.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise SigningError("The existing keychain search list could not be parsed safely.") from None
    state["original_keychains"] = keychains
    keychain = directory / "signing.keychain-db"
    state["keychain"] = str(keychain)
    # Creating a keychain may itself update macOS's search list. Record the
    # restoration requirement before the first keychain mutation.
    state["search_list_changed"] = True
    save_state(directory, state)
    keychain_password = secrets.token_urlsafe(48)
    run(["/usr/bin/security", "create-keychain", "-p", keychain_password, str(keychain)], "create the temporary signing keychain")
    run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", str(keychain)], "set the temporary keychain timeout")
    run(["/usr/bin/security", "unlock-keychain", "-p", keychain_password, str(keychain)], "unlock the temporary signing keychain")
    metadata = {}
    for name, source in profile_sources.items():
        target_bundle = bundle if name == "app" else f"{bundle}.{name}"
        capabilities = EDITION_CAPABILITIES[edition] if name == "app" else EXTENSION_BINDINGS[name][2]
        metadata[name] = profile_metadata(source, keychain, team, target_bundle, app_group, capabilities)
    if len({value[0] for value in metadata.values()}) != len(metadata):
        raise SigningError("Every selected app or extension target must have a distinct provisioning profile UUID.")
    profile_certificates = set.intersection(*(value[1] for value in metadata.values()))
    if not profile_certificates:
        raise SigningError("All selected provisioning profiles must authorize a common distribution certificate.")
    run(
        ["/usr/bin/security", "import", str(p12), "-k", str(keychain), "-P", password,
         "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"],
        "import the supplied distribution identity",
    )
    run(
        ["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
         "-s", "-k", keychain_password, str(keychain)],
        "authorize Apple signing tools for the temporary keychain",
    )
    run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *keychains, str(keychain)], "append the temporary signing keychain")
    identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", str(keychain)], "find a trusted valid distribution identity")
    try:
        identity_text = identities.decode("utf-8")
    except UnicodeDecodeError:
        raise SigningError("The signing identity response could not be parsed safely.") from None
    trusted = {
        match.upper()
        for match in re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"', identity_text, re.MULTILINE)
    }
    matching = trusted & profile_certificates
    if len(matching) != 1:
        raise SigningError("Exactly one trusted valid signing identity must match every selected provisioning profile.")
    for name, source in profile_sources.items():
        install_profile(directory, source, metadata[name][0], state)
    publish("SIGNING_MODE", "manual")
    publish("APP_BASE_BUNDLE_ID", bundle)
    publish("BUNDLE_ID", bundle)
    publish("APP_EDITION", edition)
    publish("FIREPRIVACY_APP_GROUP_ID", app_group)
    publish("FIREPRIVACY_PROFILE_UUID", metadata["app"][0])
    publish("APP_PROVISIONING_PROFILE_SPECIFIER", metadata["app"][0])
    for name in extension_data:
        publish(EXTENSION_BINDINGS[name][1], metadata[name][0])
    publish("FIREPRIVACY_SIGNING_IDENTITY", matching.pop())
    if asc_data is not None:
        publish("ASC_KEY_PATH", str(asc_path))
    print("Temporary manual Apple signing is prepared; credentials were not logged.")


def cleanup() -> None:
    root = require_runner()
    value = os.environ.get("FIREPRIVACY_SIGNING_DIR", "")
    if not value:
        print("No temporary cloud signing directory was published.")
        return
    directory = Path(value)
    if (
        not directory.is_absolute()
        or directory.is_symlink()
        or directory.parent.resolve() != root
        or not directory.name.startswith(PREFIX)
    ):
        raise SigningError("Cleanup refused a directory outside the owned runner signing location.")
    if not directory.exists():
        print("Temporary cloud signing files are already removed.")
        return
    metadata = directory.stat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise SigningError("Cleanup refused an unowned or insecure signing directory.")
    failures: list[str] = []
    state: dict = {}
    try:
        state_path = directory / STATE_NAME
        if state_path.is_file() and not state_path.is_symlink():
            try:
                candidate = json.loads(state_path.read_text(encoding="utf-8"))
                if not isinstance(candidate, dict) or candidate.get("version") not in (1, 2):
                    raise ValueError
                state = candidate
            except (ValueError, OSError, UnicodeDecodeError):
                failures.append("The private cleanup state could not be read.")
        original = state.get("original_keychains")
        if state.get("search_list_changed"):
            if not isinstance(original, list) or not all(isinstance(item, str) and "\n" not in item and "\r" not in item for item in original):
                failures.append("The original keychain search list could not be restored safely.")
            elif run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original], "restore the original keychain search list", allow_failure=True) is None:
                failures.append("The original keychain search list could not be restored.")
        keychain = directory / "signing.keychain-db"
        if keychain.exists():
            if run(["/usr/bin/security", "delete-keychain", str(keychain)], "delete the temporary signing keychain", allow_failure=True) is None:
                failures.append("macOS could not delete the temporary signing keychain registration.")

        # Version 1 covered only the app profile. Preserve cleanup compatibility
        # while recording every selected target's owned inode in version 2.
        profiles = state.get("profiles", []) if state.get("version") == 2 else [state]
        if not isinstance(profiles, list) or len(profiles) > 5:
            failures.append("The owned provisioning profile cleanup list is invalid.")
            profiles = []
        for owned in profiles:
            if not isinstance(owned, dict):
                failures.append("The owned provisioning profile cleanup state is invalid.")
                continue
            identifier = owned.get("profile_uuid")
            marker_value = owned.get("profile_marker")
            target_value = owned.get("profile_target")
            if identifier is None and marker_value is None and target_value is None:
                continue
            owned_root = profile_directory().resolve()
            if not isinstance(identifier, str) or not UUID_PATTERN.fullmatch(identifier) or not isinstance(marker_value, str) or not isinstance(target_value, str):
                failures.append("The owned provisioning profile cleanup state is invalid.")
            else:
                marker = Path(marker_value)
                target = Path(target_value)
                safe_paths = (
                    marker.is_absolute() and target.is_absolute()
                    and marker.parent.resolve() == owned_root and target.parent.resolve() == owned_root
                    and marker.name.startswith(f".{PREFIX}")
                    and target.name == f"{identifier}.mobileprovision"
                    and not marker.is_symlink() and not target.is_symlink()
                )
                if not safe_paths:
                    failures.append("Cleanup refused a provisioning profile outside its owned location.")
                else:
                    try:
                        if target.exists() and marker.exists() and os.path.samefile(marker, target):
                            target.unlink()
                        if marker.exists():
                            marker.unlink()
                    except OSError:
                        failures.append("An owned provisioning profile could not be removed.")
    finally:
        # Includes decoded P12, mobileprovision, API key, keychain files, and
        # cleanup state even when an earlier cleanup operation reports failure.
        shutil.rmtree(directory)
    if failures:
        raise SigningError(" ".join(failures))
    print("Temporary Apple signing credentials were removed and the keychain search list restored.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("check-bindings", "prepare", "cleanup"))
    operation = parser.parse_args().operation
    if operation == "check-bindings":
        summary = check_bindings()
        print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
        return 0 if summary["status"] == "bindingsPresent" else 1
    try:
        if operation == "prepare":
            prepare()
        else:
            cleanup()
        return 0
    except SigningError as error:
        print(f"Cloud signing: {error}", file=sys.stderr)
    except Exception:
        # In particular, never print CalledProcessError, arbitrary exception
        # strings, tracebacks, environment values, or credential-bearing argv.
        print("Cloud signing failed; credential details were suppressed.", file=sys.stderr)
    if operation == "prepare" and os.environ.get("FIREPRIVACY_SIGNING_DIR"):
        try:
            cleanup()
        except SigningError as error:
            print(f"Cloud signing cleanup: {error}", file=sys.stderr)
        except Exception:
            print("Cloud signing cleanup encountered an error; credential details were suppressed.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
