import Foundation
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp

/// These tests exercise the native engine and encrypted store together. They
/// never use the production HTTP worker or enable an OS protection feature.
final class EngineIntegrationTests: XCTestCase {
    @MainActor
    func testPreferencesConsentAndSelectedHistoryRestoreWithoutTransmission() async throws {
        let transport = EngineFixtureTransport()
        let harness = makeHarness(transport: transport)
        defer { harness.removeTemporaryFiles() }
        let engine = harness.engine
        _ = try await engine.restore()
        try await engine.grant(.localImport, scope: "local-import-v1")
        let first = try makeReport(1), second = try makeReport(2)
        _ = try await engine.importReport(first)
        _ = try await engine.importReport(second)
        _ = try await engine.selectReport(first.id)

        var preferences = engine.preferences
        preferences.profile = .maximumLocalProcessing
        preferences.permissionAudit.record(.init(bundleID: "example.engine.alpha", category: "location",
            state: .whileUsing, isExpected: false, note: "A local review note."))
        preferences.acceptedFindingKeys = [try XCTUnwrap(engine.analysis?.findings.first?.lifecycleKey)]
        preferences.selfHostedConfiguration = try modelConfiguration()
        preferences.advisorMode = .selfHosted
        try await engine.savePreferences(preferences)
        let prepared = try await engine.prepareSelfHostedAssessment()
        try await grantExactAdvisorConsent(engine, prepared: prepared)

        // A previously saved inventory must restore locally, without replaying it.
        let pastEvent = NetworkEvent(operationID: UUID(), purpose: .selfHostedAdvisor,
            host: "engine-model.example.test", occurredAt: Date().addingTimeInterval(-60),
            phase: .completed, requestByteCount: 400, responseByteCount: 200, statusCode: 200)
        try await harness.store.saveFeatureState([pastEvent], key: "network-events")
        let savedConsentValue = try await harness.store.loadFeatureState(ConsentState.self, key: "consent")
        let savedConsent = try XCTUnwrap(savedConsentValue)

        let restoredTransport = EngineFixtureTransport()
        // The store owns its directory for its lifetime. A fresh engine reads
        // persisted state through that same store rather than opening a rival.
        let restored = FirePrivacyEngine(store: harness.store, transport: restoredTransport,
            cleanupPlan: ProtectionCleanupPlan(directory: harness.cleanupDirectory),
            credentialStore: AdvisorCredentialStore(provider: harness.credentials),
            credentialCleanupMarker: CredentialCleanupMarker(directory: harness.credentialCleanupDirectory))
        let workspace = try await restored.restore()

        XCTAssertEqual(workspace.selectedReport, first)
        XCTAssertEqual(workspace.sessions.map(\.id), [first.id, second.id])
        XCTAssertEqual(restored.report, first)
        XCTAssertEqual(restored.sessions.map(\.id), [first.id, second.id])
        XCTAssertTrue(restored.unavailableSessionIDs.isEmpty)
        XCTAssertEqual(restored.preferences.profile, preferences.profile)
        XCTAssertEqual(restored.preferences.permissionAudit, preferences.permissionAudit)
        XCTAssertEqual(restored.preferences.acceptedFindingKeys, preferences.acceptedFindingKeys)
        XCTAssertEqual(restored.preferences.selfHostedConfiguration, preferences.selfHostedConfiguration)
        XCTAssertEqual(restored.preferences.advisorMode, .selfHosted)
        XCTAssertEqual(restored.consent, savedConsent)
        XCTAssertNotNil(restored.consent.activeReceipt(for: .selfHostedAdvisor,
            disclosureVersion: prepared.preview.disclosureVersion, scopeIdentity: prepared.preview.configurationIdentity))
        XCTAssertNil(restored.advisorResult, "Restoration must not create an automatic advisor request.")
        let events = await restored.gate.ledger.snapshot()
        XCTAssertEqual(events, [pastEvent])
        let originalCalls = await transport.callCount(), restoredCalls = await restoredTransport.callCount()
        XCTAssertEqual(originalCalls, 0)
        XCTAssertEqual(restoredCalls, 0)
        let restoredSecond = try await harness.store.reportSession(second.id)
        XCTAssertEqual(restoredSecond, second)
    }

