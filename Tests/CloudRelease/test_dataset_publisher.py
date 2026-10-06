"""Real Ed25519 publisher tests; every key exists only in a temporary directory."""
from __future__ import annotations

import base64
from contextlib import redirect_stderr, redirect_stdout
import copy
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("fireprivacy_dataset_publisher", ROOT / "scripts/publish-signed-datasets.py")
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)


class DatasetPublisherTests(unittest.TestCase):
    def setUp(self):
        self.openssl = P.openssl_path()
        if self.openssl is None: self.skipTest("OpenSSL is genuinely unavailable")
        self.temp = tempfile.TemporaryDirectory(prefix="dataset-publisher-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.key = self.root / "private.pem"
        subprocess.run([self.openssl, "genpkey", "-algorithm", "ED25519", "-out", str(self.key)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        self.key.chmod(0o600)
        self.now = int(time.time())
        stamp = dt.datetime.fromtimestamp(self.now, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.citation = "https://github.com/Ununp3ntium115/FirePrivacy"
        self.review = {"schemaVersion": 1, "reviewer": "Synthetic test reviewer", "reviewedAtSeconds": self.now, "changeSummary": "Synthetic test-only publisher fixture.", "sources": [{"url": self.citation, "retrievedAtSeconds": self.now, "purpose": "Synthetic interoperability evidence.", "license": "Synthetic test data; not a vendor claim."}]}
        self.kb = {"schemaVersion": 1, "datasetVersion": "2.0.0", "sources": [{"id": "synthetic", "title": "Synthetic source", "url": self.citation, "type": "internalReview", "retrievedAt": stamp, "excerpt": "Synthetic fixture, no real vendor classification."}], "classifications": [{"id": "synthetic", "pattern": "fixture.github.com", "patternKind": "exactHost", "categories": ["analytics"], "purposes": ["Test verification."], "confidence": 0.5, "sourceIDs": ["synthetic"], "lastReviewed": stamp, "reviewStatus": "provisional", "notes": "Synthetic data only.", "organization": None, "sdkFamily": None, "expiresAt": None}]}
        self.review_path = self.write_json("review.json", self.review)
        self.payload = self.write_json("payload.json", self.kb)

    def write_json(self, name, value):
        path = self.root / name; path.write_bytes(P.encoded(value)); return path

    def arguments(self, command="kb", **overrides):
        options = {"payload": str(self.payload), "private_key": str(self.key), "key_id": "test-only", "review_record": str(self.review_path), "endpoint": "https://github.com/Ununp3ntium115/FirePrivacy/raw/main/test-only.json", "output": str(self.root / "output"), "issued_at": self.now, "expires_at": self.now + 3600}
        if command.startswith("kb"):
            options["sequence"] = 2
            if command == "kb": options["minimum_app_version"] = "1.0.0"
        else:
            options.update(version=2, tag="synthetic-test")
            if command == "filter": options["kind"] = "safariDomainsV1"
        options.update(overrides)
        argv = [command]
        for key, value in options.items():
            if value is not None: argv.extend(["--" + key.replace("_", "-"), str(value)])
        return argv

    def prepare(self, command="kb", **overrides):
        args = P.parser().parse_args(self.arguments(command, **overrides))
        return P.prepare(args, now=self.now)

    def verify_files(self, files, kb=True, revocations=False):
        envelope = json.loads(files["download.json"])
        signer = P.Signer(self.key)
        if kb:
            item = envelope["revocations"] if revocations else envelope
            manifest = json.loads(base64.b64decode(item["manifestData" if revocations else "manifest"], validate=True))
            signature = base64.b64decode(manifest["signatureBase64"], validate=True)
            payload = base64.b64decode(item["payloadData" if revocations else "payload"], validate=True)
        else:
            manifest = envelope["manifest"]; signature = base64.b64decode(envelope["signature"], validate=True)
            payload = base64.b64decode(envelope["payload"], validate=True)
        signer.verify(files["signing-message.bin"], signature)
        self.assertEqual(P.digest(payload), manifest["payloadSHA256"])
        self.assertEqual(payload, files["payload.bin" if "payload.bin" in files else "payload.json"])
        return manifest, payload, signature

    def test_real_kb_signature_fixed_field_order_and_wire_envelope(self):
        files = self.prepare(); manifest, _, _ = self.verify_files(files)
        expected = f"FirePrivacy.KnowledgeBase.v1\n1\n2.0.0\n2\n{self.now}\n{self.now+3600}\n1.0.0\n1\n{manifest['payloadSHA256']}\ntest-only\n".encode()
        self.assertEqual(files["signing-message.bin"], expected)
        reference = json.loads(files["public-key-reference.json"])
        self.assertEqual(len(base64.b64decode(reference["publicKeyBase64"])), 32)
        self.assertEqual(reference["publicKeyHex"], base64.b64decode(reference["publicKeyBase64"]).hex())
        self.assertEqual(reference["buildVariableName"], "FIREPRIVACY_KB_PUBLIC_KEYS_JSON")
        self.assertEqual(json.loads(reference["buildVariableJSON"]), {"test-only": reference["publicKeyHex"]})
        record = json.loads(files["source-review-and-changelog.json"])
        self.assertEqual(record["artifacts"]["download.json"]["sha256"], P.digest(files["download.json"]))
        self.assertFalse(record["previousArtifactChecked"])

    def test_real_signature_rejects_tampered_message_and_signature(self):
        files = self.prepare(); _, _, signature = self.verify_files(files)
        signer = P.Signer(self.key)
        with self.assertRaises(P.PublisherError): signer.verify(files["signing-message.bin"] + b"x", signature)
        with self.assertRaises(P.PublisherError): signer.verify(files["signing-message.bin"], bytes([signature[0] ^ 1]) + signature[1:])

    def test_kb_revocation_signed_domain_separator_sorted_unique_wire(self):
        self.payload = self.write_json("kb-rev.json", {"schemaVersion": 1, "sequence": 2, "revokedVersions": ["2.0.0", "1.0.0"], "revokedKeyIDs": ["old-key"], "revokedPayloadDigests": ["a" * 64]})
        files = self.prepare("kb-revocations"); manifest, payload, _ = self.verify_files(files, revocations=True)
        self.assertEqual(json.loads(payload)["revokedVersions"], ["1.0.0", "2.0.0"])
        self.assertEqual(manifest["revocationCount"], 4)
        self.assertTrue(files["signing-message.bin"].startswith(b"FirePrivacy.KnowledgeBaseRevocations.v1\n"))
        self.assertTrue(files["signing-message.bin"].endswith(b"\n"))

    def test_safari_filter_sorted_compact_json_omits_nil_options(self):
        self.payload = self.write_json("safari.json", ["fixture.github.com"])
        files = self.prepare("filter", version=(1 << 53) + 1); manifest, _, _ = self.verify_files(files, kb=False)
        expected = P.encoded(manifest)
        self.assertEqual(files["signing-message.bin"], expected)
        self.assertNotIn(b"null", expected); self.assertFalse(expected.endswith(b"\n"))
        self.assertNotIn("rollbackFromVersion", manifest)
        self.assertEqual(manifest["version"], (1 << 53) + 1)
        self.assertEqual(json.loads(files["public-key-reference.json"])["buildVariableName"], "FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON")

    def test_apple_bloom_requires_exact_bits_and_real_operator_parameters(self):
        self.payload = self.root / "bloom.bin"; self.payload.write_bytes(b"\x01\x02")
        params = dict(kind="appleURLBloomV1", bit_count=16, hash_count=3, murmur_seed=77, pir_server_url="https://github.com/operator/pir", privacy_pass_issuer_url="https://github.com/operator/issuer", apple_configuration_identity="operator-supplied-test-identity")
        files = self.prepare("filter", **params); manifest, payload, _ = self.verify_files(files, kb=False)
        self.assertEqual(payload, b"\x01\x02"); self.assertEqual(manifest["murmurSeed"], 77)
        for bad in (dict(bit_count=17), dict(pir_server_url="https://pir.example/"), dict(apple_configuration_identity=""), dict(hash_count=33)):
            with self.subTest(bad=bad), self.assertRaises(P.PublisherError): self.prepare("filter", **(params | bad))

    def test_managed_filter_is_bound_to_outer_version_and_expiry(self):
        policy = {"version": 2, "deploymentMode": "mdmPerApp", "rules": [{"appIdentifier": "com.example.test", "domain": "fixture.github.com", "includeSubdomains": True, "action": "drop"}], "expiresAtSeconds": self.now + 1800}
        self.payload = self.write_json("managed.json", policy)
        self.verify_files(self.prepare("filter", kind="managedRulesV1"), kb=False)
        for field, value in (("version", 3), ("expiresAtSeconds", self.now + 7200)):
            self.payload = self.write_json("managed.json", policy | {field: value})
            with self.subTest(field=field), self.assertRaises(P.PublisherError): self.prepare("filter", kind="managedRulesV1")

    def test_filter_revocation_download_has_typed_target_and_sorted_sets(self):
        self.payload = self.write_json("filter-rev.json", {"targetKind": "safariDomainsV1", "revocations": {"keyIDs": ["z", "a"], "versions": [2, 1], "payloadDigests": ["a" * 64]}})
        files = self.prepare("filter-revocations"); manifest, payload, _ = self.verify_files(files, kb=False)
        self.assertEqual(manifest["kind"], "revocationsV1")
        self.assertEqual(json.loads(payload)["revocations"]["versions"], [1, 2])

    def test_previous_kb_artifact_is_authenticated_and_both_versions_increase(self):
        previous = self.write_json("previous.json", json.loads(self.prepare()["download.json"]))
        with self.assertRaises(P.PublisherError): self.prepare(previous_artifact=previous)
        self.kb["datasetVersion"] = "2.0.1"; self.payload = self.write_json("payload.json", self.kb)
        files = self.prepare(sequence=3, previous_artifact=previous)
        self.assertTrue(json.loads(files["source-review-and-changelog.json"])["previousArtifactChecked"])
        old = json.loads(previous.read_bytes()); old["payload"] = base64.b64encode(b"tampered").decode()
        previous.write_bytes(P.encoded(old))
        with self.assertRaises(P.PublisherError): self.prepare(sequence=4, previous_artifact=previous)

    def test_sticky_kb_revocations_and_revoked_signing_key_cannot_be_removed(self):
        payload = {"schemaVersion": 1, "sequence": 2, "revokedVersions": ["1.0.0"], "revokedKeyIDs": ["test-only"], "revokedPayloadDigests": []}
        self.payload = self.write_json("rev.json", payload)
        previous = self.write_json("previous.json", json.loads(self.prepare("kb-revocations")["download.json"]))
        for new in (payload | {"sequence": 3, "revokedVersions": []}, payload | {"sequence": 3}):
            self.payload = self.write_json("rev.json", new)
            with self.assertRaises(P.PublisherError): self.prepare("kb-revocations", sequence=3, previous_artifact=previous)

    def test_sticky_filter_revocations_require_same_target_and_keep_previous_entries(self):
        payload = {"targetKind": "safariDomainsV1", "revocations": {"keyIDs": ["old"], "versions": [1], "payloadDigests": []}}
        self.payload = self.write_json("rev.json", payload)
        previous = self.write_json("previous.json", json.loads(self.prepare("filter-revocations")["download.json"]))
        self.prepare("filter-revocations", version=3, previous_artifact=previous)
        for new in (payload | {"targetKind": "managedRulesV1"}, payload | {"revocations": {"keyIDs": [], "versions": [1], "payloadDigests": []}}):
            self.payload = self.write_json("rev.json", new)
            with self.assertRaises(P.PublisherError): self.prepare("filter-revocations", version=3, previous_artifact=previous)

    def test_malformed_duplicate_unknown_and_excessive_inputs_fail(self):
        for raw in (b'{"schemaVersion":1,"schemaVersion":1}', b'{"x":NaN}', b'{"x":"\xff"}', b'[' * 26 + b'0' + b']' * 26):
            with self.subTest(raw=raw), self.assertRaises(P.PublisherError): P.decode_json(raw)
        for change in (dict(schemaVersion=True), dict(datasetVersion="02.0.0"), dict(extra="unknown")):
            self.payload = self.write_json("bad.json", self.kb | change)
            with self.subTest(change=change), self.assertRaises(P.PublisherError): self.prepare()
        self.payload.write_bytes(b"x" * (4 * P.MIB + 1))
        with self.assertRaises(P.PublisherError): self.prepare()

    def test_citations_dates_public_suffixes_and_classification_semantics_fail_closed(self):
        for change in (dict(pattern="github.io"), dict(sourceIDs=["missing"]), dict(categories=["unknown"]), dict(confidence=float("inf")), dict(lastReviewed="2026-99-99T00:00:00Z")):
            payload = copy.deepcopy(self.kb); payload["classifications"][0].update(change)
            self.payload = self.root / "bad.json"; self.payload.write_text(json.dumps(payload))
            with self.subTest(change=change), self.assertRaises(P.PublisherError): self.prepare()
        self.payload = self.write_json("payload.json", self.kb)
        review = copy.deepcopy(self.review); review["sources"][0]["url"] = "https://github.com/different/citation"
        self.review_path = self.write_json("review.json", review)
        with self.assertRaises(P.PublisherError): self.prepare()

    def test_time_versions_and_target_endpoint_bounds(self):
        for change in (dict(expires_at=self.now), dict(issued_at=self.now+301), dict(expires_at=self.now+367*86400), dict(sequence=0), dict(endpoint="http://github.com/path"), dict(endpoint="https://user:token@github.com/path"), dict(endpoint="https://github.com/path?token=secret"), dict(key_id="bad\nkey")):
            with self.subTest(change=change), self.assertRaises(P.PublisherError): self.prepare(**change)

    def test_private_key_permissions_type_and_symlink_are_checked(self):
        self.key.chmod(0o640)
        with self.assertRaises(P.PublisherError): self.prepare()
        self.key.chmod(0o600)
        link = self.root / "link.pem"; link.symlink_to(self.key)
        with self.assertRaises(P.PublisherError): self.prepare(private_key=link)
        rsa = self.root / "rsa.pem"
        subprocess.run([self.openssl, "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(rsa)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        rsa.chmod(0o600)
        with self.assertRaises(P.PublisherError): self.prepare(private_key=rsa)

    def test_encrypted_key_uses_private_passphrase_file_without_logging(self):
        secret = "test-only-passphrase-that-must-not-be-logged"
        passfile = self.root / "passphrase"; passfile.write_text(secret); passfile.chmod(0o600)
        encrypted = self.root / "encrypted.pem"
        subprocess.run([self.openssl, "pkey", "-in", str(self.key), "-aes-256-cbc", "-passout", "file:"+str(passfile), "-out", str(encrypted)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        encrypted.chmod(0o600)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            result = P.main(self.arguments(private_key=encrypted, passphrase_file=passfile))
        self.assertEqual(result, 0); self.assertNotIn(secret, out.getvalue()+err.getvalue())
        self.assertNotIn(encrypted.read_text(), out.getvalue()+err.getvalue())
        for artifact in (self.root / "output").iterdir(): self.assertNotIn(secret.encode(), artifact.read_bytes())

    def test_failure_suppresses_backend_details_and_leaves_no_artifacts(self):
        leaked = b"PRIVATE KEY AND SENSITIVE BACKEND DIAGNOSTIC"
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(P, "openssl_path", return_value=self.openssl), mock.patch.object(P.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"", leaked)), redirect_stdout(out), redirect_stderr(err):
            result = P.main(self.arguments())
        self.assertEqual(result, 1); self.assertNotIn(leaked.decode(), err.getvalue()); self.assertFalse((self.root / "output").exists())

    def test_public_artifacts_never_embed_private_key_and_existing_output_is_preserved(self):
        files = self.prepare(); key_material = self.key.read_bytes()
        for data in files.values(): self.assertNotIn(key_material, data); self.assertNotIn(b"PRIVATE KEY", data)
        output = self.root / "output"; P.write_artifacts(output, files)
        self.assertEqual((output / "download.json").read_bytes(), files["download.json"])
        sentinel = output / "keep"; sentinel.write_text("owned-existing-data")
        with self.assertRaises(P.PublisherError): P.write_artifacts(output, files)
        self.assertEqual(sentinel.read_text(), "owned-existing-data")
        self.assertEqual(list(self.root.glob(".fireprivacy-publisher-*")), [])

    def test_failed_artifact_write_removes_only_its_new_output(self):
        files = self.prepare(); output = self.root / "output"
        unrelated = self.root / "unrelated"; unrelated.write_text("preserve")
        with mock.patch.object(P.os, "replace", side_effect=OSError("simulated write failure")):
            with self.assertRaises(P.PublisherError): P.write_artifacts(output, files)
        self.assertFalse(output.exists()); self.assertEqual(unrelated.read_text(), "preserve")
        self.assertEqual(list(self.root.glob(".fireprivacy-publisher-*")), [])

    def test_previous_signed_artifact_with_invalid_schema_is_rejected(self):
        files = self.prepare(); old = json.loads(files["download.json"])
        manifest = json.loads(base64.b64decode(old["manifest"]))
        manifest["schemaVersion"] = 99
        manifest["signatureBase64"] = base64.b64encode(P.Signer(self.key).sign(P.kb_signing_bytes(manifest))).decode()
        old["manifest"] = base64.b64encode(P.encoded(manifest)).decode()
        previous = self.write_json("previous.json", old)
        self.kb["datasetVersion"] = "2.0.1"; self.payload = self.write_json("payload.json", self.kb)
        with self.assertRaises(P.PublisherError): self.prepare(sequence=3, previous_artifact=previous)


if __name__ == "__main__": unittest.main()
