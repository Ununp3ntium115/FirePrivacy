import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import FirePrivacyCore

final class KnowledgeBaseRevocationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Generated test-only keys are never production trust anchors or resources.
    private let key = Curve25519.Signing.PrivateKey()
    private let replacementKey = Curve25519.Signing.PrivateKey()
    private let keyID = "revocation-test-key"
    private var initialSets: KnowledgeBaseRevocations {
        .init(revokedVersions: ["1.0.0"], revokedKeyIDs: ["retired-key"],
              revokedPayloadDigests: [String(repeating: "a", count: 64)])
    }
    private var verifier: KnowledgeBaseRevocationVerifier {
        .init(trustAnchors: [.init(keyID: keyID, publicKey: key.publicKey.rawRepresentation),
                            .init(keyID: "replacement-key", publicKey: replacementKey.publicKey.rawRepresentation)])
    }

    private func fixture(sequence: Int64 = 7, sets: KnowledgeBaseRevocations? = nil,
                         generatedAt: Int64 = 1_699_999_940, expiresAt: Int64 = 1_700_003_600,
                         payloadOverride: Data? = nil, countOverride: Int? = nil,
                         useReplacement: Bool = false, invalidSignature: Bool = false) throws -> SignedKnowledgeBaseRevocations {
        let revocations = sets ?? initialSets
        let payload = try payloadOverride ?? JSONEncoder().encode(KnowledgeBaseRevocationPayload(sequence: sequence, revocations: revocations))
        let count = countOverride ?? (revocations.revokedVersions.count + revocations.revokedKeyIDs.count + revocations.revokedPayloadDigests.count)
        let signer = useReplacement ? replacementKey : key
        let signerID = useReplacement ? "replacement-key" : keyID
        let unsigned = KnowledgeBaseRevocationManifest(sequence: sequence, generatedAt: generatedAt,
            expiresAt: expiresAt, revocationCount: count, payloadByteCount: payload.count,
            payloadSHA256: ContentDigest.sha256(payload), signingKeyID: signerID, signatureBase64: "")
        let signature = invalidSignature ? Data(repeating: 0, count: 64) : try signer.signature(for: unsigned.signingRepresentation)
        let manifest = KnowledgeBaseRevocationManifest(sequence: sequence, generatedAt: generatedAt,
            expiresAt: expiresAt, revocationCount: count, payloadByteCount: payload.count,
            payloadSHA256: unsigned.payloadSHA256, signingKeyID: signerID, signatureBase64: signature.base64EncodedString())
        return .init(manifestData: try JSONEncoder().encode(manifest), payloadData: payload)
    }

    private func verify(_ signed: SignedKnowledgeBaseRevocations,
                        previous: KnowledgeBaseRevocationHighWaterMark? = nil,
                        restoring: Bool = false, at date: Date? = nil) throws -> VerifiedKnowledgeBaseRevocations {
        try verifier.verify(signed, now: date ?? now, highWaterMark: previous, restoringCurrent: restoring)
    }
    private func failure(_ expected: KnowledgeBaseRevocationVerifier.Failure,
                         file: StaticString = #filePath, line: UInt = #line, operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? KnowledgeBaseRevocationVerifier.Failure, expected, file: file, line: line)
        }
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testGenuineEd25519DocumentActivatesAndPersistsItsIdentityAndStickySets() throws {
        let signed = try fixture()
        let result = try verify(signed)
        XCTAssertEqual(result.revocations, initialSets)
        XCTAssertEqual(result.signedDocument, signed)
        XCTAssertEqual(result.highWaterMark.sequence, 7)
        XCTAssertEqual(result.highWaterMark.documentSHA256.count, 64)
        XCTAssertEqual(result.highWaterMark.revocations, initialSets)
        XCTAssertFalse(result.isExpired(now: now))
        XCTAssertEqual(try JSONDecoder().decode(KnowledgeBaseRevocationHighWaterMark.self,
            from: JSONEncoder().encode(result.highWaterMark)), result.highWaterMark)
    }

    func testInvalidSignatureIsRejectedBeforeMalformedPayloadCanBeDecoded() throws {
        let bad = try fixture(payloadOverride: Data("{".utf8), invalidSignature: true)
        failure(.signatureInvalid) { _ = try verify(bad) }
        let authenticatedMalformed = try fixture(payloadOverride: Data("{".utf8))
        failure(.malformedPayload) { _ = try verify(authenticatedMalformed) }
    }

    func testTamperedPayloadAndBoundedManifestAndPayloadAreRejected() throws {
        let signed = try fixture()
        failure(.payloadDigestMismatch) {
            _ = try verify(.init(manifestData: signed.manifestData, payloadData: signed.payloadData + Data(" ".utf8)))
        }
        failure(.oversized) {
            _ = try verify(.init(manifestData: Data(repeating: 32, count: 16_385), payloadData: signed.payloadData))
        }
        failure(.oversized) {
            _ = try verify(.init(manifestData: signed.manifestData,
                payloadData: Data(repeating: 32, count: KnowledgeBaseRevocationVerifier.maximumPayloadBytes + 1)))
        }
    }

    func testSignatureBindsEveryManifestSemanticFieldAndItsDomainSeparator() throws {
        let signed = try fixture()
        let mutations: [String: Any] = ["sequence": 8, "generatedAt": 1_699_999_939,
            "expiresAt": 1_700_003_601, "revocationCount": 4, "payloadByteCount": signed.payloadData.count + 1,
            "payloadSHA256": String(repeating: "b", count: 64)]
        for (field, value) in mutations {
            var manifest = try object(signed.manifestData)
            manifest[field] = value
            let altered = SignedKnowledgeBaseRevocations(manifestData: try data(manifest), payloadData: signed.payloadData)
            failure(.signatureInvalid) { _ = try verify(altered) }
        }
        var manifestObject = try object(signed.manifestData)
        let manifest = try JSONDecoder().decode(KnowledgeBaseRevocationManifest.self, from: signed.manifestData)
        let wrongDomain = String(decoding: manifest.signingRepresentation, as: UTF8.self)
            .replacingOccurrences(of: "FirePrivacy.KnowledgeBaseRevocations.v1", with: "FirePrivacy.KnowledgeBase.v1")
        manifestObject["signatureBase64"] = try key.signature(for: Data(wrongDomain.utf8)).base64EncodedString()
        failure(.signatureInvalid) {
            _ = try verify(.init(manifestData: try data(manifestObject), payloadData: signed.payloadData))
        }
    }

    func testUnknownAmbiguousAndExpiredTrustAnchorsDoNotAuthorizeLists() throws {
        let signed = try fixture()
        failure(.unknownSigningKey) {
            _ = try KnowledgeBaseRevocationVerifier(trustAnchors: []).verify(signed, now: now)
        }
        let anchor = KnowledgeBaseTrustAnchor(keyID: keyID, publicKey: key.publicKey.rawRepresentation)
        failure(.unknownSigningKey) {
            _ = try KnowledgeBaseRevocationVerifier(trustAnchors: [anchor, anchor]).verify(signed, now: now)
        }
        failure(.invalidLifetime) {
            _ = try KnowledgeBaseRevocationVerifier(trustAnchors: [.init(keyID: keyID,
                publicKey: key.publicKey.rawRepresentation, expiresAt: 1_700_000_000)]).verify(signed, now: now)
        }
    }

    func testExpiryFutureDatingAndNinetyDayLifetimeBounds() throws {
        failure(.expired) { _ = try verify(fixture(expiresAt: 1_700_000_000)) }
        failure(.futureDated) { _ = try verify(fixture(generatedAt: 1_700_000_301)) }
        failure(.invalidLifetime) { _ = try verify(fixture(expiresAt: 1_710_000_000)) }
        failure(.futureDated) { _ = try verify(fixture(), at: Date(timeIntervalSince1970: .infinity)) }
    }

    func testOnlyExactAuthenticatedCurrentListRestoresAndSameSequenceSubstitutionFails() throws {
        let signed = try fixture()
        let previous = try verify(signed).highWaterMark
        failure(.rollbackRejected) { _ = try verify(signed, previous: previous) }
        XCTAssertNoThrow(try verify(signed, previous: previous, restoring: true))
        let changedPayload = try fixture(sets: .init(revokedVersions: ["1.0.0", "1.0.1"],
            revokedKeyIDs: initialSets.revokedKeyIDs, revokedPayloadDigests: initialSets.revokedPayloadDigests))
        failure(.rollbackRejected) { _ = try verify(changedPayload, previous: previous, restoring: true) }
        // Full signed identity catches substituted timestamps even for equal payload bytes.
        let changedManifest = try fixture(expiresAt: 1_700_003_601)
        failure(.rollbackRejected) { _ = try verify(changedManifest, previous: previous, restoring: true) }
        failure(.rollbackRejected) { _ = try verify(fixture(sequence: 6), previous: previous) }
    }

    func testNewerListsMustRetainEveryPreviouslyRevokedVersionKeyAndDigest() throws {
        let previous = try verify(fixture()).highWaterMark
        let extended = KnowledgeBaseRevocations(revokedVersions: ["1.0.0", "1.0.1"],
            revokedKeyIDs: initialSets.revokedKeyIDs, revokedPayloadDigests: initialSets.revokedPayloadDigests)
        XCTAssertEqual(try verify(fixture(sequence: 8, sets: extended), previous: previous).revocations, extended)
        let incomplete = [KnowledgeBaseRevocations(revokedKeyIDs: initialSets.revokedKeyIDs,
            revokedPayloadDigests: initialSets.revokedPayloadDigests),
            KnowledgeBaseRevocations(revokedVersions: initialSets.revokedVersions,
                revokedPayloadDigests: initialSets.revokedPayloadDigests),
            KnowledgeBaseRevocations(revokedVersions: initialSets.revokedVersions, revokedKeyIDs: initialSets.revokedKeyIDs)]
        for sets in incomplete {
            failure(.stickyRevocationRemoved) { _ = try verify(fixture(sequence: 8, sets: sets), previous: previous) }
        }
    }

    func testExpiredListDoesNotUnrevokeStickyStateOrPermitExpiredRestore() throws {
        let signed = try fixture()
        let previous = try verify(signed).highWaterMark
        let later = now.addingTimeInterval(3_601)
        failure(.expired) { _ = try verify(signed, previous: previous, restoring: true, at: later) }
        XCTAssertEqual(previous.revocations, initialSets)
        failure(.stickyRevocationRemoved) {
            _ = try verify(fixture(sequence: 8, sets: .init(), expiresAt: 1_700_086_400), previous: previous, at: later)
        }
    }

    func testSelfRevokingSignerAllowsExactRestoreButRequiresAnotherTrustedSignerForNewLists() throws {
        let sets = KnowledgeBaseRevocations(revokedKeyIDs: [keyID])
        let signed = try fixture(sets: sets)
        let previous = try verify(signed).highWaterMark
        XCTAssertNoThrow(try verify(signed, previous: previous, restoring: true))
        failure(.revokedSigningKey) { _ = try verify(fixture(sequence: 8, sets: sets), previous: previous) }
        XCTAssertNoThrow(try verify(fixture(sequence: 8, sets: sets, useReplacement: true), previous: previous))
    }

    func testClosedSchemasRejectUnknownMissingAndMismatchedMetadata() throws {
        let signed = try fixture()
        var manifest = try object(signed.manifestData)
        manifest["allowRollback"] = true
        failure(.malformedManifest) { _ = try verify(.init(manifestData: try data(manifest), payloadData: signed.payloadData)) }
        var payload = try object(signed.payloadData)
        payload["allowReinstatement"] = true
        failure(.malformedPayload) { _ = try verify(fixture(payloadOverride: data(payload))) }
        payload = try object(signed.payloadData)
        payload.removeValue(forKey: "revokedKeyIDs")
        failure(.malformedPayload) { _ = try verify(fixture(payloadOverride: data(payload))) }
        payload = try object(signed.payloadData)
        payload["sequence"] = 8
        failure(.metadataMismatch) { _ = try verify(fixture(payloadOverride: data(payload))) }
        failure(.metadataMismatch) { _ = try verify(fixture(countOverride: 4)) }
    }

    func testNoncanonicalVersionsKeysDigestsDuplicatesAndExcessiveSetsAreRejected() throws {
        let signed = try fixture()
        let mutations: [(String, [String], Int)] = [("revokedVersions", ["01.0.0"], 3),
            ("revokedVersions", ["1.0"], 3), ("revokedKeyIDs", ["key\nother"], 3),
            ("revokedPayloadDigests", [String(repeating: "A", count: 64)], 3),
            ("revokedVersions", ["1.0.0", "1.0.0"], 4),
            ("revokedVersions", ["2.0.0", "1.0.0"], 4)]
        for (field, value, count) in mutations {
            var payload = try object(signed.payloadData)
            payload[field] = value
            failure(.invalidSemantics) { _ = try verify(fixture(payloadOverride: data(payload), countOverride: count)) }
        }
        let huge = KnowledgeBaseRevocations(revokedKeyIDs: Set((0...10_000).map { "key-\($0)" }))
        failure(.malformedManifest) { _ = try verify(fixture(sets: huge)) }
    }

    func testDuplicateAndEscapedDuplicateJSONFieldsAreRejectedWithoutAmbiguousDecoding() throws {
        let signed = try fixture()
        for field in ["sequence", "sequen\\u0063e"] {
            let original = String(decoding: signed.manifestData, as: UTF8.self)
            let duplicate = Data((String(original.dropLast()) + ",\"" + field + "\":7}").utf8)
            failure(.malformedManifest) { _ = try verify(.init(manifestData: duplicate, payloadData: signed.payloadData)) }
            let payload = String(decoding: signed.payloadData, as: UTF8.self)
            let duplicatePayload = Data((String(payload.dropLast()) + ",\"" + field + "\":7}").utf8)
            failure(.malformedPayload) { _ = try verify(fixture(payloadOverride: duplicatePayload)) }
        }
    }

    func testDeepMalformedJSONDoesNotReachUnboundedDecoderRecursion() throws {
        let deeplyNested = Data(("{\"sequence\":" + String(repeating: "[", count: 100)
            + "0" + String(repeating: "]", count: 100) + "}").utf8)
        failure(.malformedManifest) {
            _ = try verify(.init(manifestData: deeplyNested, payloadData: Data("{}".utf8)))
        }
        failure(.malformedPayload) { _ = try verify(fixture(payloadOverride: deeplyNested)) }
    }

    func testCorruptOrSubstitutedPersistedHighWaterFailsClosed() throws {
        let signed = try fixture()
        failure(.invalidPreviousState) {
            _ = try verify(signed, previous: .init(sequence: 0, documentSHA256: String(repeating: "a", count: 64), revocations: .init()))
        }
        let previous = try verify(signed).highWaterMark
        failure(.invalidPreviousState) {
            _ = try verify(signed, previous: .init(sequence: previous.sequence, documentSHA256: previous.documentSHA256,
                revocations: .init()), restoring: true)
        }
    }

    func testAuthenticatedVersionKeyAndDigestSetsDenyKnowledgeBaseBeforePayloadDecode() throws {
        let bytes = Data("{".utf8)
        let manifest = KnowledgeBaseManifest(schemaVersion: 1, datasetVersion: "1.0.0", sequence: 1,
            generatedAt: 1_699_999_940, expiresAt: 1_700_003_600, minimumAppVersion: "1.0.0", recordCount: 0,
            payloadSHA256: ContentDigest.sha256(bytes), signingKeyID: keyID, signatureBase64: "")
        let sets = [KnowledgeBaseRevocations(revokedVersions: [manifest.datasetVersion]),
                    KnowledgeBaseRevocations(revokedKeyIDs: [manifest.signingKeyID]),
                    KnowledgeBaseRevocations(revokedPayloadDigests: [manifest.payloadSHA256])]
        for revocations in sets {
            let verified = try verify(fixture(sets: revocations))
            XCTAssertTrue(verified.revocations.revokes(manifest))
            let kb = KnowledgeBaseVerifier(trustAnchors: verifier.trustAnchors,
                revokedVersions: verified.revocations.revokedVersions, revokedKeyIDs: verified.revocations.revokedKeyIDs,
                revokedPayloadDigests: verified.revocations.revokedPayloadDigests)
            XCTAssertThrowsError(try kb.verify(manifestData: JSONEncoder().encode(manifest), payloadData: bytes,
                appVersion: "1.0.0", now: now)) { XCTAssertEqual($0 as? KnowledgeBaseVerifier.Failure, .revoked) }
        }
    }
}