    @MainActor
    func testExactConsentAfterPreviewRefreshesTokenAndSendsUnchangedRequest() async throws {
        let transport = EngineFixtureTransport()
        let harness = makeHarness(transport: transport)
        defer { harness.removeTemporaryFiles() }
        try await configure(harness.engine)
        let prepared = try await harness.engine.prepareSelfHostedAssessment(bearerToken: "fixture-authentication")
        let before = await transport.callCount()
        XCTAssertEqual(before, 0, "Preparing and previewing must not transmit.")
        XCTAssertEqual(prepared.preview.payloadUTF8, String(data: prepared.request.body, encoding: .utf8))
        XCTAssertEqual(prepared.preview.disclosure.destination, prepared.request.endpoint.absoluteString)
        do {
            _ = try await harness.engine.send(prepared)
            XCTFail("A visible preview cannot substitute for feature consent.")
        } catch { XCTAssertEqual(error as? ApprovedNetworkError, .consentRequired) }
        let callsBeforeConsent = await transport.callCount()
        XCTAssertEqual(callsBeforeConsent, 0)

        try await grantExactAdvisorConsent(harness.engine, prepared: prepared)
        // Feature consent changes the generation and destroys the old preview
        // token. The public engine send flow must recover only unchanged bytes.
        do {
            _ = try await harness.engine.gate.approve(prepared.preview)
            XCTFail("The pre-grant token must have been invalidated.")
        } catch { XCTAssertEqual(error as? ApprovedNetworkError, .approvalInvalidOrConsumed) }

        let response = try await harness.engine.send(prepared)
        XCTAssertEqual(response.statusCode, 200)
        let calls = await transport.requests()
        XCTAssertEqual(calls, [prepared.request])
        XCTAssertEqual(harness.engine.advisorResult?.mode, .selfHosted)
        let result = try XCTUnwrap(harness.engine.advisorResult)
        let analysis = try XCTUnwrap(harness.engine.analysis)
        let explanations = try AdvisorRenderer.explanations(assessment: result.assessment, analysis: analysis)
        XCTAssertFalse(explanations.isEmpty)
        XCTAssertTrue(explanations.allSatisfy { $0.actions.contains(where: { $0.kind == .keepAsIs }) })
        let events = await harness.engine.gate.ledger.snapshot()
        XCTAssertEqual(events.map(\.phase), [.started, .completed])
        XCTAssertTrue(events.allSatisfy { $0.purpose == .selfHostedAdvisor && $0.host == "engine-model.example.test" })
        let persistedEvents = try await harness.store.loadFeatureState([NetworkEvent].self, key: "network-events")
        XCTAssertEqual(persistedEvents, events)
    }

    @MainActor
    func testChangingReportAndReturningToOriginalDoesNotRevivePreparedRequest() async throws {
        let transport = EngineFixtureTransport()
        let harness = makeHarness(transport: transport)
        defer { harness.removeTemporaryFiles() }
        let first = try makeReport(1)
        try await configure(harness.engine, report: first)
        let prepared = try await harness.engine.prepareSelfHostedAssessment()
        try await grantExactAdvisorConsent(harness.engine, prepared: prepared)
        _ = try await harness.engine.importReport(makeReport(2))
        _ = try await harness.engine.selectReport(first.id)
        XCTAssertEqual(harness.engine.report, first)
        do {
            _ = try await harness.engine.send(prepared)
            XCTFail("Returning to matching report bytes must not revive an earlier operation.")
        } catch { assertStaleOperation(error) }
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(harness.engine.advisorResult)
    }

