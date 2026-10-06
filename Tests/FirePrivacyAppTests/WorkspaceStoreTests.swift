import CryptoKit
import Foundation
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp

final class WorkspaceStoreTests: XCTestCase {
    func testStaleGenerationCannotRecreateDataAfterDeleteAll() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let old = await store.currentStorageGeneration()
        _ = try await store.appendSession(makeReport(1), expectedGeneration: old)
        try await store.deleteAll()
        let current = await store.currentStorageGeneration()
        XCTAssertNotEqual(old, current)
        do {
            _ = try await store.appendSession(makeReport(2), expectedGeneration: old)
            XCTFail("A late import must not recreate deleted files or a key.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        do {
            try await store.saveFeatureState(PrivacyProfile.balanced, key: "late-receipt", expectedGeneration: old)
            XCTFail("A late response must not recreate deleted feature state.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        XCTAssertNil(keys.currentKey)
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
        _ = try await store.appendSession(makeReport(3), expectedGeneration: current)
        XCTAssertNotNil(keys.currentKey)
    }

    func testFailedDeleteStillInvalidatesInFlightLeases() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys(), removals = WorkspaceRemovalFailures()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys, fileRemoval: { try removals.remove($0) })
        let report = try makeReport(1)
        _ = try await store.appendSession(report)
        let old = await store.currentStorageGeneration()
        removals.reject(directory)
        do { try await store.deleteAll(); XCTFail("Injected deletion failure must remain visible.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .deletionFailed) }
        do {
            try await store.saveFeatureState(PrivacyProfile.balanced, key: "late-state", expectedGeneration: old)
            XCTFail("Even an incomplete deletion cancels earlier persistent work.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        let preserved = try await store.reportSession(report.id)
        XCTAssertEqual(preserved, report)
        XCTAssertFalse(FileManager().fileExists(atPath: directory.appendingPathComponent("features").path))
        removals.allowAll()
        try await store.deleteAll()
        XCTAssertNil(keys.currentKey)
    }

    func testFailedSessionUnlinkIsDurableAndIdempotentlyRetryable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys(), removals = WorkspaceRemovalFailures()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys, fileRemoval: { try removals.remove($0) })
        let first = try makeReport(1), second = try makeReport(2)
        _ = try await store.appendSession(first)
        _ = try await store.appendSession(second, encryptedSource: rawSource(2))
        let file = reportURL(second, directory: directory)
        removals.reject(file)
        do { _ = try await store.deleteSession(second.id); XCTFail("Failed ciphertext cleanup must remain visible.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .cleanupPending) }
        let pending = try await store.loadWorkspace()
        XCTAssertEqual(pending.sessions.map(\.id), [first.id])
        XCTAssertEqual(pending.selectedReport, first)
        XCTAssertEqual(pending.pendingCleanupCount, 1)
        XCTAssertTrue(FileManager().fileExists(atPath: file.path))
        removals.allowAll()
        let retried = try await store.deleteSession(second.id)
        XCTAssertEqual(retried.selectedReport, first)
        XCTAssertEqual(retried.pendingCleanupCount, 0)
        XCTAssertFalse(FileManager().fileExists(atPath: file.path))
    }

    func testRetentionCleanupFailureBlocksNewWritesUntilRealBytesAreRemoved() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys(), removals = WorkspaceRemovalFailures()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys, fileRemoval: { try removals.remove($0) })
        let first = try makeReport(1), selected = try makeReport(2), later = try makeReport(3)
        _ = try await store.appendSession(first)
        _ = try await store.appendSession(selected)
        removals.reject(reportURL(first, directory: directory))
        do { _ = try await store.updateRetention(WorkspaceRetentionPolicy(maximumReports: 1)); XCTFail("Pending disk reclamation must remain visible.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .cleanupPending) }
        let existingKey = keys.currentKey
        do { _ = try await store.appendSession(later); XCTFail("Logical pruning must not hide retained orphan bytes from future writes.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .cleanupPending) }
        XCTAssertEqual(keys.currentKey, existingKey)
        XCTAssertFalse(FileManager().fileExists(atPath: reportURL(later, directory: directory).path))
        removals.allowAll()
        let recovered = try await store.retryPendingCleanup()
        XCTAssertEqual(recovered.selectedReport, selected)
        XCTAssertEqual(recovered.pendingCleanupCount, 0)
        _ = try await store.appendSession(later)
        XCTAssertFalse(FileManager().fileExists(atPath: reportURL(first, directory: directory).path))
    }

    func testFeatureCompareAndSwapRejectsConcurrentRollback() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        try await store.saveFeatureState(VersionPin(version: 1), key: "knowledge-pin", expectedCurrent: .absent)
        let olderRequest = try await store.loadFeatureSnapshot(VersionPin.self, key: "knowledge-pin")
        let newerRequest = try await store.loadFeatureSnapshot(VersionPin.self, key: "knowledge-pin")
        XCTAssertEqual(olderRequest.precondition, newerRequest.precondition)
        try await store.saveFeatureState(VersionPin(version: 3), key: "knowledge-pin", expectedCurrent: newerRequest.precondition)
        let saved = try Data(contentsOf: directory.appendingPathComponent("features/knowledge-pin.encrypted"))
        do {
            try await store.saveFeatureState(VersionPin(version: 2), key: "knowledge-pin", expectedCurrent: olderRequest.precondition)
            XCTFail("A response accepted against older state must not overwrite a newer high-water pin.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .preconditionFailed) }
        let retained = try await store.loadFeatureState(VersionPin.self, key: "knowledge-pin")
        XCTAssertEqual(retained?.version, 3)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("features/knowledge-pin.encrypted")), saved)
    }

    func testFeatureCASAbsenceAndDecodedFingerprintDoNotDependOnCiphertextNonce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        do {
            try await store.saveFeatureState(VersionPin(version: 1), key: "pin", expectedCurrent: .checksum(String(repeating: "0", count: 64)))
            XCTFail("A failed compare-and-swap must not create files or a key.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .preconditionFailed) }
        XCTAssertNil(keys.currentKey)
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
        let absent = try await store.loadFeatureSnapshot(VersionPin.self, key: "pin")
        XCTAssertEqual(absent.precondition, .absent)
        try await store.saveFeatureState(VersionPin(version: 1), key: "pin", expectedCurrent: absent.precondition)
        let first = try await store.loadFeatureSnapshot(VersionPin.self, key: "pin")
        try await store.saveFeatureState(VersionPin(version: 1), key: "pin")
        let second = try await store.loadFeatureSnapshot(VersionPin.self, key: "pin")
        XCTAssertEqual(first.precondition, second.precondition)
        do { try await store.saveFeatureState(VersionPin(version: 2), key: "pin", expectedCurrent: .absent); XCTFail("Absence is not a checksum sentinel.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .preconditionFailed) }
    }

    func testFeatureOnlyMissingKeyCannotBeReplacedBySavingDifferentFeature() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        try await store.saveFeatureState(PrivacyProfile.balanced, key: "profile")
        let file = directory.appendingPathComponent("features/profile.encrypted")
        let original = try Data(contentsOf: file)
        try keys.deleteKey()
        do { try await store.saveFeatureState(VersionPin(version: 1), key: "new-state"); XCTFail("Existing private ciphertext requires its original key or an explicit reset.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .missingKey) }
        XCTAssertNil(keys.currentKey)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager().fileExists(atPath: directory.appendingPathComponent("features/new-state.encrypted").path))
    }
    func testLegacyMigrationPreservesReportObservationIDsAndUnknownProvenance() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let observation = Observation(id: UUID(), bundleID: "example.legacy-app", domain: "legacy-contact.example",
                                      category: .network, accessType: "networkActivity", count: 19)
        let legacy = PrivacyReport(id: UUID(), importedAt: Date(timeIntervalSince1970: 100), observations: [observation])
        try await store.save(legacy)
        let keyBefore = try XCTUnwrap(keys.currentKey)
        XCTAssertTrue(FileManager().fileExists(atPath: directory.appendingPathComponent("report.encrypted").path))

        let migrated = try await store.loadWorkspace()
        XCTAssertTrue(migrated.migratedLegacyReport)
        XCTAssertEqual(migrated.selectedReport, legacy)
        XCTAssertEqual(migrated.sessions.map(\.id), [legacy.id])
        XCTAssertEqual(migrated.selectedReport?.observations[0].id, observation.id)
        XCTAssertNil(migrated.selectedReport?.metadata)
        XCTAssertNil(migrated.selectedReport?.observations[0].provenance)
        XCTAssertEqual(keys.currentKey, keyBefore)
        XCTAssertFalse(FileManager().fileExists(atPath: directory.appendingPathComponent("report.encrypted").path))
        XCTAssertTrue(FileManager().fileExists(atPath: directory.appendingPathComponent("workspace.encrypted").path))
        let reloaded = try await store.loadWorkspace()
        XCTAssertFalse(reloaded.migratedLegacyReport)
        XCTAssertEqual(reloaded.selectedReport, legacy)
        XCTAssertEqual(reloaded.sessions.count, 1)
    }

    func testHistorySelectionRetentionPrunesOtherSessionsAndKeepsSelectedReport() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        let first = try makeReport(1), second = try makeReport(2), third = try makeReport(3)
        _ = try await store.appendSession(first, encryptedSource: rawSource(1))
        _ = try await store.appendSession(second, encryptedSource: rawSource(2))
        _ = try await store.appendSession(third, encryptedSource: rawSource(3))
        let selected = try await store.selectSession(first.id)
        XCTAssertEqual(selected.selectedReport, first)
        XCTAssertEqual(selected.sessions.count, 3)
        let retained = try await store.updateRetention(WorkspaceRetentionPolicy(maximumReports: 1))
        XCTAssertEqual(retained.sessions.map(\.id), [first.id])
        XCTAssertEqual(retained.selectedReport, first)
        XCTAssertEqual(retained.retention.maximumReports, 1)
        for removed in [second, third] {
            XCTAssertFalse(FileManager().fileExists(atPath: reportURL(removed, directory: directory).path))
            XCTAssertFalse(FileManager().fileExists(atPath: directory.appendingPathComponent("history/\(removed.id.uuidString).source.encrypted").path))
            do {
                _ = try await store.reportSession(removed.id)
                XCTFail("A pruned report must not remain selectable.")
            } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        }
        let reloaded = try await store.loadWorkspace()
        XCTAssertEqual(reloaded.selectedReport, first)
        XCTAssertEqual(reloaded.retention.maximumReports, 1)
    }

    func testDuplicateStableImportSelectsExistingSessionWithoutDuplicatingHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        let first = try makeReport(1), other = try makeReport(2)
        _ = try await store.appendSession(first)
        _ = try await store.appendSession(other)
        let duplicate = try await store.appendSession(first)
        XCTAssertEqual(duplicate.sessions.count, 2)
        XCTAssertEqual(duplicate.selectedReport, first)
    }

    func testDuplicateImportValidatesAndAddsExplicitRawRetentionWithoutDuplicatingReport() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        let source = rawSource(1), report = try ReportImporter.parse(source)
        let original = try await store.appendSession(report)
        XCTAssertFalse(original.sessions[0].retainsEncryptedSource)
        let indexURL = directory.appendingPathComponent("workspace.encrypted")
        let before = try Data(contentsOf: indexURL)
        do {
            _ = try await store.appendSession(report, encryptedSource: Data("mismatching private bytes".utf8))
            XCTFail("Duplicate imports must also validate the requested raw source digest.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        XCTAssertEqual(try Data(contentsOf: indexURL), before)
        let upgraded = try await store.appendSession(report, encryptedSource: source)
        XCTAssertEqual(upgraded.sessions.count, 1)
        XCTAssertEqual(upgraded.selectedReport, report)
        XCTAssertTrue(upgraded.sessions[0].retainsEncryptedSource)
        XCTAssertGreaterThan(upgraded.sessions[0].encryptedSourceBytes, 0)
        let again = try await store.appendSession(report, encryptedSource: source)
        XCTAssertEqual(again.sessions.count, 1)
        XCTAssertEqual(again.sessions[0].encryptedSourceBytes, upgraded.sessions[0].encryptedSourceBytes)
    }

    func testFeatureCiphertextCannotBeSwappedAcrossKeysDespiteIdenticalPayloads() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        try await store.saveFeatureState(PrivacyProfile.balanced, key: "profile-one")
        try await store.saveFeatureState(PrivacyProfile.balanced, key: "profile-two")
        let first = directory.appendingPathComponent("features/profile-one.encrypted")
        let second = directory.appendingPathComponent("features/profile-two.encrypted")
        let swapped = try Data(contentsOf: second)
        try swapped.write(to: first)
        do {
            _ = try await store.loadFeatureState(PrivacyProfile.self, key: "profile-one")
            XCTFail("Identical feature payloads must still authenticate their feature key context.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        do {
            try await store.saveFeatureState(PrivacyProfile.minimizeTracking, key: "profile-one")
            XCTFail("Saving must not overwrite ciphertext whose context does not authenticate.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        XCTAssertEqual(try Data(contentsOf: first), swapped)
    }

    func testSameReportPayloadCannotCrossFeatureAndHistoryEncryptionContexts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        let report = try makeReport(1)
        _ = try await store.appendSession(report)
        try await store.saveFeatureState(report, key: "report-copy")
        let feature = directory.appendingPathComponent("features/report-copy.encrypted")
        try Data(contentsOf: feature).write(to: reportURL(report, directory: directory))
        do {
            _ = try await store.reportSession(report.id)
            XCTFail("A valid same-ID report payload encrypted as feature state must not unlock as history.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
    }

    func testCorruptedFeatureCannotBeOverwrittenAndKeyRemainsUnchanged() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        try await store.saveFeatureState(PrivacyProfile.balanced, key: "preferences")
        let url = directory.appendingPathComponent("features/preferences.encrypted")
        let changed = try tamperEnvelope(at: url)
        let originalKey = try XCTUnwrap(keys.currentKey)
        do {
            try await store.saveFeatureState(PrivacyProfile.maximumLocalProcessing, key: "preferences")
            XCTFail("Authenticated state corruption must require an explicit reset, not an overwrite.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        XCTAssertEqual(try Data(contentsOf: url), changed)
        XCTAssertEqual(keys.currentKey, originalKey)
    }

    func testCorruptedWorkspaceDoesNotAcceptNewSessionOrReplaceIndex() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let first = try makeReport(1), second = try makeReport(2)
        _ = try await store.appendSession(first)
        let indexURL = directory.appendingPathComponent("workspace.encrypted")
        let damaged = try tamperEnvelope(at: indexURL)
        do {
            _ = try await store.appendSession(second)
            XCTFail("A damaged index must not be silently replaced by a fresh history.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        XCTAssertEqual(try Data(contentsOf: indexURL), damaged)
        XCTAssertTrue(FileManager().fileExists(atPath: reportURL(first, directory: directory).path))
        XCTAssertFalse(FileManager().fileExists(atPath: reportURL(second, directory: directory).path))
    }

    func testRawSourceRequiresMatchingDigestAndRemainsEncryptedWithBoundContext() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let source = rawSource(7)
        let report = try ReportImporter.parse(source)
        do {
            _ = try await store.appendSession(report, encryptedSource: Data("different private bytes".utf8))
            XCTFail("Raw retention requires the exact imported source digest.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        XCTAssertNil(keys.currentKey)
        let snapshot = try await store.appendSession(report, encryptedSource: source)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertTrue(snapshot.sessions[0].retainsEncryptedSource)
        XCTAssertEqual(snapshot.sessions[0].sourceSHA256, ContentDigest.sha256(source))
        let sourceURL = directory.appendingPathComponent("history/\(report.id.uuidString).source.encrypted")
        let envelopeData = try Data(contentsOf: sourceURL)
        let diskText = String(decoding: envelopeData, as: UTF8.self)
        XCTAssertFalse(diskText.contains("private-contact-7.example"))
        XCTAssertFalse(diskText.contains("example.private-app-7"))
        XCTAssertFalse(diskText.contains("networkActivity"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: envelopeData) as? [String: Any])
        let sealedData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["sealedReport"] as? String)))
        let box = try AES.GCM.SealedBox(combined: sealedData)
        let key = SymmetricKey(data: try XCTUnwrap(keys.currentKey))
        let plaintext = try AES.GCM.open(box, using: key, authenticating: Data("FirePrivacy/RawSource/v2/\(report.id.uuidString)".utf8))
        XCTAssertEqual(try JSONDecoder().decode(Data.self, from: plaintext), source)
        XCTAssertThrowsError(try AES.GCM.open(box, using: key, authenticating: Data("FirePrivacy/HistoryReport/v2/\(report.id.uuidString)".utf8)))
        XCTAssertEqual(try sourceURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testRawSourceWithoutProvenanceIsRejectedBeforeCreatingKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let legacy = PrivacyReport(observations: [Observation(bundleID: "example.app", category: .sensor, accessType: "camera", count: 1)])
        do {
            _ = try await store.appendSession(legacy, encryptedSource: rawSource(1))
            XCTFail("An unknown legacy source digest must not authorize raw retention.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        XCTAssertNil(keys.currentKey)
    }

    func testDeleteAllRemovesHistoryRawSourceFeatureStateAndKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let source = rawSource(1), report = try ReportImporter.parse(source)
        _ = try await store.appendSession(report, encryptedSource: source)
        try await store.saveFeatureState(PrivacyProfile.minimizeTracking, key: "profile")
        XCTAssertNotNil(keys.currentKey)
        XCTAssertTrue(FileManager().fileExists(atPath: directory.appendingPathComponent("history").path))
        XCTAssertTrue(FileManager().fileExists(atPath: directory.appendingPathComponent("features").path))
        try await store.deleteAll()
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
        XCTAssertNil(keys.currentKey)
        let empty = try await store.loadWorkspace()
        XCTAssertNil(empty.selectedReport)
        XCTAssertTrue(empty.sessions.isEmpty)
        let state = try await store.loadFeatureState(PrivacyProfile.self, key: "profile")
        XCTAssertNil(state)
        let remains = try await store.hasLocalData()
        XCTAssertFalse(remains)
    }

    func testRetentionChangeInvalidatesEarlierImportLease() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        let earlier = try makeReport(1), selected = try makeReport(2)
        _ = try await store.appendSession(earlier)
        _ = try await store.appendSession(selected)
        let lease = await store.currentStorageGeneration()
        _ = try await store.updateRetention(WorkspaceRetentionPolicy(maximumReports: 1), expectedGeneration: lease)
        do { _ = try await store.appendSession(earlier, expectedGeneration: lease); XCTFail("A pruned import may not return through an old lease.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        let loaded = try await store.loadWorkspace()
        XCTAssertEqual(loaded.sessions.map(\.id), [selected.id])
    }

    func testNoOpRemovalPreservesCleanupJournalAndKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys, fileRemoval: { _ in })
        let report = try makeReport(1)
        _ = try await store.appendSession(report)
        let originalKey = keys.currentKey
        do { _ = try await store.deleteSession(report.id); XCTFail("A removal callback returning success is not evidence that ciphertext disappeared.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .cleanupPending) }
        let loaded = try await store.loadWorkspace()
        XCTAssertEqual(loaded.pendingCleanupCount, 1)
        XCTAssertTrue(FileManager().fileExists(atPath: reportURL(report, directory: directory).path))
        do { try await store.deleteAll(); XCTFail("The key must remain while ciphertext survives deletion.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .deletionFailed) }
        XCTAssertEqual(keys.currentKey, originalKey)
    }

    func testFeatureCASUsesAuthenticatedPlaintextForSetContainingValues() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        let original = SetPreferences(accepted: Set((1...100).map { "finding-\($0)" }), ignored: ["one", "two", "three"], version: 1)
        try await store.saveFeatureState(original, key: "set-prefs")
        for _ in 0..<10 {
            let a = try await store.loadFeatureSnapshot(SetPreferences.self, key: "set-prefs")
            let b = try await store.loadFeatureSnapshot(SetPreferences.self, key: "set-prefs")
            XCTAssertEqual(a.precondition, b.precondition)
            XCTAssertEqual(a.value, original)
            try await store.saveFeatureState(try XCTUnwrap(a.value), key: "set-prefs", expectedCurrent: b.precondition)
        }
        let stale = try await store.loadFeatureSnapshot(SetPreferences.self, key: "set-prefs")
        try await store.saveFeatureState(SetPreferences(accepted: original.accepted, ignored: original.ignored, version: 3), key: "set-prefs", expectedCurrent: stale.precondition)
        do { try await store.saveFeatureState(original, key: "set-prefs", expectedCurrent: stale.precondition); XCTFail("A genuine newer-state conflict must still fail.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .preconditionFailed) }
    }

    func testEarlierMigrationLegacyCiphertextIsAuthenticatedAndCleaned() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        let report = try makeReport(1)
        try await store.save(report)
        let oldCiphertext = try Data(contentsOf: directory.appendingPathComponent("report.encrypted"))
        _ = try await store.loadWorkspace()
        try oldCiphertext.write(to: directory.appendingPathComponent("report.encrypted"))
        let loaded = try await store.loadWorkspace()
        XCTAssertEqual(loaded.selectedReport, report)
        XCTAssertEqual(loaded.sessions.count, 1)
        XCTAssertFalse(FileManager().fileExists(atPath: directory.appendingPathComponent("report.encrypted").path))
    }

    func testDistinctLeftoverLegacyReportIsPreservedWithoutChangingSelection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: WorkspaceTestKeys())
        let old = try makeReport(1), selected = try makeReport(2)
        try await store.save(old)
        let oldCiphertext = try Data(contentsOf: directory.appendingPathComponent("report.encrypted"))
        _ = try await store.loadWorkspace()
        _ = try await store.appendSession(selected)
        _ = try await store.deleteSession(old.id)
        try oldCiphertext.write(to: directory.appendingPathComponent("report.encrypted"))
        let loaded = try await store.loadWorkspace()
        XCTAssertEqual(loaded.selectedReport, selected)
        XCTAssertEqual(Set(loaded.sessions.map(\.id)), Set([old.id, selected.id]))
        let restored = try await store.reportSession(old.id)
        XCTAssertEqual(restored, old)
    }

    func testRotationPreservesHistoryRawSourcesOpaqueFeatureBytesAndChangesKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let first = try makeReport(1), second = try makeReport(2)
        _ = try await store.appendSession(first, encryptedSource: rawSource(1))
        _ = try await store.appendSession(second, encryptedSource: rawSource(2))
        _ = try await store.selectSession(first.id)
        let preferences = SetPreferences(accepted: ["a", "b", "c"], ignored: ["d", "e"], version: 7)
        try await store.saveFeatureState(preferences, key: "opaque-state")
        let feature = directory.appendingPathComponent("features/opaque-state.encrypted")
        let oldKey = try XCTUnwrap(keys.currentKey)
        let oldCiphertext = try Data(contentsOf: reportURL(first, directory: directory))
        let oldPlaintext = try decryptEnvelope(try Data(contentsOf: feature), key: oldKey, context: "FirePrivacy/Feature/v2/opaque-state")
        let lease = await store.currentStorageGeneration()
        try await store.rotateKey(expectedGeneration: lease)
        let newKey = try XCTUnwrap(keys.currentKey)
        XCTAssertNotEqual(newKey, oldKey)
        XCTAssertNil(keys.currentJournal)
        let status = try await store.rotationStatus()
        XCTAssertEqual(status, .idle)
        let loaded = try await store.loadWorkspace()
        XCTAssertEqual(loaded.selectedReport, first)
        XCTAssertEqual(loaded.sessions.map(\.id), [first.id, second.id])
        XCTAssertEqual(loaded.retention, WorkspaceRetentionPolicy())
        let restored = try await store.loadFeatureState(SetPreferences.self, key: "opaque-state")
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(try decryptEnvelope(try Data(contentsOf: feature), key: newKey, context: "FirePrivacy/Feature/v2/opaque-state"), oldPlaintext)
        XCTAssertThrowsError(try decryptEnvelope(oldCiphertext, key: newKey, context: "FirePrivacy/HistoryReport/v2/\(first.id.uuidString)"))
        for item in loaded.sessions {
            XCTAssertEqual(item.encryptedBytes, try Data(contentsOf: directory.appendingPathComponent("history/\(item.id.uuidString).encrypted")).count)
            let source = directory.appendingPathComponent("history/\(item.id.uuidString).source.encrypted")
            XCTAssertEqual(item.encryptedSourceBytes, try Data(contentsOf: source).count)
            let decoded = try JSONDecoder().decode(Data.self, from: decryptEnvelope(try Data(contentsOf: source), key: newKey,
                context: "FirePrivacy/RawSource/v2/\(item.id.uuidString)"))
            XCTAssertEqual(ContentDigest.sha256(decoded), item.sourceSHA256)
        }
        do { try await store.saveFeatureState(VersionPin(version: 8), key: "pin", expectedGeneration: lease); XCTFail("Rotation invalidates previous leases.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertFalse(try FileManager().contentsOfDirectory(atPath: directory.deletingLastPathComponent().path).contains(where: { $0.hasPrefix(directory.lastPathComponent + ".rotation-") }))
    }

    func testRotationPreservesLegacyV1EnvelopeAndIdentifiers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let report = PrivacyReport(id: UUID(), observations: [Observation(id: UUID(), bundleID: "legacy.app", category: .sensor, accessType: "camera", count: 1)])
        try await store.save(report)
        try await store.rotateKey()
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("report.encrypted"))) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let migrated = try await store.loadWorkspace()
        XCTAssertEqual(migrated.selectedReport, report)
        XCTAssertEqual(migrated.sessions.map(\.id), [report.id])
    }

    func testFeatureOnlyWorkspaceCanRotateWithoutInventingReportHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        try await store.saveFeatureState(VersionPin(version: 12), key: "knowledge-high-water")
        try await store.rotateKey()
        let value = try await store.loadFeatureState(VersionPin.self, key: "knowledge-high-water")
        XCTAssertEqual(value?.version, 12)
        let history = try await store.loadWorkspace()
        XCTAssertTrue(history.sessions.isEmpty)
        XCTAssertFalse(FileManager().fileExists(atPath: directory.appendingPathComponent("workspace.encrypted").path))
    }

    func testUnsupportedRotationDoesNotModifyCiphertextKeyOrEpoch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceTestKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let report = try makeReport(1)
        _ = try await store.appendSession(report)
        let key = keys.currentKey
        let ciphertext = try Data(contentsOf: reportURL(report, directory: directory))
        let lease = await store.currentStorageGeneration()
        do { try await store.rotateKey(expectedGeneration: lease); XCTFail("An ordinary key provider cannot rotate by replacement.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .rotationUnsupported) }
        XCTAssertEqual(keys.currentKey, key)
        XCTAssertEqual(try Data(contentsOf: reportURL(report, directory: directory)), ciphertext)
        let unchanged = await store.currentStorageGeneration()
        XCTAssertEqual(lease, unchanged)
    }

    func testFreshActorRecoversEveryRotationInterruptionBoundary() async throws {
        for point in RotationInterruptionPoint.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager().removeItem(at: directory) }
            let keys = WorkspaceRotatingKeys()
            let fault = RotationTestFault(point)
            var initial: EncryptedReportStore? = EncryptedReportStore(directoryURL: directory, keyProvider: keys,
                rotationCheckpoint: { try fault.check($0) })
            let report = try makeReport(1)
            _ = try await initial!.appendSession(report, encryptedSource: rawSource(1))
            try await initial!.saveFeatureState(VersionPin(version: 41), key: "pin")
            let originalKey = keys.currentKey
            let originalReportCiphertext = try Data(contentsOf: reportURL(report, directory: directory))
            do { try await initial!.rotateKey(); XCTFail("The injected checkpoint should interrupt rotation.") }
            catch { /* The journal and authenticated generations survive process exit. */ }
            XCTAssertTrue(fault.wasTriggered)
            XCTAssertNotNil(keys.currentJournal)
            weak var released = initial
            initial = nil
            XCTAssertNil(released)
            let recovered = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
            let snapshot = try await recovered.loadWorkspace()
            XCTAssertEqual(snapshot.selectedReport, report)
            XCTAssertTrue(snapshot.sessions[0].retainsEncryptedSource)
            let pin = try await recovered.loadFeatureState(VersionPin.self, key: "pin")
            XCTAssertEqual(pin?.version, 41)
            XCTAssertNil(keys.currentJournal)
            let beforeIntent = point == .journalCreated || point == .stagedGenerationVerified
            if beforeIntent {
                XCTAssertEqual(keys.currentKey, originalKey)
                XCTAssertEqual(try Data(contentsOf: reportURL(report, directory: directory)), originalReportCiphertext)
            } else {
                XCTAssertNotEqual(keys.currentKey, originalKey)
                XCTAssertThrowsError(try decryptEnvelope(originalReportCiphertext, key: try XCTUnwrap(keys.currentKey),
                    context: "FirePrivacy/HistoryReport/v2/\(report.id.uuidString)"))
            }
            XCTAssertFalse(try FileManager().contentsOfDirectory(atPath: directory.deletingLastPathComponent().path).contains(where: { $0.hasPrefix(directory.lastPathComponent + ".rotation-") }))
        }
    }

    func testRetiredCiphertextCleanupFailureLeavesNewGenerationReadableAndRetryable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        let removals = WorkspaceRemovalFailures()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys, fileRemoval: { try removals.remove($0) },
            rotationCheckpoint: { point in
                if point == .committedJournalPersisted, let journal = keys.currentJournal {
                    removals.reject(directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".rotation-retired-" + journal.transactionID.uuidString))
                }
            })
        let report = try makeReport(1)
        _ = try await store.appendSession(report)
        let oldKey = keys.currentKey
        do { try await store.rotateKey(); XCTFail("Retired ciphertext cleanup failure must be visible.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .rotationCleanupPending) }
        let newKey = keys.currentKey
        XCTAssertNotEqual(oldKey, newKey)
        XCTAssertEqual(keys.currentJournal?.phase, .committed)
        let snapshot = try await store.loadWorkspace()
        XCTAssertEqual(snapshot.selectedReport, report)
        let status = try await store.rotationStatus()
        XCTAssertEqual(status, .cleanupPending)
        do { try await store.saveFeatureState(VersionPin(version: 1), key: "pin"); XCTFail("Writes wait until retired cleanup succeeds.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .rotationCleanupPending) }
        removals.allowAll()
        try await store.rotateKey() // Resume the same transaction, never start a third key.
        XCTAssertEqual(keys.currentKey, newKey)
        XCTAssertNil(keys.currentJournal)
        let after = try await store.loadWorkspace()
        XCTAssertEqual(after.selectedReport, report)
    }

    func testOldKeyCleanupFailureIsVisibleAndDoesNotCreateThirdKeyOnRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        keys.rejectCleanup = true
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        _ = try await store.appendSession(makeReport(1))
        do { try await store.rotateKey(); XCTFail("Journal cleanup failure retains old secret material and must be reported.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .rotationCleanupPending) }
        let installedKey = keys.currentKey
        XCTAssertEqual(keys.currentJournal?.phase, .committed)
        keys.rejectCleanup = false
        try await store.retryKeyRotationCleanup()
        XCTAssertNil(keys.currentJournal)
        XCTAssertEqual(keys.currentKey, installedKey)
    }

    func testCorruptedFeatureAbortsRotationBeforeJournalOrKeyReplacement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        try await store.saveFeatureState(VersionPin(version: 5), key: "pin")
        let file = directory.appendingPathComponent("features/pin.encrypted")
        let corrupted = try tamperEnvelope(at: file)
        let originalKey = keys.currentKey
        do { try await store.rotateKey(); XCTFail("All committed ciphertext must authenticate before rotation begins.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        XCTAssertEqual(keys.currentKey, originalKey)
        XCTAssertNil(keys.currentJournal)
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }

    func testDeleteAllRemovesEveryGenerationAndPendingKeyAfterInterruptedCommit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        let fault = RotationTestFault(.oldDirectoryRetired)
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys, rotationCheckpoint: { try fault.check($0) })
        _ = try await store.appendSession(makeReport(1), encryptedSource: rawSource(1))
        do { try await store.rotateKey(); XCTFail("Expected interrupted directory swap.") } catch { }
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
        XCTAssertNotNil(keys.currentJournal)
        try await store.deleteAll() // Explicit reset does not require rotation recovery.
        XCTAssertNil(keys.currentKey)
        XCTAssertNil(keys.currentJournal)
        XCTAssertFalse(try FileManager().contentsOfDirectory(atPath: directory.deletingLastPathComponent().path).contains(where: { $0.hasPrefix(directory.lastPathComponent) }))
    }

    func testSecondLiveStoreForSameDirectoryCannotReplaceOrRotateSharedKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        var first: EncryptedReportStore? = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let report = try makeReport(1)
        _ = try await first!.appendSession(report)
        let second = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        do { try await second.rotateKey(); XCTFail("Cross-actor key transactions require exclusive directory ownership.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .storageInUse) }
        first = nil
        let loaded = try await second.loadWorkspace()
        XCTAssertEqual(loaded.selectedReport, report)
    }

    func testDefaultDeviceOnlyKeychainProviderRotatesWithoutReplacingOrdinaryStoreKey() throws {
        let provider = KeychainReportKeyProvider(service: "org.fireprivacy.rotation-tests.\(UUID().uuidString)")
        defer { try? provider.deleteKey() }
        let old = Data(repeating: 13, count: 32), new = Data(repeating: 27, count: 32)
        try provider.storeKey(old)
        XCTAssertThrowsError(try provider.storeKey(new))
        let journal = try ReportKeyRotationJournal(bindingID: UUID(), oldKey: old, newKey: new)
        try provider.beginRotation(journal)
        XCTAssertEqual(try provider.readRotationJournal(), journal)
        _ = try provider.updateRotationPhase(transactionID: journal.transactionID, phase: .commitIntent)
        try provider.installRotatedKey(transactionID: journal.transactionID)
        XCTAssertEqual(try provider.readKey(), new)
        _ = try provider.updateRotationPhase(transactionID: journal.transactionID, phase: .committed)
        try provider.finishRotationCleanup(transactionID: journal.transactionID)
        XCTAssertNil(try provider.readRotationJournal())
    }

    func testCommittedRotationRejectsDamagedNewGenerationBeforeRetiringOldCiphertext() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = WorkspaceRotatingKeys()
        let fault = RotationTestFault(.committedJournalPersisted)
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys, rotationCheckpoint: { try fault.check($0) })
        let report = try makeReport(1)
        _ = try await store.appendSession(report)
        do { try await store.rotateKey(); XCTFail("Expected interruption before retired cleanup.") } catch { }
        let pending = try XCTUnwrap(keys.currentJournal)
        XCTAssertEqual(pending.phase, .committed)
        let retired = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".rotation-retired-" + pending.transactionID.uuidString)
        _ = try tamperEnvelope(at: reportURL(report, directory: directory))
        do { try await store.retryKeyRotationCleanup(); XCTFail("A damaged active generation must not destroy the remaining authenticated old evidence.") }
        catch { XCTAssertEqual(error as? ReportStoreError, .rotationRecoveryRequired) }
        XCTAssertEqual(keys.currentJournal, pending)
        XCTAssertTrue(FileManager().fileExists(atPath: retired.path))
        let oldCiphertext = try Data(contentsOf: retired.appendingPathComponent("history/\(report.id.uuidString).encrypted"))
        let recovered = try JSONDecoder().decode(PrivacyReport.self, from: decryptEnvelope(oldCiphertext, key: pending.oldKey,
            context: "FirePrivacy/HistoryReport/v2/\(report.id.uuidString)"))
        XCTAssertEqual(recovered, report)
        try await store.deleteAll()
        XCTAssertNil(keys.currentKey)
        XCTAssertNil(keys.currentJournal)
    }

    private func decryptEnvelope(_ bytes: Data, key: Data, context: String) throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let combined = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["sealedReport"] as? String)))
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key), authenticating: Data(context.utf8))
    }

    private func temporaryDirectory() -> URL {
        FileManager().temporaryDirectory.appendingPathComponent("FirePrivacyWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
    }
    private func rawSource(_ number: Int) -> Data {
        Data("{\"type\":\"networkActivity\",\"bundleID\":\"example.private-app-\(number)\",\"domain\":\"private-contact-\(number).example\",\"hits\":\(number)}".utf8)
    }
    private func makeReport(_ number: Int) throws -> PrivacyReport {
        try ReportImporter.parse(rawSource(number), importedAt: Date(timeIntervalSince1970: Double(number * 100)))
    }
    private func reportURL(_ report: PrivacyReport, directory: URL) -> URL {
        directory.appendingPathComponent("history/\(report.id.uuidString).encrypted")
    }
    private func tamperEnvelope(at url: URL) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["sealedReport"] as? String)))
        sealed[sealed.index(before: sealed.endIndex)] ^= 1
        object["sealedReport"] = sealed.base64EncodedString()
        let changed = try JSONSerialization.data(withJSONObject: object)
        try changed.write(to: url)
        return changed
    }
}

