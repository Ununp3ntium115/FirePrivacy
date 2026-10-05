#!/usr/bin/env python3
"""Portable structural validation. This is not an Xcode compile or store approval."""
import json
from pathlib import Path
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class OpenStepParser:
    """Parse the ASCII plist subset used by our pbxproj, without dependencies."""
    def __init__(self, text):
        pattern = r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"]+'
        self.tokens = []
        cursor = 0
        for match in re.finditer(pattern, text, re.DOTALL):
            if text[cursor:match.start()].strip():
                raise ValueError("Invalid project syntax near " + text[cursor:match.start()])
            token = match[0]
            cursor = match.end()
            if not token.startswith(("//", "/*")):
                self.tokens.append(token)
        if text[cursor:].strip():
            raise ValueError("Invalid trailing project syntax")
        self.position = 0

    def take(self, expected=None):
        if self.position >= len(self.tokens):
            raise ValueError("Unexpected end of project")
        token = self.tokens[self.position]
        self.position += 1
        if expected is not None and token != expected:
            raise ValueError(f"Expected {expected}, found {token}")
        return token

    def value(self):
        token = self.take()
        if token == "{":
            result = {}
            while self.tokens[self.position] != "}":
                key = self.take()
                key = json.loads(key) if key.startswith('"') else key
                if key in result:
                    raise ValueError("Duplicate project dictionary key: " + key)
                self.take("=")
                result[key] = self.value()
                self.take(";")
            self.take("}")
            return result
        if token == "(":
            result = []
            while self.tokens[self.position] != ")":
                result.append(self.value())
                if self.tokens[self.position] != ")":
                    self.take(",")
            self.take(")")
            return result
        if token in ("}", ")", "=", ",", ";"):
            raise ValueError("Unexpected project delimiter: " + token)
        return json.loads(token) if token.startswith('"') else token

    def parse(self):
        result = self.value()
        if self.position != len(self.tokens):
            raise ValueError("Trailing project tokens")
        return result


def check(condition, message):
    if not condition:
        raise SystemExit("Project check failed: " + message)


