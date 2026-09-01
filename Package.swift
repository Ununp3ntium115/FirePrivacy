// swift-tools-version: 6.0
// Fire Privacy — Fire Software Solutions LLC
//
// One SwiftPM package holding the Fire Privacy domain modules. The iPhone app
// target, the URL Filter control provider and the Safari content blocker live in
// the Xcode project (see Documentation/BUILDING.md) and depend on these modules.

import PackageDescription

/// Applied to every target. Strict concurrency is a hard requirement (§18.7).
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

/// Every module lives under `Packages/<Module>/` so the on-disk layout matches
/// the layout described in the specification (§22).
func sources(_ name: String) -> String { "Packages/\(name)/Sources/\(name)" }
func tests(_ name: String) -> String { "Packages/\(name)/Tests/\(name)Tests" }

let package = Package(
    name: "FirePrivacy",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ObservationCore", targets: ["ObservationCore"]),
        .library(name: "AppActivityImportKit", targets: ["AppActivityImportKit"]),
        .library(name: "KnowledgeBaseKit", targets: ["KnowledgeBaseKit"]),
        .library(name: "PrivacyProfileKit", targets: ["PrivacyProfileKit"]),
        .library(name: "FindingEngine", targets: ["FindingEngine"]),
        .library(name: "AdvisorKit", targets: ["AdvisorKit"]),
        .library(name: "ProtectionKit", targets: ["ProtectionKit"]),
        .library(name: "ConsentKit", targets: ["ConsentKit"]),
        .library(name: "ObservationStore", targets: ["ObservationStore"]),
        .library(name: "ReportKit", targets: ["ReportKit"]),
        .library(name: "TrustCenterKit", targets: ["TrustCenterKit"]),
        .library(name: "FirePrivacyUI", targets: ["FirePrivacyUI"]),
    ],
    targets: [
        .target(name: "ObservationCore", path: sources("ObservationCore"), swiftSettings: strict),
        .target(
            name: "AppActivityImportKit",
            dependencies: ["ObservationCore"],
            path: sources("AppActivityImportKit"),
            swiftSettings: strict
        ),
        .target(
            name: "KnowledgeBaseKit",
            dependencies: ["ObservationCore"],
            path: sources("KnowledgeBaseKit"),
            swiftSettings: strict
        ),
        .target(
            name: "PrivacyProfileKit",
            dependencies: ["ObservationCore"],
            path: sources("PrivacyProfileKit"),
            swiftSettings: strict
        ),
        .target(
            name: "FindingEngine",
            dependencies: ["ObservationCore", "KnowledgeBaseKit", "PrivacyProfileKit"],
            path: sources("FindingEngine"),
            swiftSettings: strict
        ),
        .target(
            name: "AdvisorKit",
            dependencies: ["ObservationCore", "FindingEngine"],
            path: sources("AdvisorKit"),
            swiftSettings: strict
        ),
        .target(
            name: "ProtectionKit",
            dependencies: ["ObservationCore"],
            path: sources("ProtectionKit"),
            swiftSettings: strict
        ),
        .target(
            name: "ConsentKit",
            dependencies: ["ObservationCore"],
            path: sources("ConsentKit"),
            swiftSettings: strict
        ),
        .target(
            name: "ObservationStore",
            dependencies: ["ObservationCore", "FindingEngine", "KnowledgeBaseKit"],
            path: sources("ObservationStore"),
            swiftSettings: strict
        ),
        .target(
            name: "ReportKit",
            dependencies: ["ObservationCore", "FindingEngine", "KnowledgeBaseKit", "ObservationStore"],
            path: sources("ReportKit"),
            swiftSettings: strict
        ),
        .target(
            name: "TrustCenterKit",
            dependencies: ["ObservationCore", "ObservationStore", "ProtectionKit", "ConsentKit", "ReportKit"],
            path: sources("TrustCenterKit"),
            swiftSettings: strict
        ),
        .target(
            name: "FirePrivacyUI",
            dependencies: [
                "ObservationCore", "AppActivityImportKit", "KnowledgeBaseKit", "PrivacyProfileKit",
                "FindingEngine", "AdvisorKit", "ProtectionKit", "ConsentKit", "ObservationStore",
                "ReportKit", "TrustCenterKit",
            ],
            path: sources("FirePrivacyUI"),
            swiftSettings: strict
        ),
        .target(
            name: "TestSupport",
            dependencies: ["ObservationCore", "KnowledgeBaseKit", "FindingEngine"],
            path: sources("TestSupport"),
            swiftSettings: strict
        ),

        .testTarget(
            name: "ObservationCoreTests",
            dependencies: ["ObservationCore", "TestSupport"],
            path: tests("ObservationCore"),
            swiftSettings: strict
        ),
        .testTarget(
            name: "AppActivityImportKitTests",
            dependencies: ["AppActivityImportKit", "TestSupport"],
            path: tests("AppActivityImportKit"),
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnowledgeBaseKitTests",
            dependencies: ["KnowledgeBaseKit", "TestSupport"],
            path: tests("KnowledgeBaseKit"),
            swiftSettings: strict
        ),
        .testTarget(
            name: "FindingEngineTests",
            dependencies: ["FindingEngine", "TestSupport"],
            path: tests("FindingEngine"),
            swiftSettings: strict
        ),
        .testTarget(
            name: "AdvisorKitTests",
            dependencies: ["AdvisorKit", "TestSupport"],
            path: tests("AdvisorKit"),
            swiftSettings: strict
        ),
        .testTarget(
            name: "ProtectionKitTests",
            dependencies: ["ProtectionKit"],
            path: tests("ProtectionKit"),
            swiftSettings: strict
        ),
        .testTarget(
            name: "ObservationStoreTests",
            dependencies: ["ObservationStore", "TestSupport"],
            path: tests("ObservationStore"),
            swiftSettings: strict
        ),
        .testTarget(
            name: "ReportKitTests",
            dependencies: ["ReportKit", "TestSupport"],
            path: tests("ReportKit"),
            swiftSettings: strict
        ),
    ]
)
