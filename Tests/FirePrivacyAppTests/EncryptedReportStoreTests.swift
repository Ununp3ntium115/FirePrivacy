import Foundation
import FirePrivacyCore
import Security
import XCTest
@testable import FirePrivacyApp

final class EncryptedReportStoreTests: XCTestCase {
    func testKeychainKeyUsesDeviceOnlyUnlockedAccessWithoutSynchronization() throws {
        let service = "FirePrivacyStoreTests.\(UUID().uuidString)"
        let provider = KeychainReportKeyProvider(service: service)
        defer { try? provider.deleteKey() }
        let key = Data(repeating: 42, count: 32)
        try provider.storeKey(key)
        XCTAssertEqual(try provider.readKey(), key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        var synchronizedQuery = query
        synchronizedQuery[kSecAttrSynchronizable as String] = true
        XCTAssertEqual(SecItemCopyMatching(synchronizedQuery as CFDictionary, nil), errSecItemNotFound)
        do {
            try provider.deleteKey()
        } catch {
            // Capture only a numeric result from the same cleanup query. Never
            // print Keychain values or returned attributes. A successful retry
            // does not turn the original deletion failure into a passing test.
            let cleanupQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "encrypted-report-key-v1",
                kSecAttrSynchronizable as String: false
            ]
            let diagnosticStatus = SecItemDelete(cleanupQuery as CFDictionary)
            XCTFail("Keychain deletion failed. Cleanup diagnostic OSStatus: \(diagnosticStatus).")
            throw error
        }
        XCTAssertNil(try provider.readKey())
    }

    func testEncryptedRoundTripAndBackupExcludedFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = MemoryReportKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let report = testReport()

        try await store.save(report)
        let restored = try await store.load()
        XCTAssertEqual(restored, report)
        XCTAssertEqual(keys.currentKey?.count, 32)

