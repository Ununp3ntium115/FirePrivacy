"""Read-only ASC probe contracts; temporary genuine keys, never real credentials.

Run: python3 -m unittest discover -s Tests/CloudRelease \
    -p 'test_apple_account_preflight.py' -v
"""
from __future__ import annotations

import base64
import contextlib
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("apple_account_preflight", ROOT / "scripts/apple-account-preflight.py")
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)
KEY_ID = "TESTKEY123"
ISSUER = "00000000-0000-4000-8000-000000000001"


def collection(items):
    return {"data": items, "links": {"next": None}, "meta": {"paging": {"total": len(items)}}}


def bundle(target="app", *, seed=APP.DEFAULT_TEAM, identifier=None, platform="IOS"):
    suffix = ".SafariContentBlocker" if target == "safari" else ""
    return {"type": "bundleIds", "id": "BUNDLE-" + target,
            "attributes": {"identifier": identifier or APP.DEFAULT_BUNDLE + suffix,
                           "platform": platform, "seedId": seed}}


def capabilities(*names):
    return collection([{"type": "bundleIdCapabilities", "id": "CAP-" + name,
                        "attributes": {"capabilityType": name}} for name in names])


class Response:
    def __init__(self, url, body, *, headers=None, status=200, final_url=None):
        self.body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.headers = headers or {}
        self.status, self.url = status, final_url or url

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, count):
        return self.body[:count]

    def geturl(self):
        return self.url


class Opener:
    def __init__(self, bodies):
        self.bodies, self.requests = list(bodies), []

    def open(self, request, *, timeout):
        self.requests.append(request)
        item = self.bodies.pop(0)
        if isinstance(item, Exception):
            raise item
        if callable(item):
            return item(request)
        return Response(request.full_url, item)


class AppleAccountPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.openssl = shutil.which("openssl")
        if not cls.openssl:
            raise unittest.SkipTest("System OpenSSL is required for genuine ES256 tests.")
        cls.temporary = tempfile.TemporaryDirectory(prefix="fireprivacy-test-asc-", dir="/tmp")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        os.chmod(cls.directory, 0o700)
        cls.private = cls.directory / "fixture.p8"
        descriptor = os.open(cls.private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        subprocess.run([cls.openssl, "genpkey", "-algorithm", "EC", "-pkeyopt",
                        "ec_paramgen_curve:P-256", "-out", str(cls.private)],
                       check=True, capture_output=True)
        cls.key = cls.private.read_bytes()
        cls.public = cls.directory / "fixture-public.pem"
        subprocess.run([cls.openssl, "pkey", "-in", str(cls.private), "-pubout",
                        "-out", str(cls.public)], check=True, capture_output=True)

    def setUp(self):
        # Ambient real Actions bindings must never affect fixture behavior.
        self.environment = mock.patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.config = APP.public_configuration(APP.DEFAULT_BUNDLE, APP.DEFAULT_TEAM)

    def bindings(self):
        return {"ASC_PRIVATE_KEY_BASE64": base64.b64encode(self.key).decode(),
                "ASC_KEY_ID": KEY_ID, "ASC_ISSUER_ID": ISSUER}

    def verify_token(self, token, *, tamper=False):
        header, claims, signature = token.split(".")
        raw = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
        self.assertEqual(len(raw), 64)
        parts = []
        for integer in (raw[:32], raw[32:]):
            value = integer.lstrip(b"\0") or b"\0"
            if value[0] & 0x80:
                value = b"\0" + value
            parts.append(b"\x02" + bytes([len(value)]) + value)
        sequence = b"".join(parts)
        signature_file = self.directory / "fixture-signature.der"
        signature_file.write_bytes(b"\x30" + bytes([len(sequence)]) + sequence)
        result = subprocess.run([self.openssl, "dgst", "-sha256", "-verify", str(self.public),
            "-signature", str(signature_file)], input=(header + "." + claims + ("tampered" if tamper else "")).encode(),
            capture_output=True)
        return result.returncode

    def main(self, *, opener=None, environment=None):
        output = io.StringIO()
        with mock.patch.dict(os.environ, environment or {}, clear=True), \
                mock.patch.object(APP, "jwt", return_value="fixture-bearer"), \
                mock.patch.object(APP, "build_opener", return_value=opener), \
                contextlib.redirect_stdout(output):
            status = APP.main([])
        return status, json.loads(output.getvalue()), output.getvalue()

    def test_missing_bindings_names_only_before_signing_or_http(self):
        output = io.StringIO()
        with mock.patch.object(APP, "jwt") as signing, mock.patch.object(APP, "get_json") as request, \
                contextlib.redirect_stdout(output):
            status = APP.main([])
        result = json.loads(output.getvalue())
        self.assertEqual(status, 1)
        self.assertEqual(result["status"], "missingBindings")
        self.assertEqual(result["bindingNames"], list(APP.BINDINGS))
        self.assertFalse(result["mutationsAllowed"])
        signing.assert_not_called()
        request.assert_not_called()

    def test_invalid_bindings_report_names_without_values(self):
        for name, value in (("ASC_KEY_ID", "sensitive-key-id"),
                            ("ASC_ISSUER_ID", "sensitive-issuer"),
                            ("ASC_PRIVATE_KEY_BASE64", "sensitive-invalid-base64")):
            with self.subTest(binding=name):
                environment = self.bindings()
                environment[name] = value
                status, result, output = self.main(environment=environment)
                self.assertEqual(status, 1)
                self.assertEqual(result["status"], "invalidBindings")
                self.assertEqual(result["bindingNames"], [name])
                self.assertTrue(value not in output, "Invalid binding values must not be printed.")

    def test_genuine_p256_jwt_signature_and_five_minute_claims(self):
        token = APP.jwt(self.key, KEY_ID, ISSUER, now=1_800_000_000)
        header, claims, signature = token.split(".")
        decode = lambda part: base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
        self.assertEqual(json.loads(decode(header)), {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"})
        self.assertEqual(json.loads(decode(claims)), {"iss": ISSUER, "iat": 1_800_000_000,
            "exp": 1_800_000_300, "aud": "appstoreconnect-v1"})
        self.assertEqual(self.verify_token(token), 0, "The actual OpenSSL verifier must accept the JWT signature.")
        self.assertNotEqual(self.verify_token(token, tamper=True), 0)

    def test_twelve_character_key_id_reaches_genuine_signing_and_http_unchanged(self):
        environment = {**self.bindings(), "ASC_KEY_ID": "MixedCase123"}
        opener = Opener([collection([bundle()]), collection([bundle("safari")]),
                         capabilities("APP_GROUPS", "NETWORK_EXTENSIONS"), capabilities("APP_GROUPS")])
        output = io.StringIO()
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(APP, "build_opener", return_value=opener), contextlib.redirect_stdout(output):
            code = APP.main([])
        self.assertEqual(code, 0)
        self.assertEqual(len(opener.requests), 4)
        bearer = opener.requests[0].get_header("Authorization")
        self.assertTrue(bearer.startswith("Bearer "))
        token = bearer[len("Bearer "):]
        header = token.split(".")[0]
        decoded = json.loads(base64.urlsafe_b64decode(header + "=" * (-len(header) % 4)))
        self.assertEqual(decoded["kid"], "MixedCase123")
        self.assertEqual(self.verify_token(token), 0)
        self.assertTrue(all(request.get_header("Authorization") == bearer for request in opener.requests))
        self.assertTrue(token not in output.getvalue(), "Bearer tokens must never appear in summary output.")
        self.assertTrue(environment["ASC_PRIVATE_KEY_BASE64"] not in output.getvalue(), "Private key material must never be printed.")

    def test_key_id_ascii_bounds_preserve_exact_case(self):
        for key_id in ("a", "MixedCase123", "Aa" * 32):
            with self.subTest(length=len(key_id)):
                key, actual, issuer = APP.credentials({**self.bindings(), "ASC_KEY_ID": key_id})
                self.assertEqual(actual, key_id)
                self.assertEqual(issuer, ISSUER)
                self.assertTrue(key == self.key)

    def test_unsafe_key_ids_reject_before_signing_files_or_http(self):
        for key_id in ("", "A" * 65, " bad", "bad ", "bad\nkey", "bad\tkey", "bad/key", "bad\\key", "bad.key", "bad-key", "nonASCIIé"):
            with self.subTest(length=len(key_id)), \
                    mock.patch.dict(os.environ, {**self.bindings(), "ASC_KEY_ID": key_id}, clear=True), \
                    mock.patch.object(APP, "jwt") as signing, \
                    mock.patch.object(APP.tempfile, "TemporaryDirectory") as temporary, \
                    mock.patch.object(APP, "get_json") as request, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(APP.main([]), 1)
                signing.assert_not_called()
                temporary.assert_not_called()
                request.assert_not_called()

    def test_direct_jwt_helper_rejects_unsafe_key_ids_before_tools_or_files(self):
        for key_id in ("", "A" * 65, "bad/key", "bad\nkey", "é"):
            with self.subTest(length=len(key_id)), \
                    mock.patch.object(APP.tempfile, "TemporaryDirectory") as temporary, \
                    mock.patch.object(APP, "openssl") as signing, self.assertRaises(APP.PreflightError):
                APP.jwt(self.key, key_id, ISSUER)
            temporary.assert_not_called()
            signing.assert_not_called()

    def test_temporary_private_key_permissions_and_cleanup(self):
        original, observed = APP.openssl, []
        def inspect(arguments, data=None):
            path = Path(arguments[arguments.index("-in") + 1] if "-in" in arguments
                        else arguments[arguments.index("-sign") + 1])
            observed.append(path)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertFalse(path.resolve().is_relative_to(ROOT))
            return original(arguments, data)
        with mock.patch.object(APP, "openssl", side_effect=inspect):
            APP.jwt(self.key, KEY_ID, ISSUER)
        self.assertEqual(len(observed), 2)
        self.assertTrue(all(not path.exists() and not path.parent.exists() for path in observed))

    def test_failure_deletes_temporary_private_key(self):
        observed = []
        def fail(arguments, data=None):
            observed.append(Path(arguments[arguments.index("-in") + 1]))
            raise APP.PreflightError("keyValidationOrSigningFailed")
        with mock.patch.object(APP, "openssl", side_effect=fail), self.assertRaises(APP.PreflightError):
            APP.jwt(self.key, KEY_ID, ISSUER)
        self.assertTrue(all(not path.exists() and not path.parent.exists() for path in observed))

    def test_wrong_curve_and_noncanonical_der_rejected(self):
        with mock.patch.object(APP, "openssl", return_value=b"not-a-P256-public-key"), \
                self.assertRaises(APP.PreflightError) as failure:
            APP.jwt(self.key, KEY_ID, ISSUER)
        self.assertEqual(failure.exception.code, "keyMustBeP256")
        for invalid in (b"", b"\x30\x06\x02\x01\x00\x02\x01\x01",
                        b"\x30\x06\x02\x01\x80\x02\x01\x01",
                        b"\x30\x07\x02\x02\x00\x01\x02\x01\x01"):
            with self.subTest(encoding=invalid.hex()), self.assertRaises(APP.PreflightError):
                APP.der_to_raw(invalid)

    def test_exact_bundle_queries_and_metadata_only_capabilities(self):
        opener = Opener([collection([bundle()]), collection([bundle("safari")]),
                         capabilities("APP_GROUPS", "NETWORK_EXTENSIONS", "PUSH_NOTIFICATIONS"),
                         capabilities("APP_GROUPS")])
        result = APP.probe(self.config, "fixture-bearer", opener=opener)
        self.assertTrue(result["authenticated"])
        self.assertTrue(result["matchingIdentifierPrefix"])
        self.assertFalse(result["membershipVerified"])
        self.assertFalse(result["exactDNSEntitlementVerified"])
        self.assertFalse(result["appGroupAssociationVerified"])
        self.assertEqual(result["identifiers"]["app"]["missingCapabilityTypes"], [])
        self.assertTrue("PUSH_NOTIFICATIONS" not in json.dumps(result))
        self.assertEqual(len(opener.requests), 4)
        for target, request in zip(("app", "safari"), opener.requests):
            url = urlsplit(request.full_url)
            self.assertEqual(url.scheme, "https")
            self.assertEqual(url.netloc, "api.appstoreconnect.apple.com")
            self.assertEqual(url.path, "/v1/bundleIds")
            self.assertEqual(parse_qs(url.query)["filter[identifier]"], [self.config["bundleIdentifiers"][target]])
        for request in opener.requests:
            self.assertEqual(request.get_method(), "GET")
        self.assertEqual(urlsplit(opener.requests[2].full_url).path, "/v1/bundleIds/BUNDLE-app/bundleIdCapabilities")

    def test_missing_identifier_still_reports_authenticated_read(self):
        opener = Opener([collection([])])
        status, result, output = self.main(opener=opener, environment=self.bindings())
        self.assertEqual(status, 1)
        self.assertEqual(result["status"], "identifierNotRegistered")
        self.assertTrue(result["authenticated"])
        self.assertFalse(result["mutationsAllowed"])
        self.assertTrue("fixture-bearer" not in output)

    def test_wrong_prefix_or_unknown_prefix_stops_before_capability_reads(self):
        for seed, expected in (("WRONG12345", "teamPrefixMismatch"), (None, "teamPrefixUnconfirmed"),
                               (APP.DEFAULT_TEAM + "AA", "teamPrefixUnconfirmed")):
            with self.subTest(seed=seed):
                opener = Opener([collection([bundle(seed=seed)])])
                with self.assertRaises(APP.PreflightError) as failure:
                    APP.probe(self.config, "fixture-bearer", opener=opener)
                self.assertEqual(failure.exception.code, expected)
                self.assertTrue(failure.exception.authenticated)
                self.assertEqual(len(opener.requests), 1)

    def test_duplicate_or_inexact_identifier_and_platform_rejected(self):
        cases = (([bundle(), bundle()], "identifierAmbiguous"),
                 ([bundle(identifier=APP.DEFAULT_BUNDLE + ".Other")], "identifierNotRegistered"),
                 ([bundle(platform="MAC_OS")], "platformMismatch"))
        for values, expected in cases:
            with self.subTest(expected=expected):
                with self.assertRaises(APP.PreflightError) as failure:
                    APP.probe(self.config, "fixture-bearer", opener=Opener([collection(values)]))
                self.assertEqual(failure.exception.code, expected)

    def test_missing_capabilities_are_reported_without_rights_claims(self):
        opener = Opener([collection([bundle()]), collection([bundle("safari")]),
                         capabilities("APP_GROUPS"), capabilities()])
        status, result, output = self.main(opener=opener, environment=self.bindings())
        self.assertEqual(status, 1)
        self.assertEqual(result["status"], "capabilitiesMissing")
        self.assertEqual(result["identifiers"]["app"]["missingCapabilityTypes"], ["NETWORK_EXTENSIONS"])
        self.assertEqual(result["identifiers"]["safari"]["missingCapabilityTypes"], ["APP_GROUPS"])
        self.assertFalse(result["membershipVerified"])
        self.assertTrue("fixture-bearer" not in output)

    def test_redirect_handler_and_changed_response_url_rejected(self):
        with self.assertRaises(APP.PreflightError) as failure:
            APP.RejectRedirects().redirect_request(None, None, 302, "secret", {}, "https://other.invalid/")
        self.assertEqual(failure.exception.code, "redirectRejected")
        opener = Opener([lambda request: Response(request.full_url, collection([]), final_url="https://other.invalid/")])
        with self.assertRaises(APP.PreflightError) as failure:
            APP.get_json("/v1/bundleIds", "fixture-bearer", opener=opener)
        self.assertEqual(failure.exception.code, "redirectRejected")
        self.assertEqual(len(opener.requests), 1)

    def test_http_errors_expose_only_status_and_closed_apple_codes(self):
        raw = json.dumps({"errors": [{"code": "NOT_AUTHORIZED", "title": "sensitive-response-title"},
              {"code": "sensitive-arbitrary-code", "detail": "sensitive-response-detail"}]}).encode()
        error = HTTPError(APP.API + "/v1/bundleIds", 401, "sensitive-http-message", {}, io.BytesIO(raw))
        status, result, output = self.main(opener=Opener([error]), environment=self.bindings())
        self.assertEqual(status, 1)
        self.assertEqual(result["httpStatus"], 401)
        self.assertEqual(result["appleErrorCodes"], ["NOT_AUTHORIZED"])
        self.assertFalse(result["authenticated"])
        self.assertTrue("sensitive-" not in output)
        self.assertTrue("fixture-bearer" not in output)

    def test_truncated_or_oversized_responses_rejected(self):
        cases = ((lambda request: Response(request.full_url, collection([]), headers={"Content-Length": "999"}), "responseTruncated"),
                 (lambda request: Response(request.full_url, b"x" * (APP.MAXIMUM_RESPONSE + 1)), "responseTooLarge"),
                 (http.client.IncompleteRead(b"private", 9), "responseTruncated"))
        for response, expected in cases:
            with self.subTest(expected=expected):
                with self.assertRaises(APP.PreflightError) as failure:
                    APP.get_json("/v1/bundleIds", "fixture-bearer", opener=Opener([response]))
                self.assertEqual(failure.exception.code, expected)

    def test_duplicate_json_keys_and_nonstandard_constants_rejected(self):
        for body in (b'{"data":[],"\\u0064ata":[]}', b'{"data":[],"value":NaN}', b'{"data":'):
            with self.subTest(body=body):
                with self.assertRaises(APP.PreflightError) as failure:
                    APP.get_json("/v1/bundleIds", "fixture-bearer", opener=Opener([body]))
                self.assertEqual(failure.exception.code, "invalidResponse")

    def test_incomplete_paginated_collections_fail_without_following_links(self):
        for extra in ({"links": {"next": "/v1/bundleIds?cursor=private"}},
                      {"meta": {"paging": {"total": 2}}},
                      {"meta": {"paging": {"nextCursor": "private"}}}):
            body = collection([bundle()])
            body.update(extra)
            opener = Opener([body])
            with self.subTest(extra=extra), self.assertRaises(APP.PreflightError) as failure:
                APP.probe(self.config, "fixture-bearer", opener=opener)
            self.assertEqual(failure.exception.code, "responseIncomplete")
            self.assertEqual(len(opener.requests), 1)

    def test_transport_errors_never_echo_url_or_bearer(self):
        status, result, output = self.main(opener=Opener([URLError("private-bearer-and-url")]), environment=self.bindings())
        self.assertEqual(status, 1)
        self.assertEqual(result["status"], "connectionFailed")
        self.assertTrue("private-bearer-and-url" not in output)

    def test_invalid_public_configuration_fails_before_http(self):
        for bundle_id, team_id in (("com.example/app", APP.DEFAULT_TEAM),
                                   (APP.DEFAULT_BUNDLE, "not-a-team"),
                                   (APP.DEFAULT_BUNDLE, APP.DEFAULT_TEAM + "AA")):
            with self.subTest(bundle_id=bundle_id, team_id=team_id), self.assertRaises(APP.PreflightError):
                APP.public_configuration(bundle_id, team_id)


if __name__ == "__main__":
    unittest.main()