private struct VersionPin: Codable, Equatable, Sendable { let version: Int }

private final class WorkspaceRemovalFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected: Set<String> = []
    func reject(_ url: URL) { _ = lock.withLock { rejected.insert(url.path) } }
    func allowAll() { lock.withLock { rejected.removeAll() } }
    func remove(_ url: URL) throws {
        if lock.withLock({ rejected.contains(url.path) }) { throw ReportStoreError.deletionFailed }
        try FileManager.default.removeItem(at: url)
    }
}

/// Test-only locked memory keys; these tests never access the user's Keychain.
private final class WorkspaceTestKeys: ReportKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    var currentKey: Data? { lock.withLock { key } }
    func readKey() throws -> Data? { lock.withLock { key } }
    func storeKey(_ newKey: Data) throws {
        try lock.withLock {
            guard key == nil else { throw ReportStoreError.keyUnavailable }
            key = newKey
        }
    }
    func deleteKey() throws { lock.withLock { key = nil } }
}

private struct SetPreferences: Codable, Equatable, Sendable { let accepted: Set<String>; let ignored: Set<String>; let version: Int }

private final class RotationTestFault: @unchecked Sendable {
    private let lock = NSLock()
    private let target: RotationInterruptionPoint
    private var triggered = false
    init(_ target: RotationInterruptionPoint) { self.target = target }
    var wasTriggered: Bool { lock.withLock { triggered } }
    func check(_ point: RotationInterruptionPoint) throws {
        try lock.withLock {
            if point == target && !triggered {
                triggered = true
                throw ReportStoreError.persistenceFailed
            }
        }
    }
}

