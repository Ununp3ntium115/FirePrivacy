// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FirePrivacy",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FirePrivacyCore", targets: ["FirePrivacyCore"])],
    dependencies: [
        // Apple platforms use the OS CryptoKit framework. Linux verifies the
        // same hashes/signatures using Apple's pinned Swift Crypto package.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")
    ],
    targets: [
        .target(
            name: "FirePrivacyCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "FirePrivacyCoreTests", dependencies: ["FirePrivacyCore"])
    ],
    swiftLanguageModes: [.v6]
)
