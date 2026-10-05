import CryptoKit
import Foundation
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp

final class WorkspaceStoreTests: XCTestCase {
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
