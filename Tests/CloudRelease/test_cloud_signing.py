"""Exercise cloud signing and cleanup without credentials or external tools.

macOS Security.framework calls and command execution are mocked. These tests
verify policy selection, signing prerequisites, ownership, cleanup, and failure
handling; real certificate trust and Apple signing still require a macOS run.
"""

from __future__ import annotations

import base64
import copy
from contextlib import contextmanager, redirect_stderr, redirect_stdout
import datetime as dt
import hashlib
import importlib.util
import io
import json
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
APP_GROUP = SIGNING.APP_GROUP_DEFAULT
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
        self.profiles = {}
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
            name = Path(arguments[-1]).stem
            return plistlib.dumps(self.profile if name == "distribution" else self.profiles[name])
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
                SIGNING.GROUP_ENTITLEMENT: [APP_GROUP],
                SIGNING.NETWORK_ENTITLEMENT: ["dns-settings"],
            },
            "DeveloperCertificates": [CERTIFICATE],
        }
        commands = FakeMacCommands(profile)
        for index, (target, bindings) in enumerate(SIGNING.EXTENSION_BINDINGS.items(), start=1):
            extension = copy.deepcopy(profile)
            extension["UUID"] = f"12345678-1234-1234-1234-{index:012X}"
            extension["Entitlements"]["application-identifier"] = f"{APP_ID_PREFIX}.{BUNDLE}.{target}"
            extension["Entitlements"][SIGNING.NETWORK_ENTITLEMENT] = sorted(bindings[2])
            commands.profiles[target] = extension
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
            "APPLE_SAFARI_PROVISION_PROFILE_BASE64": base64.b64encode(b"dummy-SafariContentBlocker-cms").decode(),
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


