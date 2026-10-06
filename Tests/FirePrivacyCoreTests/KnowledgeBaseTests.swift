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
        let key: Curve25519.Signing.PrivateKey
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
        return .init(key: key, manifest: manifest, manifestData: try encoder.encode(manifest), payloadData: bytes,
                     verifier: .init(trustAnchors: [.init(keyID: "test-key", publicKey: key.publicKey.rawRepresentation)]))
    }

    private func resigned(_ value: Fixture, expiresAt: Int64? = nil, minimumApp: String? = nil,
                          signingKeyID: String? = nil, key: Curve25519.Signing.PrivateKey? = nil) throws -> Fixture {
        let original = value.manifest
        let signingKey = key ?? value.key
        let unsigned = KnowledgeBaseManifest(schemaVersion: original.schemaVersion, datasetVersion: original.datasetVersion,
            sequence: original.sequence, generatedAt: original.generatedAt, expiresAt: expiresAt ?? original.expiresAt,
            minimumAppVersion: minimumApp ?? original.minimumAppVersion, recordCount: original.recordCount,
            payloadSHA256: original.payloadSHA256, signingKeyID: signingKeyID ?? original.signingKeyID, signatureBase64: "")
        let signed = KnowledgeBaseManifest(schemaVersion: unsigned.schemaVersion, datasetVersion: unsigned.datasetVersion,
            sequence: unsigned.sequence, generatedAt: unsigned.generatedAt, expiresAt: unsigned.expiresAt,
            minimumAppVersion: unsigned.minimumAppVersion, recordCount: unsigned.recordCount,
            payloadSHA256: unsigned.payloadSHA256, signingKeyID: unsigned.signingKeyID,
            signatureBase64: try signingKey.signature(for: unsigned.signingRepresentation).base64EncodedString())
        return Fixture(key: signingKey, manifest: signed, manifestData: try JSONEncoder().encode(signed),
            payloadData: value.payloadData, verifier: .init(trustAnchors: [
                .init(keyID: signed.signingKeyID, publicKey: signingKey.publicKey.rawRepresentation)
            ]))
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
        XCTAssertEqual(activated.highWaterMark.manifestSHA256, ContentDigest.sha256(value.manifestData))
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
        assertFailure(.equivocationRejected) { _ = try self.activate(changedSameSequence, highWater: installed.highWaterMark, restoring: true) }
        let older = try fixture(version: "0.9.0", sequence: 6)
        assertFailure(.rollbackRejected) { _ = try self.activate(older, highWater: installed.highWaterMark) }
        let newer = try fixture(version: "1.0.1", sequence: 8)
        XCTAssertNoThrow(try activate(newer, highWater: installed.highWaterMark))
    }

    func testRestoreCannotExtendLifetimeLowerMinimumAppOrChangeSignerAtSameRelease() throws {
        let original = try fixture()
        let accepted = try activate(original)
        for changed in [try resigned(original, expiresAt: original.manifest.expiresAt + 600),
                        try resigned(original, minimumApp: "0.9.0"),
                        try resigned(original, signingKeyID: "new-authorized-test-key", key: Curve25519.Signing.PrivateKey())] {
            XCTAssertEqual(changed.payloadData, original.payloadData)
            XCTAssertNoThrow(try activate(changed), "The regression uses a genuine, currently valid authorized signature.")
            for restoring in [false, true] {
                assertFailure(.equivocationRejected) {
                    _ = try self.activate(changed, highWater: accepted.highWaterMark, restoring: restoring)
                }
            }
        }
    }

    func testDuplicateSelectedTrustAnchorIDsFailClosedRegardlessOfOrder() throws {
        let original = try fixture()
        let anchor = try XCTUnwrap(original.verifier.trustAnchors.first)
        let alternative = KnowledgeBaseTrustAnchor(keyID: anchor.keyID,
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let malformed = KnowledgeBaseTrustAnchor(keyID: anchor.keyID, publicKey: Data(repeating: 0, count: 31))
        for anchors in [[anchor, anchor], [anchor, alternative], [alternative, anchor],
                        [malformed, anchor], [anchor, malformed]] {
            assertFailure(.ambiguousSigningKey) {
                _ = try KnowledgeBaseVerifier(trustAnchors: anchors).verify(
                    manifestData: original.manifestData, payloadData: original.payloadData,
                    appVersion: "1.0.0", now: self.now)
            }
        }
    }

    func testRestoreCannotAcceptAnUnacceptedNewerRelease() throws {
        let accepted = try activate(fixture()).highWaterMark
        let newer = try fixture(version: "1.0.1", sequence: 8)
        XCTAssertNoThrow(try activate(newer, highWater: accepted))
        assertFailure(.rollbackRejected) { _ = try self.activate(newer, highWater: accepted, restoring: true) }
    }

    func testLegacyHighWaterDecodesFailsRestoreAndStillAllowsStrictUpgrade() throws {
        let original = try fixture()
        let accepted = try activate(original).highWaterMark
        let legacyData = try JSONSerialization.data(withJSONObject: ["sequence": accepted.sequence,
            "datasetVersion": accepted.datasetVersion, "payloadSHA256": accepted.payloadSHA256])
        let legacy = try JSONDecoder().decode(KnowledgeBaseHighWaterMark.self, from: legacyData)
        XCTAssertNil(legacy.manifestSHA256)
        assertFailure(.invalidHighWaterMark) { _ = try self.activate(original, highWater: legacy, restoring: true) }
        assertFailure(.rollbackRejected) { _ = try self.activate(original, highWater: legacy) }
        let upgraded = try fixture(version: "1.0.1", sequence: 8)
        XCTAssertNoThrow(try activate(upgraded, highWater: legacy))
        XCTAssertEqual(try JSONDecoder().decode(KnowledgeBaseHighWaterMark.self,
            from: JSONEncoder().encode(accepted)), accepted)
    }

    func testRestoreWithoutPriorAcceptanceFailsClosed() throws {
        let original = try fixture()
        assertFailure(.invalidHighWaterMark) { _ = try self.activate(original, restoring: true) }
    }

    func testRestoreRequiresExactAcceptedManifestBytes() throws {
        let original = try fixture()
        let accepted = try activate(original)
        let object = try JSONSerialization.jsonObject(with: original.manifestData)
        let reformatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        XCTAssertNotEqual(reformatted, original.manifestData)
        XCTAssertNoThrow(try original.verifier.verify(manifestData: reformatted, payloadData: original.payloadData,
            appVersion: "1.0.0", now: now))
        assertFailure(.equivocationRejected) {
            _ = try original.verifier.verify(manifestData: reformatted, payloadData: original.payloadData,
                appVersion: "1.0.0", now: self.now, highWaterMark: accepted.highWaterMark, restoringCurrent: true)
        }
        XCTAssertEqual(try activate(original, highWater: accepted.highWaterMark, restoring: true).manifestData,
                       original.manifestData)
    }

    func testMalformedStoredHighWaterMarksDoNotAuthorizeAnUpgrade() throws {
        let original = try activate(fixture()).highWaterMark
        let upgraded = try fixture(version: "1.0.1", sequence: 8)
        let invalid = [
            KnowledgeBaseHighWaterMark(sequence: 0, datasetVersion: original.datasetVersion,
                payloadSHA256: original.payloadSHA256, manifestSHA256: original.manifestSHA256),
            KnowledgeBaseHighWaterMark(sequence: original.sequence, datasetVersion: "invalid",
                payloadSHA256: original.payloadSHA256, manifestSHA256: original.manifestSHA256),
            KnowledgeBaseHighWaterMark(sequence: original.sequence, datasetVersion: original.datasetVersion,
                payloadSHA256: "too-short", manifestSHA256: original.manifestSHA256),
            KnowledgeBaseHighWaterMark(sequence: original.sequence, datasetVersion: original.datasetVersion,
                payloadSHA256: original.payloadSHA256, manifestSHA256: String(repeating: "g", count: 64))
        ]
        for prior in invalid {
            assertFailure(.invalidHighWaterMark) { _ = try self.activate(upgraded, highWater: prior) }
        }
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
