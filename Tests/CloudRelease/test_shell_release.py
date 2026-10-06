"""Exercise release command boundaries with isolated files and mocked Apple tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROFILES = {
    prefix + "_PROVISIONING_PROFILE_SPECIFIER": f"{index:08x}-1111-2222-3333-444444444444"
    for index, prefix in enumerate(("APP", "SAFARI", "URL", "MANAGED_DATA", "MANAGED_CONTROL"), 1)
}
EDITIONS = {
    "consumer": ("FirePrivacy", ("APP", "SAFARI")),
    "url-filter": ("FirePrivacyURL", ("APP", "SAFARI", "URL")),
    "managed": ("FirePrivacyManaged", ("APP", "SAFARI", "MANAGED_DATA", "MANAGED_CONTROL")),
}
SUFFIXES = {"APP": "", "SAFARI": ".SafariContentBlocker", "URL": ".URLFilterControl",
            "MANAGED_DATA": ".ManagedFilterData", "MANAGED_CONTROL": ".ManagedFilterControl"}
PIR = {"FIREPRIVACY_PIR_SERVER_URL": "https://pir.example.org/query",
       "FIREPRIVACY_PIR_CONFIGURATION_IDENTITY": "apple-approved-test-fixture-id"}

MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, plistlib, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
entry = {"tool": name, "args": args}
if name == "uname":
    print("Darwin")
elif name == "xcrun":
    print("26.0")
elif name == "xcodebuild" and args == ["-version"]:
    print("Xcode 26.0\nBuild version MOCK")
elif name == "xcodebuild" and "-exportArchive" in args:
    entry["options"] = plistlib.loads(Path(args[args.index("-exportOptionsPlist") + 1]).read_bytes())
elif name == "xcodebuild" and "archive" in args:
    archive = Path(args[args.index("-archivePath") + 1])
    (archive / "Products/Applications" / os.environ["FIREPRIVACY_PRODUCT"]).mkdir(parents=True)
with Path(os.environ["MOCK_LOG"]).open("a") as output:
    output.write(json.dumps(entry) + "\n")
if os.environ.get("MOCK_FAIL_TOOL") == name:
    raise SystemExit(9)
'''

MOCK_VALIDATOR = r'''import json, os, runpy, sys
from pathlib import Path
with Path(os.environ["MOCK_LOG"]).open("a") as output:
    output.write(json.dumps({"tool": "release-validation", "args": sys.argv[1:]}) + "\n")
if os.environ.get("MOCK_FAIL_VALIDATION") == sys.argv[1]:
    raise SystemExit(8)
if sys.argv[1] == "configuration":
    runpy.run_path(str(Path(__file__).with_name("release-validation-real.py")), run_name="__main__")
elif sys.argv[1] == "stamp":
    (Path(sys.argv[2]) / "FirePrivacyValidation.json").write_text("{}")
'''

MOCK_TESTS = r'''#!/usr/bin/env bash
python3 - "$1" <<'PY'
import json, os, sys
from pathlib import Path
with Path(os.environ["MOCK_LOG"]).open("a") as output:
    output.write(json.dumps({"tool": "test-ios", "args": sys.argv[1:]}) + "\n")
if os.environ.get("MOCK_FAIL_FAMILY") == sys.argv[1]:
    raise SystemExit(7)
PY
'''


class ShellReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fireprivacy-shell-release-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        for name in ("apple-common.sh", "archive-ios.sh", "export-app-store.sh", "dataset-public-keys.py"):
            shutil.copy2(ROOT / "scripts" / name, self.scripts / name)
        for relative in ("Sources/FirePrivacyCore/KnowledgeBaseResources.swift",
                         "Sources/FirePrivacyCore/Resources/Protection/filter-trust-roots.json"):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        shutil.copy2(ROOT / "scripts/release-validation.py", self.scripts / "release-validation-real.py")
        (self.scripts / "release-validation.py").write_text(MOCK_VALIDATOR)
        (self.scripts / "validate-project.py").write_text("print('Mock structural gate')\n")
        (self.scripts / "test-ios.sh").write_text(MOCK_TESTS)
        privacy = self.root / "Tests/PrivacyRegression"
        privacy.mkdir(parents=True)
        (privacy / "no-network-in-local-analysis.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
        cloud = self.root / "Tests/CloudRelease"
        cloud.mkdir()
        (cloud / "test_mock_gate.py").write_text(
            "import unittest\nclass Gate(unittest.TestCase):\n def test_stub(self): self.assertTrue(True)\n")
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        for name in ("uname", "xcrun", "xcodebuild", "swift", "codesign", "curl"):
            path = mock_bin / name
            path.write_text(MOCK_TOOL)
            path.chmod(0o755)
        self.log = self.root / "calls.jsonl"
        # Only the command search path is inherited; no signing secrets enter fixtures.
        self.environment = {"PATH": str(mock_bin) + ":" + os.environ.get("PATH", os.defpath),
                            "LC_ALL": "C", "MOCK_LOG": str(self.log)}

    def configuration(self, edition="consumer", manual=True):
        selected = EDITIONS[edition][1]
        values = {"APP_BASE_BUNDLE_ID": "com.example.privacy", "TEAM_ID": "LYDVWU62G4",
                  "APP_EDITION": edition, "APP_VERSION": "2.1", "BUILD_NUMBER": "9"}
        if edition == "url-filter":
            values.update(PIR)
        if manual:
            values.update({"SIGNING_MODE": "manual", "FIREPRIVACY_SIGNING_IDENTITY": "A" * 40})
            values.update({prefix + "_PROVISIONING_PROFILE_SPECIFIER": PROFILES[prefix + "_PROVISIONING_PROFILE_SPECIFIER"]
                           for prefix in selected})
        return values

    def common(self, values):
        command = ('source "$1"; configure_bundle_identifiers; configure_signing; '
                   'printf "%s\\n" "$APP_EDITION" "$FIREPRIVACY_SCHEME" "$FIREPRIVACY_PRODUCT" "${APPLE_SIGN_ARGS[@]}"')
        return subprocess.run(["bash", "-c", command, "fixture", str(self.scripts / "apple-common.sh")],
                              cwd=self.root, env={**self.environment, **values}, capture_output=True, text=True)

    def run_script(self, name, values, *arguments, success=True):
        self.log.write_text("")
        result = subprocess.run(["bash", str(self.scripts / name), *map(str, arguments)], cwd=self.root,
                                env={**self.environment, **values}, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def archive_fixture(self, edition):
        archive = self.root / (edition + ".xcarchive")
        archive.mkdir(exist_ok=True)
        (archive / "FirePrivacyValidation.json").write_text("{}")
        return archive

    def test_default_consumer_ignores_privileged_profile_bindings(self):
        values = self.configuration()
        values.pop("APP_EDITION")
        values.update({prefix + "_PROVISIONING_PROFILE_SPECIFIER": "invalid-unused-profile"
                       for prefix in ("URL", "MANAGED_DATA", "MANAGED_CONTROL")})
        result = self.common(values)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[:3], ["consumer", "FirePrivacy", "FirePrivacy.app"])
        self.assertFalse(any(line.startswith(prefix + "_PROVISIONING_PROFILE_SPECIFIER=")
                             for line in lines for prefix in ("URL", "MANAGED_DATA", "MANAGED_CONTROL")))

    def test_selected_manual_profiles_are_required_and_validated(self):
        for edition, (_, prefixes) in EDITIONS.items():
            for prefix in prefixes:
                variable = prefix + "_PROVISIONING_PROFILE_SPECIFIER"
                for invalid in (None, "not-a-uuid"):
                    with self.subTest(edition=edition, profile=variable, invalid=invalid):
                        values = self.configuration(edition)
                        values.pop(variable) if invalid is None else values.update({variable: invalid})
                        self.assertNotEqual(self.common(values).returncode, 0)
        values = self.configuration()
        values["FIREPRIVACY_SIGNING_IDENTITY"] = "not-a-fingerprint"
        self.assertNotEqual(self.common(values).returncode, 0)

    def test_aliases_must_be_coherent_and_legacy_app_alias_remains_supported(self):
        values = self.configuration()
        values["BUNDLE_ID"] = values.pop("APP_BASE_BUNDLE_ID")
        values["FIREPRIVACY_PROFILE_UUID"] = values.pop("APP_PROVISIONING_PROFILE_SPECIFIER")
        result = self.common(values)
        self.assertEqual(result.returncode, 0, result.stderr)
        for update in ({"APP_BASE_BUNDLE_ID": "com.example.other"},
                       {"APP_PROVISIONING_PROFILE_SPECIFIER": PROFILES["SAFARI_PROVISIONING_PROFILE_SPECIFIER"]}):
            self.assertNotEqual(self.common({**values, **update}).returncode, 0)

    def test_export_profile_maps_include_exact_selected_edition(self):
        for edition, (_, prefixes) in EDITIONS.items():
            with self.subTest(edition=edition):
                values = self.configuration(edition)
                values.update({name: "invalid-unused-profile" for name in PROFILES if name not in values})
                calls = self.run_script("export-app-store.sh", values, self.archive_fixture(edition), "export")
                export = next(call for call in calls if call["tool"] == "xcodebuild" and "-exportArchive" in call["args"])
                self.assertEqual(export["options"]["provisioningProfiles"],
                                 {"com.example.privacy" + SUFFIXES[prefix]: PROFILES[prefix + "_PROVISIONING_PROFILE_SPECIFIER"]
                                  for prefix in prefixes})
                self.assertEqual(export["options"]["signingCertificate"], "A" * 40)
                self.assertNotIn("-allowProvisioningUpdates", export["args"])

    def test_automatic_upload_retains_apple_provisioning_and_url_checks(self):
        calls = self.run_script("export-app-store.sh", self.configuration(manual=False), self.archive_fixture("consumer"), "upload")
        export = next(call for call in calls if call["tool"] == "xcodebuild" and "-exportArchive" in call["args"])
        self.assertEqual(export["options"]["destination"], "upload")
        self.assertEqual(export["options"]["signingStyle"], "automatic")
        self.assertNotIn("provisioningProfiles", export["options"])
        self.assertIn("-allowProvisioningUpdates", export["args"])
        urls = [call for call in calls if call["tool"] == "curl"]
        self.assertEqual(len(urls), 2)
        for call in urls:
            self.assertIn("--fail", call["args"])
            self.assertIn("--proto-redir", call["args"])
            self.assertEqual(call["args"][call["args"].index("--proto") + 1], "=https")

    def test_archive_preserves_ids_selects_product_and_runs_required_gates(self):
        for edition, (scheme, prefixes) in EDITIONS.items():
            with self.subTest(edition=edition):
                values = {**self.configuration(edition), "FIREPRIVACY_APP_GROUP_ID": "group.com.example.privacy"}
                calls = self.run_script("archive-ios.sh", values)
                archive = next(call for call in calls if call["tool"] == "xcodebuild" and "archive" in call["args"])
                args = archive["args"]
                self.assertEqual(args[args.index("-scheme") + 1], scheme)
                self.assertIn("APP_BASE_BUNDLE_ID=com.example.privacy", args)
                self.assertIn("FIREPRIVACY_APP_GROUP_ID=group.com.example.privacy", args)
                self.assertFalse(any(arg.startswith(("PRODUCT_BUNDLE_IDENTIFIER=", "PROVISIONING_PROFILE=", "PROVISIONING_PROFILE_SPECIFIER=")) for arg in args))
                for prefix in prefixes:
                    self.assertIn(prefix + "_PROVISIONING_PROFILE_SPECIFIER=" + PROFILES[prefix + "_PROVISIONING_PROFILE_SPECIFIER"], args)
                self.assertEqual([call["args"] for call in calls if call["tool"] == "test-ios"], [["iphone"], ["ipad"]])
                self.assertTrue(any(call["tool"] == "swift" and call["args"] == ["test"] for call in calls))
                self.assertEqual([call["args"][0] for call in calls if call["tool"] == "release-validation"], ["configuration", "stamp"])
                signature = next(call for call in calls if call["tool"] == "codesign")
                self.assertEqual(signature["args"][:3], ["--verify", "--deep", "--strict"])
                self.assertTrue(signature["args"][-1].endswith("/" + scheme + ".app"))

    def test_url_archive_binds_exact_pir_settings_only_to_url_edition(self):
        issuer = "https://issuer.example.org/privacy-pass"
        for edition in EDITIONS:
            with self.subTest(edition=edition):
                values = {**self.configuration(edition), **PIR, "FIREPRIVACY_PRIVACY_PASS_ISSUER_URL": issuer}
                calls = self.run_script("archive-ios.sh", values)
                args = next(call["args"] for call in calls if call["tool"] == "xcodebuild" and "archive" in call["args"])
                for variable in (*PIR, "FIREPRIVACY_PRIVACY_PASS_ISSUER_URL"):
                    self.assertEqual(variable + "=" + values[variable] in args, edition == "url-filter")

    def test_archive_preserves_public_json_as_single_literal_build_setting_arguments(self):
        knowledge = json.dumps({"operator-knowledge": "1" * 64}, indent=2)
        filters = json.dumps({"operator-filter": "2" * 64}, separators=(",", ":"))
        values = {**self.configuration(), "FIREPRIVACY_KB_PUBLIC_KEYS_JSON": knowledge,
                  "FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON": filters}
        calls = self.run_script("archive-ios.sh", values)
        args = next(call["args"] for call in calls if call["tool"] == "xcodebuild" and "archive" in call["args"])
        self.assertIn("FIREPRIVACY_KB_PUBLIC_KEYS_JSON=" + knowledge, args)
        self.assertIn("FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON=" + filters, args)

    def test_invalid_public_key_binding_stops_before_build_or_signing(self):
        values = {**self.configuration(), "FIREPRIVACY_KB_PUBLIC_KEYS_JSON": "not public JSON"}
        calls = self.run_script("archive-ios.sh", values, success=False)
        self.assertFalse(any(call["tool"] in ("codesign", "swift") for call in calls))
        self.assertFalse(any(call["tool"] == "xcodebuild" and "archive" in call["args"] for call in calls))

    def test_url_archive_rejects_missing_or_unsafe_pir_configuration(self):
        invalid = [("FIREPRIVACY_PIR_SERVER_URL", ""), ("FIREPRIVACY_PIR_SERVER_URL", "http://pir.example.org"),
                   ("FIREPRIVACY_PIR_SERVER_URL", "https://"), ("FIREPRIVACY_PIR_SERVER_URL", "https://user:password@pir.example.org"),
                   ("FIREPRIVACY_PRIVACY_PASS_ISSUER_URL", "http://issuer.example.org"),
                   ("FIREPRIVACY_PIR_CONFIGURATION_IDENTITY", ""), ("FIREPRIVACY_PIR_CONFIGURATION_IDENTITY", "   ")]
        for variable, value in invalid:
            with self.subTest(variable=variable, value=value):
                calls = self.run_script("archive-ios.sh", {**self.configuration("url-filter"), variable: value}, success=False)
                self.assertFalse(any(call["tool"] == "xcodebuild" and "archive" in call["args"] for call in calls))

    def test_failed_validation_or_public_url_prevents_upload(self):
        for failure in ({"MOCK_FAIL_VALIDATION": "verify"}, {"MOCK_FAIL_TOOL": "curl"}, {"MOCK_FAIL_TOOL": "codesign"}):
            with self.subTest(failure=failure):
                calls = self.run_script("export-app-store.sh", {**self.configuration(), **failure}, self.archive_fixture("consumer"), "upload", success=False)
                self.assertFalse(any(call["tool"] == "xcodebuild" and "-exportArchive" in call["args"] for call in calls))

    def test_failed_core_or_ipad_tests_prevent_archive(self):
        for failure in ({"MOCK_FAIL_TOOL": "swift"}, {"MOCK_FAIL_FAMILY": "ipad"}):
            with self.subTest(failure=failure):
                calls = self.run_script("archive-ios.sh", {**self.configuration(), **failure}, success=False)
                self.assertFalse(any(call["tool"] == "xcodebuild" and "archive" in call["args"] for call in calls))


if __name__ == "__main__":
    unittest.main()