def select_edition(profile, commands, edition):
    """Supply only synthetic profiles required by the chosen edition."""
    os.environ["APP_EDITION"] = edition
    profile["Entitlements"][SIGNING.NETWORK_ENTITLEMENT] = sorted(SIGNING.EDITION_CAPABILITIES[edition])
    for target in SIGNING.EDITION_EXTENSIONS[edition]:
        os.environ[SIGNING.EXTENSION_BINDINGS[target][0]] = base64.b64encode(f"dummy-{target}-cms".encode()).decode()


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

    def test_each_edition_verifies_and_installs_only_its_exact_profile_subset(self):
        for edition, targets in SIGNING.EDITION_EXTENSIONS.items():
            with self.subTest(edition=edition), signing_fixture() as fixture:
                root, environment_file, profile, commands, security, output = fixture
                select_edition(profile, commands, edition)
                # Unselected malformed bindings must not enable or require a
                # privileged target in a consumer or unrelated edition.
                for target in set(SIGNING.EXTENSION_BINDINGS) - set(targets):
                    os.environ[SIGNING.EXTENSION_BINDINGS[target][0]] = "not-base64"
                SIGNING.prepare()
                directory = Path(os.environ["FIREPRIVACY_SIGNING_DIR"])
                state = json.loads((directory / "state.json").read_text())
                self.assertEqual(len(state["profiles"]), len(targets) + 1)
                decoded = {Path(call[-1]).stem for call in commands.calls if call[1] == "cms"}
                self.assertEqual(decoded, {"distribution", *targets})
                published = environment_file.read_text()
                self.assertIn(f"APP_EDITION={edition}\n", published)
                self.assertIn(f"APP_BASE_BUNDLE_ID={BUNDLE}\n", published)
                self.assertIn(f"FIREPRIVACY_APP_GROUP_ID={APP_GROUP}\n", published)
                for target, bindings in SIGNING.EXTENSION_BINDINGS.items():
                    self.assertEqual(f"{bindings[1]}=" in published, target in targets)
                SIGNING.cleanup()
                self.assertFalse(directory.exists())
                self.assertEqual(list((root / "profiles").iterdir()), [])

    def test_aggregate_schema_decodes_selected_profiles_and_ignores_known_extras(self):
        with signing_fixture() as fixture:
            root, environment_file, profile, commands, security, output = fixture
            os.environ["APPLE_SAFARI_PROVISION_PROFILE_BASE64"] = ""
            os.environ["APPLE_URL_PROVISION_PROFILE_BASE64"] = "irrelevant"
            os.environ["APPLE_EXTENSION_PROFILES_BASE64"] = json.dumps({
                "SafariContentBlocker": base64.b64encode(b"dummy-SafariContentBlocker-cms").decode(),
                "URLFilterControl": {"unselected": "not activated"},
            })
            SIGNING.prepare()
            self.assertNotIn("URL_PROVISIONING_PROFILE_SPECIFIER=", environment_file.read_text())
            SIGNING.cleanup()

    def test_invalid_aggregate_or_missing_selected_profiles_fail_before_mutation(self):
        supplied = base64.b64encode(b"dummy-cms").decode()
        cases = {
            "duplicate": '{"SafariContentBlocker":"x","SafariContentBlocker":"y"}',
            "unknown": json.dumps({"OtherExtension": supplied}),
            "missing": "{}",
            "wrong type": "[]",
            "selected malformed": json.dumps({"SafariContentBlocker": "not base64"}),
            "mixed": json.dumps({"SafariContentBlocker": supplied}),
        }
        for case, value in cases.items():
            with self.subTest(case=case), signing_fixture() as fixture:
                root, environment_file, profile, commands, security, output = fixture
                os.environ["APPLE_EXTENSION_PROFILES_BASE64"] = value
                if case != "mixed":
                    os.environ["APPLE_SAFARI_PROVISION_PROFILE_BASE64"] = ""
                self.assertEqual(prepare_with_main(), 1)
                self.assertFalse(commands.calls)
                self.assertEqual(environment_file.read_text(), "")

    def test_selected_profile_is_required_but_unselected_profile_is_optional(self):
        with signing_fixture() as fixture:
            root, environment_file, profile, commands, security, output = fixture
            select_edition(profile, commands, "managed")
            os.environ["APPLE_MANAGED_CONTROL_PROVISION_PROFILE_BASE64"] = ""
            self.assertEqual(prepare_with_main(), 1)
            self.assertFalse(commands.calls)
            self.assertEqual(environment_file.read_text(), "")

    def test_invalid_edition_or_incoherent_bundle_alias_fail_before_mutation(self):
        for mutation in ("edition", "alias", "group"):
            with self.subTest(mutation=mutation), signing_fixture() as fixture:
                root, environment_file, profile, commands, security, output = fixture
                if mutation == "edition":
                    os.environ["APP_EDITION"] = "all"
                elif mutation == "alias":
                    os.environ["APP_BASE_BUNDLE_ID"] = "com.example.Other"
                else:
                    os.environ["FIREPRIVACY_APP_GROUP_ID"] = "unregistered"
                self.assertEqual(prepare_with_main(), 1)
                self.assertFalse(commands.calls)

    def test_every_selected_target_requires_group_and_network_grants_before_import(self):
        cases = (("consumer", "app", "group"), ("consumer", "SafariContentBlocker", "group"),
                 ("consumer", "app", "network"), ("url-filter", "URLFilterControl", "network"),
                 ("managed", "ManagedFilterData", "network"), ("managed", "ManagedFilterControl", "network"))
        for edition, target, mutation in cases:
            with self.subTest(edition=edition, target=target, mutation=mutation), signing_fixture() as fixture:
                root, environment_file, profile, commands, security, output = fixture
                select_edition(profile, commands, edition)
                selected = profile if target == "app" else commands.profiles[target]
                entitlement = SIGNING.GROUP_ENTITLEMENT if mutation == "group" else SIGNING.NETWORK_ENTITLEMENT
                selected["Entitlements"][entitlement] = []
                self.assertEqual(prepare_with_main(), 1)
                self.assertFalse(any(call[1] == "import" for call in commands.calls))
                self.assertFalse(Path(os.environ["FIREPRIVACY_SIGNING_DIR"]).exists())

    def test_selected_extension_bundle_and_team_are_checked_independently(self):
        for mutation in ("bundle", "team"):
            with self.subTest(mutation=mutation), signing_fixture() as fixture:
                root, environment_file, profile, commands, security, output = fixture
                entitlements = commands.profiles["SafariContentBlocker"]["Entitlements"]
                key = "application-identifier" if mutation == "bundle" else "com.apple.developer.team-identifier"
                entitlements[key] = "wrong-value"
                self.assertEqual(prepare_with_main(), 1)
                self.assertFalse(any(call[1] == "import" for call in commands.calls))

    def test_duplicate_target_profile_uuid_is_rejected_before_import(self):
        for identifier in (UUID, UUID.lower()):
            with self.subTest(identifier=identifier), signing_fixture() as fixture:
                root, environment_file, profile, commands, security, output = fixture
                commands.profiles["SafariContentBlocker"]["UUID"] = identifier
                self.assertEqual(prepare_with_main(), 1)
                self.assertFalse(any(call[1] == "import" for call in commands.calls))

    def test_all_selected_profiles_must_authorize_common_certificate_before_import(self):
        with signing_fixture() as fixture:
            root, environment_file, profile, commands, security, output = fixture
            commands.profiles["SafariContentBlocker"]["DeveloperCertificates"] = [b"different certificate"]
            self.assertEqual(prepare_with_main(), 1)
            self.assertFalse(any(call[1] == "import" for call in commands.calls))

    def test_partial_profile_installation_removes_prior_owned_profiles_only(self):
        with signing_fixture() as fixture:
            root, environment_file, profile, commands, security, output = fixture
            extension_uuid = commands.profiles["SafariContentBlocker"]["UUID"]
            existing = root / "profiles" / f"{extension_uuid}.mobileprovision"
            existing.parent.mkdir()
            existing.write_bytes(b"preexisting conflict")
            self.assertEqual(prepare_with_main(), 1)
            self.assertEqual(list((root / "profiles").iterdir()), [existing])
            self.assertEqual(existing.read_bytes(), b"preexisting conflict")
            self.assertFalse(Path(os.environ["FIREPRIVACY_SIGNING_DIR"]).exists())

    def test_cleanup_preserves_replaced_profile_inode_and_removes_other_owned_files(self):
        with signing_fixture() as fixture:
            root, environment_file, profile, commands, security, output = fixture
            SIGNING.prepare()
            existing = root / "profiles" / f"{UUID}.mobileprovision"
            existing.unlink()
            existing.write_bytes(b"replacement belonging to another operation")
            SIGNING.cleanup()
            self.assertEqual(list((root / "profiles").iterdir()), [existing])
            self.assertEqual(existing.read_bytes(), b"replacement belonging to another operation")

    def test_cleanup_supports_previous_single_profile_state(self):
        with signing_fixture() as fixture:
            root, environment_file, profile, commands, security, output = fixture
            SIGNING.prepare()
            directory = Path(os.environ["FIREPRIVACY_SIGNING_DIR"])
            state = json.loads((directory / "state.json").read_text())
            # Retire the second synthetic target before modeling a v1 run.
            extra = state["profiles"].pop()
            Path(extra["profile_target"]).unlink()
            Path(extra["profile_marker"]).unlink()
            state.update(state.pop("profiles")[0])
            state["version"] = 1
            SIGNING.save_state(directory, state)
            SIGNING.cleanup()
            self.assertFalse(directory.exists())
            self.assertEqual(list((root / "profiles").iterdir()), [])


