import XCTest
@testable import KnowledgeBaseKit
import ObservationCore
import TestSupport

final class DomainMatcherTests: XCTestCase {
    private let matcher = Fixtures.matcher

    func testMatchesSubdomains() {
        let matches = matcher.matches(for: Fixtures.host("collect.tracker.example"))
        XCTAssertEqual(matches.first?.classification.organization, "Tracker Demo")
        XCTAssertFalse(matches.first?.isExactMatch ?? true)
    }

    func testMatchesTheSuffixItself() {
        let matches = matcher.matches(for: Fixtures.host("tracker.example"))
        XCTAssertTrue(matches.first?.isExactMatch ?? false)
    }

    /// A suffix rule must never match a host that merely ends with the same
    /// characters — that is how a blocklist libels an unrelated business.
    func testDoesNotMatchAcrossLabelBoundary() {
        XCTAssertTrue(matcher.matches(for: Fixtures.host("badtracker.example")).isEmpty)
        XCTAssertTrue(matcher.matches(for: Fixtures.host("nottracker.example")).isEmpty)
    }

    func testAddressLiteralsNeverMatch() {
        XCTAssertTrue(matcher.matches(for: Fixtures.host("203.0.113.7")).isEmpty)
    }

    func testInfrastructureCategoriesAreRecognized() {
        XCTAssertTrue(matcher.matches(for: Fixtures.host("edge.cdn.example")).isCommonInfrastructureOnly)
        XCTAssertFalse(matcher.matches(for: Fixtures.host("collect.tracker.example")).isCommonInfrastructureOnly)
    }
}

final class BundledKnowledgeBaseTests: XCTestCase {
    func testDecodes() throws {
        let payload = try BundledKnowledgeBase.decode()
        XCTAssertFalse(payload.classifications.isEmpty)
        XCTAssertEqual(payload.datasetVersion, BundledKnowledgeBase.datasetVersion)
    }

    /// Every shipped classification must be traceable to a source, or be
    /// labeled heuristic (KB-005).
    func testEveryClassificationHasProvenance() throws {
        let payload = try BundledKnowledgeBase.decode()
        let sourceIDs = Set(payload.sources.map(\.id))
        for classification in payload.classifications {
            if classification.isHeuristicOnly { continue }
            XCTAssertFalse(classification.sourceIDs.isEmpty, "\(classification.id) has no source")
            for id in classification.sourceIDs {
                XCTAssertTrue(sourceIDs.contains(id), "\(classification.id) cites unknown source \(id)")
            }
        }
    }

    func testHighImpactCategoriesAreReviewed() throws {
        let payload = try BundledKnowledgeBase.decode()
        for classification in payload.classifications
        where classification.categories.contains(.dataBroker) || classification.categories.contains(.locationIntelligence) {
            XCTAssertEqual(classification.reviewStatus, .reviewed, "\(classification.id) must be reviewed before shipping")
            XCTAssertNotEqual(classification.sourceType, .heuristic, "\(classification.id) must not be a heuristic")
        }
    }

    func testPatternsAreNormalizedHosts() throws {
        let payload = try BundledKnowledgeBase.decode()
        let normalizer = DomainNormalizer()
        for classification in payload.classifications {
            let result = normalizer.normalize(classification.pattern)
            XCTAssertEqual(result.host?.value, classification.pattern, "\(classification.id) is not in canonical form")
        }
    }
}