    @MainActor
    func testRevokingFeatureRejectsPreparedRequestAndPersistsRevocation() async throws {
        let transport = EngineFixtureTransport()
        let harness = makeHarness(transport: transport)
        defer { harness.removeTemporaryFiles() }
        try await configure(harness.engine)
        let prepared = try await harness.engine.prepareSelfHostedAssessment()
        try await grantExactAdvisorConsent(harness.engine, prepared: prepared)
        try await harness.engine.revoke(.selfHostedAdvisor)
        do {
            _ = try await harness.engine.send(prepared)
            XCTFail("A prepared request must not override later revocation.")
        } catch { assertStaleOperation(error) }
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
        let persistedValue = try await harness.store.loadFeatureState(ConsentState.self, key: "consent")
        let persisted = try XCTUnwrap(persistedValue)
        XCTAssertNil(persisted.activeReceipt(for: .selfHostedAdvisor,
            disclosureVersion: prepared.preview.disclosureVersion, scopeIdentity: prepared.preview.configurationIdentity))
        XCTAssertTrue(persisted.receipts.contains { $0.feature == .selfHostedAdvisor && !$0.isActive })
        XCTAssertNil(harness.engine.advisorResult)
    }

    @MainActor
    func testLateCancelledResponseAfterDeleteAllCannotRecreatePrivateState() async throws {
        let transport = EngineFixtureTransport(pauseResponses: true)
        let harness = makeHarness(transport: transport)
        defer { harness.removeTemporaryFiles() }
        try await configure(harness.engine)
        let configuration = try XCTUnwrap(harness.engine.preferences.selfHostedConfiguration)
        let credentialGeneration = await harness.credentialStore.currentGeneration()
        try await harness.credentialStore.retain("delete-all-fixture-token", for: configuration,
            expectedGeneration: credentialGeneration)
        let prepared = try await harness.engine.prepareSelfHostedAssessment()
        try await grantExactAdvisorConsent(harness.engine, prepared: prepared)
        let operation = Task { @MainActor in try await harness.engine.send(prepared) }
        let started = await transport.waitUntilStarted()
        guard started else {
            await transport.complete()
            _ = await operation.result
            XCTFail("The injected transport did not start within its bounded wait.")
            return
        }

        let createdKeys = harness.keys.creationCount
        XCTAssertGreaterThan(createdKeys, 0)
        let existingGate = harness.engine.gate
        do { try await harness.engine.deleteAll() }
        catch {
            await transport.complete()
            _ = await operation.result
            throw error
        }
        let generationAfterDeletion = await harness.store.currentStorageGeneration()
        XCTAssertNotEqual(generationAfterDeletion, prepared.storageGeneration)
        XCTAssertNil(harness.keys.currentKey)
        let credentialCountAfterDeletion = await harness.credentials.entryCount()
        XCTAssertEqual(credentialCountAfterDeletion, 0)
        XCTAssertFalse(FileManager().fileExists(atPath: harness.storageDirectory.path))
        XCTAssertNil(harness.engine.report)
        XCTAssertNil(harness.engine.advisorResult)
        XCTAssertTrue(harness.engine.sessions.isEmpty)

        // The fake deliberately ignores task cancellation and returns a valid
        // late response. The engine/gate/store must reject it independently.
        await transport.complete()
        do {
            _ = try await operation.value
            XCTFail("A valid late response must not survive Delete All.")
        } catch { XCTAssertEqual(error as? ApprovedNetworkError, .cancelled) }

        let events = await existingGate.ledger.snapshot()
        XCTAssertTrue(events.isEmpty, "Late terminal events must not recreate the deleted ledger.")
        let persistedEvents = try await harness.store.loadFeatureState([NetworkEvent].self, key: "network-events")
        let persistedConsent = try await harness.store.loadFeatureState(ConsentState.self, key: "consent")
        let hasLocalData = try await harness.store.hasLocalData()
        XCTAssertNil(persistedEvents)
        XCTAssertNil(persistedConsent)
        XCTAssertFalse(hasLocalData)
        XCTAssertNil(harness.keys.currentKey)
        XCTAssertEqual(harness.keys.creationCount, createdKeys, "A late callback must not mint a replacement key.")
        let finalCredentialCount = await harness.credentials.entryCount()
        let credentialWrites = await harness.credentials.writeCount()
        XCTAssertEqual(finalCredentialCount, 0)
        XCTAssertEqual(credentialWrites, 1, "A late callback must not retain replacement credentials.")
        XCTAssertFalse(FileManager().fileExists(atPath: harness.storageDirectory.path))
        XCTAssertNil(harness.engine.analysis)
        XCTAssertNil(harness.engine.comparison)
        XCTAssertNil(harness.engine.weeklySummary)
        XCTAssertNil(harness.engine.preferences.selfHostedConfiguration)
        XCTAssertTrue(harness.engine.consent.receipts.isEmpty)

        let restored = try await harness.engine.restore()
        XCTAssertNil(restored.selectedReport)
        XCTAssertTrue(restored.sessions.isEmpty)
        XCTAssertNil(harness.engine.report)
        XCTAssertNil(harness.engine.advisorResult)
        XCTAssertNil(harness.keys.currentKey)
        XCTAssertFalse(FileManager().fileExists(atPath: harness.storageDirectory.path))
        let finalEvents = await harness.engine.gate.ledger.snapshot(), calls = await transport.callCount()
        XCTAssertTrue(finalEvents.isEmpty)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testSuspendedCredentialDeletionRejectsConcurrentRetentionAndRestore() async throws {
        let transport = EngineFixtureTransport()
        let harness = makeHarness(transport: transport, pauseCredentialDeletion: true)
        defer { harness.removeTemporaryFiles() }
        try await configure(harness.engine)
        let configuration = try XCTUnwrap(harness.engine.preferences.selfHostedConfiguration)
        try await harness.engine.retainAdvisorCredential("saved-before-deletion")
        let deletion = Task { @MainActor in try await harness.engine.deleteAll() }
        let started = await harness.credentials.waitUntilDeletionStarted()
        guard started else {
            await harness.credentials.completeDeletion()
            _ = await deletion.result
            XCTFail("Credential deletion did not start within its bounded wait.")
            return
        }

        let markerDuringDeletion: Bool
        do { markerDuringDeletion = try await harness.credentialCleanupMarker.isRequired() }
        catch {
            await harness.credentials.completeDeletion()
            _ = await deletion.result
            throw error
        }
        XCTAssertTrue(markerDuringDeletion, "Cleanup intent must be durable before the provider suspends.")
        do {
            try await harness.engine.retainAdvisorCredential("rejected-during-deletion")
            XCTFail("A suspended deletion must not allow a concurrent token save.")
        } catch {
            if case .unavailable? = error as? EngineError {} else {
                XCTFail("Expected credential retention to be unavailable during deletion.")
            }
        }
        do {
            _ = try await harness.engine.restore()
            XCTFail("Restore must not re-enable credentials while deletion is suspended.")
        } catch { assertStaleOperation(error) }
        let writesDuringDeletion = await harness.credentials.writeCount()
        XCTAssertEqual(writesDuringDeletion, 1)

        await harness.credentials.completeDeletion()
        try await deletion.value
        let entries = await harness.credentials.entryCount()
        let writes = await harness.credentials.writeCount()
        let markerAfterDeletion = try await harness.credentialCleanupMarker.isRequired()
        XCTAssertEqual(entries, 0)
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(markerAfterDeletion)
        XCTAssertNil(harness.keys.currentKey)
        XCTAssertFalse(FileManager().fileExists(atPath: harness.storageDirectory.path))
        XCTAssertNil(harness.engine.report)
        XCTAssertNil(harness.engine.advisorResult)
        let credentialGeneration = await harness.credentialStore.currentGeneration()
        do {
            _ = try await harness.credentialStore.token(for: configuration, expectedGeneration: credentialGeneration)
            XCTFail("Successful deletion must keep credential access disabled until explicit setup.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .cleanupPending) }
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testUsageComparisonRestoresFromEncryptedPrivateStateWithoutTransmission() async throws {
        let transport = EngineFixtureTransport()
        let harness = makeHarness(transport: transport)
        defer { harness.removeTemporaryFiles() }
        try await configure(harness.engine, report: usageReport())
        let timeline = try usageReference(for: XCTUnwrap(harness.engine.report).id)
        try await harness.engine.saveUsageTimeline(timeline)
        let comparison = try XCTUnwrap(harness.engine.usageComparison)
        XCTAssertEqual(comparison.apps.first { $0.bundleID == "example.engine.alpha" }?.outsideClaimedWindowActivities, 1)
        let cache = harness.storageDirectory.appendingPathComponent("features/usage-timeline.encrypted")
        let encrypted = try Data(contentsOf: cache)
        let text = String(decoding: encrypted, as: UTF8.self)
        XCTAssertFalse(text.contains("example.engine.alpha"))
        XCTAssertFalse(text.contains("foregroundWindows"))
        let saved = try await harness.store.loadFeatureState(EngineUsageFixtureState.self, key: "usage-timeline")
        XCTAssertEqual(saved?.timeline, timeline)
        let restored = FirePrivacyEngine(store: harness.store, transport: transport,
            cleanupPlan: ProtectionCleanupPlan(directory: harness.cleanupDirectory),
            credentialStore: harness.credentialStore, credentialCleanupMarker: harness.credentialCleanupMarker)
        _ = try await restored.restore()
        XCTAssertEqual(restored.usageTimeline, timeline)
        XCTAssertEqual(restored.usageComparison, comparison)
        XCTAssertEqual(try Data(contentsOf: cache), encrypted)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testUsageEditsInvalidatePreparedRequestAndClearDerivedReferences() async throws {
        let transport = EngineFixtureTransport()
        let harness = makeHarness(transport: transport)
        defer { harness.removeTemporaryFiles() }
        try await configure(harness.engine, report: usageReport())
        let findings = try XCTUnwrap(harness.engine.analysis).findings
        let prepared = try await harness.engine.prepareSelfHostedAssessment()
        try await grantExactAdvisorConsent(harness.engine, prepared: prepared)
        try await harness.engine.saveUsageTimeline(usageReference(for: XCTUnwrap(harness.engine.report).id))
        do { _ = try await harness.engine.send(prepared); XCTFail("A context edit must invalidate a prepared request.") }
        catch { assertStaleOperation(error) }
        XCTAssertEqual(harness.engine.analysis?.findings, findings, "Usage claims must not change publisher facts or posture rules.")
        try await harness.engine.saveUsageTimeline(.empty)
        XCTAssertTrue(harness.engine.usageTimeline.references.isEmpty)
        let comparison = try XCTUnwrap(harness.engine.usageComparison)
        XCTAssertTrue(comparison.apps.flatMap(\.activities).allSatisfy { $0.sourceAssessments.isEmpty && !$0.reviewSuggested })
        let saved = try await harness.store.loadFeatureState(EngineUsageFixtureState.self, key: "usage-timeline")
        XCTAssertEqual(saved?.timeline, .empty)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testUsageComparisonFollowsSelectedReportAndDeleteAllRemovesItsState() async throws {
        let transport = EngineFixtureTransport()
        let harness = makeHarness(transport: transport)
        defer { harness.removeTemporaryFiles() }
        let first = try usageReport()
        try await configure(harness.engine, report: first)
        try await harness.engine.saveUsageTimeline(usageReference(for: first.id))
        let second = try ReportImporter.parse(Data("{\"type\":\"networkActivity\",\"bundleID\":\"example.different.app\",\"domain\":\"another.example\",\"hits\":1,\"timeStamp\":\"2026-10-06T13:00:00Z\"}".utf8))
        _ = try await harness.engine.importReport(second)
        XCTAssertEqual(harness.engine.usageComparison?.reportID, second.id)
        XCTAssertTrue(try XCTUnwrap(harness.engine.usageComparison).apps.flatMap(\.activities).allSatisfy { $0.sourceAssessments.isEmpty })
        _ = try await harness.engine.selectReport(first.id)
        XCTAssertEqual(harness.engine.usageComparison?.reportID, first.id)
        XCTAssertEqual(harness.engine.usageComparison?.apps.first { $0.bundleID == "example.engine.alpha" }?.outsideClaimedWindowActivities, 1)
        try await harness.engine.deleteAll()
        XCTAssertNil(harness.engine.usageComparison)
        XCTAssertEqual(harness.engine.usageTimeline, .empty)
        XCTAssertFalse(FileManager().fileExists(atPath: harness.storageDirectory.path))
        let saved = try await harness.store.loadFeatureState(EngineUsageFixtureState.self, key: "usage-timeline")
        XCTAssertNil(saved)
        XCTAssertNil(harness.keys.currentKey)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    private func usageReport() throws -> PrivacyReport {
        let lines = ["alpha", "beta", "gamma"].map { app in
            "{\"type\":\"networkActivity\",\"bundleID\":\"example.engine.\(app)\",\"domain\":\"shared-usage.example\",\"hits\":1,\"timeStamp\":\"2026-10-06T13:00:00Z\"}"
        }
        return try ReportImporter.parse(Data(lines.joined(separator: "\n").utf8))
    }

    private func usageReference(for reportID: UUID) throws -> AppUsageTimeline {
        let coverage = try UsageTimeRange(startTimestampText: "2026-10-06T12:00:00Z", endTimestampText: "2026-10-06T14:00:00Z")
        let foreground = try UsageTimeRange(startTimestampText: "2026-10-06T12:00:00Z", endTimestampText: "2026-10-06T12:30:00Z")
        return try AppUsageTimeline(references: [AppUsageReference(bundleID: "example.engine.alpha", provenance: .userRecollection,
            coverage: coverage, claimsCompleteForegroundWindows: true, foregroundWindows: [foreground],
            deviceScope: .sameDeviceAsReport, comparisonReportID: reportID)])
    }

    @MainActor
    private func configure(_ engine: FirePrivacyEngine, report: PrivacyReport? = nil) async throws {
        _ = try await engine.restore()
        try await engine.grant(.localImport, scope: "local-import-v1")
        _ = try await engine.importReport(report ?? makeReport(1))
        var preferences = engine.preferences
        preferences.selfHostedConfiguration = try modelConfiguration()
        preferences.advisorMode = .selfHosted
        try await engine.savePreferences(preferences)
    }

    @MainActor
    private func grantExactAdvisorConsent(_ engine: FirePrivacyEngine, prepared: PreparedEngineRequest) async throws {
        XCTAssertEqual(prepared.preview.disclosure.purpose.requiredConsent, .selfHostedAdvisor)
        try await engine.grant(.selfHostedAdvisor, scope: prepared.preview.configurationIdentity,
            disclosureVersion: prepared.preview.disclosureVersion)
    }

    @MainActor
    private func makeHarness(transport: any ApprovedRequestTransport,
                             pauseCredentialDeletion: Bool = false) -> EngineTestHarness {
        let root = FileManager().temporaryDirectory.appendingPathComponent("FirePrivacyEngineTests-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("private-store", isDirectory: true)
        let cleanup = root.appendingPathComponent("cleanup-plan", isDirectory: true)
        let credentialCleanup = root.appendingPathComponent("credential-cleanup", isDirectory: true)
        let keys = EngineMemoryKeys()
        let credentials = EngineMemoryAdvisorCredentials(pauseDeletion: pauseCredentialDeletion)
        let credentialStore = AdvisorCredentialStore(provider: credentials)
        let credentialCleanupMarker = CredentialCleanupMarker(directory: credentialCleanup)
        let store = EncryptedReportStore(directoryURL: storage, keyProvider: keys)
        return EngineTestHarness(root: root, storageDirectory: storage, cleanupDirectory: cleanup,
            credentialCleanupDirectory: credentialCleanup,
            keys: keys, credentials: credentials, credentialStore: credentialStore, store: store,
            engine: FirePrivacyEngine(store: store, transport: transport,
                cleanupPlan: ProtectionCleanupPlan(directory: cleanup), credentialStore: credentialStore,
                credentialCleanupMarker: credentialCleanupMarker), credentialCleanupMarker: credentialCleanupMarker)
    }

    private func modelConfiguration() throws -> SelfHostedAdvisorConfiguration {
        try SelfHostedAdvisorConfiguration(endpoint: XCTUnwrap(URL(string: "https://engine-model.example.test/api/chat")),
            modelName: "fixture-model", retentionDisclosure: "An injected fixture handles this request; no live endpoint is contacted.")
    }

    private func makeReport(_ number: Int) throws -> PrivacyReport {
        let lines = ["alpha", "beta", "gamma"].enumerated().map { index, app in
            "{\"type\":\"networkActivity\",\"bundleID\":\"example.engine.\(app)\",\"domain\":\"shared-\(number).example\",\"hits\":\(number + index)}"
        }
        return try ReportImporter.parse(Data(lines.joined(separator: "\n").utf8),
            importedAt: Date().addingTimeInterval(-3_600 + Double(number)))
    }

    private func assertStaleOperation(_ error: any Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let failure = error as? EngineError else {
            XCTFail("Expected the engine to reject a stale prepared operation.", file: file, line: line)
            return
        }
        switch failure {
        case .staleOperation: break
        default: XCTFail("Expected staleOperation.", file: file, line: line)
        }
    }
}

private struct EngineUsageFixtureState: Codable, Sendable {
    let version: Int
    let timeline: AppUsageTimeline
}

@MainActor
private struct EngineTestHarness {
    let root: URL
    let storageDirectory: URL
    let cleanupDirectory: URL
    let credentialCleanupDirectory: URL
    let keys: EngineMemoryKeys
    let credentials: EngineMemoryAdvisorCredentials
    let credentialStore: AdvisorCredentialStore
    let store: EncryptedReportStore
    let engine: FirePrivacyEngine
    let credentialCleanupMarker: CredentialCleanupMarker

    func removeTemporaryFiles() { try? FileManager().removeItem(at: root) }
}

/// This provider never accesses the system Keychain; every shared value is locked.
private final class EngineMemoryKeys: ReportKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var creations = 0
    var currentKey: Data? { lock.withLock { key } }
    var creationCount: Int { lock.withLock { creations } }
    func readKey() throws -> Data? { lock.withLock { key } }
    func storeKey(_ value: Data) throws {
        try lock.withLock {
            guard key == nil else { throw ReportStoreError.keyUnavailable }
            key = value; creations += 1
        }
    }
    func deleteKey() throws { lock.withLock { key = nil } }
}

/// Credential state is isolated too; these integration tests never operate on
/// the app's Keychain service, including during restoration and Delete All.
private actor EngineMemoryAdvisorCredentials: AdvisorCredentialProvider {
    private var entries: [String: Data] = [:]
    private var writes = 0
    private let pauseDeletion: Bool
    private var deletionStarted = false
    private var deletionReleased = false
    private var deletionContinuation: CheckedContinuation<Void, Never>?
    private var deletionWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(pauseDeletion: Bool = false) { self.pauseDeletion = pauseDeletion }

    func read(identity: String) async throws -> Data? { entries[identity] }
    func store(_ token: Data, identity: String) async throws { entries[identity] = token; writes += 1 }
    func delete(identity: String) async throws { entries.removeValue(forKey: identity) }
    func deleteAll() async throws {
        deletionStarted = true
        if pauseDeletion && !deletionReleased {
            await withCheckedContinuation { continuation in
                deletionContinuation = continuation
                notifyDeletionStarted()
            }
        } else { notifyDeletionStarted() }
        entries.removeAll()
    }
    func entryCount() -> Int { entries.count }
    func writeCount() -> Int { writes }

    func waitUntilDeletionStarted() async -> Bool {
        if deletionStarted { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            deletionWaiters[id] = continuation
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.expireDeletionWaiter(id)
            }
        }
    }

    func completeDeletion() {
        deletionReleased = true
        let continuation = deletionContinuation
        deletionContinuation = nil
        continuation?.resume()
    }

    private func notifyDeletionStarted() {
        let waiters = Array(deletionWaiters.values)
        deletionWaiters.removeAll()
        for continuation in waiters { continuation.resume(returning: true) }
    }
    private func expireDeletionWaiter(_ id: UUID) { deletionWaiters.removeValue(forKey: id)?.resume(returning: false) }
}

private enum EngineFixtureError: Error { case invalidPermit, invalidPayload, oversizedResponse }

/// Cancellation is intentionally non-cooperating in paused mode. This verifies
/// the actual engine/gate protection, rather than trusting the fixture to cancel.
private actor EngineFixtureTransport: ApprovedRequestTransport {
    private let pauseResponses: Bool
    private var calls: [ApprovedNetworkRequest] = []
    private var usedPermits: Set<UUID> = []
    private var pending: (CheckedContinuation<ApprovedNetworkResponse, Never>, ApprovedNetworkResponse)?
    private var released = false
    private var startWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(pauseResponses: Bool = false) { self.pauseResponses = pauseResponses }

    func send(_ request: ApprovedNetworkRequest, permit: NetworkTransmissionPermit,
              maximumResponseBytes: Int) async throws -> ApprovedNetworkResponse {
        guard permit.authorizes(request), usedPermits.insert(permit.id).inserted else { throw EngineFixtureError.invalidPermit }
        calls.append(request)
        let response = try EngineAdvisorResponse.make(for: request)
        guard response.body.count <= maximumResponseBytes else { throw EngineFixtureError.oversizedResponse }
        if pauseResponses && !released {
            return await withCheckedContinuation { continuation in
                pending = (continuation, response)
                notifyStarted()
            }
        }
        notifyStarted()
        return response
    }

    func requests() -> [ApprovedNetworkRequest] { calls }
    func callCount() -> Int { calls.count }
    func waitUntilStarted() async -> Bool {
        if !calls.isEmpty { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            startWaiters[id] = continuation
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.expireWaiter(id)
            }
        }
    }

    func complete() {
        released = true
        if let (continuation, response) = pending {
            pending = nil
            continuation.resume(returning: response)
        }
    }

    private func notifyStarted() {
        let waiters = Array(startWaiters.values)
        startWaiters.removeAll()
        for continuation in waiters { continuation.resume(returning: true) }
    }

    private func expireWaiter(_ id: UUID) { startWaiters.removeValue(forKey: id)?.resume(returning: false) }
}

/// An Ollama-compatible fixture consumes only the transmitted ordinal protocol.
/// It cannot access the local report/analysis mapping captured by the engine.
private enum EngineAdvisorResponse {
    private struct Input: Decodable {
        let schemaVersion: Int
        let claims: [Claim]
        struct Claim: Decodable {
            let reference: String
            let ruleID: String
            let evidenceReferences: [String]
            let actionIDs: [String]
        }
    }
    private struct Output: Encodable {
        let schemaVersion: Int
        let items: [Item]
        struct Item: Encodable {
            let claimReference: String
            let ruleID: String
            let evidenceReferences: [String]
            let actionIDs: [String]
            let style = "steps"
        }
    }

    static func make(for request: ApprovedNetworkRequest) throws -> ApprovedNetworkResponse {
        guard let payload = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let messages = payload["messages"] as? [[String: String]],
              let user = messages.first(where: { $0["role"] == "user" })?["content"] else { throw EngineFixtureError.invalidPayload }
        let input = try JSONDecoder().decode(Input.self, from: Data(user.utf8))
        let output = Output(schemaVersion: input.schemaVersion, items: input.claims.map {
            .init(claimReference: $0.reference, ruleID: $0.ruleID,
                evidenceReferences: $0.evidenceReferences, actionIDs: $0.actionIDs)
        })
        guard let content = String(data: try JSONEncoder().encode(output), encoding: .utf8) else { throw EngineFixtureError.invalidPayload }
        let body = try JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": content]])
        return ApprovedNetworkResponse(statusCode: 200, body: body, contentType: "application/json")
    }
}
