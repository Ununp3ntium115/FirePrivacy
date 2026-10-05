import Foundation
import XCTest
@testable import FirePrivacyCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class KnowledgeBaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let manifest: KnowledgeBaseManifest
        let manifestData: Data
        let payloadData: Data
        let verifier: KnowledgeBaseVerifier
    }

    private func fixture(
        version: String = "1.0.0", payloadVersion: String? = nil, sequence: Int64 = 7,
        generatedAt: Int64 = 1_699_999_940, expiresAt: Int64 = 1_700_086_400,
        minimumApp: String = "1.0.0", pattern: String = "example.com",
        kind: DomainPatternKind = .domainSuffix, sourceIDs: [String] = ["source"],
        payloadOverride: Data? = nil, invalidSignature: Bool = false
    ) throws -> Fixture {
        // Fresh ephemeral test keys never enter production trust anchors.
        let key = Curve25519.Signing.PrivateKey()
        let source = KnowledgeSource(id: "source", title: "Fixture vendor documentation", url: "https://vendor.example/reference",
                                     type: .vendorDocumentation, retrievedAt: now.addingTimeInterval(-120), excerpt: "A documented test endpoint role.")
        let record = DomainClassification(id: "rule", pattern: pattern, patternKind: kind, organization: "Fixture", sdkFamily: nil,
                                         categories: [.analytics], purposes: ["Documented endpoint role"], confidence: 0.9,
                                         sourceIDs: sourceIDs, lastReviewed: now.addingTimeInterval(-120), expiresAt: nil,
                                         reviewStatus: .reviewed, notes: "The endpoint role does not establish what a contact sent.")
        let payload = KnowledgeBasePayload(schemaVersion: 1, datasetVersion: payloadVersion ?? version,
                                          sources: [source], classifications: [record])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try payloadOverride ?? encoder.encode(payload)
        let unsigned = KnowledgeBaseManifest(schemaVersion: 1, datasetVersion: version, sequence: sequence,
                                             generatedAt: generatedAt, expiresAt: expiresAt, minimumAppVersion: minimumApp,
                                             recordCount: 1, payloadSHA256: ContentDigest.sha256(bytes), signingKeyID: "test-key", signatureBase64: "")
        let signature = invalidSignature ? Data(repeating: 0, count: 64) : try key.signature(for: unsigned.signingRepresentation)
        let manifest = KnowledgeBaseManifest(schemaVersion: unsigned.schemaVersion, datasetVersion: unsigned.datasetVersion,
                                             sequence: unsigned.sequence, generatedAt: unsigned.generatedAt, expiresAt: unsigned.expiresAt,
                                             minimumAppVersion: unsigned.minimumAppVersion, recordCount: unsigned.recordCount,
                                             payloadSHA256: unsigned.payloadSHA256, signingKeyID: unsigned.signingKeyID,
                                             signatureBase64: signature.base64EncodedString())
        return .init(manifest: manifest, manifestData: try encoder.encode(manifest), payloadData: bytes,
                     verifier: .init(trustAnchors: [.init(keyID: "test-key", publicKey: key.publicKey.rawRepresentation)]))
    }

    private func activate(_ value: Fixture, highWater: KnowledgeBaseHighWaterMark? = nil, restoring: Bool = false) throws -> VerifiedKnowledgeBase {
        try value.verifier.verify(manifestData: value.manifestData, payloadData: value.payloadData, appVersion: "1.0.0",
                                  now: now, highWaterMark: highWater, restoringCurrent: restoring)
    }

    private func assertFailure(_ failure: KnowledgeBaseVerifier.Failure, _ operation: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? KnowledgeBaseVerifier.Failure, failure, file: file, line: line)
        }
    }

    func testGenuineSignatureActivatesOnSupportedCryptoBackend() throws {
        let value = try fixture()
        let activated = try activate(value)
        XCTAssertEqual(activated.version, "1.0.0")
        XCTAssertEqual(activated.highWaterMark.sequence, 7)
        XCTAssertEqual(activated.payloadData, value.payloadData)
        XCTAssertNoThrow(try value.verifier.verify(manifestData: value.manifestData, payloadData: value.payloadData, appVersion: "1.0", now: now))
        XCTAssertFalse(DetachedSignature.verify(signature: Data(repeating: 0, count: 64), message: value.manifest.signingRepresentation,
                                                publicKey: value.verifier.trustAnchors[0].publicKey))
    }

    func testInvalidSignatureIsRejectedBeforeMalformedPayloadDecode() throws {
        let value = try fixture(payloadOverride: Data("{".utf8), invalidSignature: true)
        assertFailure(.signatureInvalid) { _ = try self.activate(value) }
        let signedMalformed = try fixture(payloadOverride: Data("{".utf8))
        assertFailure(.malformedPayload) { _ = try self.activate(signedMalformed) }
    }

    func testTamperedPayloadDigestAndOversizedInputsAreRejected() throws {
        let value = try fixture()
        assertFailure(.payloadDigestMismatch) {
            _ = try value.verifier.verify(manifestData: value.manifestData, payloadData: value.payloadData + Data(" ".utf8), appVersion: "1.0.0", now: self.now)
        }
        assertFailure(.oversized) {
            _ = try value.verifier.verify(manifestData: Data(repeating: 32, count: 16_385), payloadData: value.payloadData, appVersion: "1.0.0", now: self.now)
        }
        assertFailure(.oversized) {
            _ = try value.verifier.verify(manifestData: value.manifestData, payloadData: Data(repeating: 0, count: KnowledgeBaseVerifier.maximumPayloadBytes + 1), appVersion: "1.0.0", now: self.now)
        }
    }

    func testSignedPayloadVersionMustAgreeWithManifest() throws {
        let value = try fixture(payloadVersion: "1.0.1")
        assertFailure(.metadataMismatch) { _ = try self.activate(value) }
    }

    func testUnknownAndRevokedSigningKeysAndVersionsAreRejected() throws {
        let value = try fixture()
        for verifier in [KnowledgeBaseVerifier(trustAnchors: []),
                         KnowledgeBaseVerifier(trustAnchors: value.verifier.trustAnchors, revokedKeyIDs: ["test-key"]),
                         KnowledgeBaseVerifier(trustAnchors: value.verifier.trustAnchors, revokedVersions: ["1.0.0"])] {
            XCTAssertThrowsError(try verifier.verify(manifestData: value.manifestData, payloadData: value.payloadData, appVersion: "1.0.0", now: now))
        }
    }

    func testExpiryFutureDatingLifetimeAndMinimumAppGates() throws {
        let expired = try fixture(expiresAt: 1_700_000_000)
        assertFailure(.expired) { _ = try self.activate(expired) }
        let future = try fixture(generatedAt: 1_700_000_301)
        assertFailure(.futureDated) { _ = try self.activate(future) }
        let longLived = try fixture(expiresAt: 1_740_000_000)
        assertFailure(.invalidLifetime) { _ = try self.activate(longLived) }
        let requiresNewApp = try fixture(minimumApp: "1.1.0")
        assertFailure(.minimumAppVersionNotMet) { _ = try self.activate(requiresNewApp) }
    }

    func testPersistedHighWaterRejectsRollbackAndOnlyRestoresIdenticalRelease() throws {
        let original = try fixture()
        let installed = try activate(original)
        assertFailure(.rollbackRejected) { _ = try self.activate(original, highWater: installed.highWaterMark) }
        XCTAssertNoThrow(try activate(original, highWater: installed.highWaterMark, restoring: true))
        let changedSameSequence = try fixture(pattern: "other.example.com")
        assertFailure(.rollbackRejected) { _ = try self.activate(changedSameSequence, highWater: installed.highWaterMark, restoring: true) }
        let older = try fixture(version: "0.9.0", sequence: 6)
        assertFailure(.rollbackRejected) { _ = try self.activate(older, highWater: installed.highWaterMark) }
        let newer = try fixture(version: "1.0.1", sequence: 8)
        XCTAssertNoThrow(try activate(newer, highWater: installed.highWaterMark))
    }

    func testSignedSemanticallyInvalidRulesAreRejected() throws {
        for pattern in ["com", "github.io", "*.example.com", "https://example.com", "bad..example.com"] {
            let value = try fixture(pattern: pattern)
            assertFailure(.invalidSemantics) { _ = try self.activate(value) }
        }
        let unresolvedCitation = try fixture(sourceIDs: ["missing-source"])
        assertFailure(.invalidSemantics) { _ = try self.activate(unresolvedCitation) }
    }

    func testExactAndSuffixMatchingRespectDNSLabelBoundaries() throws {
        let suffix = DomainMatcher(snapshot: try activate(fixture()))
        XCTAssertEqual(suffix.matches(for: "a.example.com", now: now).count, 1)
        XCTAssertEqual(suffix.matches(for: "example.com", now: now).count, 1)
        XCTAssertTrue(suffix.matches(for: "badexample.com", now: now).isEmpty)
        XCTAssertTrue(suffix.matches(for: "example.com.attacker.net", now: now).isEmpty)
        let exact = DomainMatcher(snapshot: try activate(fixture(kind: .exactHost)))
        XCTAssertEqual(exact.matches(for: "example.com", now: now).count, 1)
        XCTAssertTrue(exact.matches(for: "a.example.com", now: now).isEmpty)
        XCTAssertEqual(exact.matches(for: "example.com", now: now).first?.sources.first?.id, "source")
    }

    func testExpiredInstalledMatchesRemainExplicitlyStale() throws {
        let snapshot = try activate(fixture())
        let matcher = DomainMatcher(snapshot: snapshot)
        XCTAssertFalse(matcher.matches(for: "example.com", now: now)[0].isStale)
        XCTAssertTrue(matcher.matches(for: "example.com", now: now.addingTimeInterval(100_000))[0].isStale)
    }

    func testIDNAASCIIIdentityAndMaliciousHostRejection() throws {
        XCTAssertEqual(DomainIdentity("BÜCHER.de.")?.value, "xn--bcher-kva.de")
        XCTAssertEqual(DomainIdentity("bücher.de")?.value, DomainIdentity("xn--bcher-kva.de")?.value)
        XCTAssertTrue(DomainIdentity("bücher.de")?.wasInternationalized == true)
        for host in ["https://example.com", "example.com:443", "user@example.com", "example.com/path", "example%2ecom", "a..com", "-a.com", "xn--a.com", "xn--0.com", "127.0.0.1", "[::1]", String(repeating: "a", count: 64) + ".com"] {
            XCTAssertNil(DomainIdentity(host), host)
        }
    }

    func testCompletePSLPrivateTenantIsolationAndICANNOnlyScope() throws {
        XCTAssertEqual(DomainIdentity("a.github.io")?.registrableDomain, "a.github.io")
        XCTAssertEqual(DomainIdentity("b.github.io")?.registrableDomain, "b.github.io")
        XCTAssertTrue(DomainIdentity("a.github.io")?.usedPrivateSuffix == true)
        let icann = try PublicSuffixList(text: XCTUnwrap(KnowledgeBaseResources.publicSuffixText), includePrivate: false)
        XCTAssertEqual(DomainIdentity("a.github.io", suffixList: icann)?.registrableDomain, "github.io")
        XCTAssertFalse(DomainIdentity("evilgithub.io")?.usedPrivateSuffix ?? true)
        XCTAssertNil(DomainIdentity("some.unknown-suffix")?.registrableDomain)
    }

    func testPSLWildcardAndExceptionRules() throws {
        XCTAssertEqual(DomainIdentity("a.b.kawasaki.jp")?.publicSuffix, "b.kawasaki.jp")
        XCTAssertEqual(DomainIdentity("a.b.kawasaki.jp")?.registrableDomain, "a.b.kawasaki.jp")
        XCTAssertEqual(DomainIdentity("www.city.kawasaki.jp")?.publicSuffix, "kawasaki.jp")
        XCTAssertEqual(DomainIdentity("www.city.kawasaki.jp")?.registrableDomain, "city.kawasaki.jp")
    }

    func testUserOverridesDoNotMutateSignedFacts() throws {
        let snapshot = try activate(fixture())
        let identity = try XCTUnwrap(DomainIdentity("example.com"))
        var overrides = DomainOverrideSet()
        overrides.set(.init(host: identity, disposition: .trusted, note: "Expected for my app", createdAt: now))
        XCTAssertEqual(overrides.override(for: identity)?.disposition, .trusted)
        XCTAssertEqual(snapshot.payload.classifications[0].categories, [.analytics])
        overrides.remove(host: identity)
        XCTAssertTrue(overrides.sorted.isEmpty)
    }

    func testBundledProductionDatasetVerifiesWithIndependentBootstrapAnchor() throws {
        let snapshot = try KnowledgeBaseResources.loadBundled()
        XCTAssertEqual(snapshot.manifest.recordCount, 3)
        XCTAssertEqual(snapshot.payload.classifications.count, 3)
        XCTAssertTrue(snapshot.payload.classifications.allSatisfy { $0.reviewStatus == .reviewed && !$0.sourceIDs.isEmpty })
        XCTAssertEqual(DomainMatcher(snapshot: snapshot).matches(for: "cloudflare-dns.com").first?.classification.categories, [.dnsResolution])
    }
}
