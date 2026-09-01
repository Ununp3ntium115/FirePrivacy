import XCTest
@testable import ProtectionKit
import ObservationCore

final class BloomFilterTests: XCTestCase {
    private func makeFilter(entries: [String], bitCount: Int = 4096, hashCount: Int = 7) -> BloomFilter? {
        var bits = [UInt8](repeating: 0, count: bitCount / 8)
        guard let empty = BloomFilter(bits: bits, bitCount: bitCount, hashCount: hashCount) else { return nil }
        for entry in entries {
            for index in empty.indices(for: entry) {
                bits[index >> 3] |= UInt8(1) << UInt8(index & 7)
            }
        }
        return BloomFilter(bits: bits, bitCount: bitCount, hashCount: hashCount)
    }

    func testMembersAreAlwaysFound() throws {
        let entries = (0..<200).map { "tracker\($0).example" }
        let filter = try XCTUnwrap(makeFilter(entries: entries))
        for entry in entries {
            XCTAssertTrue(filter.mayContain(entry), "\(entry) must never be missed")
        }
    }

    func testNonMembersAreMostlyRejected() throws {
        let filter = try XCTUnwrap(makeFilter(entries: (0..<200).map { "tracker\($0).example" }))
        let misses = (0..<500).filter { !filter.mayContain("clean\($0).example") }.count
        XCTAssertGreaterThan(misses, 450, "false-positive rate is far above the released target")
    }

    func testRejectsInconsistentParameters() {
        XCTAssertNil(BloomFilter(bits: [0, 0], bitCount: 4096, hashCount: 7))
        XCTAssertNil(BloomFilter(bits: [0], bitCount: 0, hashCount: 7))
        XCTAssertNil(BloomFilter(bits: [0], bitCount: 8, hashCount: 0))
    }
}

final class FilterDatasetVerifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func manifest(payload: [UInt8], expires: TimeInterval = 86_400, version: String = "filter-1") -> FilterDatasetManifest {
        FilterDatasetManifest(
            datasetVersion: version,
            profile: "standard",
            generatedAt: now,
            expiresAt: now.addingTimeInterval(expires),
            bitCount: payload.count * 8,
            hashCount: 7,
            entryCount: 10,
            falsePositiveRate: 0.001,
            payloadDigest: FireHasher.hash(payload),
            signingKeyID: "key-1",
            signature: Data([9, 9, 9]).base64EncodedString(),
            rollbackVersion: nil
        )
    }

    func testRejectsExpiredDataset() {
        let payload = [UInt8](repeating: 0, count: 64)
        let verifier = FilterDatasetVerifier(publicKeysByID: ["key-1": [UInt8](repeating: 1, count: 32)])
        XCTAssertThrowsError(try verifier.verify(manifest: manifest(payload: payload, expires: -1), payload: payload, now: now))
    }

    func testRejectsDigestMismatch() {
        let payload = [UInt8](repeating: 0, count: 64)
        let verifier = FilterDatasetVerifier(publicKeysByID: ["key-1": [UInt8](repeating: 1, count: 32)])
        XCTAssertThrowsError(try verifier.verify(manifest: manifest(payload: payload), payload: [1, 2, 3, 4], now: now))
    }

    func testRejectsRevokedDataset() {
        let payload = [UInt8](repeating: 0, count: 64)
        let verifier = FilterDatasetVerifier(publicKeysByID: [:], revokedVersions: ["filter-1"])
        XCTAssertThrowsError(try verifier.verify(manifest: manifest(payload: payload), payload: payload, now: now)) { error in
            XCTAssertEqual(error as? FilterDatasetVerifier.Failure, .revoked("filter-1"))
        }
    }

    func testRejectsUnknownSigningKey() {
        let payload = [UInt8](repeating: 0, count: 64)
        let verifier = FilterDatasetVerifier(publicKeysByID: [:])
        XCTAssertThrowsError(try verifier.verify(manifest: manifest(payload: payload), payload: payload, now: now)) { error in
            XCTAssertEqual(error as? FilterDatasetVerifier.Failure, .unknownSigningKey("key-1"))
        }
    }
}

/// A bridge whose behaviour the test controls, so the controller's state
/// machine can be driven through every failure path.
private actor StubBridge: URLFilterSystemBridge {
    var availabilityResult: URLFilterAvailability
    var state: URLFilterState
    var saveShouldFail: Bool

    init(availability: URLFilterAvailability, state: URLFilterState, saveShouldFail: Bool = false) {
        self.availabilityResult = availability
        self.state = state
        self.saveShouldFail = saveShouldFail
    }

    func systemAvailability() async -> URLFilterAvailability { availabilityResult }
    func loadState() async -> URLFilterState { state }

    func save(configuration: URLFilterConfiguration) async throws {
        if saveShouldFail { throw URLFilterError.saveFailed("stub") }
        state = .active
    }

    func removeConfiguration() async throws {
        state = .disabled
    }
}

