"""Public dataset trust gates. No private keys, network, or Apple credentials."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("fireprivacy_public_keys_tested", ROOT / "scripts/dataset-public-keys.py")
PUBLIC_KEYS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLIC_KEYS)


class DatasetPublicKeysTests(unittest.TestCase):
    def test_empty_configuration_preserves_actual_bundled_pins(self):
        pinned = PUBLIC_KEYS.pinned_keys()
        self.assertEqual(set(pinned), {"knowledgeBase", "filter"})
        self.assertEqual(pinned["knowledgeBase"]["fireprivacy-bootstrap-2026-10"],
                         "9a0a157127033232629d4851b1b6484053cd912306f806473852b7999e96be5b")
        self.assertTrue(pinned["filter"])
        self.assertEqual(PUBLIC_KEYS.configuration(), pinned)
        self.assertEqual(PUBLIC_KEYS.configuration("{}", "{}"), pinned)
        self.assertEqual(PUBLIC_KEYS.configuration(json.dumps(pinned["knowledgeBase"]), json.dumps(pinned["filter"])), pinned)

    def test_rejects_malformed_duplicate_and_non_public_key_bindings(self):
        valid = "1" * 64
        malformed = [" ", "null", "[]", "false", '{"id":true}', '{"id":32}', '{"id":{}}',
                     '{"id":null}', json.dumps({"": valid}), json.dumps({"with space": valid}),
                     json.dumps({"é": valid}), json.dumps({"x" * 81: valid}),
                     json.dumps({"id": "0" * 64}), json.dumps({"id": "A" * 64}),
                     json.dumps({"id": "1" * 63}), json.dumps({"id": "1" * 65}),
                     '{"id":"' + valid + '","id":"' + valid + '"}',
                     '{"id":"' + valid + '","\\u0069d":"' + valid + '"}',
                     '{"id":"' + valid + '"} trailing',
                     json.dumps({str(i): valid for i in range(33)}),
                     "[" * 2_000 + "]" * 2_000]
        for raw in malformed:
            with self.subTest(index=malformed.index(raw)), self.assertRaises(SystemExit):
                PUBLIC_KEYS.parse_keys(raw, "Test public keys")
        for raw in [None, {}, 32]:
            with self.subTest(type=type(raw).__name__), self.assertRaises(SystemExit):
                PUBLIC_KEYS.parse_keys(raw, "Test public keys")

    def test_key_count_and_utf8_byte_limits_have_explicit_boundaries(self):
        mapping = {f"operator-{i}": "1" * 64 for i in range(32)}
        encoded = json.dumps(mapping)
        boundary = encoded + " " * (PUBLIC_KEYS.MAXIMUM_BYTES - len(encoded.encode("utf-8")))
        self.assertEqual(PUBLIC_KEYS.parse_keys(boundary, "Boundary public keys"), mapping)
        merged = PUBLIC_KEYS.configuration(boundary)["knowledgeBase"]
        self.assertEqual(len(merged), 32 + len(PUBLIC_KEYS.pinned_keys()["knowledgeBase"]))
        with self.assertRaises(SystemExit):
            PUBLIC_KEYS.parse_keys(boundary + " ", "Oversized public keys")

    def test_pinned_replacements_and_cross_family_ids_are_rejected(self):
        pinned = PUBLIC_KEYS.pinned_keys()
        for family, variable in (("knowledgeBase", 0), ("filter", 1)):
            key = next(iter(pinned[family]))
            fields = ["", ""]
            fields[variable] = json.dumps({key: "2" * 64})
            with self.subTest(family=family), self.assertRaises(SystemExit):
                PUBLIC_KEYS.configuration(*fields)
            fields = ["", ""]
            fields[1 - variable] = json.dumps({key: pinned[family][key]})
            with self.subTest(pinnedCrossFamily=family), self.assertRaises(SystemExit):
                PUBLIC_KEYS.configuration(*fields)
        for second_value in ("1" * 64, "2" * 64):
            with self.subTest(matchingBytes=second_value == "1" * 64), self.assertRaises(SystemExit):
                PUBLIC_KEYS.configuration(json.dumps({"operator": "1" * 64}), json.dumps({"operator": second_value}))

    def test_legacy_base64_map_is_only_an_unchanged_pin_path(self):
        pinned = PUBLIC_KEYS.pinned_keys()
        legacy = {key: base64.b64encode(bytes.fromhex(value)).decode("ascii") for key, value in pinned["filter"].items()}
        self.assertEqual(PUBLIC_KEYS.configuration(legacy_filter=legacy), pinned)
        key = next(iter(legacy))
        for malformed in [[], {"unknown": legacy[key]}, {key: "not base64"},
                          {key: base64.b64encode(bytes([3]) * 32).decode("ascii")},
                          {key: "A" * 129}, {key: 32}]:
            with self.subTest(type=type(malformed).__name__), self.assertRaises(SystemExit):
                PUBLIC_KEYS.configuration(legacy_filter=malformed)

    def test_environment_and_every_bundle_use_equivalent_semantic_maps(self):
        knowledge = json.dumps({"operator-knowledge": "1" * 64})
        filters = json.dumps({"operator-filter": "2" * 64})
        with mock.patch.dict(os.environ, {PUBLIC_KEYS.VARIABLES["knowledgeBase"]: knowledge,
                                         PUBLIC_KEYS.VARIABLES["filter"]: filters}, clear=True):
            expected = PUBLIC_KEYS.environment_keys()
        info = {PUBLIC_KEYS.INFO_FIELDS["knowledgeBase"]: knowledge,
                PUBLIC_KEYS.INFO_FIELDS["filter"]: filters}
        self.assertEqual(PUBLIC_KEYS.bundle_keys(info), expected)
        for field in PUBLIC_KEYS.INFO_FIELDS.values():
            invalid = dict(info)
            invalid.pop(field)
            with self.subTest(missing=field), self.assertRaises(SystemExit):
                PUBLIC_KEYS.bundle_keys(invalid)
            invalid[field] = {}
            with self.subTest(nonString=field), self.assertRaises(SystemExit):
                PUBLIC_KEYS.bundle_keys(invalid)

    def test_malformed_binding_errors_do_not_echo_input(self):
        raw = '{"private-material":"synthetic secret fixture"}'
        try:
            PUBLIC_KEYS.parse_keys(raw, "Test public keys")
        except SystemExit as error:
            self.assertNotIn("synthetic secret fixture", str(error))
            self.assertNotIn("private-material", str(error))
        else:
            self.fail("Malformed configuration must fail.")


if __name__ == "__main__":
    unittest.main()
