// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FirePrivacy",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FirePrivacyCore", targets: ["FirePrivacyCore"])],
    targets: [
        .target(name: "FirePrivacyCore"),
        .testTarget(name: "FirePrivacyCoreTests", dependencies: ["FirePrivacyCore"])
    ],
    swiftLanguageModes: [.v6]
)
