"""Exercise cloud signing and cleanup without credentials or external tools.

macOS Security.framework calls and command execution are mocked. These tests
verify policy selection, signing prerequisites, ownership, cleanup, and failure
handling; real certificate trust and Apple signing still require a macOS run.
"""

from __future__ import annotations

import base64
from contextlib import contextmanager, redirect_stderr, redirect_stdout
import datetime as dt
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "fireprivacy_cloud_signing", ROOT / "scripts/cloud-signing.py"
)
SIGNING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNING)

CERTIFICATE = b"dummy-distribution-certificate"
IDENTITY = hashlib.sha1(CERTIFICATE).hexdigest().upper()
TEAM = "LYDVWU62G4"
APP_ID_PREFIX = "OLDPREFIX1"
BUNDLE = "com.example.FirePrivacy"
UUID = "12345678-1234-1234-1234-123456789ABC"
PASSWORD = "dummy-password-for-test"
ORIGINAL_KEYCHAINS = [
    "/tmp/original Login.keychain-db",
    "/tmp/original System.keychain",
]
RESTORE_COMMAND = [
    "/usr/bin/security", "list-keychains", "-d", "user", "-s",
    *ORIGINAL_KEYCHAINS,
]


class FakeSecurityFramework:
    """Match the C APIs' pointer outputs without loading macOS frameworks."""

    def __init__(self):
        self.signer_status = 1  # kCMSSignerValid
        self.certificate_status = 0
        self.trust = 222
        self.signer_count = 1
        self.api_result = 0
        self.calls = []
        self.released = []

    def SecPolicyCreateWithProperties(self, identifier, properties):
        self.calls.append(("policy", identifier, properties))
        return 111

    def CMSDecoderCreate(self, output):
        output._obj.value = 333
        return 0

    def CMSDecoderUpdateMessage(self, decoder, buffer, length):
        return 0

    def CMSDecoderFinalizeMessage(self, decoder):
        return 0

    def CMSDecoderGetNumSigners(self, decoder, output):
        output._obj.value = self.signer_count
        return 0

    def CMSDecoderCopySignerStatus(
        self, decoder, index, policy, evaluate_trust, status, trust, result
    ):
        self.calls.append(("verify", index, policy, evaluate_trust))
        status._obj.value = self.signer_status
        trust._obj.value = self.trust
        result._obj.value = self.certificate_status
        return self.api_result

    def CFRelease(self, value):
        self.released.append(value.value if hasattr(value, "value") else value)


class FakeMacCommands:
    """Capture command arguments and simulate only the required tool results."""

    def __init__(self, profile):
        self.profile = profile
        self.calls = []
        self.fail_import = False
        self.fail_restore = False
        self.identity = IDENTITY

    def __call__(self, arguments, description, *, allow_failure=False):
        self.calls.append(arguments)
        if arguments[0] == "/usr/bin/openssl":
            return b"Key is valid"
        operation = arguments[1]
        if operation == "create-keychain":
            SIGNING.private_write(Path(arguments[-1]), b"dummy-keychain")
        if operation == "import" and self.fail_import:
            raise SIGNING.SigningError(
                "Identity import failed; credential details suppressed."
            )
        if operation == "list-keychains" and "-s" not in arguments:
            return "\n".join(f'"{path}"' for path in ORIGINAL_KEYCHAINS).encode()
        if operation == "list-keychains" and allow_failure and self.fail_restore:
            return None
        if operation == "cms":
            return plistlib.dumps(self.profile)
        if operation == "find-identity":
            return (
                f' 1) {self.identity} "Apple Distribution: Fixture"\n'
                "1 valid identities found\n"
            ).encode()
        return b""