/// Injected test capability mirrors forward-only journal transitions. No Keychain
/// item or actual production key is involved in interruption fixtures.
private final class WorkspaceRotatingKeys: RotatingReportKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var journal: ReportKeyRotationJournal?
    private var cleanupRejected = false
    var currentKey: Data? { lock.withLock { key } }
    var currentJournal: ReportKeyRotationJournal? { lock.withLock { journal } }
    var rejectCleanup: Bool {
        get { lock.withLock { cleanupRejected } }
        set { lock.withLock { cleanupRejected = newValue } }
    }
    func readKey() throws -> Data? { currentKey }
    func storeKey(_ value: Data) throws {
        try lock.withLock {
            guard key == nil, value.count == 32 else { throw ReportStoreError.keyUnavailable }
            key = value
        }
    }
    func deleteKey() throws { lock.withLock { key = nil; journal = nil } }
    func readRotationJournal() throws -> ReportKeyRotationJournal? { currentJournal }
    func beginRotation(_ value: ReportKeyRotationJournal) throws {
        try lock.withLock {
            guard value.phase == .staging, value.oldKey == key, journal == nil else { throw KeyRotationProviderError.conflictingRotation }
            journal = try ReportKeyRotationJournal.decode(value.encoded())
        }
    }
    func updateRotationPhase(transactionID: UUID, phase: ReportKeyRotationPhase) throws -> ReportKeyRotationJournal {
        try lock.withLock {
            guard let current = journal, current.transactionID == transactionID else { throw KeyRotationProviderError.invalidJournal }
            guard (current.phase == .staging && phase == .commitIntent && key == current.oldKey) ||
                  (current.phase == .commitIntent && phase == .committed && key == current.newKey) else { throw KeyRotationProviderError.invalidPhaseTransition }
            let updated = try ReportKeyRotationJournal(transactionID: current.transactionID, bindingID: current.bindingID,
                oldKey: current.oldKey, newKey: current.newKey, phase: phase)
            journal = updated
            return updated
        }
    }
    func installRotatedKey(transactionID: UUID) throws {
        try lock.withLock {
            guard let current = journal, current.transactionID == transactionID,
                  current.phase == .commitIntent || current.phase == .committed,
                  key == current.oldKey || key == current.newKey else { throw KeyRotationProviderError.primaryKeyMismatch }
            key = current.newKey
        }
    }
    func finishRotationCleanup(transactionID: UUID) throws {
        try lock.withLock {
            guard !cleanupRejected else { throw KeyRotationProviderError.cleanupFailed }
            guard let current = journal, current.transactionID == transactionID, current.phase == .committed, key == current.newKey else {
                throw KeyRotationProviderError.invalidPhaseTransition
            }
            journal = nil
        }
    }
    func cancelRotation(transactionID: UUID) throws {
        try lock.withLock {
            guard let current = journal, current.transactionID == transactionID, current.phase == .staging, key == current.oldKey else {
                throw KeyRotationProviderError.invalidPhaseTransition
            }
            journal = nil
        }
    }
}
