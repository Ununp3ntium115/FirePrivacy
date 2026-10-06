#!/usr/bin/env python3
"""Prepare authenticated dataset downloads locally; never publish or create keys.

Only an operator-supplied Ed25519 private PEM key is used. Public-key deployment,
source accuracy/licensing, HTTPS hosting and Apple service approval are separate
operator duties. OpenSSL errors and credential material never enter output/logs.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import functools
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
MIB = 1024 * 1024
MAX_ENVELOPE = 8 * MIB  # The approved app transport's actual response bound.
MAX_FILTER_PAYLOAD = 5 * MIB  # Base64 plus manifest remains below MAX_ENVELOPE.
MAX_TIME = 253_402_300_799
MAX_INT64 = (1 << 63) - 1
MAX_UINT64 = (1 << 64) - 1
ED25519_PUBLIC_PREFIX = bytes.fromhex("302a300506032b6570032100")
FILTER_KINDS = ("safariDomainsV1", "appleURLBloomV1", "managedRulesV1")
RULE_IDS = {"AGG-APPLE-001", "AGG-CROSSAPP-002", "LOC-NET-003", "SENSOR-UNEXPECTED-004", "UNKNOWN-HIGHFANOUT-005", "VENDOR-KNOWN-006", "COVERAGE-GAP-007", "FRESHNESS-008"}
CATEGORIES = {"advertising", "analytics", "attribution", "authentication", "contentDelivery", "content", "crashReporting", "dataBroker", "fraudPrevention", "locationIntelligence", "messaging", "payments", "personalization", "pushNotifications", "social", "telemetry", "dnsResolution"}


class PublisherError(Exception):
    """Only fixed, non-sensitive messages may reach the CLI."""


def require(condition, message):
    if not condition:
        raise PublisherError(message)


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def b64(data):
    return base64.b64encode(data).decode("ascii")


def integer(value, minimum=0, maximum=MAX_INT64):
    require(type(value) is int and minimum <= value <= maximum, "Invalid integer or version bound.")
    return value


def numeric_version(value):
    require(isinstance(value, str) and re.fullmatch(r"(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){2}", value), "Expected a three-component numeric dataset/app version.")
    return tuple(map(int, value.split(".")))


def rule_version(value):
    parsed = numeric_version(value)
    require(all(len(part) <= 6 for part in value.split(".")), "Rule versions have at most six digits per component.")
    return parsed


def identifier(value, limit=80):
    require(isinstance(value, str) and len(value) <= limit and re.fullmatch(r"[A-Za-z0-9_.-]+", value), "Invalid signing/source identifier.")
    return value


def text(value, limit):
    require(isinstance(value, str) and bool(value.strip()) and all(unicodedata.category(c) not in ("Cc", "Cs") or c == "\n" for c in value) and len(value.encode("utf-8")) <= limit, "Missing, excessive or unsafe text.")
    return value


def ascii_token(value, limit):
    require(isinstance(value, str) and 0 < len(value) <= limit and all(33 <= ord(c) <= 126 for c in value), "Invalid ASCII configuration token.")
    return value


def https(value, *, source=False):
    require(isinstance(value, str) and 0 < len(value) <= 2048 and all(33 <= ord(c) <= 126 for c in value) and "\\" not in value, "Expected an ASCII HTTPS URL.")
    try:
        parsed = urlsplit(value)
        host, port = parsed.hostname, parsed.port
    except ValueError:
        raise PublisherError("Malformed HTTPS URL.") from None
    require(parsed.scheme == "https" and host and parsed.username is None and parsed.password is None and not parsed.fragment and (source or not parsed.query) and port in (None, 443), "HTTPS URL must have no credentials, fragment or unsupported port/query.")
    require(parsed.netloc == host + (":443" if port else ""), "Use a canonical lowercase ASCII HTTPS host.")
    require(host not in {"localhost", "example.com", "example.net", "example.org"} and not host.endswith((".example", ".invalid", ".test", ".localhost", ".local")), "A real operator HTTPS host is required, not a placeholder.")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        domain(host)
    else:
        raise PublisherError("Use a named operator HTTPS endpoint.")
    require(not re.search(r"%(?![0-9A-Fa-f]{2})", value), "Malformed URL percent encoding.")
    return value


def domain(value):
    require(isinstance(value, str) and 0 < len(value) <= 253 and value == value.lower() and "." in value and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in value.split(".")), "Expected a canonical ASCII/Punycode DNS domain.")
    require(not all(label.isdigit() for label in value.split(".")), "IP literals are not dataset domains.")
    return value


def fields(value, required, optional=()):
    require(type(value) is dict and set(required) <= set(value) <= set(required) | set(optional), "Unknown or missing JSON schema fields.")


def read_bytes(path, maximum, *, private=False):
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= maximum, "Input must be a nonempty bounded regular file.")
            if private:
                require(info.st_uid == os.getuid() and info.st_mode & 0o077 == 0, "Private key/passphrase file must be owned by you with no group/other access.")
            data = stream.read(maximum + 1)
    except (OSError, ValueError):
        raise PublisherError("Input file is unavailable or unsafe; file details suppressed.") from None
    require(0 < len(data) <= maximum, "Input exceeds its byte bound.")
    return data


def decode_json(data):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, "Duplicate JSON field.")
            result[key] = value
        return result
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(PublisherError("Non-finite JSON number.")))
        def depth(item, level=0):
            require(level <= 24, "JSON nesting exceeds the bound.")
            if isinstance(item, dict):
                for v in item.values(): depth(v, level + 1)
            elif isinstance(item, list):
                for v in item: depth(v, level + 1)
        depth(value)
        return value
    except (UnicodeError, ValueError, RecursionError):
        raise PublisherError("Malformed or excessively nested UTF-8 JSON.") from None


def input_json(path, maximum):
    data = read_bytes(path, maximum)
    return data, decode_json(data)


def iso_time(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value), "Use whole-second ISO8601 UTC dates.")
    try:
        result = int(dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp())
    except (ValueError, OverflowError):
        raise PublisherError("Invalid UTC date.") from None
    return integer(result, maximum=MAX_TIME)


def time_window(issued, expires, days, now):
    integer(issued, maximum=MAX_TIME); integer(expires, maximum=MAX_TIME)
    require(issued <= now + 300 and expires > now and 0 < expires - issued <= days * 86400, "Dataset time window is expired, future-dated or excessive.")


@functools.lru_cache(maxsize=1)
def suffix_rules():
    data = read_bytes(ROOT / "Sources/FirePrivacyCore/Resources/KnowledgeBase/public_suffix_list.dat", MIB)
    exact, wild, exceptions = set(), set(), set()
    for raw in data.decode("utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("//"): continue
        prefix = "!" if line.startswith("!") else "*." if line.startswith("*.") else ""
        key = line[len(prefix):].encode("idna").decode("ascii")
        (exceptions if prefix == "!" else wild if prefix else exact).add(key)
    return exact, wild, exceptions


def public_suffix(value):
    # Same pinned PSL and longest-match/exception semantics as PublicSuffixList.
    exact, wild, exceptions = suffix_rules()
    labels = value.split("."); best = None
    for i in range(len(labels)):
        candidate = ".".join(labels[i:])
        if candidate in exceptions: return ".".join(labels[i + 1:])
        if candidate in exact and (best is None or len(labels) - i > len(best.split("."))): best = candidate
        if i > 0 and candidate in wild and (best is None or len(labels) - i + 1 > len(best.split("."))): best = ".".join(labels[i - 1:])
    return best


def validate_kb(payload, issued, expires):
    fields(payload, {"schemaVersion", "datasetVersion", "sources", "classifications"})
    require(payload["schemaVersion"] == 1 and type(payload["schemaVersion"]) is int, "Unsupported payload schema.")
    numeric_version(payload["datasetVersion"])
    sources, records = payload["sources"], payload["classifications"]
    require(type(sources) is list and len(sources) <= 2000 and type(records) is list and len(records) <= 20_000, "Excessive knowledge records/sources.")
    source_ids, record_ids, patterns = set(), set(), set()
    for s in sources:
        fields(s, {"id", "title", "url", "type", "retrievedAt", "excerpt"})
        identifier(s["id"]); require(s["id"] not in source_ids, "Duplicate source identity."); source_ids.add(s["id"])
        text(s["title"], 240); text(s["excerpt"], 2000); https(s["url"], source=True)
        require(s["type"] in {"vendorDocumentation", "publishedResearch", "registryRecord", "internalReview"} and iso_time(s["retrievedAt"]) <= issued + 300, "Invalid source type/retrieval date.")
    for r in records:
        fields(r, {"id", "pattern", "patternKind", "categories", "purposes", "confidence", "sourceIDs", "lastReviewed", "reviewStatus", "notes"}, {"organization", "sdkFamily", "expiresAt"})
        identifier(r["id"]); require(r["id"] not in record_ids, "Duplicate classification identity."); record_ids.add(r["id"])
        host = domain(r["pattern"]); require(public_suffix(host) != host, "Classification cannot target a public suffix.")
        require(r["patternKind"] in {"exactHost", "domainSuffix"} and (r["patternKind"], host) not in patterns, "Duplicate or invalid classification pattern."); patterns.add((r["patternKind"], host))
        categories, ids, purposes = r["categories"], r["sourceIDs"], r["purposes"]
        require(type(categories) is list and 0 < len(categories) <= 8 and len(set(categories)) == len(categories) and set(categories) <= CATEGORIES, "Invalid classification categories.")
        require(type(ids) is list and 0 < len(ids) <= 8 and len(set(ids)) == len(ids) and set(ids) <= source_ids, "Classification needs valid unique citations.")
        require(type(purposes) is list and 0 < len(purposes) <= 8, "Invalid classification purposes.")
        for v in purposes: text(v, 400)
        require(type(r["confidence"]) in (int, float) and math.isfinite(r["confidence"]) and 0 <= r["confidence"] <= 1, "Invalid classification confidence.")
        require(r["reviewStatus"] in {"reviewed", "provisional", "disputed", "retired"}, "Invalid classification review status.")
        text(r["notes"], 2000)
        for field in ("organization", "sdkFamily"):
            if r.get(field) is not None: text(r[field], 240)
        reviewed = iso_time(r["lastReviewed"]); require(reviewed <= issued + 300, "Classification review is future-dated.")
        if r.get("expiresAt") is not None: require(reviewed < iso_time(r["expiresAt"]) <= expires, "Invalid classification expiry.")


def sorted_unique(values, validator, limit):
    require(type(values) is list and len(values) <= limit, "Excessive revocation entries.")
    for v in values: validator(v)
    require(len(set(values)) == len(values), "Duplicate revocation entry.")
    return sorted(values)


def hex_digest(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "Invalid payload digest.")


def validate_revocations(payload, kb):
    if kb:
        fields(payload, {"schemaVersion", "sequence", "revokedVersions", "revokedKeyIDs", "revokedPayloadDigests"})
        require(type(payload["schemaVersion"]) is int and payload["schemaVersion"] == 1, "Unsupported revocation schema.")
        integer(payload["sequence"], 1)
        keys = ("revokedVersions", "revokedKeyIDs", "revokedPayloadDigests")
        validators = (numeric_version, identifier, hex_digest)
        for k, validator in zip(keys, validators): payload[k] = sorted_unique(payload[k], validator, 10_000)
        require(sum(len(payload[k]) for k in keys) <= 10_000, "Excessive combined KB revocations.")
    else:
        fields(payload, {"targetKind", "revocations"}); require(payload["targetKind"] in FILTER_KINDS, "Invalid filter revocation target.")
        r = payload["revocations"]; fields(r, {"keyIDs", "versions", "payloadDigests"})
        for k, validator, limit in (("keyIDs", lambda v: ascii_token(v, 120), 1000), ("versions", lambda v: integer(v, 1, MAX_UINT64), 5000), ("payloadDigests", hex_digest, 5000)):
            r[k] = sorted_unique(r[k], validator, limit)


def validate_filter_payload(payload, kind, version, expires):
    if kind == "safariDomainsV1":
        require(type(payload) is list and 0 < len(payload) <= 50_000, "Safari dataset needs bounded domains.")
        for value in payload: domain(value)
        require(len(set(payload)) == len(payload), "Duplicate Safari domain.")
    elif kind == "managedRulesV1":
        fields(payload, {"version", "deploymentMode", "rules", "expiresAtSeconds"})
        require(integer(payload["version"], 1, MAX_UINT64) == version and integer(payload["expiresAtSeconds"], 1, MAX_TIME) <= expires, "Managed policy must match dataset version/expiry.")
        require(payload["deploymentMode"] in {"supervisedDevice", "mdmPerApp"} and type(payload["rules"]) is list and len(payload["rules"]) <= 50_000, "Invalid managed deployment/rule bound.")
        for rule in payload["rules"]:
            fields(rule, {"domain", "includeSubdomains", "action"}, {"appIdentifier"}); domain(rule["domain"])
            require(type(rule["includeSubdomains"]) is bool and rule["action"] in {"allow", "drop"}, "Invalid managed rule.")
            if rule.get("appIdentifier") is not None:
                require(isinstance(rule["appIdentifier"], str) and len(rule["appIdentifier"]) <= 200 and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", rule["appIdentifier"]), "Invalid managed app identifier.")


def validate_rules(payload):
    fields(payload, {"schemaVersion", "version", "implementationVersion", "rules"})
    require(type(payload["schemaVersion"]) is int and payload["schemaVersion"] == 1 and payload["implementationVersion"] == "ruleset-2.0.0", "Unsupported rule schema/compiled implementation.")
    rule_version(payload["version"])
    rules = payload["rules"]
    require(type(rules) is list and len(rules) == 8, "Rule configuration must contain all eight known detectors.")
    seen = set()
    for rule in rules:
        fields(rule, {"id", "enabled", "parameters"})
        require(isinstance(rule["id"], str) and rule["id"] in RULE_IDS and rule["id"] not in seen and type(rule["enabled"]) is bool, "Unknown, duplicate or malformed detector.")
        seen.add(rule["id"]); parameters = rule["parameters"]
        if rule["id"] == "AGG-CROSSAPP-002":
            fields(parameters, {"minimumDistinctApps"}); integer(parameters["minimumDistinctApps"], 3, 1000)
        elif rule["id"] == "UNKNOWN-HIGHFANOUT-005":
            fields(parameters, {"minimumDistinctDestinations", "maximumReviewedCoverage"})
            integer(parameters["minimumDistinctDestinations"], 10, 1000)
            coverage = parameters["maximumReviewedCoverage"]
            require(type(coverage) in (int, float) and math.isfinite(coverage) and 0.05 <= coverage <= 0.5, "Rule coverage parameter exceeds its reviewed range.")
        elif rule["id"] == "FRESHNESS-008":
            fields(parameters, {"minimumAgeDays"}); integer(parameters["minimumAgeDays"], 1, 365)
        else: fields(parameters, set())
    require(seen == RULE_IDS, "Rule configuration is incomplete.")


def rules_signing_bytes(manifest):
    keys = ("schemaVersion", "configurationVersion", "sequence", "generatedAt", "expiresAt", "minimumAppVersion", "ruleCount", "payloadSHA256", "signingKeyID")
    return ("\n".join(["FirePrivacy.AnalysisRules.v1", *(str(manifest[k]) for k in keys)]) + "\n").encode("ascii")


def kb_signing_bytes(manifest, revocations=False):
    if revocations:
        separator = "FirePrivacy.KnowledgeBaseRevocations.v1"
        keys = ("schemaVersion", "sequence", "generatedAt", "expiresAt", "revocationCount", "payloadByteCount", "payloadSHA256", "signingKeyID")
    else:
        separator = "FirePrivacy.KnowledgeBase.v1"
        keys = ("schemaVersion", "datasetVersion", "sequence", "generatedAt", "expiresAt", "minimumAppVersion", "recordCount", "payloadSHA256", "signingKeyID")
    return ("\n".join([separator, *(str(manifest[k]) for k in keys)]) + "\n").encode("ascii")


def openssl_path():
    candidates = [os.environ.get("FIREPRIVACY_OPENSSL_PATH"), shutil.which("openssl"), "/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"]
    for candidate in candidates:
        if not candidate or not os.access(candidate, os.X_OK): continue
        try:
            version = subprocess.run([candidate, "version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=False)
        except (OSError, subprocess.TimeoutExpired): continue
        if version.returncode == 0 and version.stdout.startswith(b"OpenSSL "): return candidate
    return None


class Signer:
    def __init__(self, key_path, passphrase_path=None):
        read_bytes(key_path, 16_384, private=True)
        self.key_path = str(Path(key_path).absolute())
        self.passin = ["-passin", "file:" + str(Path(passphrase_path).absolute())] if passphrase_path else []
        if passphrase_path: read_bytes(passphrase_path, 4096, private=True)
        self.openssl = openssl_path()
        require(self.openssl is not None, "OpenSSL with Ed25519 support is required.")
        self.public_der = self.run(["pkey", "-in", self.key_path, *self.passin, "-pubout", "-outform", "DER"])
        require(len(self.public_der) == 44 and self.public_der.startswith(ED25519_PUBLIC_PREFIX), "The supplied private key must be Ed25519.")
        self.public_key = self.public_der[len(ED25519_PUBLIC_PREFIX):]

    def run(self, arguments):
        try:
            result = subprocess.run([self.openssl, *arguments], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise PublisherError("OpenSSL operation unavailable/timed out; credential details suppressed.") from None
        require(result.returncode == 0, "OpenSSL operation failed; credential details suppressed.")
        return result.stdout

    def verify(self, message, signature):
        require(len(signature) == 64, "Invalid Ed25519 signature size.")
        with tempfile.TemporaryDirectory(prefix="fireprivacy-signature-") as name:
            root = Path(name)
            for path, data in ((root / "message", message), (root / "signature", signature), (root / "public.der", self.public_der)):
                path.write_bytes(data); path.chmod(0o600)
            self.run(["pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER", "-inkey", str(root / "public.der"), "-in", str(root / "message"), "-sigfile", str(root / "signature")])

    def sign(self, message):
        with tempfile.TemporaryDirectory(prefix="fireprivacy-signature-") as name:
            path = Path(name) / "message"; path.write_bytes(message); path.chmod(0o600)
            signature = self.run(["pkeyutl", "-sign", "-rawin", "-inkey", self.key_path, *self.passin, "-in", str(path)])
        self.verify(message, signature)
        return signature


def review_record(path, now):
    _, value = input_json(path, 128 * 1024)
    fields(value, {"schemaVersion", "reviewer", "reviewedAtSeconds", "changeSummary", "sources"})
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1, "Unsupported source-review schema.")
    text(value["reviewer"], 240); text(value["changeSummary"], 4000)
    require(integer(value["reviewedAtSeconds"], maximum=MAX_TIME) <= now + 300, "Source review is future-dated.")
    require(type(value["sources"]) is list and 0 < len(value["sources"]) <= 2000, "A bounded source-review record is required.")
    for source in value["sources"]:
        fields(source, {"url", "retrievedAtSeconds", "purpose", "license"}, {"sha256"})
        https(source["url"], source=True); text(source["purpose"], 2000); text(source["license"], 1000)
        require(integer(source["retrievedAtSeconds"], maximum=MAX_TIME) <= value["reviewedAtSeconds"] + 300, "Source retrieval is after the review.")
        if "sha256" in source: hex_digest(source["sha256"])
    return value


def prepare(args, now=None):
    now = int(time.time()) if now is None else integer(now, maximum=MAX_TIME)
    issued = now if args.issued_at is None else args.issued_at
    command = args.command
    revocation = command.endswith("revocations")
    kb = command.startswith("kb")
    rules = command == "rules"
    time_window(issued, args.expires_at, 90 if revocation or not kb else 366, now)
    endpoint = https(args.endpoint)
    key_id = identifier(args.key_id)
    review = review_record(args.review_record, now)
    maximum = 16_384 if rules else MIB if command == "kb-revocations" else 4 * MIB if kb else 512 * 1024 if revocation else MAX_FILTER_PAYLOAD
    raw = read_bytes(args.payload, maximum)
    input_digest = digest(raw)
    payload = None if command == "filter" and args.kind == "appleURLBloomV1" else decode_json(raw)
    if revocation:
        validate_revocations(payload, kb)
        raw = encoded(payload)  # Canonical sorted unique revocations are required.
    if rules:
        validate_rules(payload); rule_version(args.minimum_app_version)
        manifest = {"schemaVersion": 1, "configurationVersion": payload["version"], "sequence": integer(args.sequence, 1), "generatedAt": issued, "expiresAt": args.expires_at, "minimumAppVersion": args.minimum_app_version, "ruleCount": 8, "payloadSHA256": digest(raw), "signingKeyID": key_id}
        message = rules_signing_bytes(manifest)
    elif kb:
        sequence = integer(args.sequence, 1)
        manifest = {"schemaVersion": 1, "sequence": sequence, "generatedAt": issued, "expiresAt": args.expires_at, "payloadSHA256": digest(raw), "signingKeyID": key_id}
        if revocation:
            require(payload["sequence"] == sequence, "Revocation sequence must match the publisher sequence.")
            manifest.update(revocationCount=sum(len(payload[k]) for k in ("revokedVersions", "revokedKeyIDs", "revokedPayloadDigests")), payloadByteCount=len(raw))
        else:
            validate_kb(payload, issued, args.expires_at); numeric_version(args.minimum_app_version)
            manifest.update(datasetVersion=payload["datasetVersion"], minimumAppVersion=args.minimum_app_version, recordCount=len(payload["classifications"]))
            cited = {s["url"] for s in payload["sources"]}
            require(cited <= {s["url"] for s in review["sources"]}, "Source review must cover every knowledge citation.")
        message = kb_signing_bytes(manifest, revocation)
    else:
        version = integer(args.version, 1, MAX_UINT64); tag = ascii_token(args.tag, 120)
        kind = "revocationsV1" if revocation else args.kind
        manifest = {"schemaVersion": 1, "version": version, "kind": kind, "tag": tag, "issuedAtSeconds": issued, "expiresAtSeconds": args.expires_at, "payloadSHA256": digest(raw), "payloadByteCount": len(raw), "keyID": key_id}
        if kind == "appleURLBloomV1":
            bits = integer(args.bit_count, 1, MAX_FILTER_PAYLOAD * 8); integer(args.hash_count, 1, 32); integer(args.murmur_seed, 0, (1 << 32) - 1)
            require((bits + 7) // 8 == len(raw), "Apple Bloom byte count does not match bit count.")
            manifest.update(bitCount=bits, hashCount=args.hash_count, murmurSeed=args.murmur_seed, hashAlgorithm="fnv1a32-murmur3-x86-32-double-hash/1", pirServerURL=https(args.pir_server_url), appleConfigurationIdentity=ascii_token(args.apple_configuration_identity, 200))
            if args.privacy_pass_issuer_url is not None: manifest["privacyPassIssuerURL"] = https(args.privacy_pass_issuer_url)
        elif command == "filter":
            require(all(getattr(args, k) is None for k in ("bit_count", "hash_count", "murmur_seed", "pir_server_url", "privacy_pass_issuer_url", "apple_configuration_identity")), "Bloom/service fields are invalid for this filter target.")
            validate_filter_payload(payload, kind, version, args.expires_at)
        message = encoded(manifest)  # Swift nil optionals are omitted, never null.
    require(len(raw) <= maximum, "Normalized payload exceeds its target bound.")
    signer = Signer(args.private_key, args.passphrase_file)
    if args.previous_artifact:
        check_previous(args.previous_artifact, manifest, payload, signer, kb, revocation, rules=rules)
    signature = signer.sign(message)
    if rules:
        manifest["signatureBase64"] = b64(signature)
        manifest_bytes = encoded(manifest)
        envelope = {"rules": {"manifest": manifest, "payloadData": b64(raw)}}
    elif kb:
        manifest["signatureBase64"] = b64(signature)
        manifest_bytes = encoded(manifest)
        require(len(manifest_bytes) <= 16_384, "Manifest exceeds the app bound.")
        envelope = {"revocations": {"manifestData": b64(manifest_bytes), "payloadData": b64(raw)}} if revocation else {"manifest": b64(manifest_bytes), "payload": b64(raw)}
    else:
        manifest_bytes = encoded(manifest)
        envelope = {"manifest": manifest, "payload": b64(raw), "signature": b64(signature)}
    envelope_bytes = encoded(envelope)
    require(len(envelope_bytes) <= MAX_ENVELOPE, "Download envelope exceeds the approved transport response bound.")
    files = {"download.json": envelope_bytes, "manifest.json": manifest_bytes, "payload.bin" if payload is None else "payload.json": raw, "signing-message.bin": message}
    public_map = {key_id: signer.public_key.hex()}
    files["public-key-reference.json"] = encoded({"keyID": key_id, "publicKeyBase64": b64(signer.public_key), "publicKeyHex": signer.public_key.hex(), "publicKeySHA256": digest(signer.public_key), "buildVariableName": "FIREPRIVACY_KB_PUBLIC_KEYS_JSON" if kb or rules else "FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON", "buildVariableJSON": encoded(public_map).decode("ascii"), "requirement": "A matching trusted public key must be deployed in the app before this download is accepted; this file does not install or authorize a key."})
    record = {"schemaVersion": 1, "target": command, "payloadKind": manifest.get("kind"), "endpoint": endpoint, "preparedAtSeconds": now, "sourceReview": review, "inputPayloadSHA256": input_digest, "signedPayloadSHA256": digest(raw), "signingMessageSHA256": digest(message), "signingKeyID": key_id, "publicKeySHA256": digest(signer.public_key), "previousArtifactChecked": bool(args.previous_artifact), "artifacts": {name: {"sha256": digest(data), "bytes": len(data)} for name, data in files.items()}, "status": "Local artifacts only; no hosting, operator identity, key deployment, Apple approval or network publication verified."}
    files["source-review-and-changelog.json"] = encoded(record)
    return files


def check_previous(path, new, payload, signer, kb, revocation, *, rules=False):
    _, old = input_json(path, MAX_ENVELOPE)
    try:
        if rules:
            fields(old, {"rules"}); fields(old["rules"], {"manifest", "payloadData"})
            m = old["rules"]["manifest"]
            fields(m, {"schemaVersion", "configurationVersion", "sequence", "generatedAt", "expiresAt", "minimumAppVersion", "ruleCount", "payloadSHA256", "signingKeyID", "signatureBase64"})
            raw = base64.b64decode(old["rules"]["payloadData"], validate=True)
            require(type(m["schemaVersion"]) is int and m["schemaVersion"] == 1 and type(m["ruleCount"]) is int and m["ruleCount"] == 8 and 0 < len(raw) <= 16_384, "Invalid previous rule envelope schema/bounds.")
            time_window(m["generatedAt"], m["expiresAt"], 90, m["generatedAt"])
            identifier(m["signingKeyID"]); hex_digest(m["payloadSHA256"]); rule_version(m["minimumAppVersion"])
            signer.verify(rules_signing_bytes(m), base64.b64decode(m["signatureBase64"], validate=True))
            require(m["signingKeyID"] == new["signingKeyID"] and new["sequence"] > integer(m["sequence"], 1) and rule_version(new["configurationVersion"]) > rule_version(m["configurationVersion"]), "Rule publisher sequence and configuration version must increase.")
            old_payload = decode_json(raw); validate_rules(old_payload)
            require(old_payload["version"] == m["configurationVersion"], "Previous rule payload/manifest version mismatch.")
        elif kb:
            fields(old, {"revocations"} if revocation else {"manifest", "payload"})
            item = old["revocations"] if revocation else old
            if revocation: fields(item, {"manifestData", "payloadData"})
            m = decode_json(base64.b64decode(item["manifestData" if revocation else "manifest"], validate=True))
            raw = base64.b64decode(item["payloadData" if revocation else "payload"], validate=True)
            required = {"schemaVersion", "sequence", "generatedAt", "expiresAt", "payloadSHA256", "signingKeyID", "signatureBase64"}
            fields(m, required | ({"revocationCount", "payloadByteCount"} if revocation else {"datasetVersion", "minimumAppVersion", "recordCount"}))
            require(type(m["schemaVersion"]) is int and m["schemaVersion"] == 1 and len(encoded(m)) <= 16_384 and len(raw) <= (MIB if revocation else 4 * MIB), "Invalid previous knowledge envelope bounds/schema.")
            time_window(m["generatedAt"], m["expiresAt"], 90 if revocation else 366, m["generatedAt"])
            identifier(m["signingKeyID"]); hex_digest(m["payloadSHA256"])
            signer.verify(kb_signing_bytes(m, revocation), base64.b64decode(m["signatureBase64"], validate=True))
            require(m["signingKeyID"] == new["signingKeyID"] and new["sequence"] > integer(m["sequence"], 1), "Previous publisher sequence/key does not authorize this release.")
            if not revocation:
                require(numeric_version(new["datasetVersion"]) > numeric_version(m["datasetVersion"]), "Knowledge dataset version must increase.")
                numeric_version(m["minimumAppVersion"])
                old_payload = decode_json(raw); validate_kb(old_payload, m["generatedAt"], m["expiresAt"])
                require(old_payload["datasetVersion"] == m["datasetVersion"] and len(old_payload["classifications"]) == integer(m["recordCount"], 0, 20_000), "Previous knowledge metadata mismatch.")
        else:
            fields(old, {"manifest", "payload", "signature"}); m = old["manifest"]
            fields(m, {"schemaVersion", "version", "kind", "tag", "issuedAtSeconds", "expiresAtSeconds", "payloadSHA256", "payloadByteCount", "keyID"}, {"bitCount", "hashCount", "murmurSeed", "hashAlgorithm", "pirServerURL", "privacyPassIssuerURL", "appleConfigurationIdentity"})
            require(all(v is not None for v in m.values()), "Previous filter canonical fields cannot contain null.")
            raw = base64.b64decode(old["payload"], validate=True)
            require(type(m["schemaVersion"]) is int and m["schemaVersion"] == 1 and 0 < len(raw) <= (512 * 1024 if revocation else MAX_FILTER_PAYLOAD), "Invalid previous filter bounds/schema.")
            time_window(m["issuedAtSeconds"], m["expiresAtSeconds"], 90, m["issuedAtSeconds"])
            ascii_token(m["tag"], 120); identifier(m["keyID"]); hex_digest(m["payloadSHA256"])
            require(len(raw) == integer(m["payloadByteCount"], 1, MAX_FILTER_PAYLOAD), "Previous filter byte count mismatch.")
            signer.verify(encoded(m), base64.b64decode(old["signature"], validate=True))
            require(m["kind"] == new["kind"] and m["keyID"] == new["keyID"] and new["version"] > integer(m["version"], 1, MAX_UINT64), "Filter target/key/version must match and increase.")
        require(digest(raw) == m["payloadSHA256"], "Previous artifact payload authentication mismatch.")
        if revocation:
            previous = decode_json(raw); validate_revocations(previous, kb)
            if kb:
                require(previous["sequence"] == m["sequence"] and len(raw) == integer(m["payloadByteCount"], 1, MIB) and sum(len(previous[k]) for k in ("revokedVersions", "revokedKeyIDs", "revokedPayloadDigests")) == integer(m["revocationCount"], 0, 10_000), "Previous revocation metadata mismatch.")
            if not kb: require(previous["targetKind"] == payload["targetKind"], "Revocation target cannot change.")
            before, after = (previous, payload) if kb else (previous["revocations"], payload["revocations"])
            keys = ("revokedVersions", "revokedKeyIDs", "revokedPayloadDigests") if kb else ("keyIDs", "versions", "payloadDigests")
            require(all(set(before[k]) <= set(after[k]) for k in keys), "Authenticated sticky revocations cannot be removed.")
            require(new["signingKeyID" if kb else "keyID"] not in before["revokedKeyIDs" if kb else "keyIDs"], "A previously revoked signing key cannot publish new authority.")
    except (KeyError, TypeError, ValueError, UnicodeError):
        raise PublisherError("Previous artifact is malformed; details suppressed.") from None


def write_artifacts(output, files):
    destination = Path(output).absolute()
    require(not destination.exists() and not destination.is_symlink() and destination.parent.is_dir(), "Choose a new output directory under an existing parent.")
    try:
        with tempfile.TemporaryDirectory(prefix=".fireprivacy-publisher-", dir=destination.parent) as name:
            staging = Path(name) / "artifacts"; staging.mkdir(mode=0o700)
            for filename, data in files.items():
                path = staging / filename; path.write_bytes(data); path.chmod(0o600)
            # Reservation prevents overwriting a concurrently created directory.
            destination.mkdir(mode=0o700)
            try:
                for filename in files: os.replace(staging / filename, destination / filename)
            except OSError:
                shutil.rmtree(destination)
                raise
    except OSError:
        raise PublisherError("Artifact write failed; no release was published.") from None


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    subs = result.add_subparsers(dest="command", required=True)
    for command in ("kb", "kb-revocations", "filter", "filter-revocations", "rules"):
        p = subs.add_parser(command)
        for name in ("payload", "private-key", "key-id", "review-record", "endpoint", "output"):
            p.add_argument("--" + name, required=True)
        p.add_argument("--passphrase-file")
        p.add_argument("--previous-artifact", help="Prior same-key download; authenticate and enforce increasing version/sticky revocations")
        p.add_argument("--issued-at", type=int)
        p.add_argument("--expires-at", type=int, required=True)
        if command.startswith("kb") or command == "rules":
            p.add_argument("--sequence", type=int, required=True)
            if command in ("kb", "rules"): p.add_argument("--minimum-app-version", required=True)
        else:
            p.add_argument("--version", type=int, required=True)
            p.add_argument("--tag", required=True)
            if command == "filter":
                p.add_argument("--kind", choices=FILTER_KINDS, required=True)
                for option in ("bit-count", "hash-count", "murmur-seed"): p.add_argument("--" + option, type=int)
                for option in ("pir-server-url", "privacy-pass-issuer-url", "apple-configuration-identity"): p.add_argument("--" + option)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        files = prepare(args)
        write_artifacts(args.output, files)
    except (PublisherError, TypeError, OverflowError, UnicodeError) as error:
        message = str(error) if isinstance(error, PublisherError) else "Invalid schema/value; details suppressed."
        print("Dataset preparation failed: " + message, file=sys.stderr)
        return 1
    print("Prepared local signed artifacts. No network publication performed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