final class URLFilterControllerTests: XCTestCase {
    private func makeController(bridge: any URLFilterSystemBridge) -> URLFilterController {
        URLFilterController(
            bridge: bridge,
            makeConfiguration: { profile in
                URLFilterConfiguration(
                    profile: profile,
                    pirServerURL: URL(fileURLWithPath: "/pir"),
                    privacyPassIssuerURL: URL(fileURLWithPath: "/issuer"),
                    controlProviderBundleIdentifier: "com.example.provider"
                )
            }
        )
    }

    func testEnablingReachesActive() async throws {
        let controller = makeController(bridge: StubBridge(availability: .available, state: .available))
        try await controller.enable(profile: .standard)
        let state = await controller.currentState()
        XCTAssertEqual(state, .active)
        XCTAssertTrue(state.isProtecting)
    }

    /// The single most important property of this type.
    func testAFailedSaveNeverClaimsProtection() async {
        let controller = makeController(bridge: StubBridge(availability: .available, state: .available, saveShouldFail: true))
        do {
            try await controller.enable(profile: .standard)
            XCTFail("expected the save to fail")
        } catch {
            let snapshot = await controller.snapshot(profile: .standard)
            XCTAssertFalse(snapshot.urlFilterState.isProtecting)
            XCTAssertFalse(snapshot.isAnyProtectionActive)
        }
    }

    func testEnablingIsRefusedWhenUnavailable() async {
        let controller = makeController(bridge: StubBridge(availability: .entitlementMissing, state: .unsupported))
        do {
            try await controller.enable(profile: .standard)
            XCTFail("expected refusal")
        } catch {
            let state = await controller.currentState()
            XCTAssertFalse(state.isProtecting)
        }
    }

    func testCustomProfileIsNotSelectable() async {
        let controller = makeController(bridge: StubBridge(availability: .available, state: .available))
        do {
            try await controller.enable(profile: .custom)
            XCTFail("custom lists are not available yet")
        } catch {
            XCTAssertEqual(error as? URLFilterError, .profileNotSelectable)
        }
    }

    func testDisablingReturnsToDisabled() async throws {
        let controller = makeController(bridge: StubBridge(availability: .available, state: .active))
        try await controller.disable()
        let snapshot = await controller.snapshot(profile: nil)
        XCTAssertEqual(snapshot.urlFilterState, .disabled)
    }
}

final class DisclosureTests: XCTestCase {
    func testStandardDisclosureStatesTheLimits() {
        let disclosure = URLFilterDisclosure.standard(profile: .standard, datasetVersion: "filter-1")
        XCTAssertFalse(disclosure.notCovered.isEmpty)
        XCTAssertTrue(disclosure.privacyStatements.contains { $0.contains("does not receive the addresses") })
        XCTAssertTrue(disclosure.privacyStatements.contains { $0.contains("allowed rather than blocked") })
        XCTAssertFalse(disclosure.howToTurnOff.isEmpty)
    }

    func testStrictProfileCarriesABreakageWarning() {
        XCTAssertNotNil(URLFilterProfile.strict.breakageWarning)
        XCTAssertNil(URLFilterProfile.standard.breakageWarning)
    }

    func testConsumerConfigurationFailsOpenByDefault() {
        let configuration = URLFilterConfiguration(
            profile: .standard,
            pirServerURL: URL(fileURLWithPath: "/pir"),
            privacyPassIssuerURL: URL(fileURLWithPath: "/issuer"),
            controlProviderBundleIdentifier: "com.example.provider"
        )
        XCTAssertFalse(configuration.shouldFailClosed)
        XCTAssertFalse(configuration.blockedURLReportingEnabled)
    }

    func testEveryFilterStateExplainsItself() {
        for state in [
            URLFilterState.unsupported, .available, .enabling, .active, .updatePending,
            .staleDataset, .degradedFailOpen, .disabled, .configurationRemoved,
        ] {
            XCTAssertFalse(state.displayName.isEmpty)
            XCTAssertFalse(state.explanation.isEmpty)
        }
        XCTAssertFalse(URLFilterState.degradedFailOpen.isProtecting)
        XCTAssertFalse(URLFilterState.staleDataset.isProtecting)
    }

    func testTroubleshootingIncludesARemovalPathOutsideTheApp() {
        let removal = ProtectionTroubleshooting.steps.first { $0.id == "remove" }
        XCTAssertTrue(removal?.detail.contains("Settings") ?? false)
    }
}