class CloudBindingInventoryTests(unittest.TestCase):
    """Presence inventories cannot enter any signing/preparation path."""

    def inspect(self, environment):
        output = io.StringIO()
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(SIGNING.sys, "argv", ["cloud-signing.py", "check-bindings"]), \
                mock.patch.object(SIGNING, "require_runner", side_effect=AssertionError("runner access forbidden")), \
                mock.patch.object(SIGNING, "prepare", side_effect=AssertionError("preparation forbidden")), \
                mock.patch.object(SIGNING, "cleanup", side_effect=AssertionError("cleanup forbidden")), \
                mock.patch.object(SIGNING, "decode_base64_value", side_effect=AssertionError("credential decoding forbidden")), \
                mock.patch.object(SIGNING, "run", side_effect=AssertionError("external tools forbidden")), \
                mock.patch.object(SIGNING, "private_write", side_effect=AssertionError("private files forbidden")), \
                mock.patch.object(SIGNING.tempfile, "mkdtemp", side_effect=AssertionError("temporary files forbidden")), \
                redirect_stdout(output):
            code = SIGNING.main()
        return code, json.loads(output.getvalue()), output.getvalue()

    def complete(self, mode="upload", edition="consumer"):
        # Intentionally malformed values demonstrate presence is not validity.
        environment = {"RELEASE_MODE": mode, "APP_EDITION": edition,
            "APP_BASE_BUNDLE_ID": "private-placeholder-app-id",
            "APPLE_DISTRIBUTION_P12_BASE64": "private-placeholder-p12",
            "APPLE_DISTRIBUTION_P12_PASSWORD": "private-placeholder-password",
            "APPLE_PROVISION_PROFILE_BASE64": "private-placeholder-app-profile"}
        for target in SIGNING.EDITION_EXTENSIONS[edition]:
            environment[SIGNING.EXTENSION_BINDINGS[target][0]] = "private-placeholder-extension-profile"
        if mode == "upload":
            environment.update({name: "private-placeholder-" + name for name in SIGNING.ASC_BINDINGS})
        if edition == "url-filter":
            environment.update(FIREPRIVACY_PIR_SERVER_URL="private-placeholder-pir-url",
                               FIREPRIVACY_PIR_CONFIGURATION_IDENTITY="private-placeholder-pir-identity")
        return environment

    def test_all_consumer_upload_missing_bindings_reported_together(self):
        code, result, output = self.inspect({"RELEASE_MODE": "upload"})
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "missingBindings")
        self.assertEqual(result["missingBindings"], ["APP_BASE_BUNDLE_ID",
            "APPLE_DISTRIBUTION_P12_BASE64", "APPLE_DISTRIBUTION_P12_PASSWORD",
            "APPLE_PROVISION_PROFILE_BASE64", "APPLE_SAFARI_PROVISION_PROFILE_BASE64",
            *SIGNING.ASC_BINDINGS])
        self.assertTrue(result["readOnly"])
        self.assertFalse(result["credentialValidityVerified"])
        self.assertFalse(result["identifierRegistrationVerified"])

    def test_archive_requires_asc_only_when_partially_supplied(self):
        environment = self.complete(mode="archive")
        code, result, output = self.inspect(environment)
        self.assertEqual(code, 0)
        self.assertEqual(result["missingBindings"], [])
        for supplied in SIGNING.ASC_BINDINGS:
            with self.subTest(supplied=supplied):
                partial = {**environment, supplied: "private-partial-asc-value"}
                code, result, output = self.inspect(partial)
                self.assertEqual(code, 1)
                self.assertEqual(result["missingBindings"], [name for name in SIGNING.ASC_BINDINGS if name != supplied])
                self.assertTrue("private-partial-asc-value" not in output)

    def test_empty_declared_asc_archive_bindings_remain_optional(self):
        environment = self.complete(mode="archive")
        environment.update({name: "" for name in SIGNING.ASC_BINDINGS})
        code, result, output = self.inspect(environment)
        self.assertEqual(code, 0)
        self.assertEqual(result["missingBindings"], [])

    def test_missing_or_invalid_mode_and_edition_fail_without_echoing_values(self):
        cases = (({}, "invalidMode", "RELEASE_MODE"),
                 ({"RELEASE_MODE": "private-invalid-mode"}, "invalidMode", "RELEASE_MODE"),
                 ({"RELEASE_MODE": "upload", "APP_EDITION": "private-invalid-edition"}, "invalidEdition", "APP_EDITION"))
        for environment, status, name in cases:
            with self.subTest(status=status):
                code, result, output = self.inspect(environment)
                self.assertEqual(code, 1)
                self.assertEqual(result["status"], status)
                self.assertEqual(result["invalidBindingNames"], [name])
                self.assertTrue("private-invalid-" not in output)

    def test_aggregate_extension_profile_map_is_presence_alternative_only(self):
        environment = self.complete()
        environment.pop("APPLE_SAFARI_PROVISION_PROFILE_BASE64")
        environment["APPLE_EXTENSION_PROFILES_BASE64"] = "private-not-json-or-profiles"
        code, result, output = self.inspect(environment)
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "bindingsPresent")
        self.assertFalse(result["credentialValidityVerified"])
        self.assertIn("target coverage is not checked here", result["note"])
        self.assertTrue("private-not-json-or-profiles" not in output)

    def test_existing_bundle_alias_satisfies_presence_without_registration_claim(self):
        environment = self.complete()
        environment["BUNDLE_ID"] = environment.pop("APP_BASE_BUNDLE_ID")
        code, result, output = self.inspect(environment)
        self.assertEqual(code, 0)
        self.assertEqual(result["missingBindings"], [])
        self.assertFalse(result["identifierRegistrationVerified"])

    def test_each_edition_requires_only_its_selected_profile_bindings(self):
        for edition, targets in SIGNING.EDITION_EXTENSIONS.items():
            with self.subTest(edition=edition):
                environment = self.complete(edition=edition)
                for target in targets:
                    environment.pop(SIGNING.EXTENSION_BINDINGS[target][0])
                code, result, output = self.inspect(environment)
                self.assertEqual(code, 1)
                self.assertEqual(result["missingBindings"], [SIGNING.EXTENSION_BINDINGS[target][0] for target in targets])
                self.assertTrue("private-placeholder-" not in output)

    def test_url_edition_collects_missing_pir_service_variables(self):
        environment = self.complete(edition="url-filter")
        environment.pop("FIREPRIVACY_PIR_SERVER_URL")
        environment.pop("FIREPRIVACY_PIR_CONFIGURATION_IDENTITY")
        code, result, output = self.inspect(environment)
        self.assertEqual(code, 1)
        self.assertEqual(result["missingBindings"], ["FIREPRIVACY_PIR_SERVER_URL", "FIREPRIVACY_PIR_CONFIGURATION_IDENTITY"])


if __name__ == "__main__":
    unittest.main()
