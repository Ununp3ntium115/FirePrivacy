import Foundation
import CryptoKit
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp

/// Genuine CryptoKit signatures exercise the native engine and authenticated
/// encrypted cache. Every key, credential, cleanup path, clock and transport is
/// isolated; no live endpoint or operating-system protection is enabled.
final class SignedRulesEngineTests: XCTestCase {
    @MainActor
    func testSignedInstallChangesFindingsAndIdenticalUpdateDoesNotRewriteHistoryOrCache() async throws {
        let fixture = try fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await importReport(into: engine, fixture: fixture)
        let original = try XCTUnwrap(engine.analysis)
        XCTAssertTrue(hasCrossApp(original))
        let originalRevision = try XCTUnwrap(engine.latestAnalysisRevision)
        let configuration = try configuration(version: "1.0.1", minimumApps: 4)
        let signed = try fixture.rules(configuration: configuration, sequence: 10)

        try await engine.installRuleConfiguration(signed)
        XCTAssertEqual(engine.ruleConfiguration, configuration)
        XCTAssertFalse(engine.ruleConfigurationFailure)
        let changed = try XCTUnwrap(engine.analysis)
        XCTAssertEqual(changed.rulesetVersion, configuration.analysisVersion)
        XCTAssertNotEqual(changed.rulesetVersion, original.rulesetVersion)
        XCTAssertFalse(hasCrossApp(changed), "The accepted threshold must control the real engine, not only its cache.")
        let changedRevision = try XCTUnwrap(engine.latestAnalysisRevision)
        let change = try XCTUnwrap(changedRevision.comparison)
        XCTAssertTrue(change.dimensions.contains(.rulesetVersion))
        XCTAssertTrue(change.isSameEvidenceReanalysis)
        XCTAssertEqual(changedRevision.inputs.normalizedEvidenceSHA256, originalRevision.inputs.normalizedEvidenceSHA256)
        XCTAssertEqual(changedRevision.evaluatedAt, fixture.clock.read())
        let history = engine.analysisHistory
        let before = try Data(contentsOf: fixture.rulesCacheURL)
        let ciphertextText = String(decoding: before, as: UTF8.self)
        XCTAssertFalse(ciphertextText.contains("minimumDistinctApps"))
        XCTAssertFalse(ciphertextText.contains(configuration.digest))
        XCTAssertFalse(ciphertextText.contains(SignedRulesFixture.rulesKeyID))
        let savedValue = try await fixture.store.loadFeatureState(SignedRulesStoredCache.self, key: "analysis-rules")
        let saved = try XCTUnwrap(savedValue)
        XCTAssertEqual(saved.signed, signed)
        XCTAssertEqual(saved.highWaterMark, engine.verifiedRuleConfiguration?.highWaterMark)

        fixture.clock.advance(by: 1)
        try await engine.installRuleConfiguration(signed)
        XCTAssertEqual(engine.analysis, changed)
        XCTAssertEqual(engine.latestAnalysisRevision, changedRevision)
        XCTAssertEqual(engine.analysisHistory, history)
        XCTAssertEqual(try Data(contentsOf: fixture.rulesCacheURL), before)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testGenuinelyResignedSameReleaseMetadataCannotReplaceAcceptedState() async throws {
        let fixture = try fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await importReport(into: engine, fixture: fixture)
        let configuration = try configuration(version: "1.0.1", minimumApps: 4)
        let accepted = try fixture.rules(configuration: configuration, sequence: 10, lifetime: 1_200)
        try await engine.installRuleConfiguration(accepted)
        let originalAnalysis = engine.analysis, originalHistory = engine.analysisHistory
        let originalWater = try XCTUnwrap(engine.verifiedRuleConfiguration?.highWaterMark)
        let originalBytes = try Data(contentsOf: fixture.rulesCacheURL)
        let substituted = try fixture.rules(configuration: configuration, sequence: 10, lifetime: 1_260)
        XCTAssertEqual(substituted.payloadData, accepted.payloadData)
        XCTAssertNotEqual(substituted.manifest.signatureBase64, accepted.manifest.signatureBase64)
        // Both signatures are authentic; the attack is extending metadata for
        // an already accepted sequence, rather than corrupting a signature.
        XCTAssertNoThrow(try fixture.ruleVerifier.verify(substituted, appVersion: "1.0.0", now: fixture.clock.read()))
        do {
            try await engine.installRuleConfiguration(substituted)
            XCTFail("An authentic same-sequence lifetime change must be rejected.")
        } catch { XCTAssertEqual(error as? RuleConfigurationVerifier.Failure, .equivocationRejected) }
        XCTAssertEqual(engine.ruleConfiguration, configuration)
        XCTAssertFalse(engine.ruleConfigurationFailure)
        XCTAssertEqual(engine.verifiedRuleConfiguration?.highWaterMark, originalWater)
        XCTAssertEqual(engine.analysis, originalAnalysis)
        XCTAssertEqual(engine.analysisHistory, originalHistory)
        XCTAssertEqual(try Data(contentsOf: fixture.rulesCacheURL), originalBytes)
        let saved = try await fixture.store.loadFeatureState(SignedRulesStoredCache.self, key: "analysis-rules")
        XCTAssertEqual(saved?.signed, accepted)
        XCTAssertEqual(saved?.highWaterMark, originalWater)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testEncryptedRestoreReauthenticatesExactAcceptedReleaseWithoutNewRevision() async throws {
        let fixture = try fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        let imported = try await importReport(into: engine, fixture: fixture)
        let configuration = try configuration(version: "1.0.1", minimumApps: 4)
        let signed = try fixture.rules(configuration: configuration, sequence: 10)
        try await engine.installRuleConfiguration(signed)
        let water = try XCTUnwrap(engine.verifiedRuleConfiguration?.highWaterMark)
        let revision = try XCTUnwrap(engine.latestAnalysisRevision)
        let history = engine.analysisHistory
        let cacheBytes = try Data(contentsOf: fixture.rulesCacheURL)
        fixture.clock.advance(by: 10)

        // Reuse the store actor that owns this directory, with fresh engine
        // state. Restoration still decrypts/reverifies the persisted features.
        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertEqual(restored.report?.id, imported.id)
        XCTAssertEqual(restored.ruleConfiguration, configuration)
        XCTAssertFalse(restored.ruleConfigurationFailure)
        XCTAssertEqual(restored.verifiedRuleConfiguration?.highWaterMark, water)
        XCTAssertEqual(restored.verifiedRuleConfiguration?.signed, signed)
        XCTAssertEqual(restored.analysis?.rulesetVersion, configuration.analysisVersion)
        XCTAssertFalse(hasCrossApp(try XCTUnwrap(restored.analysis)))
        XCTAssertEqual(restored.latestAnalysisRevision, revision)
        XCTAssertEqual(restored.analysisHistory, history)
        XCTAssertEqual(try Data(contentsOf: fixture.rulesCacheURL), cacheBytes)
        let events = await restored.gate.ledger.snapshot(), calls = await fixture.transport.callCount()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testExpiredReleaseFallsBackVisiblyWhileRetainedHighWaterRejectsRollback() async throws {
        let fixture = try fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await importReport(into: engine, fixture: fixture)
        let configuration = try configuration(version: "2.0.0", minimumApps: 4)
        let accepted = try fixture.rules(configuration: configuration, sequence: 20, lifetime: 60)
        try await engine.installRuleConfiguration(accepted)
        let water = try XCTUnwrap(engine.verifiedRuleConfiguration?.highWaterMark)
        let savedBytes = try Data(contentsOf: fixture.rulesCacheURL)
        fixture.clock.advance(by: 60)

        try await engine.rebuildAnalysis()
        XCTAssertEqual(engine.ruleConfiguration, VersionedRuleSet.defaultConfiguration)
        XCTAssertTrue(engine.ruleConfigurationFailure)
        XCTAssertNil(engine.verifiedRuleConfiguration)
        XCTAssertTrue(hasCrossApp(try XCTUnwrap(engine.analysis)))
        XCTAssertEqual(engine.latestAnalysisRevision?.evaluatedAt, fixture.clock.read())
        let storedValue = try await fixture.store.loadFeatureState(SignedRulesStoredCache.self, key: "analysis-rules")
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.highWaterMark, water)
        XCTAssertEqual(stored.signed, accepted)
        XCTAssertEqual(try Data(contentsOf: fixture.rulesCacheURL), savedBytes)

        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertTrue(restored.ruleConfigurationFailure)
        XCTAssertEqual(restored.ruleConfiguration, VersionedRuleSet.defaultConfiguration)
        XCTAssertNil(restored.verifiedRuleConfiguration)
        let older = try fixture.rules(configuration: self.configuration(version: "1.0.1", minimumApps: 4), sequence: 19)
        XCTAssertNoThrow(try fixture.ruleVerifier.verify(older, appVersion: "1.0.0", now: fixture.clock.read()))
        do {
            try await restored.installRuleConfiguration(older)
            XCTFail("Expiry must not erase the persisted release high-water mark.")
        } catch { XCTAssertEqual(error as? RuleConfigurationVerifier.Failure, .rollbackRejected) }
        XCTAssertTrue(restored.ruleConfigurationFailure)
        XCTAssertEqual(try Data(contentsOf: fixture.rulesCacheURL), savedBytes)

        let renewedConfiguration = try self.configuration(version: "2.0.1", minimumApps: 5)
        let renewed = try fixture.rules(configuration: renewedConfiguration, sequence: 21)
        try await restored.installRuleConfiguration(renewed)
        XCTAssertEqual(restored.ruleConfiguration, renewedConfiguration)
        XCTAssertFalse(restored.ruleConfigurationFailure)
        XCTAssertEqual(restored.verifiedRuleConfiguration?.highWaterMark.sequence, 21)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testSignerRevocationInvalidatesRulesAndKnowledgeAndCannotBeRemovedOnRestart() async throws {
        let fixture = try fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await importReport(into: engine, fixture: fixture)
        let accepted = try fixture.rules(configuration: configuration(version: "1.0.1", minimumApps: 4), sequence: 10)
        try await engine.installRuleConfiguration(accepted)
        let knowledge = try fixture.knowledge(version: "2.0.0", sequence: 2)
        try await engine.installKnowledgeBase(manifest: knowledge.manifest, payload: knowledge.payload)
        XCTAssertNotNil(engine.knowledgeBase)
        let denials = KnowledgeBaseRevocations(revokedKeyIDs: [SignedRulesFixture.rulesKeyID])
        let revocations = try fixture.revocations(denials, sequence: 1)
        try await engine.installKnowledgeBaseRevocations(revocations)
        XCTAssertEqual(engine.knowledgeBaseRevocations, denials)
        XCTAssertTrue(engine.knowledgeBaseRevocationsCurrent)
        XCTAssertNil(engine.knowledgeBase)
        XCTAssertTrue(engine.knowledgeBaseFailure)
        XCTAssertEqual(engine.ruleConfiguration, VersionedRuleSet.defaultConfiguration)
        XCTAssertTrue(engine.ruleConfigurationFailure)
        XCTAssertNil(engine.verifiedRuleConfiguration)

        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertEqual(restored.knowledgeBaseRevocations, denials)
        XCTAssertTrue(restored.knowledgeBaseRevocationsCurrent)
        XCTAssertTrue(restored.ruleConfigurationFailure)
        XCTAssertNil(restored.verifiedRuleConfiguration)
        let newer = try fixture.rules(configuration: configuration(version: "1.0.2", minimumApps: 5), sequence: 11)
        do {
            try await restored.installRuleConfiguration(newer)
            XCTFail("A newer release from a revoked signer must remain denied.")
        } catch { XCTAssertEqual(error as? RuleConfigurationVerifier.Failure, .revoked) }
        let newKnowledge = try fixture.knowledge(version: "2.0.1", sequence: 3)
        do {
            try await restored.installKnowledgeBase(manifest: newKnowledge.manifest, payload: newKnowledge.payload)
            XCTFail("The same operator revocation must deny knowledge updates too.")
        } catch { XCTAssertEqual(error as? KnowledgeBaseVerifier.Failure, .revoked) }
        let removal = try fixture.revocations(KnowledgeBaseRevocations(), sequence: 2)
        do {
            try await restored.installKnowledgeBaseRevocations(removal)
            XCTFail("A new signed revocation document cannot silently remove an existing denial.")
        } catch { XCTAssertEqual(error as? KnowledgeBaseRevocationVerifier.Failure, .stickyRevocationRemoved) }
        XCTAssertEqual(restored.knowledgeBaseRevocations, denials)
        let savedRevocation = try await fixture.store.loadFeatureState(SignedRulesRevocationCache.self, key: "kb-revocations")
        XCTAssertEqual(savedRevocation?.highWaterMark.revocations, denials)
        let savedRules = try await fixture.store.loadFeatureState(SignedRulesStoredCache.self, key: "analysis-rules")
        XCTAssertEqual(savedRules?.signed, accepted)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testPayloadRevocationDeniesResigningButAllowsDifferentReviewedPayload() async throws {
        let fixture = try fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await importReport(into: engine, fixture: fixture)
        let configuration = try configuration(version: "1.0.1", minimumApps: 4)
        let accepted = try fixture.rules(configuration: configuration, sequence: 10)
        try await engine.installRuleConfiguration(accepted)
        let denials = KnowledgeBaseRevocations(revokedPayloadDigests: [accepted.manifest.payloadSHA256])
        try await engine.installKnowledgeBaseRevocations(fixture.revocations(denials, sequence: 1))
        XCTAssertTrue(engine.ruleConfigurationFailure)
        XCTAssertEqual(engine.ruleConfiguration, VersionedRuleSet.defaultConfiguration)
        let resigned = try fixture.rules(configuration: configuration, sequence: 11, useRevocationSigner: true)
        XCTAssertEqual(resigned.manifest.payloadSHA256, accepted.manifest.payloadSHA256)
        XCTAssertNotEqual(resigned.manifest.signingKeyID, accepted.manifest.signingKeyID)
        do {
            try await engine.installRuleConfiguration(resigned)
            XCTFail("Changing the signer must not reauthorize revoked payload bytes.")
        } catch { XCTAssertEqual(error as? RuleConfigurationVerifier.Failure, .revoked) }
        let freshConfiguration = try self.configuration(version: "1.0.2", minimumApps: 5)
        let fresh = try fixture.rules(configuration: freshConfiguration, sequence: 11, useRevocationSigner: true)
        try await engine.installRuleConfiguration(fresh)
        XCTAssertEqual(engine.ruleConfiguration, freshConfiguration)
        XCTAssertFalse(engine.ruleConfigurationFailure)
        XCTAssertEqual(engine.knowledgeBaseRevocations, denials)
        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertEqual(restored.ruleConfiguration, freshConfiguration)
        XCTAssertEqual(restored.knowledgeBaseRevocations, denials)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testExpiredRevocationDocumentBlocksEvenUnrevokedNewRulesAndKnowledgeUntilRenewal() async throws {
        let fixture = try fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await importReport(into: engine, fixture: fixture)
        let original = try fixture.rules(configuration: configuration(version: "1.0.1", minimumApps: 4), sequence: 10)
        try await engine.installRuleConfiguration(original)
        let revocations = try fixture.revocations(KnowledgeBaseRevocations(), sequence: 1, lifetime: 60)
        try await engine.installKnowledgeBaseRevocations(revocations)
        fixture.clock.advance(by: 60)
        let freshConfiguration = try configuration(version: "1.0.2", minimumApps: 5)
        let freshRules = try fixture.rules(configuration: freshConfiguration, sequence: 11, useRevocationSigner: true)
        let freshKnowledge = try fixture.knowledge(version: "2.0.0", sequence: 2, useRevocationSigner: true)
        XCTAssertNoThrow(try fixture.ruleVerifier.verify(freshRules, appVersion: "1.0.0", now: fixture.clock.read()))
        XCTAssertNoThrow(try KnowledgeBaseVerifier(trustAnchors: fixture.trust.verifierAnchors).verify(
            manifestData: freshKnowledge.manifest, payloadData: freshKnowledge.payload, appVersion: "1.0.0", now: fixture.clock.read()))
        let cacheBefore = try Data(contentsOf: fixture.rulesCacheURL)
        do {
            try await engine.installRuleConfiguration(freshRules)
            XCTFail("Expired revocation information must block unrevoked rule releases.")
        } catch { assertInvalidUpdate(error) }
        do {
            try await engine.installKnowledgeBase(manifest: freshKnowledge.manifest, payload: freshKnowledge.payload)
            XCTFail("Expired revocation information must block unrevoked knowledge releases.")
        } catch { assertInvalidUpdate(error) }
        XCTAssertFalse(engine.knowledgeBaseRevocationsCurrent)
        XCTAssertEqual(try Data(contentsOf: fixture.rulesCacheURL), cacheBefore)

        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertFalse(restored.knowledgeBaseRevocationsCurrent)
        do {
            try await restored.installRuleConfiguration(freshRules)
            XCTFail("Restart must not clear the expired-document block.")
        } catch { assertInvalidUpdate(error) }
        let renewed = try fixture.revocations(KnowledgeBaseRevocations(), sequence: 2)
        try await restored.installKnowledgeBaseRevocations(renewed)
        XCTAssertTrue(restored.knowledgeBaseRevocationsCurrent)
        try await restored.installRuleConfiguration(freshRules)
        try await restored.installKnowledgeBase(manifest: freshKnowledge.manifest, payload: freshKnowledge.payload)
        XCTAssertEqual(restored.ruleConfiguration, freshConfiguration)
        XCTAssertFalse(restored.ruleConfigurationFailure)
        XCTAssertEqual(restored.knowledgeBase?.version, "2.0.0")
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    private func configuration(version: String, minimumApps: Int) throws -> DeclarativeRuleConfiguration {
        try .init(version: version, rules: VersionedRuleSet.defaultConfiguration.rules.map {
            $0.id == .crossApp ? try DeclarativeRule(id: .crossApp, parameters: .crossApp(minimumDistinctApps: minimumApps)) : $0
        })
    }
    private func hasCrossApp(_ analysis: FindingAnalysis) -> Bool { analysis.findings.contains { $0.ruleID == DetectorRuleID.crossApp.rawValue } }

    @MainActor
    @discardableResult
    private func importReport(into engine: FirePrivacyEngine, fixture: SignedRulesFixture) async throws -> PrivacyReport {
        _ = try await engine.restore()
        XCTAssertFalse(engine.datasetTrustConfigurationFailure)
        try await engine.grant(.localImport, scope: "local-import-v1")
        let lines = ["alpha", "beta", "gamma"].map {
            "{\"type\":\"networkActivity\",\"bundleID\":\"example.signedrules.\($0)\",\"domain\":\"private-rules.example\",\"hits\":1}"
        }
        let report = try ReportImporter.parse(Data(lines.joined(separator: "\n").utf8),
            importedAt: fixture.clock.read().addingTimeInterval(-3_600))
        _ = try await engine.importReport(report)
        return report
    }

    private func assertInvalidUpdate(_ error: any Error, file: StaticString = #filePath, line: UInt = #line) {
        if case .invalidUpdate? = error as? EngineError {} else {
            XCTFail("Expected invalidUpdate while revocation information is expired.", file: file, line: line)
        }
    }

    @MainActor
    private func fixture() throws -> SignedRulesFixture {
        let root = FileManager().temporaryDirectory.appendingPathComponent("SignedRulesEngineTests-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("private-store", isDirectory: true)
        let rulesKey = Curve25519.Signing.PrivateKey(), revocationKey = Curve25519.Signing.PrivateKey()
        let anchors = KnowledgeBaseResources.trustAnchors + [
            KnowledgeBaseTrustAnchor(keyID: SignedRulesFixture.rulesKeyID, publicKey: rulesKey.publicKey.rawRepresentation),
            KnowledgeBaseTrustAnchor(keyID: SignedRulesFixture.revocationKeyID, publicKey: revocationKey.publicKey.rawRepresentation)]
        return SignedRulesFixture(root: root, storage: storage,
            store: EncryptedReportStore(directoryURL: storage, keyProvider: SignedRulesMemoryKeys()),
            transport: SignedRulesForbiddenTransport(), credentials: AdvisorCredentialStore(provider: SignedRulesMemoryCredentials()),
            cleanup: ProtectionCleanupPlan(directory: root.appendingPathComponent("system-cleanup", isDirectory: true)),
            credentialCleanup: CredentialCleanupMarker(directory: root.appendingPathComponent("credential-cleanup", isDirectory: true)),
            trust: try DatasetTrustConfiguration(pinnedKnowledgeAnchors: anchors, pinnedFilterKeys: [:]),
            clock: SignedRulesClock(Date(timeIntervalSince1970: 1_791_242_400)), rulesKey: rulesKey, revocationKey: revocationKey)
    }
}

private struct SignedRulesStoredCache: Codable, Equatable, Sendable {
    let signed: SignedRuleConfiguration
    let highWaterMark: RuleConfigurationHighWaterMark
}
private struct SignedRulesRevocationCache: Codable, Sendable {
    let signed: SignedKnowledgeBaseRevocations
    let highWaterMark: KnowledgeBaseRevocationHighWaterMark
}

@MainActor
private struct SignedRulesFixture {
    static let rulesKeyID = "signed-rules-engine-primary"
    static let revocationKeyID = "signed-rules-engine-revocations"
    let root: URL
    let storage: URL
    let store: EncryptedReportStore
    let transport: SignedRulesForbiddenTransport
    let credentials: AdvisorCredentialStore
    let cleanup: ProtectionCleanupPlan
    let credentialCleanup: CredentialCleanupMarker
    let trust: DatasetTrustConfiguration
    let clock: SignedRulesClock
    let rulesKey: Curve25519.Signing.PrivateKey
    let revocationKey: Curve25519.Signing.PrivateKey
    var rulesCacheURL: URL { storage.appendingPathComponent("features/analysis-rules.encrypted") }
    var ruleVerifier: RuleConfigurationVerifier { .init(trustAnchors: trust.verifierAnchors) }

    func engine() -> FirePrivacyEngine {
        let clock = clock
        return FirePrivacyEngine(store: store, transport: transport, cleanupPlan: cleanup,
            credentialStore: credentials, credentialCleanupMarker: credentialCleanup,
            datasetTrustConfiguration: trust, now: { clock.read() })
    }
    func removeTemporaryFiles() { try? FileManager().removeItem(at: root) }

    func rules(configuration: DeclarativeRuleConfiguration, sequence: Int64, lifetime: Int64 = 1_200,
               useRevocationSigner: Bool = false) throws -> SignedRuleConfiguration {
        let bytes = try configuration.encoded(), issued = Int64(clock.read().timeIntervalSince1970)
        let id = useRevocationSigner ? Self.revocationKeyID : Self.rulesKeyID
        let key = useRevocationSigner ? revocationKey : rulesKey
        let unsigned = RuleConfigurationManifest(configurationVersion: configuration.version, sequence: sequence,
            generatedAt: issued, expiresAt: issued + lifetime, minimumAppVersion: "1.0.0",
            payloadSHA256: ContentDigest.sha256(bytes), signingKeyID: id, signatureBase64: "")
        let signature = try key.signature(for: unsigned.signingRepresentation)
        let manifest = RuleConfigurationManifest(configurationVersion: unsigned.configurationVersion, sequence: unsigned.sequence,
            generatedAt: unsigned.generatedAt, expiresAt: unsigned.expiresAt, minimumAppVersion: unsigned.minimumAppVersion,
            payloadSHA256: unsigned.payloadSHA256, signingKeyID: unsigned.signingKeyID, signatureBase64: signature.base64EncodedString())
        return .init(manifest: manifest, payloadData: bytes)
    }

    func revocations(_ denied: KnowledgeBaseRevocations, sequence: Int64,
                     lifetime: Int64 = 1_200) throws -> SignedKnowledgeBaseRevocations {
        let bytes = try JSONEncoder().encode(KnowledgeBaseRevocationPayload(sequence: sequence, revocations: denied))
        let issued = Int64(clock.read().timeIntervalSince1970)
        let count = denied.revokedKeyIDs.count + denied.revokedVersions.count + denied.revokedPayloadDigests.count
        let unsigned = KnowledgeBaseRevocationManifest(sequence: sequence, generatedAt: issued, expiresAt: issued + lifetime,
            revocationCount: count, payloadByteCount: bytes.count, payloadSHA256: ContentDigest.sha256(bytes),
            signingKeyID: Self.revocationKeyID, signatureBase64: "")
        let signature = try revocationKey.signature(for: unsigned.signingRepresentation)
        let manifest = KnowledgeBaseRevocationManifest(sequence: unsigned.sequence, generatedAt: unsigned.generatedAt,
            expiresAt: unsigned.expiresAt, revocationCount: unsigned.revocationCount, payloadByteCount: unsigned.payloadByteCount,
            payloadSHA256: unsigned.payloadSHA256, signingKeyID: unsigned.signingKeyID, signatureBase64: signature.base64EncodedString())
        return .init(manifestData: try JSONEncoder().encode(manifest), payloadData: bytes)
    }

    func knowledge(version: String, sequence: Int64, useRevocationSigner: Bool = false) throws -> (manifest: Data, payload: Data) {
        let payload = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "datasetVersion": version,
            "sources": [], "classifications": []], options: [.sortedKeys])
        let issued = Int64(clock.read().timeIntervalSince1970)
        let id = useRevocationSigner ? Self.revocationKeyID : Self.rulesKeyID
        let key = useRevocationSigner ? revocationKey : rulesKey
        var fields: [String: Any] = ["schemaVersion": 1, "datasetVersion": version, "sequence": sequence,
            "generatedAt": issued, "expiresAt": issued + 1_200, "minimumAppVersion": "1.0.0", "recordCount": 0,
            "payloadSHA256": ContentDigest.sha256(payload), "signingKeyID": id, "signatureBase64": ""]
        let unsigned = try JSONDecoder().decode(KnowledgeBaseManifest.self,
            from: JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        fields["signatureBase64"] = try key.signature(for: unsigned.signingRepresentation).base64EncodedString()
        return (try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), payload)
    }
}

private final class SignedRulesClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}
private final class SignedRulesMemoryKeys: ReportKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func readKey() throws -> Data? { lock.withLock { value } }
    func storeKey(_ key: Data) throws {
        try lock.withLock {
            guard value == nil else { throw ReportStoreError.keyUnavailable }
            value = key
        }
    }
    func deleteKey() throws { lock.withLock { value = nil } }
}
private actor SignedRulesMemoryCredentials: AdvisorCredentialProvider {
    private var values: [String: Data] = [:]
    func read(identity: String) async throws -> Data? { values[identity] }
    func store(_ token: Data, identity: String) async throws { values[identity] = token }
    func delete(identity: String) async throws { values.removeValue(forKey: identity) }
    func deleteAll() async throws { values.removeAll() }
}
private enum SignedRulesFixtureError: Error { case unexpectedTransmission }
private actor SignedRulesForbiddenTransport: ApprovedRequestTransport {
    private var calls = 0
    func send(_ request: ApprovedNetworkRequest, permit: NetworkTransmissionPermit,
              maximumResponseBytes: Int) async throws -> ApprovedNetworkResponse {
        calls += 1
        throw SignedRulesFixtureError.unexpectedTransmission
    }
    func callCount() -> Int { calls }
}