        let file = directory.appendingPathComponent("report.encrypted")
        let ciphertext = try Data(contentsOf: file)
        let persistedText = String(decoding: ciphertext, as: UTF8.self)
        XCTAssertFalse(persistedText.contains("private-contact.example"))
        XCTAssertFalse(persistedText.contains("example.private-app"))
        XCTAssertFalse(persistedText.contains("observations"))
        let contents = try FileManager().contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.count, 1)

        for url in [directory, file] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }
    }

    func testCompleteFileProtectionRequiresPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("iOS hardware Data Protection is unavailable in Simulator. Run this test on a signed physical device with a passcode, and complete locked-device release QA.")
        #else
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: MemoryReportKeys())
        try await store.save(testReport())
        let file = directory.appendingPathComponent("report.encrypted")
        for url in [directory, file] {
            let attributes = try FileManager().attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
        }
        #endif
    }

    func testTamperingFailsClosedAndCannotSilentlyReplaceReport() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: MemoryReportKeys())
        try await store.save(testReport())
        let file = directory.appendingPathComponent("report.encrypted")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let base64 = try XCTUnwrap(envelope["sealedReport"] as? String)
        var payload = try XCTUnwrap(Data(base64Encoded: base64))
        let last = payload.index(before: payload.endIndex)
        payload[last] ^= 1
        envelope["sealedReport"] = payload.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        try tampered.write(to: file)

        do {
            _ = try await store.load()
            XCTFail("Authenticated decryption must reject modified ciphertext.")
        } catch {
            XCTAssertEqual(error as? ReportStoreError, .invalidReport)
        }
        do {
            try await store.save(testReport())
            XCTFail("Saving must not silently replace a damaged saved report.")
        } catch {
            XCTAssertEqual(error as? ReportStoreError, .invalidReport)
        }
        XCTAssertEqual(try Data(contentsOf: file), tampered)
    }

    func testMissingKeyDoesNotCreateReplacementKeyOrOverwriteCiphertext() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = MemoryReportKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        try await store.save(testReport())
        let file = directory.appendingPathComponent("report.encrypted")
        let original = try Data(contentsOf: file)
        try keys.deleteKey()

        do {
            try await store.save(testReport())
            XCTFail("A missing key must require an explicit reset.")
        } catch {
            XCTAssertEqual(error as? ReportStoreError, .missingKey)
        }
        XCTAssertNil(keys.currentKey)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDeleteRemovesCiphertextAndKeyAndNewKeyCannotUnlockCapturedCiphertext() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = MemoryReportKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        try await store.save(testReport())
        let file = directory.appendingPathComponent("report.encrypted")
        let captured = try Data(contentsOf: file)
        let originalKey = try XCTUnwrap(keys.currentKey)

        try await store.deleteAll()
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
        XCTAssertNil(keys.currentKey)
        let deleted = try await store.load()
        XCTAssertNil(deleted)

        try await store.save(testReport())
        XCTAssertNotEqual(keys.currentKey, originalKey)
        try captured.write(to: file)
        do {
            _ = try await store.load()
            XCTFail("Destroyed-key ciphertext must not decrypt under a new key.")
        } catch {
            XCTAssertEqual(error as? ReportStoreError, .invalidReport)
        }
    }

    func testKeyDeletionFailureIsReportedAndRetryRemovesResidualKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = MemoryReportKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        try await store.save(testReport())
        keys.failDeletion = true

        do {
            try await store.deleteAll()
            XCTFail("A failed key deletion must not claim all data was deleted.")
        } catch {
            XCTAssertEqual(error as? ReportStoreError, .deletionFailed)
        }
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
        XCTAssertNotNil(keys.currentKey)
        keys.failDeletion = false
        try await store.deleteAll()
        XCTAssertNil(keys.currentKey)
    }

    @MainActor
    func testModelKeepsDeletionFailureVisibleUntilCompleteRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let keys = MemoryReportKeys()
        let store = EncryptedReportStore(directoryURL: directory, keyProvider: keys)
        let report = testReport()
        try await store.save(report)
        let model = AppModel(store: store)
        await model.load()
        XCTAssertEqual(model.report, report)
        XCTAssertTrue(model.hasSavedReport)
        XCTAssertFalse(model.savedReportUnavailable)

        keys.failDeletion = true
        await model.deleteAll()
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
        XCTAssertNotNil(keys.currentKey)
        XCTAssertEqual(model.report, report)
        XCTAssertTrue(model.hasSavedReport)
        XCTAssertTrue(model.savedReportUnavailable)
        XCTAssertNotNil(model.notice)

        // Dismissing the error does not clear the saved-data warning. Only a
        // fully successful deletion retry can report that no data remains.
        model.notice = nil
        XCTAssertTrue(model.savedReportUnavailable)
        keys.failDeletion = false
        await model.deleteAll()
        XCTAssertNil(model.report)
        XCTAssertFalse(model.hasSavedReport)
        XCTAssertFalse(model.savedReportUnavailable)
        XCTAssertNil(keys.currentKey)
        XCTAssertNil(model.notice)
    }

    func testBoundedReaderAcceptsLimitAndRejectsOversizedFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("input.ndjson")
        let allowed = Data(repeating: 65, count: 128)
        try allowed.write(to: file)
        XCTAssertEqual(try ReportFileIO.readImportedData(from: file, maximumBytes: 128), allowed)
        try Data(repeating: 65, count: 129).write(to: file)
        XCTAssertThrowsError(try ReportFileIO.readImportedData(from: file, maximumBytes: 128)) { error in
            XCTAssertEqual(error as? ReportFileError, .tooLarge)
        }
    }

    func testExplicitExportIsNormalizedProtectedAndRemovedAfterSharing() throws {
        let report = testReport()
        let url = try ReportFileIO.makeExportFile(for: report)
        defer { try? ReportFileIO.removeExportFile(at: url) }
        let exported = try Data(contentsOf: url)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(envelope["schemaVersion"] as? Int, 1)
        XCTAssertEqual(envelope["isSyntheticDemo"] as? Bool, false)
        let notice = try XCTUnwrap(envelope["exportNotice"] as? String)
        XCTAssertTrue(notice.contains("outside your device"))
        let normalized = try XCTUnwrap(envelope["report"] as? [String: Any])
        let reconstructed = try JSONDecoder().decode(
            PrivacyReport.self,
            from: JSONSerialization.data(withJSONObject: normalized)
        )
        XCTAssertEqual(reconstructed, report)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try ReportFileIO.removeExportFile(at: url)
        XCTAssertFalse(FileManager().fileExists(atPath: url.path))
    }

    func testExportIdentifiesSyntheticDemoExplicitly() throws {
        let url = try ReportFileIO.makeExportFile(for: .demo, isSyntheticDemo: true)
        defer { try? ReportFileIO.removeExportFile(at: url) }
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(envelope["isSyntheticDemo"] as? Bool, true)
    }

    private func temporaryDirectory() -> URL {
        FileManager().temporaryDirectory.appendingPathComponent("FirePrivacyStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func testReport() -> PrivacyReport {
        PrivacyReport(importedAt: Date(timeIntervalSince1970: 1_760_000_000), observations: [
            Observation(
                bundleID: "example.private-app",
                domain: "private-contact.example",
                category: .network,
                accessType: "networkActivity",
                count: 7
            )
        ])
    }
}

/// Deliberately does not touch the user's Keychain. All shared state is locked.
private final class MemoryReportKeys: ReportKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var deletionFailure = false

    var currentKey: Data? { lock.withLock { key } }
    var failDeletion: Bool {
        get { lock.withLock { deletionFailure } }
        set { lock.withLock { deletionFailure = newValue } }
    }

    func readKey() throws -> Data? { lock.withLock { key } }

    func storeKey(_ newKey: Data) throws {
        try lock.withLock {
            guard key == nil else { throw ReportStoreError.keyUnavailable }
            key = newKey
        }
    }

    func deleteKey() throws {
        try lock.withLock {
            if deletionFailure { throw ReportStoreError.deletionFailed }
            key = nil
        }
    }
}
