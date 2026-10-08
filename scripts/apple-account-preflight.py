#!/usr/bin/env python3
"""Read-only App Store Connect identity/capability probe; never registers anything.

Only the three existing ASC environment bindings are used. Key material lives
briefly in a private system temporary directory; JWTs and raw responses are
never printed. A matching BundleId.seedId is prefix evidence, not proof of
membership, agreements, an exact DNS entitlement or App Group association.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
API = "https://api.appstoreconnect.apple.com"
BINDINGS = ("ASC_PRIVATE_KEY_BASE64", "ASC_KEY_ID", "ASC_ISSUER_ID")
KEY_ID_PATTERN = re.compile(r"[A-Za-z0-9]{1,64}")
DEFAULT_BUNDLE = "com.firesoftwaresolutions.FirePrivacy"
DEFAULT_TEAM = "LYDVWU62G4"
MAXIMUM_RESPONSE = 262_144
P256_SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")
APPLE_CODES = frozenset({"NOT_AUTHORIZED", "FORBIDDEN_ERROR", "NOT_FOUND", "NOT_FOUND_ERROR",
    "PARAMETER_ERROR.INVALID", "PARAMETER_ERROR.MISSING", "PARAMETER_ERROR.UNKNOWN",
    "ENTITY_ERROR.ATTRIBUTE.INVALID", "RATE_LIMIT_EXCEEDED", "UNEXPECTED_ERROR"})


class PreflightError(Exception):
    def __init__(self, code: str, *, http_status: int | None = None,
                 apple_codes: tuple[str, ...] = (), bindings: tuple[str, ...] = (),
                 authenticated: bool = False):
        self.code, self.http_status = code, http_status
        self.apple_codes, self.bindings = apple_codes, bindings
        self.authenticated = authenticated
        super().__init__(code)


def public_configuration(bundle: str, team: str) -> dict:
    if not isinstance(bundle, str) or len(bundle) > 255 or not re.fullmatch(
            r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
        raise PreflightError("invalidConfiguration")
    if not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise PreflightError("invalidConfiguration")
    # Reuse the release verifier's actual consumer extension suffix.
    spec = importlib.util.spec_from_file_location("fireprivacy_preflight_editions", ROOT / "scripts/release-validation.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    suffix = module.TARGETS["safari"][1]
    return {"expectedTeamID": team, "bundleIdentifiers": {"app": bundle, "safari": bundle + suffix}}


def credentials(environment: dict) -> tuple[bytes, str, str]:
    missing = tuple(name for name in BINDINGS if not environment.get(name))
    if missing:
        raise PreflightError("missingBindings", bindings=missing)
    key_id, issuer = environment[BINDINGS[1]], environment[BINDINGS[2]]
    if not isinstance(key_id, str) or not KEY_ID_PATTERN.fullmatch(key_id):
        raise PreflightError("invalidBindings", bindings=(BINDINGS[1],))
    if not isinstance(issuer, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", issuer):
        raise PreflightError("invalidBindings", bindings=(BINDINGS[2],))
    encoded = environment[BINDINGS[0]]
    try:
        if not isinstance(encoded, str) or len(encoded) > 32_768:
            raise ValueError()
        key = base64.b64decode("".join(encoded.split()), validate=True)
        if not 64 <= len(key) <= 16_384:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise PreflightError("invalidBindings", bindings=(BINDINGS[0],)) from None
    return key, key_id, issuer


def openssl(arguments: list[str], data: bytes | None = None) -> bytes:
    executable = shutil.which("openssl")
    if not executable:
        raise PreflightError("opensslUnavailable")
    try:
        result = subprocess.run([executable, *arguments], input=data, capture_output=True, timeout=15, check=True)
    except (OSError, subprocess.SubprocessError):
        raise PreflightError("keyValidationOrSigningFailed") from None
    if len(result.stdout) > 8_192:
        raise PreflightError("keyValidationOrSigningFailed")
    return result.stdout


def der_to_raw(signature: bytes) -> bytes:
    # OpenSSL emits canonical short DER for two positive P-256 integers.
    if len(signature) < 8 or len(signature) > 72 or signature[0] != 0x30 or signature[1] != len(signature) - 2:
        raise PreflightError("keyValidationOrSigningFailed")
    offset, components = 2, []
    for _ in range(2):
        if offset + 2 > len(signature) or signature[offset] != 2:
            raise PreflightError("keyValidationOrSigningFailed")
        count = signature[offset + 1]
        value = signature[offset + 2:offset + 2 + count]
        offset += 2 + count
        if not 1 <= count <= 33 or len(value) != count or value[0] & 0x80:
            raise PreflightError("keyValidationOrSigningFailed")
        if len(value) > 1 and value[0] == 0 and not value[1] & 0x80:
            raise PreflightError("keyValidationOrSigningFailed")
        if count == 33:
            if value[0] != 0:
                raise PreflightError("keyValidationOrSigningFailed")
            value = value[1:]
        if not any(value):
            raise PreflightError("keyValidationOrSigningFailed")
        components.append(value.rjust(32, b"\0"))
    if offset != len(signature):
        raise PreflightError("keyValidationOrSigningFailed")
    return b"".join(components)


def jwt(key: bytes, key_id: str, issuer: str, *, now: int | None = None) -> str:
    if not isinstance(key_id, str) or not KEY_ID_PATTERN.fullmatch(key_id):
        raise PreflightError("invalidBindings", bindings=(BINDINGS[1],))
    timestamp = int(time.time()) if now is None else now
    if not isinstance(timestamp, int) or isinstance(timestamp, bool) or not 0 <= timestamp <= 253_402_300_499:
        raise PreflightError("invalidClock")
    def segment(value: dict) -> bytes:
        return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":"), sort_keys=True).encode()).rstrip(b"=")
    signing = segment({"alg": "ES256", "kid": key_id, "typ": "JWT"}) + b"." + segment(
        {"iss": issuer, "iat": timestamp, "exp": timestamp + 300, "aud": "appstoreconnect-v1"})
    # Explicit /tmp avoids a checkout-directed TMPDIR or retained artifact path.
    with tempfile.TemporaryDirectory(prefix="fireprivacy-asc-readonly-", dir="/tmp") as temporary:
        directory = Path(temporary)
        if directory.resolve().is_relative_to(ROOT):
            raise PreflightError("unsafeTemporaryDirectory")
        os.chmod(directory, 0o700)
        path = directory / "AuthKey.p8"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(key)
        public = openssl(["pkey", "-in", str(path), "-pubout", "-outform", "DER"])
        if len(public) != 91 or not public.startswith(P256_SPKI_PREFIX):
            raise PreflightError("keyMustBeP256")
        signature = der_to_raw(openssl(["dgst", "-sha256", "-sign", str(path)], signing))
    return (signing + b"." + base64.urlsafe_b64encode(signature).rstrip(b"=")).decode("ascii")


class RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, stream, code, message, headers, new_url):
        raise PreflightError("redirectRejected", http_status=code)


def unique_json(data: bytes):
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError()
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError()
    return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid_constant)


def response_bytes(response) -> bytes:
    data = response.read(MAXIMUM_RESPONSE + 1)
    if len(data) > MAXIMUM_RESPONSE:
        raise PreflightError("responseTooLarge")
    length = response.headers.get("Content-Length")
    if length is not None:
        if not isinstance(length, str) or not re.fullmatch(r"[0-9]{1,9}", length) or int(length) != len(data):
            raise PreflightError("responseTruncated")
    return data


def get_json(path: str, token: str, *, query: dict | None = None, opener=None) -> dict:
    url = API + path + ("?" + urlencode(query) if query else "")
    request = Request(url, headers={"Authorization": "Bearer " + token, "Accept": "application/json"}, method="GET")
    client = opener or build_opener(HTTPSHandler(context=ssl.create_default_context()), RejectRedirects())
    try:
        with client.open(request, timeout=20) as response:
            if response.geturl() != url:
                raise PreflightError("redirectRejected")
            if response.status != 200:
                raise PreflightError("httpError", http_status=response.status)
            body = unique_json(response_bytes(response))
    except HTTPError as error:
        codes = ()
        try:
            parsed = unique_json(response_bytes(error))
            codes = tuple(sorted({item["code"] for item in parsed.get("errors", [])
                if isinstance(item, dict) and isinstance(item.get("code"), str) and item["code"] in APPLE_CODES}))
        except Exception:
            pass
        raise PreflightError("redirectRejected" if 300 <= error.code < 400 else "httpError",
            http_status=error.code, apple_codes=codes) from None
    except PreflightError:
        raise
    except http.client.IncompleteRead:
        raise PreflightError("responseTruncated") from None
    except (URLError, OSError, TimeoutError):
        raise PreflightError("connectionFailed") from None
    except (ValueError, TypeError, RecursionError):
        raise PreflightError("invalidResponse") from None
    if not isinstance(body, dict) or "errors" in body:
        raise PreflightError("invalidResponse")
    return body


def complete_collection(body: dict) -> list:
    data, links = body.get("data"), body.get("links", {})
    if not isinstance(data, list) or len(data) > 200 or not isinstance(links, dict):
        raise PreflightError("invalidResponse")
    if links.get("next") not in (None, ""):
        raise PreflightError("responseIncomplete")
    paging = body.get("meta", {}).get("paging", {}) if isinstance(body.get("meta", {}), dict) else None
    if not isinstance(paging, dict):
        raise PreflightError("invalidResponse")
    if paging.get("nextCursor") not in (None, ""):
        raise PreflightError("responseIncomplete")
    if "total" in paging and (type(paging["total"]) is not int or paging["total"] != len(data)):
        raise PreflightError("responseIncomplete")
    return data


def probe(config: dict, token: str, *, opener=None) -> dict:
    authenticated = False
    def fetch(path, *, query):
        nonlocal authenticated
        body = get_json(path, token, query=query, opener=opener)
        authenticated = True
        return body
    try:
        return probe_details(config, fetch)
    except PreflightError as error:
        error.authenticated = authenticated
        raise


def probe_details(config: dict, fetch) -> dict:
    found = {}
    for target, identifier in config["bundleIdentifiers"].items():
        data = complete_collection(fetch("/v1/bundleIds", query={"filter[identifier]": identifier,
            "fields[bundleIds]": "identifier,platform,seedId", "limit": "200"}))
        matches = [item for item in data if isinstance(item, dict) and isinstance(item.get("attributes"), dict)
            and item["attributes"].get("identifier") == identifier]
        if not matches:
            raise PreflightError("identifierNotRegistered")
        if len(matches) != 1:
            raise PreflightError("identifierAmbiguous")
        item, attributes = matches[0], matches[0]["attributes"]
        resource = item.get("id")
        if item.get("type") != "bundleIds" or not isinstance(resource, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", resource):
            raise PreflightError("invalidResponse")
        if attributes.get("platform") not in ("IOS", "UNIVERSAL"):
            raise PreflightError("platformMismatch")
        seed = attributes.get("seedId")
        if not isinstance(seed, str) or not re.fullmatch(r"[A-Z0-9]{10}", seed):
            raise PreflightError("teamPrefixUnconfirmed")
        if seed != config["expectedTeamID"]:
            raise PreflightError("teamPrefixMismatch")
        found[target] = {"identifier": identifier, "resourceID": resource, "seedID": seed}
    for target, item in found.items():
        data = complete_collection(fetch("/v1/bundleIds/" + item["resourceID"] + "/bundleIdCapabilities",
            query={"limit": "200"}))
        types = set()
        for capability in data:
            if not isinstance(capability, dict) or capability.get("type") != "bundleIdCapabilities" or not isinstance(capability.get("attributes"), dict):
                raise PreflightError("invalidResponse")
            value = capability["attributes"].get("capabilityType")
            if not isinstance(value, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,79}", value):
                raise PreflightError("invalidResponse")
            types.add(value)
        required = {"APP_GROUPS", "NETWORK_EXTENSIONS"} if target == "app" else {"APP_GROUPS"}
        item["requiredCapabilityTypesPresent"] = sorted(types & required)
        item["missingCapabilityTypes"] = sorted(required - types)
    return {"authenticated": True, "matchingIdentifierPrefix": True, "identifiers": found,
        "membershipVerified": False, "exactDNSEntitlementVerified": False, "appGroupAssociationVerified": False}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default=os.environ.get("APP_BASE_BUNDLE_ID") or DEFAULT_BUNDLE)
    parser.add_argument("--team-id", default=os.environ.get("APPLE_TEAM_ID") or os.environ.get("TEAM_ID") or DEFAULT_TEAM)
    args = parser.parse_args(argv)
    summary = {"schemaVersion": 1, "readOnly": True, "mutationsAllowed": False,
        "authenticated": False, "matchingIdentifierPrefix": False, "membershipVerified": False}
    try:
        config = public_configuration(args.bundle_id, args.team_id)
        summary.update(config)
        key, key_id, issuer = credentials(os.environ)
        summary.update(probe(config, jwt(key, key_id, issuer)))
        summary["status"] = "capabilitiesMissing" if any(value["missingCapabilityTypes"] for value in summary["identifiers"].values()) else "readOnlyPreflightComplete"
        exit_code = 1 if summary["status"] == "capabilitiesMissing" else 0
    except PreflightError as error:
        summary["status"] = error.code
        summary["authenticated"] = error.authenticated
        if error.bindings:
            summary["bindingNames"] = list(error.bindings)
        if error.http_status is not None:
            summary["httpStatus"] = error.http_status
        if error.apple_codes:
            summary["appleErrorCodes"] = list(error.apple_codes)
        exit_code = 1
    except Exception:
        summary["status"] = "preflightFailed"
        exit_code = 1
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
