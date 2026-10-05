"""Archive release gates, without credentials, Apple tooling or network calls.

The fixtures model real signed bundle layouts for each distribution edition.
Native signature trust itself still requires Apple's macOS tooling.
"""
import datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager, redirect_stdout
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("fireprivacy_release_validation", ROOT / "scripts/release-validation.py")
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)

TEAM = "LYDVWU62G4"
PREFIX = "OLDPREFIX1"
BUNDLE = "com.example.FirePrivacy"
GROUP = "group.com.example.FirePrivacy.protection"
CERTIFICATE = b"mock Apple distribution certificate"
IDENTITY = hashlib.sha1(CERTIFICATE).hexdigest().upper()


class ArchiveFixture:
    def __init__(self, directory, edition):
        # macOS commonly exposes runner temporary paths through /var while
        # Path.resolve() returns /private/var. Model the validator's canonical
        # paths rather than comparing two spellings of the same fixture.
        self.root = Path(directory).resolve()
        self.archive = self.root / "FirePrivacy.xcarchive"
        self.build = self.root / "apple"
        self.build.mkdir()
        self.edition = edition
        self.environment = {"APP_EDITION": edition, "APP_BASE_BUNDLE_ID": BUNDLE,
                            "TEAM_ID": TEAM, "APP_VERSION": "1.0", "BUILD_NUMBER": "1",
                            "FIREPRIVACY_APP_GROUP_ID": GROUP,
                            "PRIVACY_POLICY_URL": "https://example.com/privacy", "SUPPORT_URL": "https://example.com/support"}
        if edition == "url-filter":
            self.environment.update(FIREPRIVACY_PIR_SERVER_URL="https://pir.example.com/query",
                                    FIREPRIVACY_PRIVACY_PASS_ISSUER_URL="https://issuer.example.com/token",
                                    FIREPRIVACY_PIR_CONFIGURATION_IDENTITY="registered-apple-pir-fixture")
        self.bundles = {}
        self.profiles = {}
        self.entitlements = {}
        self.certificates = {}
        self.signature_teams = {}
        self.signature_ids = {}
        self.calls = []
        self.summaries = {family: {"result": "Passed", "passedTests": 9, "skippedTests": 1,
                                 "totalTestCount": 10, "failedTests": 0} for family in ("iphone", "ipad")}
        self.invalid_signatures = set()
        self.trusted_identities = {IDENTITY}
        self.fail_keychain_creation = False
        product, selected, capabilities = RELEASE.EDITIONS[edition]
        self.app = self.archive / "Products/Applications" / (product + ".app")
        for index, target in enumerate(selected, 1):
            name, suffix, required, point = RELEASE.TARGETS[target]
            name = product if target == "app" else name
            parent = self.app / ("Extensions" if target == "url" else "PlugIns")
            bundle = self.app if target == "app" else parent / (name + ".appex")
            bundle.mkdir(parents=True)
            self.bundles[target] = bundle
            bundle_id = BUNDLE + suffix
            info = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": name,
                    "CFBundlePackageType": "APPL" if target == "app" else "XPC!",
                    "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "DTSDKName": "iphoneos26.0",
                    "UIDeviceFamily": [1, 2], "FirePrivacyAppGroup": GROUP}
            if target == "app":
                info.update(FirePrivacyDistributionEdition=edition, FirePrivacyPrivacyURL=self.environment["PRIVACY_POLICY_URL"],
                            FirePrivacySupportURL=self.environment["SUPPORT_URL"])
                if edition == "url-filter":
                    info["NSPIRConfiguration"] = {"PIRServerURL": self.environment["FIREPRIVACY_PIR_SERVER_URL"],
                                                   "PrivacyPassIssuerURL": self.environment["FIREPRIVACY_PRIVACY_PASS_ISSUER_URL"]}
                    info["FirePrivacyApplePIRConfigurationIdentity"] = self.environment["FIREPRIVACY_PIR_CONFIGURATION_IDENTITY"]
            elif target == "url":
                info["EXAppExtensionAttributes"] = {"EXExtensionPointIdentifier": point}
            else:
                info["NSExtension"] = {"NSExtensionPointIdentifier": point}
            self.write_plist(target, "Info.plist", info)
            self.write_plist(target, "PrivacyInfo.xcprivacy", {"NSPrivacyTracking": False, "NSPrivacyCollectedDataTypes": [], "NSPrivacyAccessedAPITypes": []})
            (bundle / name).write_bytes(b"mock signed executable " + target.encode())
            (bundle / "embedded.mobileprovision").write_bytes(b"mock signed Apple CMS " + target.encode())
            entitlement = {"application-identifier": PREFIX + "." + bundle_id,
                           "com.apple.developer.team-identifier": TEAM, "get-task-allow": False,
                           "com.apple.security.application-groups": [GROUP]}
            required = capabilities if target == "app" else required
            if required:
                entitlement["com.apple.developer.networking.networkextension"] = sorted(required)
            self.entitlements[target] = entitlement
            self.profiles[target] = {"UUID": f"0000000{index}-0000-0000-0000-000000000001",
                                     "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=365),
                                     "TeamIdentifier": [TEAM], "Platform": ["iOS"], "ApplicationIdentifierPrefix": [PREFIX],
                                     "DeveloperCertificates": [CERTIFICATE], "Entitlements": dict(entitlement)}
            self.certificates[target] = CERTIFICATE
            self.signature_teams[target] = TEAM
            self.signature_ids[target] = bundle_id
        for family in ("iphone", "ipad"):
            result = self.root / (family + ".xcresult")
            result.mkdir()
            (self.build / f"LatestTests-{family}.txt").write_text(str(result) + "\n")

    def write_plist(self, target, name, value):
        (self.bundles[target] / name).write_bytes(plistlib.dumps(value))

    def modify_info(self, target, key, value):
        info = plistlib.loads((self.bundles[target] / "Info.plist").read_bytes())
        info[key] = value
        self.write_plist(target, "Info.plist", info)

    def manual(self):
        self.environment.update(SIGNING_MODE="manual", FIREPRIVACY_SIGNING_IDENTITY=IDENTITY)
        for target, profile in self.profiles.items():
            self.environment[RELEASE.PROFILE_VARIABLES[target]] = profile["UUID"]

    def target_at(self, path):
        return next(target for target, bundle in self.bundles.items() if bundle == Path(path).resolve())

    def run(self, arguments, *, capture_output, text, check):
        self.calls.append(arguments)
        output = b""
        error = b""
        if arguments[0] == "codesign":
            target = self.target_at(arguments[-1])
            if "--verify" in arguments:
                if target in self.invalid_signatures:
                    raise subprocess.CalledProcessError(1, arguments)
            elif "--extract-certificates" in arguments:
                prefix = arguments[arguments.index("--extract-certificates") + 1]
                Path(prefix + "0").write_bytes(self.certificates[target])
            elif "--entitlements" in arguments:
                output = plistlib.dumps(self.entitlements[target])
            else:
                error = f"Executable={arguments[-1]}\nIdentifier={self.signature_ids[target]}\nTeamIdentifier={self.signature_teams[target]}\n".encode()
        elif arguments[0] == "/usr/bin/security":
            if arguments[1] == "create-keychain" and self.fail_keychain_creation:
                Path(arguments[-1]).write_bytes(b"partially-created-keychain")
                raise subprocess.CalledProcessError(1, arguments)
            elif arguments[1] == "delete-keychain":
                Path(arguments[-1]).unlink(missing_ok=True)
            elif arguments[1] == "find-identity":
                output = "".join(f' 1) {identity} "Apple Distribution: Fixture"\n' for identity in self.trusted_identities).encode()
            elif arguments[1] == "list-keychains":
                if "-s" not in arguments:
                    output = b'"/tmp/original Login.keychain-db"\n"/tmp/original System.keychain"\n'
            elif arguments[1] == "cms":
                target = self.target_at(Path(arguments[-1]).parent)
                self.assert_decode_isolated(arguments)
                output = plistlib.dumps(self.profiles[target])
            elif arguments[1] not in ("create-keychain", "unlock-keychain", "delete-keychain"):
                raise AssertionError("Unexpected security operation")
        elif arguments[:2] == ["xcrun", "xcresulttool"]:
            family = Path(arguments[-1]).stem
            output = json.dumps(self.summaries[family]).encode()
        else:
            raise AssertionError("Unexpected external command")
        return subprocess.CompletedProcess(arguments, 0, output.decode() if text else output, error.decode() if text else error)

    def assert_decode_isolated(self, arguments):
        if "-k" not in arguments:
            raise AssertionError("Profile decoding must not mutate the default keychain")
        keychain = arguments[arguments.index("-k") + 1]
        if not any(call[1] == "create-keychain" and call[-1] == keychain for call in self.calls if call[0] == "/usr/bin/security"):
            raise AssertionError("Profile decoding must use the owned temporary keychain")

    def invoke(self, mode):
        with mock.patch.dict(os.environ, self.environment, clear=True), mock.patch.object(sys, "argv", ["release-validation.py", mode, str(self.archive)]), redirect_stdout(io.StringIO()):
            RELEASE.main()

    def stamp(self):
        self.invoke("stamp")
        return json.loads((self.archive / "FirePrivacyValidation.json").read_text())

    def edit_stamp(self, edit):
        path = self.archive / "FirePrivacyValidation.json"
        data = json.loads(path.read_text())
        edit(data)
        path.write_text(json.dumps(data))