@contextmanager
def signing_fixture():
    """Contain all mutable state and prevent native commands or network calls."""

    with tempfile.TemporaryDirectory(prefix="cloud-signing-tests-") as name:
        root = Path(name)
        environment_file = root / "github-env"
        environment_file.touch()
        profile = {
            "UUID": UUID,
            "ExpirationDate": (
                dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
                + dt.timedelta(days=30)
            ),
            "Platform": ["iOS"],
            "TeamIdentifier": [TEAM],
            "ApplicationIdentifierPrefix": [APP_ID_PREFIX],
            "Entitlements": {
                "com.apple.developer.team-identifier": TEAM,
                "application-identifier": f"{APP_ID_PREFIX}.{BUNDLE}",
                "get-task-allow": False,
            },
            "DeveloperCertificates": [CERTIFICATE],
        }
        commands = FakeMacCommands(profile)
        security = FakeSecurityFramework()
        output = io.StringIO()
        environment = {
            "GITHUB_ACTIONS": "true",
            "RUNNER_TEMP": str(root),
            "GITHUB_ENV": str(environment_file),
            "RELEASE_MODE": "archive",
            "TEAM_ID": TEAM,
            "BUNDLE_ID": BUNDLE,
            "APPLE_DISTRIBUTION_P12_PASSWORD": PASSWORD,
            "APPLE_DISTRIBUTION_P12_BASE64": base64.b64encode(b"dummy-p12").decode(),
            "APPLE_PROVISION_PROFILE_BASE64": base64.b64encode(b"dummy-cms").decode(),
            # GitHub injects empty strings for undeclared secrets. An archive
            # must not mistake these declarations for supplied ASC credentials.
            "ASC_PRIVATE_KEY_BASE64": "",
            "ASC_KEY_ID": "",
            "ASC_ISSUER_ID": "",
        }
        with (
            mock.patch.dict(os.environ, environment, clear=True),
            mock.patch.object(SIGNING.sys, "platform", "darwin"),
            mock.patch.object(SIGNING, "run", commands),
            mock.patch.object(
                SIGNING, "apple_security_api", return_value=(security, security, 999)
            ),
            mock.patch.object(SIGNING, "profile_directory", return_value=root / "profiles"),
            redirect_stdout(output),
            redirect_stderr(output),
        ):
            yield root, environment_file, profile, commands, security, output


def prepare_with_main():
    with mock.patch.object(SIGNING.sys, "argv", ["cloud-signing.py", "prepare"]):
        return SIGNING.main()


