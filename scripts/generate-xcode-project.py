#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project. Requires Python 3, not XcodeGen.

Xcode 16+ synchronized groups discover app/test Swift sources and resources.
Only this script, the pbxproj and the shared scheme are generator-owned.
"""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]


def identifier(name):
    return hashlib.sha256(("FirePrivacy:" + name).encode()).hexdigest()[:24].upper()


names = ["project", "main_group", "products", "app_group", "test_group", "info_exception",
         "app_target", "test_target", "app_product", "test_product", "package",
         "core_product", "core_build", "app_sources", "app_resources", "app_frameworks",
         "test_sources", "test_resources", "test_frameworks", "test_dependency", "test_proxy",
         "project_configs", "app_configs", "test_configs", "project_debug", "project_release",
         "app_debug", "app_release", "test_debug", "test_release", "ui_group", "ui_target", "ui_product",
         "ui_sources", "ui_resources", "ui_frameworks", "ui_dependency", "ui_proxy", "ui_configs", "ui_debug", "ui_release", "test_core_build"]
ids = {name: identifier(name) for name in names}
objects = []


def object_(name, isa, body):
    objects.append(f"\t\t{ids[name]} /* {name} */ = {{\n\t\t\tisa = {isa};\n{body}\n\t\t}};")


def setting_block(values):
    return "\n".join(f"\t\t\t\t{key} = {value};" for key, value in values.items())


object_("core_build", "PBXBuildFile", f"\t\t\tproductRef = {ids['core_product']};")
object_("test_core_build", "PBXBuildFile", f"\t\t\tproductRef = {ids['core_product']};")
object_("test_proxy", "PBXContainerItemProxy", f"\t\t\tcontainerPortal = {ids['project']};\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {ids['app_target']};\n\t\t\tremoteInfo = FirePrivacy;")
object_("app_product", "PBXFileReference", "\t\t\texplicitFileType = wrapper.application;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = FirePrivacy.app;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;")
object_("test_product", "PBXFileReference", "\t\t\texplicitFileType = wrapper.cfbundle;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = FirePrivacyAppTests.xctest;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;")
object_("ui_product", "PBXFileReference", "\t\t\texplicitFileType = wrapper.cfbundle;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = FirePrivacyUITests.xctest;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;")
object_("ui_proxy", "PBXContainerItemProxy", f"\t\t\tcontainerPortal = {ids['project']};\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {ids['app_target']};\n\t\t\tremoteInfo = FirePrivacy;")
object_("info_exception", "PBXFileSystemSynchronizedBuildFileExceptionSet", f"\t\t\tmembershipExceptions = (Info.plist,);\n\t\t\ttarget = {ids['app_target']};")
object_("app_group", "PBXFileSystemSynchronizedRootGroup", f"\t\t\texceptions = ({ids['info_exception']},);\n\t\t\tpath = Apps/FirePrivacyApp;\n\t\t\tsourceTree = \"<group>\";")
object_("test_group", "PBXFileSystemSynchronizedRootGroup", "\t\t\tpath = Tests/FirePrivacyAppTests;\n\t\t\tsourceTree = \"<group>\";")
object_("ui_group", "PBXFileSystemSynchronizedRootGroup", "\t\t\tpath = Tests/FirePrivacyUITests;\n\t\t\tsourceTree = \"<group>\";")
object_("main_group", "PBXGroup", f"\t\t\tchildren = ({ids['app_group']}, {ids['test_group']}, {ids['ui_group']}, {ids['products']},);\n\t\t\tsourceTree = \"<group>\";")
object_("products", "PBXGroup", f"\t\t\tchildren = ({ids['app_product']}, {ids['test_product']}, {ids['ui_product']},);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";")
for name, isa, files in [
    ("app_sources", "PBXSourcesBuildPhase", []), ("app_resources", "PBXResourcesBuildPhase", []),
    ("app_frameworks", "PBXFrameworksBuildPhase", [ids["core_build"]]),
    ("test_sources", "PBXSourcesBuildPhase", []), ("test_resources", "PBXResourcesBuildPhase", []),
    ("test_frameworks", "PBXFrameworksBuildPhase", [ids['test_core_build']]),
    ("ui_sources", "PBXSourcesBuildPhase", []), ("ui_resources", "PBXResourcesBuildPhase", []),
    ("ui_frameworks", "PBXFrameworksBuildPhase", []),
]:
    object_(name, isa, "\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (" + ", ".join(files) + ("," if files else "") + ");\n\t\t\trunOnlyForDeploymentPostprocessing = 0;")
object_("app_target", "PBXNativeTarget", f"""\t\t\tbuildConfigurationList = {ids['app_configs']};
\t\t\tbuildPhases = ({ids['app_sources']}, {ids['app_frameworks']}, {ids['app_resources']},);
\t\t\tbuildRules = ();
\t\t\tdependencies = ();
\t\t\tfileSystemSynchronizedGroups = ({ids['app_group']},);
\t\t\tname = FirePrivacy;
\t\t\tpackageProductDependencies = ({ids['core_product']},);
\t\t\tproductName = FirePrivacy;
\t\t\tproductReference = {ids['app_product']};
\t\t\tproductType = "com.apple.product-type.application";""")
object_("test_target", "PBXNativeTarget", f"""\t\t\tbuildConfigurationList = {ids['test_configs']};
\t\t\tbuildPhases = ({ids['test_sources']}, {ids['test_frameworks']}, {ids['test_resources']},);
\t\t\tbuildRules = ();
\t\t\tdependencies = ({ids['test_dependency']},);
\t\t\tfileSystemSynchronizedGroups = ({ids['test_group']},);
\t\t\tname = FirePrivacyAppTests;
\t\t\tpackageProductDependencies = ({ids['core_product']},);
\t\t\tproductName = FirePrivacyAppTests;
\t\t\tproductReference = {ids['test_product']};
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";""")
object_("ui_target", "PBXNativeTarget", f"""\t\t\tbuildConfigurationList = {ids['ui_configs']};
\t\t\tbuildPhases = ({ids['ui_sources']}, {ids['ui_frameworks']}, {ids['ui_resources']},);
\t\t\tbuildRules = ();
\t\t\tdependencies = ({ids['ui_dependency']},);
\t\t\tfileSystemSynchronizedGroups = ({ids['ui_group']},);
\t\t\tname = FirePrivacyUITests;
\t\t\tpackageProductDependencies = ();
\t\t\tproductName = FirePrivacyUITests;
\t\t\tproductReference = {ids['ui_product']};
\t\t\tproductType = "com.apple.product-type.bundle.ui-testing";""")
object_("project", "PBXProject", f"""\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastUpgradeCheck = 2600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{ids['app_target']} = {{ CreatedOnToolsVersion = 26.0; ProvisioningStyle = Automatic; }};
\t\t\t\t\t{ids['test_target']} = {{ CreatedOnToolsVersion = 26.0; TestTargetID = {ids['app_target']}; }};
\t\t\t\t\t{ids['ui_target']} = {{ CreatedOnToolsVersion = 26.0; TestTargetID = {ids['app_target']}; }};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {ids['project_configs']};
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (en, Base,);
\t\t\tmainGroup = {ids['main_group']};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpackageReferences = ({ids['package']},);
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {ids['products']};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = ({ids['app_target']}, {ids['test_target']}, {ids['ui_target']},);""")
object_("test_dependency", "PBXTargetDependency", f"\t\t\ttarget = {ids['app_target']};\n\t\t\ttargetProxy = {ids['test_proxy']};")
object_("ui_dependency", "PBXTargetDependency", f"\t\t\ttarget = {ids['app_target']};\n\t\t\ttargetProxy = {ids['ui_proxy']};")
object_("package", "XCLocalSwiftPackageReference", "\t\t\trelativePath = .;")
object_("core_product", "XCSwiftPackageProductDependency", f"\t\t\tpackage = {ids['package']};\n\t\t\tproductName = FirePrivacyCore;")
common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES", "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES", "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES", "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES", "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES", "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "COPY_PHASE_STRIP": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17", "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES", "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE", "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "SDKROOT": "iphoneos", "SWIFT_STRICT_CONCURRENCY": "complete", "SWIFT_VERSION": "6.0",
}
app = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1", "DEVELOPMENT_TEAM": "LYDVWU62G4",
    "ENABLE_PREVIEWS": "YES", "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "Apps/FirePrivacyApp/Info.plist",
    "FIREPRIVACY_PRIVACY_URL": '\"https://github.com/Ununp3ntium115/FirePrivacy/blob/gh-pages/privacy-policy.md\"',
    "FIREPRIVACY_SUPPORT_URL": '\"https://github.com/Ununp3ntium115/FirePrivacy/issues\"',
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks",)',
    "MARKETING_VERSION": "1.0", "PRODUCT_BUNDLE_IDENTIFIER": "com.firesoftwaresolutions.FirePrivacy",
    "PRODUCT_MODULE_NAME": "FirePrivacyApp", "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"', "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "TARGETED_DEVICE_FAMILY": '"1,2"',
}
test = {
    "BUNDLE_LOADER": '"$(TEST_HOST)"', "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "LYDVWU62G4",
    "GENERATE_INFOPLIST_FILE": "YES", "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks",)',
    "PRODUCT_BUNDLE_IDENTIFIER": "com.firesoftwaresolutions.FirePrivacy.tests", "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"', "TARGETED_DEVICE_FAMILY": '"1,2"',
    "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/FirePrivacy.app/FirePrivacy"',
}
ui = {
    "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "LYDVWU62G4", "GENERATE_INFOPLIST_FILE": "YES",
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks",)',
    "PRODUCT_BUNDLE_IDENTIFIER": "com.firesoftwaresolutions.FirePrivacy.uitests", "PRODUCT_NAME": '\"$(TARGET_NAME)\"',
    "SUPPORTED_PLATFORMS": '\"iphoneos iphonesimulator\"', "TARGETED_DEVICE_FAMILY": '\"1,2\"', "TEST_TARGET_NAME": "FirePrivacy",
}
for scope, base in [("project", common), ("app", app), ("test", test), ("ui", ui)]:
    for variant in ["debug", "release"]:
        values = dict(base)
        if scope == "project":
            values.update({"DEBUG_INFORMATION_FORMAT": "dwarf" if variant == "debug" else '"dwarf-with-dsym"',
                           "ENABLE_NS_ASSERTIONS": "YES" if variant == "debug" else "NO",
                           "SWIFT_COMPILATION_MODE": "singlefile" if variant == "debug" else "wholemodule",
                           "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"' if variant == "debug" else '"-O"'})
            if variant == "debug":
                values.update({"ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
                               "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"'})
            else:
                values["VALIDATE_PRODUCT"] = "YES"
        object_(scope + "_" + variant, "XCBuildConfiguration", "\t\t\tbuildSettings = {\n" + setting_block(values) + f"\n\t\t\t}};\n\t\t\tname = {variant.title()};")
    object_(scope + "_configs", "XCConfigurationList", f"\t\t\tbuildConfigurations = ({ids[scope + '_debug']}, {ids[scope + '_release']},);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;")
project = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 77;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {ids['project']};\n}}\n"
path = ROOT / "FirePrivacy.xcodeproj"
path.mkdir(exist_ok=True)
(path / "project.pbxproj").write_text(project)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['app_target']}" BuildableName="FirePrivacy.app" BlueprintName="FirePrivacy" ReferencedContainer="container:FirePrivacy.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['test_target']}" BuildableName="FirePrivacyAppTests.xctest" BlueprintName="FirePrivacyAppTests" ReferencedContainer="container:FirePrivacy.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['ui_target']}" BuildableName="FirePrivacyUITests.xctest" BlueprintName="FirePrivacyUITests" ReferencedContainer="container:FirePrivacy.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables>
      <TestableReference skipped="NO" parallelizable="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['test_target']}" BuildableName="FirePrivacyAppTests.xctest" BlueprintName="FirePrivacyAppTests" ReferencedContainer="container:FirePrivacy.xcodeproj"/>
      </TestableReference>
      <TestableReference skipped="NO" parallelizable="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['ui_target']}" BuildableName="FirePrivacyUITests.xctest" BlueprintName="FirePrivacyUITests" ReferencedContainer="container:FirePrivacy.xcodeproj"/>
      </TestableReference>
    </Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="NO">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['app_target']}" BuildableName="FirePrivacy.app" BlueprintName="FirePrivacy" ReferencedContainer="container:FirePrivacy.xcodeproj"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['app_target']}" BuildableName="FirePrivacy.app" BlueprintName="FirePrivacy" ReferencedContainer="container:FirePrivacy.xcodeproj"/>
    </BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
scheme_path = path / "xcshareddata" / "xcschemes"
scheme_path.mkdir(parents=True, exist_ok=True)
(scheme_path / "FirePrivacy.xcscheme").write_text(scheme)
print("Generated FirePrivacy.xcodeproj and shared FirePrivacy scheme.")