final class VerifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func manifest(
        version: String = "kb-2",
        expires: TimeInterval = 86_400,
        digest: FireDigest,
        recordCount: Int,
        keyID: String = "key-1"
    ) -> KnowledgeBaseManifest {
        KnowledgeBaseManifest(
            schemaVersion: "fireprivacy.kb/1",
            datasetVersion: version,
            generatedAt: now,
            expiresAt: now.addingTimeInterval(expires),
            minimumAppVersion: "1.0.0",
            recordCount: recordCount,
            payloadDigest: digest,
            signingKeyID: keyID,
            signature: Data([1, 2, 3]).base64EncodedString()
        )
    }

    private func encodedPayload() throws -> (bytes: [UInt8], payload: KnowledgeBasePayload) {
        let payload = Fixtures.knowledgeBase
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (Array(try encoder.encode(payload)), payload)
    }

    func testRejectsUnknownSchema() throws {
        let (bytes, payload) = try encodedPayload()
        let verifier = KnowledgeBaseVerifier(trustAnchors: [])
        var manifest = manifest(digest: FireHasher.hash(bytes), recordCount: payload.classifications.count)
        manifest = KnowledgeBaseManifest(
            schemaVersion: "fireprivacy.kb/99",
            datasetVersion: manifest.datasetVersion,
            generatedAt: manifest.generatedAt,
            expiresAt: manifest.expiresAt,
            minimumAppVersion: manifest.minimumAppVersion,
            recordCount: manifest.recordCount,
            payloadDigest: manifest.payloadDigest,
            signingKeyID: manifest.signingKeyID,
            signature: manifest.signature
        )
        XCTAssertThrowsError(try verifier.verify(
            manifest: manifest, payloadBytes: bytes, payload: payload,
            installedVersion: "kb-1", appVersion: "1.0.0", now: now
        ))
    }

    func testRejectsDigestMismatch() throws {
        let (bytes, payload) = try encodedPayload()
        let verifier = KnowledgeBaseVerifier(trustAnchors: [])
        let manifest = manifest(digest: FireHasher.hash("something else"), recordCount: payload.classifications.count)
        XCTAssertThrowsError(try verifier.verify(
            manifest: manifest, payloadBytes: bytes, payload: payload,
            installedVersion: "kb-1", appVersion: "1.0.0", now: now
        )) { error in
            XCTAssertEqual(error as? KnowledgeBaseVerifier.Failure, .payloadDigestMismatch)
        }
    }

    func testRejectsExpiredDataset() throws {
        let (bytes, payload) = try encodedPayload()
        let verifier = KnowledgeBaseVerifier(trustAnchors: [])
        let manifest = manifest(expires: -1, digest: FireHasher.hash(bytes), recordCount: payload.classifications.count)
        XCTAssertThrowsError(try verifier.verify(
            manifest: manifest, payloadBytes: bytes, payload: payload,
            installedVersion: "kb-1", appVersion: "1.0.0", now: now
        ))
    }

    func testRejectsRollback() throws {
        let (bytes, payload) = try encodedPayload()
        let verifier = KnowledgeBaseVerifier(trustAnchors: [])
        let manifest = manifest(version: "kb-1", digest: FireHasher.hash(bytes), recordCount: payload.classifications.count)
        XCTAssertThrowsError(try verifier.verify(
            manifest: manifest, payloadBytes: bytes, payload: payload,
            installedVersion: "kb-5", appVersion: "1.0.0", now: now
        )) { error in
            guard case .rollbackRejected = error as? KnowledgeBaseVerifier.Failure else {
                return XCTFail("expected a rollback rejection, got \(error)")
            }
        }
    }

    func testRejectsRevokedVersion() throws {
        let (bytes, payload) = try encodedPayload()
        let verifier = KnowledgeBaseVerifier(trustAnchors: [], revokedVersions: ["kb-2"])
        let manifest = manifest(digest: FireHasher.hash(bytes), recordCount: payload.classifications.count)
        XCTAssertThrowsError(try verifier.verify(
            manifest: manifest, payloadBytes: bytes, payload: payload,
            installedVersion: "kb-1", appVersion: "1.0.0", now: now
        )) { error in
            XCTAssertEqual(error as? KnowledgeBaseVerifier.Failure, .revokedVersion("kb-2"))
        }
    }

    func testRejectsRecordCountMismatch() throws {
        let (bytes, payload) = try encodedPayload()
        let verifier = KnowledgeBaseVerifier(trustAnchors: [])
        let manifest = manifest(digest: FireHasher.hash(bytes), recordCount: payload.classifications.count + 1)
        XCTAssertThrowsError(try verifier.verify(
            manifest: manifest, payloadBytes: bytes, payload: payload,
            installedVersion: "kb-1", appVersion: "1.0.0", now: now
        ))
    }

    func testDatasetVersionOrdering() {
        XCTAssertTrue(DatasetVersion("kb-2026.08.31") > DatasetVersion("kb-2026.08.30"))
        XCTAssertTrue(DatasetVersion("1.10.0") > DatasetVersion("1.9.0"))
        XCTAssertEqual(DatasetVersion("1.0"), DatasetVersion("1.0.0"))
    }
}

final class KnowledgeBaseServiceTests: XCTestCase {
    func testUpdatesAreNotAttemptedWithoutATransport() async throws {
        let service = KnowledgeBaseService()
        let result = try await service.updateIfNeeded(now: Date())
        XCTAssertEqual(result, .notAttempted(reason: "updates_disabled"))
    }

    func testClassifiesFromTheBundledDataset() async {
        let service = KnowledgeBaseService()
        let matches = await service.classify(Fixtures.host("collect.metricforge.example"))
        XCTAssertFalse(matches.isEmpty)
    }

    func testRollbackWithoutAPreviousVersionFails() async {
        let service = KnowledgeBaseService()
        do {
            try await service.rollback()
            XCTFail("expected rollback to fail")
        } catch {
            XCTAssertEqual(error as? KnowledgeBaseServiceError, .noRollbackAvailable)
        }
    }
}

final class OverrideTests: XCTestCase {
    func testOverridesAreKeyedByNormalizedHost() {
        var set = DomainOverrideSet()
        set.set(DomainOverride(host: Fixtures.host("Tracker.Example."), disposition: .trusted, createdAt: Date()))
        XCTAssertNotNil(set.override(for: Fixtures.host("tracker.example")))
        set.remove(host: Fixtures.host("tracker.example"))
        XCTAssertTrue(set.isEmpty)
    }
}
