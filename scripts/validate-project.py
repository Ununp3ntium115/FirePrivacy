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
    check(set(targets) == {"FirePrivacy", "FirePrivacyAppTests", "FirePrivacyUITests"}, "app, storage and UI test targets must exist")
    for name, target in targets.items():
        configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
        check(len(configs) == 2, name + " must have Debug and Release configurations")
        for config in configs:
            settings = objects[config]["buildSettings"]
            check(settings["TARGETED_DEVICE_FAMILY"] == "1,2", name + " must support iPhone and iPad")
            check(settings["DEVELOPMENT_TEAM"] == "LYDVWU62G4", "unexpected default signing team")
            if name == "FirePrivacy":
                check(settings["PRODUCT_MODULE_NAME"] == "FirePrivacyApp", "XCTest import module differs")
                check("CODE_SIGN_ENTITLEMENTS" not in settings, "MVP must not request an undeclared entitlement")
        for group in target["fileSystemSynchronizedGroups"]:
            path = ROOT / objects[group]["path"]
            check(path.is_dir() and any(path.glob("*.swift")), name + " sources must exist")
    package_refs = [obj for obj in objects.values() if obj["isa"] == "XCLocalSwiftPackageReference"]
    check(len(package_refs) == 1 and package_refs[0]["relativePath"] == ".", "core must use this checkout's local Swift package")
    check((ROOT / "Package.swift").is_file(), "Package.swift missing")
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
    print("Project structure, universal targets, shared tests, manifests, document handling and opaque icon dimensions passed.")
    print("Native compilation, simulator behavior and App Store signing still require the macOS checks.")


if __name__ == "__main__":
    validate()
