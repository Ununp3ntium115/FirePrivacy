import Foundation
import XCTest
@testable import FirePrivacyCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class SignedRuleConfigurationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let key: Curve25519.Signing.PrivateKey
        let signed: SignedRuleConfiguration
        let anchor: KnowledgeBaseTrustAnchor
        var verifier: RuleConfigurationVerifier { .init(trustAnchors: [anchor]) }
    }

    private func fixture(version: String = "1.0.0", payloadVersion: String? = nil, sequence: Int64 = 7,
                         generatedAt: Int64 = 1_699_999_940, expiresAt: Int64 = 1_700_086_400,
                         minimumApp: String = "1.0.0", schemaVersion: Int = 1, ruleCount: Int = 8,
                         payloadOverride: Data? = nil, digestOverride: String? = nil,
                         invalidSignature: Bool = false, key: Curve25519.Signing.PrivateKey? = nil) throws -> Fixture {
        // Ephemeral test keys never become production trust roots or artifacts.
        let signingKey = key ?? Curve25519.Signing.PrivateKey()
        let config = try DeclarativeRuleConfiguration(version: payloadVersion ?? version,
            rules: VersionedRuleSet.defaultConfiguration.rules)
        let bytes = try payloadOverride ?? config.encoded()
        let unsigned = RuleConfigurationManifest(schemaVersion: schemaVersion, configurationVersion: version,
            sequence: sequence, generatedAt: generatedAt, expiresAt: expiresAt, minimumAppVersion: minimumApp,
            ruleCount: ruleCount, payloadSHA256: digestOverride ?? ContentDigest.sha256(bytes),
            signingKeyID: "ephemeral-rules-test", signatureBase64: "")
        let signature = invalidSignature ? Data(repeating: 0, count: 64) : try signingKey.signature(for: unsigned.signingRepresentation)
        let manifest = RuleConfigurationManifest(schemaVersion: schemaVersion, configurationVersion: version,
            sequence: sequence, generatedAt: generatedAt, expiresAt: expiresAt, minimumAppVersion: minimumApp,
            ruleCount: ruleCount, payloadSHA256: unsigned.payloadSHA256, signingKeyID: unsigned.signingKeyID,
            signatureBase64: signature.base64EncodedString())
        return Fixture(key: signingKey, signed: .init(manifest: manifest, payloadData: bytes),
            anchor: .init(keyID: unsigned.signingKeyID, publicKey: signingKey.publicKey.rawRepresentation))
    }

    private func verify(_ value: Fixture, highWater: RuleConfigurationHighWaterMark? = nil,
                        restoring: Bool = false) throws -> VerifiedRuleConfiguration {
        try value.verifier.verify(value.signed, appVersion: "1.0.0", now: now,
            highWaterMark: highWater, restoringCurrent: restoring)
    }

    private func assertFailure(_ failure: RuleConfigurationVerifier.Failure, _ operation: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? RuleConfigurationVerifier.Failure, failure, file: file, line: line)
        }
    }

    func testGenuineSignatureActivatesExactClosedConfiguration() throws {
        let value = try fixture()
        let activated = try verify(value)
        XCTAssertEqual(activated.configuration, VersionedRuleSet.defaultConfiguration)
        XCTAssertEqual(activated.highWaterMark.sequence, 7)
        XCTAssertEqual(activated.highWaterMark.configurationVersion, "1.0.0")
        XCTAssertEqual(activated.highWaterMark.payloadSHA256, ContentDigest.sha256(value.signed.payloadData))
        XCTAssertEqual(activated.highWaterMark.manifestSHA256.count, 64)
        XCTAssertNotEqual(activated.highWaterMark.manifestSHA256, activated.highWaterMark.payloadSHA256)
        XCTAssertNoThrow(try value.verifier.verify(value.signed, appVersion: "1.0", now: now))
        let restoredEnvelope = try SignedRuleConfiguration.decode(value.signed.encoded())
        XCTAssertEqual(restoredEnvelope.payloadData, value.signed.payloadData)
        XCTAssertNoThrow(try value.verifier.verify(restoredEnvelope, appVersion: "1.0.0", now: now))
    }

    func testSignatureAndAuthorityAreCheckedBeforeMalformedPayloadDecode() throws {
        let unauthenticated = try fixture(payloadOverride: Data("{".utf8), invalidSignature: true)
        assertFailure(.signatureInvalid) { _ = try self.verify(unauthenticated) }
        let authenticated = try fixture(payloadOverride: Data("{".utf8))
        assertFailure(.malformedPayload) { _ = try self.verify(authenticated) }
        assertFailure(.unknownSigningKey) {
            _ = try RuleConfigurationVerifier(trustAnchors: []).verify(authenticated.signed,
                appVersion: "1.0.0", now: self.now)
        }
    }

    func testPayloadWhitespaceTamperingCannotReuseValidSignature() throws {
        let original = try fixture()
        let tampered = SignedRuleConfiguration(manifest: original.signed.manifest,
            payloadData: original.signed.payloadData + Data(" ".utf8))
        assertFailure(.payloadDigestMismatch) {
            _ = try original.verifier.verify(tampered, appVersion: "1.0.0", now: self.now)
        }
    }

    func testManifestLifetimeTamperingWithoutResigningIsRejected() throws {
        let original = try fixture()
        let m = original.signed.manifest
        let changed = RuleConfigurationManifest(schemaVersion: m.schemaVersion, configurationVersion: m.configurationVersion,
            sequence: m.sequence, generatedAt: m.generatedAt, expiresAt: m.expiresAt + 60,
            minimumAppVersion: m.minimumAppVersion, ruleCount: m.ruleCount, payloadSHA256: m.payloadSHA256,
            signingKeyID: m.signingKeyID, signatureBase64: m.signatureBase64)
        assertFailure(.signatureInvalid) {
            _ = try original.verifier.verify(.init(manifest: changed, payloadData: original.signed.payloadData),
                appVersion: "1.0.0", now: self.now)
        }
    }

    func testKnowledgeSignatureCannotAuthorizeRulesEvenUnderSameTrustedPublicKey() throws {
        let original = try fixture()
        let m = original.signed.manifest
        let knowledge = KnowledgeBaseManifest(schemaVersion: m.schemaVersion, datasetVersion: m.configurationVersion,
            sequence: m.sequence, generatedAt: m.generatedAt, expiresAt: m.expiresAt,
            minimumAppVersion: m.minimumAppVersion, recordCount: m.ruleCount, payloadSHA256: m.payloadSHA256,
            signingKeyID: m.signingKeyID, signatureBase64: "")
        let otherProtocolSignature = try original.key.signature(for: knowledge.signingRepresentation)
        let substituted = RuleConfigurationManifest(schemaVersion: m.schemaVersion, configurationVersion: m.configurationVersion,
            sequence: m.sequence, generatedAt: m.generatedAt, expiresAt: m.expiresAt,
            minimumAppVersion: m.minimumAppVersion, ruleCount: m.ruleCount, payloadSHA256: m.payloadSHA256,
            signingKeyID: m.signingKeyID, signatureBase64: otherProtocolSignature.base64EncodedString())
        assertFailure(.signatureInvalid) {
            _ = try original.verifier.verify(.init(manifest: substituted, payloadData: original.signed.payloadData),
                appVersion: "1.0.0", now: self.now)
        }
    }

    func testUnknownAmbiguousAndRevokedAuthorityCannotActivate() throws {
        let original = try fixture()
        assertFailure(.ambiguousSigningKey) {
            _ = try RuleConfigurationVerifier(trustAnchors: [original.anchor, original.anchor]).verify(original.signed,
                appVersion: "1.0.0", now: self.now)
        }
        assertFailure(.revoked) {
            _ = try RuleConfigurationVerifier(trustAnchors: [original.anchor], revokedKeyIDs: [original.anchor.keyID])
                .verify(original.signed, appVersion: "1.0.0", now: self.now)
        }
        assertFailure(.revoked) {
            _ = try RuleConfigurationVerifier(trustAnchors: [original.anchor],
                revokedPayloadDigests: [original.signed.manifest.payloadSHA256])
                .verify(original.signed, appVersion: "1.0.0", now: self.now)
        }
    }

    func testExpiryFutureDateAndNinetyDayLifetimeBoundaries() throws {
        let expired = try fixture(expiresAt: 1_700_000_000)
        assertFailure(.expired) { _ = try self.verify(expired) }
        let future = try fixture(generatedAt: 1_700_000_301)
        assertFailure(.futureDated) { _ = try self.verify(future) }
        XCTAssertNoThrow(try verify(fixture(generatedAt: 1_700_000_300)))
        let issued: Int64 = 1_699_999_940
        XCTAssertNoThrow(try verify(fixture(generatedAt: issued, expiresAt: issued + 90 * 86_400)))
        for expiration in [issued, issued - 1, issued + 90 * 86_400 + 1] {
            let invalid = try fixture(generatedAt: issued, expiresAt: expiration)
            assertFailure(.invalidLifetime) { _ = try self.verify(invalid) }
        }
    }

    func testAnchorValidityWindowAndMinimumAppVersionRemainEnforced() throws {
        let original = try fixture()
        for anchor in [KnowledgeBaseTrustAnchor(keyID: original.anchor.keyID, publicKey: original.anchor.publicKey,
                                                validFrom: 1_699_999_970),
                       KnowledgeBaseTrustAnchor(keyID: original.anchor.keyID, publicKey: original.anchor.publicKey,
                                                expiresAt: 1_700_000_000)] {
            assertFailure(.invalidLifetime) {
                _ = try RuleConfigurationVerifier(trustAnchors: [anchor]).verify(original.signed,
                    appVersion: "1.0.0", now: self.now)
            }
        }
        let newerApp = try fixture(minimumApp: "2.0.0")
        assertFailure(.minimumAppVersionNotMet) { _ = try self.verify(newerApp) }
    }

    func testUnsupportedSchemaMalformedSequenceAndDigestAreRejected() throws {
        let unsupported = try fixture(schemaVersion: 2)
        assertFailure(.unsupportedSchema) { _ = try self.verify(unsupported) }
        let zeroSequence = try fixture(sequence: 0)
        assertFailure(.malformedManifest) { _ = try self.verify(zeroSequence) }
        let malformedDigest = try fixture(digestOverride: String(repeating: "z", count: 64))
        assertFailure(.malformedManifest) { _ = try self.verify(malformedDigest) }
    }

    func testSignedPayloadCannotAddProseActionsOrDetectorCode() throws {
        let bytes = try VersionedRuleSet.defaultConfiguration.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for unauthorizedField in ["prose", "actions", "detectorCode", "severity"] {
            var changed = object
            var rules = try XCTUnwrap(changed["rules"] as? [[String: Any]])
            rules[0][unauthorizedField] = "unreviewed supplied value"
            changed["rules"] = rules
            let signed = try fixture(payloadOverride: JSONSerialization.data(withJSONObject: changed))
            assertFailure(.malformedPayload) { _ = try self.verify(signed) }
        }
    }

    func testSignedPayloadStillRejectsDuplicateRulesAndUnsafeThresholds() throws {
        let bytes = try VersionedRuleSet.defaultConfiguration.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var duplicate = object
        var rules = try XCTUnwrap(duplicate["rules"] as? [[String: Any]])
        rules[1] = rules[0]
        duplicate["rules"] = rules
        let duplicated = try fixture(payloadOverride: JSONSerialization.data(withJSONObject: duplicate))
        assertFailure(.malformedPayload) { _ = try self.verify(duplicated) }
        var unsafe = object
        rules = try XCTUnwrap(unsafe["rules"] as? [[String: Any]])
        let crossAppIndex = try XCTUnwrap(rules.firstIndex { $0["id"] as? String == DetectorRuleID.crossApp.rawValue })
        rules[crossAppIndex]["parameters"] = ["minimumDistinctApps": 1]
        unsafe["rules"] = rules
        let invalid = try fixture(payloadOverride: JSONSerialization.data(withJSONObject: unsafe))
        assertFailure(.malformedPayload) { _ = try self.verify(invalid) }
        let normalized = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let duplicateRawVersion = normalized.replacingOccurrences(of: "\"version\":\"1.0.0\"",
            with: "\"version\":\"1.0.0\",\"v\\u0065rsion\":\"1.0.0\"")
        XCTAssertNotEqual(normalized, duplicateRawVersion)
        let duplicateRaw = try fixture(payloadOverride: Data(duplicateRawVersion.utf8))
        assertFailure(.malformedPayload) { _ = try self.verify(duplicateRaw) }
    }

    func testPayloadVersionMustMatchAuthenticatedManifest() throws {
        let mismatch = try fixture(payloadVersion: "1.0.1")
        assertFailure(.metadataMismatch) { _ = try self.verify(mismatch) }
    }

    func testFreshReplayIsRejectedAndAcceptedExactRestoreSucceeds() throws {
        let original = try fixture()
        let accepted = try verify(original)
        assertFailure(.invalidHighWaterMark) { _ = try self.verify(original, restoring: true) }
        assertFailure(.rollbackRejected) { _ = try self.verify(original, highWater: accepted.highWaterMark) }
        let restored = try verify(original, highWater: accepted.highWaterMark, restoring: true)
        XCTAssertEqual(restored.configuration, accepted.configuration)
        XCTAssertEqual(restored.highWaterMark, accepted.highWaterMark)
    }

    func testUpgradeRequiresBothIncreasingSequenceAndSemanticVersion() throws {
        let original = try fixture()
        let accepted = try verify(original)
        let upgrade = try fixture(version: "1.0.1", sequence: 8, key: original.key)
        let upgraded = try verify(upgrade, highWater: accepted.highWaterMark)
        XCTAssertEqual(upgraded.highWaterMark.sequence, 8)
        XCTAssertEqual(upgraded.highWaterMark.configurationVersion, "1.0.1")
        for value in [try fixture(version: "1.0.0", sequence: 8, key: original.key),
                      try fixture(version: "0.9.9", sequence: 8, key: original.key),
                      try fixture(version: "1.0.1", sequence: 6, key: original.key)] {
            assertFailure(.rollbackRejected) { _ = try self.verify(value, highWater: accepted.highWaterMark) }
        }
    }

    func testRestoreCannotAcceptAnUnacceptedNewerConfiguration() throws {
        let original = try fixture()
        let accepted = try verify(original)
        let unaccepted = try fixture(version: "1.0.1", sequence: 8, key: original.key)
        assertFailure(.rollbackRejected) {
            _ = try self.verify(unaccepted, highWater: accepted.highWaterMark, restoring: true)
        }
    }

    func testSameVersionManifestLifetimeChangeIsEquivocationIncludingDuringRestore() throws {
        let original = try fixture()
        let accepted = try verify(original)
        let changed = try fixture(expiresAt: original.signed.manifest.expiresAt + 1, key: original.key)
        XCTAssertEqual(changed.signed.manifest.payloadSHA256, original.signed.manifest.payloadSHA256)
        for restoring in [false, true] {
            assertFailure(.equivocationRejected) {
                _ = try self.verify(changed, highWater: accepted.highWaterMark, restoring: restoring)
            }
        }
    }

    func testInvalidStoredHighWaterMarksCannotAuthorizeRollbackOrRestore() throws {
        let original = try fixture()
        let valid = try verify(original).highWaterMark
        let invalid = [
            RuleConfigurationHighWaterMark(sequence: 0, configurationVersion: valid.configurationVersion,
                payloadSHA256: valid.payloadSHA256, manifestSHA256: valid.manifestSHA256),
            RuleConfigurationHighWaterMark(sequence: valid.sequence, configurationVersion: "invalid",
                payloadSHA256: valid.payloadSHA256, manifestSHA256: valid.manifestSHA256),
            RuleConfigurationHighWaterMark(sequence: valid.sequence, configurationVersion: valid.configurationVersion,
                payloadSHA256: String(repeating: "g", count: 64), manifestSHA256: valid.manifestSHA256),
            RuleConfigurationHighWaterMark(sequence: valid.sequence, configurationVersion: valid.configurationVersion,
                payloadSHA256: valid.payloadSHA256, manifestSHA256: "too-short")
        ]
        for mark in invalid {
            assertFailure(.invalidHighWaterMark) { _ = try self.verify(original, highWater: mark, restoring: true) }
        }
    }

    func testUnknownAndDuplicateEnvelopeOrManifestFieldsAreRejectedBeforeSelection() throws {
        let original = try fixture()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original.signed.encoded()) as? [String: Any])
        var unknownEnvelope = object
        unknownEnvelope["alternativeTrustRoot"] = "unreviewed"
        XCTAssertThrowsError(try SignedRuleConfiguration.decode(JSONSerialization.data(withJSONObject: unknownEnvelope)))
        var unknownManifest = object
        var manifest = try XCTUnwrap(unknownManifest["manifest"] as? [String: Any])
        manifest["arbitraryDetector"] = "unreviewed"
        unknownManifest["manifest"] = manifest
        XCTAssertThrowsError(try SignedRuleConfiguration.decode(JSONSerialization.data(withJSONObject: unknownManifest)))
        let normalized = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let duplicateManifestField = normalized.replacingOccurrences(of: "\"schemaVersion\":1",
            with: "\"schemaVersion\":1,\"\\u0073chemaVersion\":1")
        XCTAssertNotEqual(duplicateManifestField, normalized)
        XCTAssertThrowsError(try SignedRuleConfiguration.decode(Data(duplicateManifestField.utf8)))
    }

    func testOversizedPayloadIsRejectedWithoutDecoding() throws {
        let value = try fixture(payloadOverride: Data(repeating: 32, count: DeclarativeRuleConfiguration.maximumDocumentBytes + 1))
        assertFailure(.oversized) { _ = try self.verify(value) }
        assertFailure(.oversized) {
            _ = try SignedRuleConfiguration.decode(Data(repeating: 32, count: SignedRuleConfiguration.maximumEncodedBytes + 1))
        }
        let original = try fixture()
        let m = original.signed.manifest
        let oversizedManifest = RuleConfigurationManifest(configurationVersion: m.configurationVersion, sequence: m.sequence,
            generatedAt: m.generatedAt, expiresAt: m.expiresAt, minimumAppVersion: m.minimumAppVersion,
            payloadSHA256: m.payloadSHA256, signingKeyID: String(repeating: "a", count: 4_100),
            signatureBase64: m.signatureBase64)
        assertFailure(.oversized) {
            _ = try original.verifier.verify(.init(manifest: oversizedManifest, payloadData: original.signed.payloadData),
                appVersion: "1.0.0", now: self.now)
        }
    }
}