class CloudSigningTests(unittest.TestCase):
    def test_archive_without_asc_supports_legacy_prefix_and_cleans_owned_files(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            SIGNING.prepare()
            directory = Path(os.environ["FIREPRIVACY_SIGNING_DIR"])
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            for name in ("distribution.p12", "distribution.mobileprovision", "state.json"):
                self.assertEqual((directory / name).stat().st_mode & 0o777, 0o600)
            published = environment_file.read_text()
            self.assertTrue(published.startswith("FIREPRIVACY_SIGNING_DIR="))
            self.assertIn("SIGNING_MODE=manual\n", published)
            self.assertIn(IDENTITY, published)
            self.assertNotIn("ASC_KEY_PATH=", published)
            self.assertIn(("policy", 999, None), security.calls)
            self.assertIn(("verify", 0, 111, True), security.calls)
            self.assertTrue(
                all("-k" in arguments for arguments in commands.calls if arguments[1] == "cms")
            )
            self.assertNotIn(PASSWORD, (directory / "state.json").read_text())
            SIGNING.cleanup()
            self.assertFalse(directory.exists())
            self.assertEqual(list((root / "profiles").iterdir()), [])
            self.assertIn(RESTORE_COMMAND, commands.calls)
            SIGNING.cleanup()
            self.assertNotIn(PASSWORD, output.getvalue())

    def test_upload_validates_private_key_and_publishes_its_temporary_path(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            os.environ.update(
                RELEASE_MODE="upload",
                ASC_KEY_ID="ABC1234567",
                ASC_ISSUER_ID=UUID,
                ASC_PRIVATE_KEY_BASE64=base64.b64encode(b"dummy-p8").decode(),
            )
            SIGNING.prepare()
            directory = Path(os.environ["FIREPRIVACY_SIGNING_DIR"])
            self.assertIn(
                f"ASC_KEY_PATH={directory / 'AuthKey_ABC1234567.p8'}",
                environment_file.read_text(),
            )
            self.assertTrue(
                any(
                    arguments[0] == "/usr/bin/openssl"
                    and arguments[-2:] == ["-noout", "-check"]
                    for arguments in commands.calls
                )
            )
            SIGNING.cleanup()

    def test_partial_asc_configuration_is_rejected_before_mutation(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            os.environ["ASC_KEY_ID"] = "ABC1234567"
            self.assertEqual(prepare_with_main(), 1)
            self.assertFalse(commands.calls)
            self.assertEqual(environment_file.read_text(), "")

    def test_non_apple_signer_is_rejected_and_temporary_keychain_removed(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            security.signer_status = 4  # kCMSSignerInvalidCert
            security.certificate_status = -67843
            self.assertEqual(prepare_with_main(), 1)
            self.assertFalse(Path(os.environ["FIREPRIVACY_SIGNING_DIR"]).exists())
            self.assertFalse(any(arguments[1] == "cms" for arguments in commands.calls))
            self.assertTrue(any(arguments[1] == "delete-keychain" for arguments in commands.calls))
            self.assertNotIn(PASSWORD, output.getvalue())

    def test_bad_cms_signature_is_rejected(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            security.signer_status = 3  # kCMSSignerInvalidSignature
            self.assertEqual(prepare_with_main(), 1)

    def test_zero_cms_signers_is_rejected(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            security.signer_count = 0
            self.assertEqual(prepare_with_main(), 1)

    def test_missing_trust_object_is_rejected(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            security.trust = None
            self.assertEqual(prepare_with_main(), 1)

    def test_certificate_verification_error_is_rejected(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            security.certificate_status = -1
            self.assertEqual(prepare_with_main(), 1)

    def test_api_error_is_rejected_and_core_foundation_objects_released(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            security.api_result = -1
            self.assertEqual(prepare_with_main(), 1)
            self.assertEqual(sorted(security.released), [111, 222, 333])

    def test_expired_profile_is_rejected(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            profile["ExpirationDate"] = (
                dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) - dt.timedelta(days=1)
            )
            self.assertEqual(prepare_with_main(), 1)

    def test_device_distribution_profile_is_rejected(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            profile["ProvisionedDevices"] = ["dummy-device"]
            self.assertEqual(prepare_with_main(), 1)

    def test_wildcard_bundle_and_team_mismatch_are_rejected(self):
        for mutation in ("wildcard", "team"):
            with self.subTest(mutation=mutation), signing_fixture() as fixture:
                root, environment_file, profile, commands, security, output = fixture
                if mutation == "wildcard":
                    profile["Entitlements"]["application-identifier"] = f"{APP_ID_PREFIX}.*"
                else:
                    profile["Entitlements"]["com.apple.developer.team-identifier"] = "OTHERTEAM1"
                self.assertEqual(prepare_with_main(), 1)

    def test_signing_identity_mismatch_is_rejected(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            commands.identity = "0" * 40
            self.assertEqual(prepare_with_main(), 1)

    def test_certificate_import_failure_restores_original_keychain_list(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            commands.fail_import = True
            self.assertEqual(prepare_with_main(), 1)
            self.assertIn(RESTORE_COMMAND, commands.calls)
            self.assertFalse(Path(os.environ["FIREPRIVACY_SIGNING_DIR"]).exists())

    def test_existing_profiles_are_never_overwritten_or_removed(self):
        for content in (b"dummy-cms", b"preexisting-conflict"):
            with self.subTest(content=content), signing_fixture() as fixture:
                root, environment_file, profile, commands, security, output = fixture
                existing = root / "profiles" / f"{UUID}.mobileprovision"
                existing.parent.mkdir()
                existing.write_bytes(content)
                if content == b"dummy-cms":
                    SIGNING.prepare()
                    SIGNING.cleanup()
                else:
                    self.assertEqual(prepare_with_main(), 1)
                self.assertEqual(existing.read_bytes(), content)

    def test_cleanup_failure_still_removes_credentials_and_owned_profile(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            SIGNING.prepare()
            directory = Path(os.environ["FIREPRIVACY_SIGNING_DIR"])
            commands.fail_restore = True
            with self.assertRaises(SIGNING.SigningError):
                SIGNING.cleanup()
            self.assertFalse(directory.exists())
            self.assertEqual(list((root / "profiles").iterdir()), [])

    def test_cleanup_preserves_unowned_directory(self):
        with signing_fixture() as (root, environment_file, profile, commands, security, output):
            path = root / "valuable-folder"
            path.mkdir()
            os.environ["FIREPRIVACY_SIGNING_DIR"] = str(path)
            with self.assertRaises(SIGNING.SigningError):
                SIGNING.cleanup()
            self.assertTrue(path.exists())

    def test_unavailable_apple_security_policy_fails_closed(self):
        with mock.patch.object(SIGNING.ctypes, "CDLL", side_effect=OSError("dummy-error")):
            with self.assertRaises(SIGNING.SigningError):
                SIGNING.apple_security_api()

    def test_command_exception_never_logs_credential_arguments(self):
        with mock.patch.object(SIGNING.subprocess, "run", side_effect=OSError(PASSWORD)):
            with self.assertRaises(SIGNING.SigningError) as result:
                SIGNING.run(
                    ["/usr/bin/security", "import", "-P", PASSWORD], "import identity"
                )
            self.assertNotIn(PASSWORD, str(result.exception))


if __name__ == "__main__":
    unittest.main()