def validate():
    project_path = ROOT / "FirePrivacy.xcodeproj/project.pbxproj"
    source = project_path.read_text()
    project = OpenStepParser(source).parse()
    objects = project["objects"]
    check(project["objectVersion"] == "77", "synchronized groups need the current project format")
    check(objects[project["rootObject"]]["isa"] == "PBXProject", "project root is invalid")
    for reference in re.findall(r"\b[A-F0-9]{24}\b", source):
        check(reference in objects, "unknown project reference " + reference)
    targets = {value["name"]: value for value in objects.values() if value["isa"] == "PBXNativeTarget"}
    extension_names = {"SafariContentBlocker", "URLFilterControl", "ManagedFilterData", "ManagedFilterControl"}
    app_editions = {"FirePrivacy": ("consumer", {"SafariContentBlocker"}, "Info.plist", "FirePrivacy.entitlements", {"dns-settings"}),
                    "FirePrivacyURL": ("url-filter", {"SafariContentBlocker", "URLFilterControl"}, "URLInfo.plist", "FirePrivacyURL.entitlements", {"dns-settings", "url-filter-provider"}),
                    "FirePrivacyManaged": ("managed", {"SafariContentBlocker", "ManagedFilterData", "ManagedFilterControl"}, "ManagedInfo.plist", "FirePrivacyManaged.entitlements", {"dns-settings", "content-filter-provider"})}
    check(set(targets) == set(app_editions) | {"FirePrivacyAppTests", "FirePrivacyUITests"} | extension_names,
          "app, storage/UI tests and real protection extension targets must exist")
    for name, target in targets.items():
        configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
        check(len(configs) == 2, name + " must have Debug and Release configurations")
        for config in configs:
            settings = objects[config]["buildSettings"]
            check(settings["TARGETED_DEVICE_FAMILY"] == "1,2", name + " must support iPhone and iPad")
            check(settings["DEVELOPMENT_TEAM"] == "LYDVWU62G4", "unexpected default signing team")
            if name in app_editions:
                check(settings["PRODUCT_MODULE_NAME"] == "FirePrivacyApp", "XCTest import module differs")
                check(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "$(APP_BASE_BUNDLE_ID)", "base bundle must remain configurable")
                check(settings["CODE_SIGN_ENTITLEMENTS"] == "Apps/FirePrivacyApp/" + app_editions[name][3], "edition protection entitlement file differs")
                check(settings["INFOPLIST_FILE"] == "Apps/FirePrivacyApp/" + app_editions[name][2], "edition Info file differs")
            elif name in extension_names:
                check(target["productType"] == "com.apple.product-type.app-extension", "protection extension product type differs")
                check(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "$(APP_BASE_BUNDLE_ID)." + name, "extension identifiers must be distinct and configurable")
                check(settings["APPLICATION_EXTENSION_API_ONLY"] == "YES" and settings["SKIP_INSTALL"] == "YES", "extension-only API/archive settings missing")
                check(settings["IPHONEOS_DEPLOYMENT_TARGET"] == ("26.0" if name == "URLFilterControl" else "17.0"), "unexpected extension deployment target")
                check(settings["CODE_SIGN_ENTITLEMENTS"] == f"Extensions/{name}/FirePrivacy.entitlements", "extension entitlement file missing")
        for group in target["fileSystemSynchronizedGroups"]:
            path = ROOT / objects[group]["path"]
            check(path.is_dir() and any(path.glob("*.swift")), name + " sources must exist")
    package_refs = [obj for obj in objects.values() if obj["isa"] == "XCLocalSwiftPackageReference"]
    check(len(package_refs) == 1 and package_refs[0]["relativePath"] == ".", "core must use this checkout's local Swift package")
    check((ROOT / "Package.swift").is_file(), "Package.swift missing")
    target_ids = {obj["name"]: key for key, obj in objects.items() if obj["isa"] == "PBXNativeTarget"}
    for app_name, (edition, included, info_file, entitlement_file, capabilities) in app_editions.items():
        app_target = targets[app_name]
        dependencies = {objects[item]["target"] for item in app_target["dependencies"]}
        check(dependencies == {target_ids[name] for name in included}, "edition must build exactly its approved extension subset")
        copy_phases = [objects[key] for key in app_target["buildPhases"] if objects[key]["isa"] == "PBXCopyFilesBuildPhase"]
        embedded = {}
        for phase in copy_phases:
            for key in phase["files"]:
                product = objects[objects[key]["fileRef"]]["path"]
                embedded[product] = (phase["dstSubfolderSpec"], phase["dstPath"])
        check(set(embedded) == {name + ".appex" for name in included}, "consumer must never embed a dormant privileged provider")
        for name in included:
            check(embedded[name + ".appex"] == (("16", "$(EXTENSIONS_FOLDER_PATH)") if name == "URLFilterControl" else ("13", "")), "incorrect edition-specific extension embedding")
        with (ROOT / "Apps/FirePrivacyApp" / info_file).open("rb") as file:
            edition_info = plistlib.load(file)
        check(edition_info["FirePrivacyDistributionEdition"] == edition, "runtime edition guard differs")
        with (ROOT / "Apps/FirePrivacyApp" / entitlement_file).open("rb") as file:
            edition_entitlements = plistlib.load(file)
        check(set(edition_entitlements["com.apple.developer.networking.networkextension"]) == capabilities, "edition requests unapproved dormant capabilities")
        edition_scheme = ET.parse(ROOT / f"FirePrivacy.xcodeproj/xcshareddata/xcschemes/{app_name}.xcscheme")
        build_entries = edition_scheme.findall(".//BuildActionEntry/BuildableReference")
        check(any(entry.attrib["BlueprintIdentifier"] == target_ids[app_name] for entry in build_entries), "edition scheme targets wrong app")
    scheme = ET.parse(ROOT / "FirePrivacy.xcodeproj/xcshareddata/xcschemes/FirePrivacy.xcscheme")
    testables = scheme.findall(".//TestableReference")
    check(len(testables) == 2 and all(test.attrib["skipped"] == "NO" for test in testables), "scheme must run storage and UI tests")
    for ref in scheme.findall(".//BuildableReference"):
        check(ref.attrib["BlueprintIdentifier"] in objects, "scheme target reference is unknown")
    with (ROOT / "Apps/FirePrivacyApp/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    check(not any(key.startswith("NS") and key.endswith("UsageDescription") for key in info), "local report importer must not ask for system permission")
    check("NSAppTransportSecurity" not in info, "TLS policy must not be relaxed")
    check(info["ITSAppUsesNonExemptEncryption"] is False, "export classification setting changed; revisit release documentation")
    check(len(info["UISupportedInterfaceOrientations~ipad"]) == 4, "iPad must support all four orientations")
    check(info["FirePrivacyAppGroup"] == "$(FIREPRIVACY_APP_GROUP_ID)", "app shared rule group must remain configurable")
    expected_points = {"SafariContentBlocker": "com.apple.Safari.content-blocker",
                       "ManagedFilterData": "com.apple.networkextension.filter-data",
                       "ManagedFilterControl": "com.apple.networkextension.filter-control"}
    expected_network = {"FirePrivacy": {"dns-settings"},
                        "SafariContentBlocker": set(), "URLFilterControl": {"url-filter-provider"},
                        "ManagedFilterData": {"content-filter-provider"}, "ManagedFilterControl": {"content-filter-provider"}}
    for name, capabilities in expected_network.items():
        directory = ROOT / ("Apps/FirePrivacyApp" if name == "FirePrivacy" else f"Extensions/{name}")
        with (directory / "FirePrivacy.entitlements").open("rb") as file:
            entitlements = plistlib.load(file)
        check(entitlements["com.apple.security.application-groups"] == ["$(FIREPRIVACY_APP_GROUP_ID)"], "App Group must share rules only and remain configurable")
        check(set(entitlements.get("com.apple.developer.networking.networkextension", [])) == capabilities,
              name + " requests an unexpected or obsolete Network Extension entitlement")
        check(set(entitlements) <= {"com.apple.security.application-groups", "com.apple.developer.networking.networkextension"}, "undeclared protection entitlement")
        if name != "FirePrivacy":
            with (directory / "Info.plist").open("rb") as file:
                extension_info = plistlib.load(file)
            check(extension_info["FirePrivacyAppGroup"] == info["FirePrivacyAppGroup"], "extension/App Group configuration differs")
            check(extension_info["FirePrivacyFilterTrustKeys"] == info["FirePrivacyFilterTrustKeys"], "all processes must use the same reviewed filter trust roots")
            if name == "URLFilterControl":
                check(extension_info["EXAppExtensionAttributes"]["EXExtensionPointIdentifier"] == "com.apple.networkextension.url-filter-control", "URL filter must use the verified ExtensionKit point")
                check("NSExtension" not in extension_info, "URL ExtensionKit provider must not use a legacy principal class")
            else:
                check(extension_info["NSExtension"]["NSExtensionPointIdentifier"] == expected_points[name], "incorrect native extension point")
            with (directory / "PrivacyInfo.xcprivacy").open("rb") as file:
                extension_privacy = plistlib.load(file)
            check(extension_privacy["NSPrivacyTracking"] is False and not extension_privacy["NSPrivacyCollectedDataTypes"], "protection providers must not collect or track browsing/flows")
            check("NSAppTransportSecurity" not in extension_info, "extension must not bypass TLS")
    types = info["UTImportedTypeDeclarations"]
    check(any("ndjson" in item["UTTypeTagSpecification"].get("public.filename-extension", []) for item in types), "NDJSON document type missing")
    with (ROOT / "Apps/FirePrivacyApp/PrivacyInfo.xcprivacy").open("rb") as file:
        privacy = plistlib.load(file)
    check(privacy["NSPrivacyTracking"] is False, "MVP must not track")
    check(privacy["NSPrivacyTrackingDomains"] == [], "MVP must not have tracking domains")
    check(privacy["NSPrivacyCollectedDataTypes"] == [], "MVP must not collect data off-device")
    app_source = "\n".join(path.read_text() for path in (ROOT / "Apps/FirePrivacyApp").glob("*.swift"))
    check(".onOpenURL" in app_source, "registered report documents need a supported open handler")
    accessed = privacy["NSPrivacyAccessedAPITypes"]
    if re.search(r"\bUserDefaults\b|@AppStorage", app_source):
        check(any(item["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryUserDefaults" for item in accessed), "declare the actual app-owned UserDefaults usage")
    if re.search(r"\b(?:stat|fstat|fstatat|lstat|getattrlist|fgetattrlist|getattrlistbulk)\s*\(|\.contentModificationDateKey|\.creationDateKey", app_source):
        check(any(item["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryFileTimestamp" for item in accessed), "declare the actual file metadata required-reason API usage")
    icons = ROOT / "Apps/FirePrivacyApp/Assets.xcassets/AppIcon.appiconset"
    images = json.loads((icons / "Contents.json").read_text())["images"]
    check(any(image["idiom"] == "ios-marketing" or (image["idiom"] == "universal" and image.get("platform") == "ios" and image.get("size") == "1024x1024") for image in images), "App Store icon missing")
    for image in images:
        png = (icons / image["filename"]).read_bytes()
        check(png[:8] == b"\x89PNG\r\n\x1a\n", "invalid app icon PNG")
        width, height, depth, color, _, _, _ = struct.unpack(">IIBBBBB", png[16:29])
        size = int(float(image["size"].split("x")[0]) * int(image.get("scale", "1x").removesuffix("x")))
        check((width, height) == (size, size), "incorrect icon dimensions")
        check(color == 2 and depth == 8, "icons must be opaque 8-bit RGB")
    print("Project structure, universal targets, native protection extensions, exact capabilities, shared tests, manifests and opaque icon dimensions passed.")
    print("Native compilation, simulator behavior and App Store signing still require the macOS checks.")


if __name__ == "__main__":
    validate()
