import Foundation
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp

/// Uses the actual native engine/encrypted store with isolated keys, credentials,
/// cleanup files and a transport that fails if anything attempts transmission.
final class NativeAnalysisHistoryTests: XCTestCase {
    @MainActor
    func testEncryptedRevisionRestoresWithoutCreatingWallClockRevision() async throws {
        let fixture = fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await authorizeImport(engine)
        let report = try report(1)
        _ = try await engine.importReport(report)
        let first = try XCTUnwrap(engine.latestAnalysisRevision)
        XCTAssertFalse(first.lifecycle.current.isEmpty)
        XCTAssertTrue(first.lifecycle.current.allSatisfy { $0.status == .new })

        let encrypted = fixture.storage.appendingPathComponent("features/analysis-history.encrypted")
        XCTAssertTrue(FileManager().fileExists(atPath: encrypted.path))
        let encryptedText = String(decoding: try Data(contentsOf: encrypted), as: UTF8.self)
        XCTAssertFalse(encryptedText.contains("private-history-1.example"))
        XCTAssertFalse(encryptedText.contains("example.history.alpha"))

        let restoredEngine = fixture.engine()
        _ = try await restoredEngine.restore()
        XCTAssertEqual(restoredEngine.report?.id, report.id)
        XCTAssertEqual(restoredEngine.latestAnalysisRevision, first)
        XCTAssertEqual(restoredEngine.lifecycle, first.lifecycle)
        XCTAssertEqual(restoredEngine.analysisHistory.records.count, 1)
        XCTAssertFalse(restoredEngine.analysisHistoryCapacityExceeded)
        let persisted = try await fixture.store.loadFeatureState(AnalysisHistory.self, key: "analysis-history")
        XCTAssertEqual(persisted, restoredEngine.analysisHistory)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testSelectingReportsPreservesEachPersistedRevision() async throws {
        let fixture = fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await authorizeImport(engine)
        let first = try report(1), second = try report(2)
        _ = try await engine.importReport(first)
        let firstRevision = try XCTUnwrap(engine.latestAnalysisRevision)
        _ = try await engine.importReport(second)
        let secondRevision = try XCTUnwrap(engine.latestAnalysisRevision)
        XCTAssertEqual(secondRevision.comparison?.earlierReportID, first.id)
        _ = try await engine.selectReport(first.id)
        XCTAssertEqual(engine.latestAnalysisRevision, firstRevision)
        _ = try await engine.selectReport(second.id)
        XCTAssertEqual(engine.latestAnalysisRevision, secondRevision)
        XCTAssertEqual(engine.analysisHistory.records.count, 2)

        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertEqual(restored.latestAnalysisRevision, secondRevision)
        XCTAssertEqual(restored.analysisHistory.records.count, 2)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testPreferenceRevisionAndAcknowledgmentRestoreWithoutChangingObservedFacts() async throws {
        let fixture = fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await authorizeImport(engine)
        _ = try await engine.importReport(report(1))
        let original = try XCTUnwrap(engine.latestAnalysisRevision)
        let key = try XCTUnwrap(original.analysis.findings.first?.lifecycleKey)
        var preferences = engine.preferences
        let oldProfile = preferences.profile
        preferences.profile = PrivacyProfile(id: oldProfile.id, name: oldProfile.name,
            trackingTolerance: 5, analyticsTolerance: 5, updatedAt: oldProfile.updatedAt)
        preferences.acceptedFindingKeys.insert(key)
        try await engine.savePreferences(preferences)
        let revised = try XCTUnwrap(engine.latestAnalysisRevision)
        let change = try XCTUnwrap(revised.comparison)
        XCTAssertTrue(change.dimensions.contains(.profile))
        XCTAssertTrue(change.dimensions.contains(.findingDecisions))
        XCTAssertFalse(change.normalizedEvidenceChanged)
        XCTAssertEqual(change.sourceBytesChanged, false)
        XCTAssertEqual(original.analysis.findings.map(\.observedFacts), revised.analysis.findings.map(\.observedFacts))
        XCTAssertEqual(original.analysis.findings.map(\.confidence), revised.analysis.findings.map(\.confidence))
        XCTAssertEqual(revised.lifecycle.current.first { $0.lifecycleKey == key }?.status, .accepted)

        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertEqual(restored.latestAnalysisRevision, revised)
        XCTAssertEqual(restored.lifecycle?.current.first { $0.lifecycleKey == key }?.status, .accepted)
        XCTAssertEqual(restored.analysisHistory.records.count, 2)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testDeletingBaselinePurgesItsComparisonFactsFromEncryptedHistory() async throws {
        let fixture = fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await authorizeImport(engine)
        let deleted = try report(1), retained = try report(2)
        _ = try await engine.importReport(deleted)
        _ = try await engine.importReport(retained)
        XCTAssertEqual(engine.latestAnalysisRevision?.comparison?.earlierReportID, deleted.id)
        XCTAssertTrue(try XCTUnwrap(engine.latestAnalysisRevision).lifecycle.previousOnly.contains {
            $0.subject == .domain("private-history-1.example")
        })
        try await engine.deleteReport(deleted.id)
        let persistedHistory = try await fixture.store.loadFeatureState(AnalysisHistory.self, key: "analysis-history")
        let history = try XCTUnwrap(persistedHistory)
        XCTAssertEqual(Set(history.records.map { $0.inputs.reportID }), [retained.id])
        XCTAssertNil(history.latest(for: retained.id)?.comparison)
        XCTAssertTrue(try XCTUnwrap(history.latest(for: retained.id)).lifecycle.previousOnly.isEmpty)
        let plaintext = String(decoding: try history.encoded(), as: UTF8.self)
        XCTAssertFalse(plaintext.contains("private-history-1.example"))
        XCTAssertFalse(plaintext.contains(deleted.id.uuidString))
        for observation in deleted.observations { XCTAssertFalse(plaintext.contains(observation.id.uuidString)) }

        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertEqual(restored.analysisHistory, history)
        XCTAssertEqual(restored.sessions.map(\.id), [retained.id])
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testRetentionEvictionAndDeletingLastReportPrunePersistedHistory() async throws {
        let fixture = fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await authorizeImport(engine)
        let oldest = try report(1), latest = try report(2)
        _ = try await engine.importReport(oldest)
        _ = try await engine.importReport(latest)
        var retention = engine.retention
        retention.maximumReports = 1
        try await engine.updateRetention(retention)
        XCTAssertEqual(engine.sessions.map(\.id), [latest.id])
        XCTAssertEqual(Set(engine.analysisHistory.records.map { $0.inputs.reportID }), [latest.id])
        let afterRetention = try await fixture.store.loadFeatureState(AnalysisHistory.self, key: "analysis-history")
        XCTAssertEqual(afterRetention, engine.analysisHistory)
        try await engine.deleteReport(latest.id)
        XCTAssertNil(engine.report)
        XCTAssertNil(engine.analysis)
        XCTAssertNil(engine.latestAnalysisRevision)
        XCTAssertTrue(engine.analysisHistory.records.isEmpty)
        let afterDeletion = try await fixture.store.loadFeatureState(AnalysisHistory.self, key: "analysis-history")
        XCTAssertTrue(try XCTUnwrap(afterDeletion).records.isEmpty)
        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertTrue(restored.analysisHistory.records.isEmpty)
        XCTAssertNil(restored.latestAnalysisRevision)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testDeletingOnlyRecurringBaselineResetsStatusAndPersistsThatReset() async throws {
        let fixture = fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await authorizeImport(engine)
        let first = try report(1, domain: "shared-history.example")
        let second = try report(2, domain: "shared-history.example")
        _ = try await engine.importReport(first)
        _ = try await engine.importReport(second)
        let recurring = try XCTUnwrap(engine.lifecycle?.current.first { $0.ruleID == "AGG-CROSSAPP-002" })
        XCTAssertEqual(recurring.status, .recurring)
        try await engine.deleteReport(first.id)
        XCTAssertEqual(engine.lifecycle?.current.first { $0.ruleID == "AGG-CROSSAPP-002" }?.status, .new)
        let restored = fixture.engine()
        _ = try await restored.restore()
        XCTAssertEqual(restored.lifecycle?.current.first { $0.ruleID == "AGG-CROSSAPP-002" }?.status, .new)
        XCTAssertEqual(restored.analysisHistory, engine.analysisHistory)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testSampleDoesNotPersistOrCompareUnrelatedPrivateReportFacts() async throws {
        let fixture = fixture()
        defer { fixture.removeTemporaryFiles() }
        let engine = fixture.engine()
        try await authorizeImport(engine)
        let privateReport = try report(1)
        _ = try await engine.importReport(privateReport)
        let history = engine.analysisHistory
        try await engine.showSample()
        XCTAssertEqual(engine.report?.metadata?.isSyntheticDemo, true)
        XCTAssertNotEqual(engine.report?.id, privateReport.id)
        XCTAssertNil(engine.latestAnalysisRevision)
        XCTAssertFalse(engine.analysisHistoryCapacityExceeded)
        XCTAssertEqual(engine.analysisHistory, history)
        let lifecycle = try XCTUnwrap(engine.lifecycle)
        let privateIDs = Set(privateReport.observations.map(\.id))
        XCTAssertTrue(lifecycle.previousOnly.isEmpty)
        XCTAssertFalse(lifecycle.current.flatMap(\.evidenceIDs).contains { privateIDs.contains($0) })
        let persisted = try await fixture.store.loadFeatureState(AnalysisHistory.self, key: "analysis-history")
        XCTAssertEqual(persisted, history)
        let calls = await fixture.transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    private func authorizeImport(_ engine: FirePrivacyEngine) async throws {
        _ = try await engine.restore()
        try await engine.grant(.localImport, scope: "local-import-v1")
    }

    private func report(_ number: Int, domain: String? = nil) throws -> PrivacyReport {
        let host = domain ?? "private-history-\(number).example"
        let lines = ["alpha", "beta", "gamma"].enumerated().map { index, app in
            "{\"type\":\"networkActivity\",\"bundleID\":\"example.history.\(app)\",\"domain\":\"\(host)\",\"hits\":\(number + index)}"
        }
        return try ReportImporter.parse(Data(lines.joined(separator: "\n").utf8),
            importedAt: Date().addingTimeInterval(-3_600 + Double(number)))
    }

    @MainActor
    private func fixture() -> NativeHistoryFixture {
        let root = FileManager().temporaryDirectory.appendingPathComponent("NativeAnalysisHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("private-store", isDirectory: true)
        return NativeHistoryFixture(root: root, storage: storage,
            store: EncryptedReportStore(directoryURL: storage, keyProvider: NativeHistoryMemoryKeys()),
            transport: NativeHistoryForbiddenTransport(),
            credentials: AdvisorCredentialStore(provider: NativeHistoryMemoryCredentials()),
            cleanup: ProtectionCleanupPlan(directory: root.appendingPathComponent("system-cleanup", isDirectory: true)),
            credentialCleanup: CredentialCleanupMarker(directory: root.appendingPathComponent("credential-cleanup", isDirectory: true)))
    }
}

@MainActor
private struct NativeHistoryFixture {
    let root: URL
    let storage: URL
    let store: EncryptedReportStore
    let transport: NativeHistoryForbiddenTransport
    let credentials: AdvisorCredentialStore
    let cleanup: ProtectionCleanupPlan
    let credentialCleanup: CredentialCleanupMarker

    func engine() -> FirePrivacyEngine {
        FirePrivacyEngine(store: store, transport: transport, cleanupPlan: cleanup,
            credentialStore: credentials, credentialCleanupMarker: credentialCleanup)
    }
    func removeTemporaryFiles() { try? FileManager().removeItem(at: root) }
}

private final class NativeHistoryMemoryKeys: ReportKeyProvider, @unchecked Sendable {
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

private actor NativeHistoryMemoryCredentials: AdvisorCredentialProvider {
    private var entries: [String: Data] = [:]
    func read(identity: String) async throws -> Data? { entries[identity] }
    func store(_ token: Data, identity: String) async throws { entries[identity] = token }
    func delete(identity: String) async throws { entries.removeValue(forKey: identity) }
    func deleteAll() async throws { entries.removeAll() }
}

private enum NativeHistoryFixtureError: Error { case unexpectedTransmission }
private actor NativeHistoryForbiddenTransport: ApprovedRequestTransport {
    private var calls = 0
    func send(_ request: ApprovedNetworkRequest, permit: NetworkTransmissionPermit,
              maximumResponseBytes: Int) async throws -> ApprovedNetworkResponse {
        calls += 1
        throw NativeHistoryFixtureError.unexpectedTransmission
    }
    func callCount() -> Int { calls }
}