@contextmanager
def archive_fixture(edition="consumer"):
    with tempfile.TemporaryDirectory(prefix="release-validation-tests-") as directory:
        fixture = ArchiveFixture(directory, edition)
        with mock.patch.object(RELEASE, "BUILD", fixture.build), mock.patch.object(RELEASE.subprocess, "run", side_effect=fixture.run), mock.patch.object(RELEASE, "verify_apple_profile") as trust:
            fixture.trust = trust
            yield fixture


class ReleaseValidationTests(unittest.TestCase):
    def test_runner_temporary_symlink_alias_uses_canonical_fixture_paths(self):
        for edition in RELEASE.EDITIONS:
            with self.subTest(edition=edition), tempfile.TemporaryDirectory(prefix="release-path-alias-") as directory:
                root = Path(directory).resolve()
                actual = root / "actual"
                actual.mkdir()
                alias = root / "runner-temp-alias"
                alias.symlink_to(actual, target_is_directory=True)
                fixture = ArchiveFixture(alias, edition)
                fixture.manual()
                self.assertEqual(fixture.root, actual)
                for target, bundle in fixture.bundles.items():
                    self.assertEqual(fixture.target_at(alias / bundle.relative_to(actual)), target)
                with (mock.patch.object(RELEASE, "BUILD", fixture.build),
                      mock.patch.object(RELEASE.subprocess, "run", side_effect=fixture.run),
                      mock.patch.object(RELEASE, "verify_apple_profile")):
                    fixture.stamp()
                    fixture.invoke("verify")

    def test_each_edition_stamps_exact_targets_and_hashes(self):
        for edition, (_, selected, _) in RELEASE.EDITIONS.items():
            with self.subTest(edition=edition), archive_fixture(edition) as fixture:
                fixture.manual()
                stamp = fixture.stamp()
                fixture.invoke("verify")
                self.assertEqual(set(stamp["targets"]), set(selected))
                self.assertEqual(stamp["configuration"]["edition"], edition)
                for target in selected:
                    details = stamp["targets"][target]
                    executable = plistlib.loads((fixture.bundles[target] / "Info.plist").read_bytes())["CFBundleExecutable"]
                    self.assertEqual(set(details["hashes"]), {executable, "Info.plist", "PrivacyInfo.xcprivacy", "embedded.mobileprovision"})
                    self.assertEqual(details["teamIdentifier"], TEAM)
                    self.assertEqual(details["deviceFamilies"], [1, 2])
                    self.assertEqual(details["signingIdentity"], IDENTITY)
                self.assertEqual(stamp["xctestResults"]["iphone"]["totalTests"], 10)
                self.assertEqual(stamp["xctestResults"]["ipad"]["passedTests"], 9)
                self.assertEqual(fixture.trust.call_count, 2 * len(selected))
                decoded = [call for call in fixture.calls if call[:2] == ["/usr/bin/security", "cms"]]
                self.assertEqual(len(decoded), 2 * len(selected))
                self.assertTrue(all("-k" in call for call in decoded))
                self.assertEqual(sum(call[1] == "delete-keychain" for call in fixture.calls if call[0] == "/usr/bin/security"), 2)
                restoration = ["/usr/bin/security", "list-keychains", "-d", "user", "-s", "/tmp/original Login.keychain-db", "/tmp/original System.keychain"]
                self.assertEqual(fixture.calls.count(restoration), 4)

    def test_all_selected_bundle_bytes_bound_to_stamp(self):
        for edition, (_, selected, _) in RELEASE.EDITIONS.items():
            for target in selected:
                for kind in ("executable", "Info.plist", "PrivacyInfo.xcprivacy", "embedded.mobileprovision"):
                    with self.subTest(edition=edition, target=target, kind=kind), archive_fixture(edition) as fixture:
                        fixture.stamp()
                        bundle = fixture.bundles[target]
                        if kind == "executable":
                            name = plistlib.loads((bundle / "Info.plist").read_bytes())["CFBundleExecutable"]
                            (bundle / name).write_bytes(b"changed signed binary")
                        elif kind.endswith("plist") or kind.endswith("xcprivacy"):
                            value = plistlib.loads((bundle / kind).read_bytes())
                            value["DifferentButStructurallyValid"] = "tampered"
                            fixture.write_plist(target, kind, value)
                        else:
                            (bundle / kind).write_bytes(b"changed CMS profile")
                        with self.assertRaises(SystemExit):
                            fixture.invoke("verify")

    def test_every_target_rejects_wrong_bundle_version_build_sdk_family_and_group(self):
        fields = {"CFBundleIdentifier": "com.example.Unexpected", "CFBundleShortVersionString": "2.0",
                  "CFBundleVersion": "2", "DTSDKName": "iphonesimulator26.0", "UIDeviceFamily": [1],
                  "FirePrivacyAppGroup": "group.com.example.Other"}
        for edition, (_, selected, _) in RELEASE.EDITIONS.items():
            for target in selected:
                for key, value in fields.items():
                    with self.subTest(edition=edition, target=target, key=key), archive_fixture(edition) as fixture:
                        fixture.modify_info(target, key, value)
                        with self.assertRaises(SystemExit):
                            fixture.stamp()

    def test_device_families_require_integer_iphone_and_ipad_ids(self):
        for value in ([True, 2], [1, "2"], [1, 2, 2], None):
            with self.subTest(value=value), archive_fixture() as fixture:
                if value is None:
                    info = plistlib.loads((fixture.app / "Info.plist").read_bytes())
                    info.pop("UIDeviceFamily")
                    fixture.write_plist("app", "Info.plist", info)
                else:
                    fixture.modify_info("app", "UIDeviceFamily", value)
                with self.assertRaises(SystemExit):
                    fixture.stamp()

    def test_wrong_signature_team_and_identifier_are_rejected_for_each_target(self):
        for edition, (_, selected, _) in RELEASE.EDITIONS.items():
            for target in selected:
                for key in ("signature_teams", "signature_ids"):
                    with self.subTest(edition=edition, target=target, key=key), archive_fixture(edition) as fixture:
                        getattr(fixture, key)[target] = "WRONGTEAM1" if key == "signature_teams" else "com.example.Wrong"
                        with self.assertRaises(SystemExit):
                            fixture.stamp()

    def test_each_expected_extension_is_required(self):
        for edition, (_, selected, _) in RELEASE.EDITIONS.items():
            for target in selected[1:]:
                with self.subTest(edition=edition, target=target), archive_fixture(edition) as fixture:
                    fixture.bundles[target].rename(fixture.root / (target + ".appex"))
                    with self.assertRaises(SystemExit):
                        fixture.stamp()

    def test_consumer_rejects_each_privileged_extension(self):
        for name in ("URLFilterControl", "ManagedFilterData", "ManagedFilterControl"):
            with self.subTest(name=name), archive_fixture() as fixture:
                (fixture.app / "PlugIns" / (name + ".appex")).mkdir()
                with self.assertRaises(SystemExit):
                    fixture.stamp()

    def test_consumer_rejects_privileged_network_entitlements(self):
        for capability in ("url-filter-provider", "content-filter-provider"):
            with self.subTest(capability=capability), archive_fixture() as fixture:
                fixture.entitlements["app"]["com.apple.developer.networking.networkextension"].append(capability)
                with self.assertRaises(SystemExit):
                    fixture.stamp()

    def test_unknown_and_duplicate_embedded_extensions_are_rejected(self):
        for name, parent in (("Unknown", "PlugIns"), ("SafariContentBlocker", "Extensions")):
            with self.subTest(name=name), archive_fixture() as fixture:
                (fixture.app / parent / (name + ".appex")).mkdir(parents=True)
                with self.assertRaises(SystemExit):
                    fixture.stamp()

    def test_url_extension_accepts_foundationextensions_location(self):
        with archive_fixture("url-filter") as fixture:
            old = fixture.bundles["url"]
            new = fixture.app / "FoundationExtensions" / old.name
            new.parent.mkdir()
            old.rename(new)
            fixture.bundles["url"] = new
            fixture.stamp()
            fixture.invoke("verify")

    def test_rejects_wrong_edition_host_or_product(self):
        with archive_fixture() as fixture:
            fixture.modify_info("app", "FirePrivacyDistributionEdition", "managed")
            with self.assertRaises(SystemExit):
                fixture.stamp()
        with archive_fixture() as fixture:
            fixture.environment["APP_EDITION"] = "managed"
            with self.assertRaises(SystemExit):
                fixture.stamp()

    def test_release_configuration_changes_invalidate_stamp(self):
        changes = {"APP_EDITION": "managed", "APP_BASE_BUNDLE_ID": "com.example.Other", "TEAM_ID": "OTHERTEAM1",
                   "APP_VERSION": "2.0", "BUILD_NUMBER": "2", "FIREPRIVACY_APP_GROUP_ID": "group.com.example.Other",
                   "PRIVACY_POLICY_URL": "https://example.com/other", "SUPPORT_URL": "https://example.com/other",
                   "SIGNING_MODE": "manual", "FIREPRIVACY_SIGNING_IDENTITY": "A" * 40}
        for key, value in changes.items():
            with self.subTest(key=key), archive_fixture() as fixture:
                fixture.stamp()
                fixture.environment[key] = value
                with self.assertRaises(SystemExit):
                    fixture.invoke("verify")

    def test_legacy_bundle_alias_must_be_coherent(self):
        with archive_fixture() as fixture:
            fixture.environment["BUNDLE_ID"] = BUNDLE
            fixture.stamp()
            fixture.invoke("verify")
            fixture.environment["BUNDLE_ID"] = "com.example.Other"
            with self.assertRaises(SystemExit):
                fixture.invoke("verify")
        with archive_fixture() as fixture:
            fixture.environment["BUNDLE_ID"] = fixture.environment.pop("APP_BASE_BUNDLE_ID")
            fixture.stamp()
            fixture.invoke("verify")

    def test_irrelevant_edition_profile_bindings_do_not_activate_targets(self):
        with archive_fixture() as fixture:
            fixture.environment.update(URL_PROVISIONING_PROFILE_SPECIFIER="unused", MANAGED_DATA_PROVISIONING_PROFILE_SPECIFIER="unused", MANAGED_CONTROL_PROVISIONING_PROFILE_SPECIFIER="unused")
            stamp = fixture.stamp()
            self.assertEqual(set(stamp["configuration"]["provisioningProfiles"]), {"app", "safari"})
            self.assertEqual(set(stamp["targets"]), {"app", "safari"})

    def test_manual_profile_subset_and_uuid_are_required(self):
        with archive_fixture() as fixture:
            fixture.manual()
            fixture.environment.pop("SAFARI_PROVISIONING_PROFILE_SPECIFIER")
            with self.assertRaises(SystemExit):
                fixture.stamp()
        with archive_fixture() as fixture:
            fixture.manual()
            fixture.environment["SAFARI_PROVISIONING_PROFILE_SPECIFIER"] = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
            with self.assertRaises(SystemExit):
                fixture.stamp()

    def test_legacy_app_profile_alias_is_coherent_and_sufficient(self):
        with archive_fixture() as fixture:
            fixture.manual()
            fixture.environment["FIREPRIVACY_PROFILE_UUID"] = fixture.environment.pop("APP_PROVISIONING_PROFILE_SPECIFIER")
            fixture.stamp()
            fixture.invoke("verify")
            fixture.environment["APP_PROVISIONING_PROFILE_SPECIFIER"] = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
            with self.assertRaises(SystemExit):
                fixture.invoke("verify")

    def test_url_edition_requires_public_pir_service_and_registered_identity(self):
        changes = {"FIREPRIVACY_PIR_SERVER_URL": ("", "http://pir.example.com", "https://user:pass@pir.example.com"),
                   "FIREPRIVACY_PRIVACY_PASS_ISSUER_URL": ("http://issuer.example.com", "https:///issuer"),
                   "FIREPRIVACY_PIR_CONFIGURATION_IDENTITY": ("", "   ", " identity-with-whitespace ")}
        for key, values in changes.items():
            for value in values:
                with self.subTest(key=key, value=value), archive_fixture("url-filter") as fixture:
                    fixture.environment[key] = value
                    with self.assertRaises(SystemExit):
                        fixture.stamp()

    def test_compiled_pir_values_must_match_configuration_and_stamp(self):
        for key in ("PIRServerURL", "PrivacyPassIssuerURL"):
            with self.subTest(key=key), archive_fixture("url-filter") as fixture:
                fixture.stamp()
                info = plistlib.loads((fixture.app / "Info.plist").read_bytes())
                info["NSPIRConfiguration"][key] = "https://different.example.com"
                fixture.write_plist("app", "Info.plist", info)
                with self.assertRaises(SystemExit):
                    fixture.invoke("verify")
        with archive_fixture("url-filter") as fixture:
            fixture.modify_info("app", "FirePrivacyApplePIRConfigurationIdentity", "different-registration")
            with self.assertRaises(SystemExit):
                fixture.stamp()
        with archive_fixture("url-filter") as fixture:
            fixture.stamp()
            fixture.environment["FIREPRIVACY_PIR_CONFIGURATION_IDENTITY"] = "different-registration"
            with self.assertRaises(SystemExit):
                fixture.invoke("verify")

    def test_optional_privacy_pass_and_consumer_pir_exclusion(self):
        with archive_fixture("url-filter") as fixture:
            fixture.environment["FIREPRIVACY_PRIVACY_PASS_ISSUER_URL"] = ""
            info = plistlib.loads((fixture.app / "Info.plist").read_bytes())
            info["NSPIRConfiguration"].pop("PrivacyPassIssuerURL")
            fixture.write_plist("app", "Info.plist", info)
            fixture.stamp()
            fixture.invoke("verify")
        with archive_fixture() as fixture:
            fixture.environment.update(FIREPRIVACY_PIR_SERVER_URL="unused-invalid-value", FIREPRIVACY_PIR_CONFIGURATION_IDENTITY="")
            stamp = fixture.stamp()
            self.assertEqual(stamp["configuration"]["pirConfiguration"], {})

    def test_profile_grants_may_include_other_registered_capabilities(self):
        with archive_fixture() as fixture:
            for profile in fixture.profiles.values():
                profile["Entitlements"]["com.apple.security.application-groups"] = [GROUP, "group.com.example.Other"]
                profile["Entitlements"]["com.apple.developer.networking.networkextension"] = ["dns-settings", "content-filter-provider", "url-filter-provider"]
            fixture.stamp()
            fixture.invoke("verify")

    def test_signed_profile_prefix_may_differ_from_team(self):
        with archive_fixture() as fixture:
            self.assertNotEqual(PREFIX, TEAM)
            fixture.stamp()
            fixture.invoke("verify")

    def test_profile_trust_failure_stops_validation_and_deletes_keychain(self):
        with archive_fixture() as fixture:
            fixture.trust.side_effect = SystemExit("Apple trust rejected the profile")
            with self.assertRaises(SystemExit):
                fixture.stamp()
            self.assertFalse(any(call[:2] == ["/usr/bin/security", "cms"] for call in fixture.calls))
            self.assertTrue(any(call[:2] == ["/usr/bin/security", "delete-keychain"] for call in fixture.calls))

    def test_invalid_profiles_are_rejected(self):
        changes = {"TeamIdentifier": ["OTHERTEAM1"], "Platform": ["macOS"], "ProvisionedDevices": [],
                   "ProvisionsAllDevices": True, "ExpirationDate": datetime.datetime(2000, 1, 1),
                   "DeveloperCertificates": [b"wrong certificate"], "UUID": "bad UUID"}
        for key, value in changes.items():
            with self.subTest(key=key), archive_fixture() as fixture:
                fixture.profiles["safari"][key] = value
                with self.assertRaises(SystemExit):
                    fixture.stamp()

    def test_missing_profile_or_manifest_and_symlink_inputs_rejected(self):
        for name in ("PrivacyInfo.xcprivacy", "embedded.mobileprovision"):
            with self.subTest(name=name), archive_fixture() as fixture:
                (fixture.bundles["safari"] / name).unlink()
                with self.assertRaises(SystemExit):
                    fixture.stamp()
        with archive_fixture() as fixture:
            profile = fixture.bundles["safari"] / "embedded.mobileprovision"
            moved = fixture.root / "external-profile"
            profile.rename(moved)
            profile.symlink_to(moved)
            with self.assertRaises(SystemExit):
                fixture.stamp()

    def test_privacy_collection_or_tracking_gate_applies_to_every_target(self):
        for edition, (_, selected, _) in RELEASE.EDITIONS.items():
            for target in selected:
                for key, value in (("NSPrivacyTracking", True), ("NSPrivacyCollectedDataTypes", [{"NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeOtherDataTypes"}])):
                    with self.subTest(edition=edition, target=target, key=key), archive_fixture(edition) as fixture:
                        fixture.write_plist(target, "PrivacyInfo.xcprivacy", {key: value})
                        with self.assertRaises(SystemExit):
                            fixture.stamp()

    def test_changed_signing_identity_and_entitlements_rejected(self):
        with archive_fixture("managed") as fixture:
            fixture.stamp()
            fixture.certificates["managed_data"] = b"different certificate"
            fixture.profiles["managed_data"]["DeveloperCertificates"] = [b"different certificate"]
            with self.assertRaises(SystemExit):
                fixture.invoke("verify")
        with archive_fixture() as fixture:
            fixture.stamp()
            fixture.entitlements["safari"]["keychain-access-groups"] = ["new extra signed grant"]
            with self.assertRaises(SystemExit):
                fixture.invoke("verify")

    def test_partial_native_keychain_creation_failure_restores_and_deletes(self):
        with archive_fixture() as fixture:
            fixture.fail_keychain_creation = True
            with self.assertRaises(SystemExit):
                fixture.stamp()
            create = next(call for call in fixture.calls if call[:2] == ["/usr/bin/security", "create-keychain"])
            restore = ["/usr/bin/security", "list-keychains", "-d", "user", "-s", "/tmp/original Login.keychain-db", "/tmp/original System.keychain"]
            self.assertIn(restore, fixture.calls)
            self.assertIn(["/usr/bin/security", "delete-keychain", create[-1]], fixture.calls)
            self.assertFalse(Path(create[-1]).exists())
            self.assertFalse(fixture.trust.called)

    def test_signed_leaf_must_be_current_trusted_valid_codesigning_identity(self):
        for manual in (False, True):
            with self.subTest(manual=manual), archive_fixture() as fixture:
                if manual:
                    fixture.manual()
                fixture.trusted_identities.clear()
                with self.assertRaises(SystemExit):
                    fixture.stamp()
                self.assertIn(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], fixture.calls)

    def test_duplicate_profile_uuids_rejected_for_automatic_and_manual(self):
        for manual in (False, True):
            with self.subTest(manual=manual), archive_fixture() as fixture:
                fixture.profiles["safari"]["UUID"] = fixture.profiles["app"]["UUID"]
                if manual:
                    fixture.manual()
                with self.assertRaises(SystemExit):
                    fixture.stamp()

    def test_signed_identity_team_group_application_and_debugger_grants_exact(self):
        fields = {"com.apple.developer.team-identifier": "OTHERTEAM1", "application-identifier": PREFIX + ".com.example.Wrong",
                  "get-task-allow": True, "com.apple.security.application-groups": [GROUP, "group.com.example.Other"]}
        for target in ("app", "safari"):
            for key, value in fields.items():
                with self.subTest(target=target, key=key), archive_fixture() as fixture:
                    fixture.entitlements[target][key] = value
                    with self.assertRaises(SystemExit):
                        fixture.stamp()

    def test_codesign_verification_failure_rejected(self):
        with archive_fixture() as fixture:
            fixture.invalid_signatures.add("safari")
            with self.assertRaises(SystemExit):
                fixture.stamp()

    def test_missing_failed_or_empty_native_tests_prevent_stamp(self):
        for family in ("iphone", "ipad"):
            for change in ({"result": "Failed", "failedTests": 1}, {"passedTests": 0, "skippedTests": 0, "totalTestCount": 0}, {"passedTests": 0, "skippedTests": 10}, {"failedTests": 1}, {"totalTestCount": 99}):
                with self.subTest(family=family, change=change), archive_fixture() as fixture:
                    fixture.summaries[family].update(change)
                    with self.assertRaises(SystemExit):
                        fixture.stamp()
            with self.subTest(family=family, missing=True), archive_fixture() as fixture:
                (fixture.build / f"LatestTests-{family}.txt").unlink()
                with self.assertRaises(SystemExit):
                    fixture.stamp()

    def test_stamp_must_retain_both_test_families_and_core_privacy_gates(self):
        changes = (lambda stamp: stamp.pop("coreTests"), lambda stamp: stamp.update(privacyRegression="failed"),
                   lambda stamp: stamp["xctestResults"].pop("ipad"),
                   lambda stamp: stamp["xctestResults"]["iphone"].update(failedTests=1),
                   lambda stamp: stamp["xctestResults"]["ipad"].update(totalTests=0))
        for index, edit in enumerate(changes):
            with self.subTest(index=index), archive_fixture() as fixture:
                fixture.stamp()
                fixture.edit_stamp(edit)
                with self.assertRaises(SystemExit):
                    fixture.invoke("verify")

    def test_saved_target_metadata_and_old_stamps_rejected(self):
        changes = (lambda stamp: stamp.update(schemaVersion=1), lambda stamp: stamp["targets"].pop("safari"),
                   lambda stamp: stamp["targets"]["safari"].update(teamIdentifier="OTHERTEAM1"),
                   lambda stamp: stamp.update(version="2.0"))
        for index, edit in enumerate(changes):
            with self.subTest(index=index), archive_fixture() as fixture:
                fixture.stamp()
                fixture.edit_stamp(edit)
                with self.assertRaises(SystemExit):
                    fixture.invoke("verify")

    def test_unsafe_public_urls_rejected(self):
        for value in ("http://example.com/privacy", "https://username:password@example.com/privacy", "https:///privacy"):
            with self.subTest(value=value), archive_fixture() as fixture:
                fixture.environment["PRIVACY_POLICY_URL"] = value
                with self.assertRaises(SystemExit):
                    fixture.stamp()


if __name__ == "__main__":
    unittest.main()
