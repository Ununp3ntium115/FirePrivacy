#!/usr/bin/env python3
"""Validate PUBLIC dataset trust configuration without handling private keys."""
import base64
import binascii
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MAXIMUM_BYTES = 16_384
MAXIMUM_KEYS = 32
KEY_ID = re.compile(r"[A-Za-z0-9_.-]{1,80}")
HEX_KEY = re.compile(r"[0-9a-f]{64}")
VARIABLES = {"knowledgeBase": "FIREPRIVACY_KB_PUBLIC_KEYS_JSON", "filter": "FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON"}
INFO_FIELDS = {"knowledgeBase": "FirePrivacyKnowledgeBasePublicKeysJSON", "filter": "FirePrivacyFilterPublicKeysJSON"}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate decoded JSON key")
        result[key] = value
    return result


def parse_keys(raw, label):
    if not isinstance(raw, str):
        raise SystemExit(f"{label} must be a JSON string containing public keys.")
    try:
        if len(raw.encode("utf-8")) > MAXIMUM_BYTES:
            raise ValueError("Oversized JSON")
        keys = {} if raw == "" else json.loads(raw, object_pairs_hook=unique_object)
        if not isinstance(keys, dict) or len(keys) > MAXIMUM_KEYS:
            raise ValueError("Invalid key map")
        if any(not isinstance(key, str) or not KEY_ID.fullmatch(key)
               or not isinstance(value, str) or not HEX_KEY.fullmatch(value)
               or value == "0" * 64 for key, value in keys.items()):
            raise ValueError("Invalid public key")
    except (ValueError, TypeError, UnicodeError, RecursionError):
        # A malformed binding might accidentally contain private material.
        # Do not include raw JSON or parser excerpts in error messages.
        raise SystemExit(f"{label} must contain at most 32 unique ASCII key IDs and nonzero 64-character lowercase-hex public keys, within 16,384 UTF-8 bytes.") from None
    return keys


def pinned_keys():
    """Read the actual reviewed bootstrap roots; never silently replace them."""
    try:
        source = (ROOT / "Sources/FirePrivacyCore/KnowledgeBaseResources.swift").read_text()
        identifier = re.search(r'public static let bootstrapKeyID = "([A-Za-z0-9_.-]{1,80})"', source)
        representation = re.search(r'publicKey: Data\(\[([^\]]+)\]\)', source)
        if source.count(".init(keyID:") != 1 or identifier is None or representation is None:
            raise ValueError("Update bootstrap root extraction after changing its representation")
        byte_tokens = [token.strip() for token in representation[1].split(",")]
        if len(byte_tokens) != 32 or any(not re.fullmatch(r"0x[0-9a-fA-F]{2}", token) for token in byte_tokens):
            raise ValueError("Malformed pinned knowledge root")
        knowledge = {identifier[1]: bytes(int(token, 16) for token in byte_tokens).hex()}
        filter_file = ROOT / "Sources/FirePrivacyCore/Resources/Protection/filter-trust-roots.json"
        raw_filter = json.loads(filter_file.read_text(), object_pairs_hook=unique_object)
        if not isinstance(raw_filter, dict):
            raise ValueError("Malformed pinned filter roots")
        filters = {key: base64.b64decode(value, validate=True).hex() for key, value in raw_filter.items()}
        knowledge = parse_keys(json.dumps(knowledge), "Pinned knowledge roots")
        filters = parse_keys(json.dumps(filters), "Pinned filter roots")
        if set(knowledge).intersection(filters):
            raise ValueError("Cross-family pinned root collision")
    except (OSError, ValueError, TypeError, binascii.Error):
        raise SystemExit("The reviewed bundled public trust roots are missing or inconsistent; update the root extraction and rerun validation.") from None
    return {"knowledgeBase": knowledge, "filter": filters}


def configuration(knowledge_raw="", filter_raw="", legacy_filter=None):
    pinned = pinned_keys()
    configured = {"knowledgeBase": parse_keys(knowledge_raw, INFO_FIELDS["knowledgeBase"]),
                  "filter": parse_keys(filter_raw, INFO_FIELDS["filter"])}
    merged = {}
    for family in VARIABLES:
        for key, value in configured[family].items():
            if key in pinned[family] and value != pinned[family][key]:
                raise SystemExit("Operator public keys must not replace a pinned bootstrap key.")
        merged[family] = {**pinned[family], **configured[family]}
    if set(merged["knowledgeBase"]).intersection(merged["filter"]):
        raise SystemExit("Knowledge-base and filter signing key IDs must remain separate, even when public-key bytes match.")
    if legacy_filter is not None:
        try:
            if not isinstance(legacy_filter, dict) or len(legacy_filter) > MAXIMUM_KEYS:
                raise ValueError("Invalid legacy roots")
            for key, value in legacy_filter.items():
                if not isinstance(key, str) or not isinstance(value, str) or len(value) > 128:
                    raise ValueError("Invalid legacy root")
                if key not in pinned["filter"] or base64.b64decode(value, validate=True).hex() != pinned["filter"][key]:
                    raise ValueError("Unknown or changed legacy root")
        except (ValueError, TypeError, binascii.Error):
            raise SystemExit("FirePrivacyFilterTrustKeys may contain only unchanged reviewed pinned filter roots; configure operator public keys through the JSON fields.") from None
    return merged


def environment_keys():
    return configuration(os.environ.get(VARIABLES["knowledgeBase"], ""),
                         os.environ.get(VARIABLES["filter"], ""))


def bundle_keys(info):
    if any(field not in info or not isinstance(info[field], str) for field in INFO_FIELDS.values()):
        raise SystemExit("Every app/provider Info.plist must contain both public-key JSON string fields.")
    return configuration(info[INFO_FIELDS["knowledgeBase"]], info[INFO_FIELDS["filter"]],
                         info.get("FirePrivacyFilterTrustKeys", {}))


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] != "validate":
        raise SystemExit("Usage: dataset-public-keys.py validate")
    environment_keys()
    print("Public dataset signing keys are bounded, separate by dataset family, and preserve pinned roots.")
