import CryptoKit
import Darwin
import Foundation
import FirePrivacyCore
import Security

enum ReportStoreError: LocalizedError, Equatable {
    case storageUnavailable
    case keyUnavailable
    case missingKey
    case invalidKey
    case invalidReport
    case unsupportedFormat
    case persistenceFailed
    case deletionFailed

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Protected local storage is unavailable. Unlock your device and try again."
        case .keyUnavailable:
            "The local encryption key is unavailable. Unlock your device and try again."
        case .missingKey, .invalidKey:
            "The saved report cannot be unlocked. Delete local data before saving a new report."
        case .invalidReport:
            "The saved report could not be verified. Delete local data before saving a new report."
        case .unsupportedFormat:
            "The saved report uses an unsupported format."
        case .persistenceFailed:
            "The report could not be saved securely. Your previous saved report has been preserved."
        case .deletionFailed:
            "Local data could not be completely deleted. Unlock your device and try again."
        }
    }
}

/// Providers must be safe to call from the store actor. `storeKey` must never
/// replace an existing key, since that would make an existing report unreadable.
protocol ReportKeyProvider: Sendable {
    func readKey() throws -> Data?
    func storeKey(_ key: Data) throws
    func deleteKey() throws
}

struct KeychainReportKeyProvider: ReportKeyProvider {
    private let service: String
    private let account = "encrypted-report-key-v1"

    init(service: String? = nil) {
        self.service = service ?? "\(Bundle.main.bundleIdentifier ?? "org.fireprivacy.app").local-report"
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func readKey() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ReportStoreError.keyUnavailable
        }
        return data
    }

    func storeKey(_ key: Data) throws {
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = key
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ReportStoreError.keyUnavailable
        }
    }

    func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReportStoreError.deletionFailed
        }
    }
}

/// Bounded report history and feature state, authenticated with a device-only key.
/// Raw imports enter storage only when the caller supplies an explicitly authorized copy.
actor EncryptedReportStore {
    private struct Envelope: Codable {
        let version: Int
        let sealedReport: Data
    }

    private static let formatVersion = 1
    private static let authenticatedContext = Data("FirePrivacy/PrivacyReport/v1".utf8)
    private static let maximumStoredBytes = 48 * 1_024 * 1_024
    private let injectedDirectoryURL: URL?
    private let keyProvider: any ReportKeyProvider
    private let fileManager = FileManager()

    init(directoryURL: URL? = nil, keyProvider: any ReportKeyProvider = KeychainReportKeyProvider()) {
        injectedDirectoryURL = directoryURL
        self.keyProvider = keyProvider
    }

    func load() throws -> PrivacyReport? {
        let directory = try directoryURL()
        let reportURL = directory.appendingPathComponent("report.encrypted", isDirectory: false)
        guard fileManager.fileExists(atPath: reportURL.path) else { return nil }
        guard let keyData = try keyProvider.readKey() else { throw ReportStoreError.missingKey }
        guard keyData.count == 32 else { throw ReportStoreError.invalidKey }

        let encoded: Data
        do {
            encoded = try ReportFileIO.readBoundedData(from: reportURL, maximumBytes: Self.maximumStoredBytes)
        } catch {
            throw ReportStoreError.storageUnavailable
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: encoded)
        } catch {
            throw ReportStoreError.invalidReport
        }
        guard envelope.version == Self.formatVersion else { throw ReportStoreError.unsupportedFormat }

        do {
            let sealed = try AES.GCM.SealedBox(combined: envelope.sealedReport)
            let cleartext = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: keyData),
                authenticating: Self.authenticatedContext
            )
            return try JSONDecoder().decode(PrivacyReport.self, from: cleartext)
        } catch {
            throw ReportStoreError.invalidReport
        }
    }

    func save(_ report: PrivacyReport) throws {
        let directory = try directoryURL()
        let reportURL = directory.appendingPathComponent("report.encrypted", isDirectory: false)
        // Fail closed if a previous report cannot be read. Do not silently
        // replace inaccessible or damaged data with a newly created key.
        if fileManager.fileExists(atPath: reportURL.path) { _ = try load() }
        try prepareDirectory(directory)

        let keyData: Data
        if let existing = try keyProvider.readKey() {
            guard existing.count == 32 else { throw ReportStoreError.invalidKey }
            keyData = existing
        } else {
            var random = Data(count: 32)
            let status = random.withUnsafeMutableBytes { bytes in
                guard let address = bytes.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
            }
            guard status == errSecSuccess else { throw ReportStoreError.keyUnavailable }
            // Persist the key before committing ciphertext. A failed write may
            // leave an unused key; keeping it permits a safe retry or deletion.
            try keyProvider.storeKey(random)
            keyData = random
        }

        let encrypted: Data
        do {
            let cleartext = try JSONEncoder().encode(report)
            let box = try AES.GCM.seal(
                cleartext,
                using: SymmetricKey(data: keyData),
                authenticating: Self.authenticatedContext
            )
            guard let combined = box.combined else { throw ReportStoreError.persistenceFailed }
            encrypted = try JSONEncoder().encode(Envelope(version: Self.formatVersion, sealedReport: combined))
            guard encrypted.count <= Self.maximumStoredBytes else { throw ReportStoreError.persistenceFailed }
        } catch {
            throw ReportStoreError.persistenceFailed
        }

        let stagedURL = directory.appendingPathComponent(".report-\(UUID().uuidString).encrypted")
        defer { try? fileManager.removeItem(at: stagedURL) }
        do {
            // The staged file receives protection and backup exclusion before
            // the atomic rename, so metadata failures cannot replace old data.
            try ReportFileIO.writeProtectedData(encrypted, to: stagedURL)
            let result = stagedURL.withUnsafeFileSystemRepresentation { source in
                reportURL.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination else { return Int32(-1) }
                    return Darwin.rename(source, destination)
                }
            }
            guard result == 0 else { throw ReportStoreError.persistenceFailed }
        } catch {
            throw ReportStoreError.persistenceFailed
        }
    }

    func deleteAll() throws {
        let directory = try directoryURL()
        // Remove the whole dedicated directory, including encrypted staging
        // files left by an interrupted write. If removal fails, preserve the
        // key so the report remains recoverable and propagate the failure.
        do {
            try ReportFileIO.removeAllExportFiles()
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        } catch {
            throw ReportStoreError.deletionFailed
        }
        // A failed key deletion is surfaced even after ciphertext was removed.
        // Retrying Delete All removes the remaining key without needing a file.
        do {
            try keyProvider.deleteKey()
        } catch {
            throw ReportStoreError.deletionFailed
        }
    }

    /// Loads the bounded multi-report workspace. Migration commits an authenticated
    /// index before removing the legacy file; a failed migration preserves it.
    func loadWorkspace() throws -> EncryptedWorkspaceSnapshot {
        let directory = try directoryURL()
        let indexURL = directory.appendingPathComponent("workspace.encrypted")
        if fileManager.fileExists(atPath: indexURL.path) {
            let index: EncryptedWorkspaceIndex = try readRecord(from: indexURL, context: "FirePrivacy/Workspace/v2", limit: 262_144)
            try index.validate()
            let selected = try index.selectedReportID.map { try loadSession($0, index: index, directory: directory) }
            return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions,
                                              retention: index.retention, migratedLegacyReport: false)
        }
        if let legacy = try load() {
            let snapshot = try appendSession(legacy)
            // Removing the extra legacy ciphertext is housekeeping. It stays
            // encrypted and remains covered by Delete All if removal fails.
            try? fileManager.removeItem(at: directory.appendingPathComponent("report.encrypted"))
            return EncryptedWorkspaceSnapshot(selectedReport: snapshot.selectedReport, sessions: snapshot.sessions,
                                              retention: snapshot.retention, migratedLegacyReport: true)
        }
        let empty = EncryptedWorkspaceIndex()
        return EncryptedWorkspaceSnapshot(selectedReport: nil, sessions: [], retention: empty.retention, migratedLegacyReport: false)
    }

    func appendSession(_ report: PrivacyReport, encryptedSource: Data? = nil) throws -> EncryptedWorkspaceSnapshot {
        let directory = try directoryURL()
        var index = try readWorkspaceIndex(directory)
        if let source = encryptedSource {
            guard source.count <= ReportImporter.maximumFileBytes,
                  let expected = report.metadata?.sourceSHA256,
                  ContentDigest.sha256(source) == expected else { throw ReportStoreError.invalidReport }
        }
        if index.sessions.contains(where: { $0.id == report.id }) {
            let selected = try loadSession(report.id, index: index, directory: directory)
            if let source = encryptedSource {
                guard selected.metadata?.sourceSHA256 == ContentDigest.sha256(source),
                      let position = index.sessions.firstIndex(where: { $0.id == report.id }) else {
                    throw ReportStoreError.invalidReport
                }
                let history = directory.appendingPathComponent("history", isDirectory: true)
                let sourceURL = history.appendingPathComponent("\(report.id.uuidString).source.encrypted")
                let old = index.sessions[position]
                if old.retainsEncryptedSource {
                    let retained: Data = try readRecord(from: sourceURL, context: "FirePrivacy/RawSource/v2/\(report.id.uuidString)", limit: 32 * 1_024 * 1_024)
                    guard retained == source else { throw ReportStoreError.invalidReport }
                } else {
                    let bytes = try sealRecord(source, context: "FirePrivacy/RawSource/v2/\(report.id.uuidString)", limit: 32 * 1_024 * 1_024)
                    let previous = index.sessions
                    index.sessions[position] = ReportSessionDescriptor(id: old.id, importedAt: old.importedAt,
                        observationCount: old.observationCount, contactCount: old.contactCount,
                        encryptedBytes: old.encryptedBytes, encryptedSourceBytes: bytes.count, sourceSHA256: old.sourceSHA256)
                    try pruneIndex(&index, preserving: report.id)
                    index.selectedReportID = report.id
                    try atomicallyWrite(bytes, to: sourceURL)
                    do { try writeWorkspaceIndex(index, directory: directory) }
                    catch { try? fileManager.removeItem(at: sourceURL); throw error }
                    for oldSession in previous where !index.sessions.contains(where: { $0.id == oldSession.id }) {
                        try? fileManager.removeItem(at: history.appendingPathComponent("\(oldSession.id.uuidString).encrypted"))
                        try? fileManager.removeItem(at: history.appendingPathComponent("\(oldSession.id.uuidString).source.encrypted"))
                    }
                    return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions,
                        retention: index.retention, migratedLegacyReport: false)
                }
            }
            index.selectedReportID = report.id
            try writeWorkspaceIndex(index, directory: directory)
            return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions,
                                              retention: index.retention, migratedLegacyReport: false)
        }
        let reportBytes = try sealRecord(report, context: "FirePrivacy/HistoryReport/v2/\(report.id.uuidString)", limit: Self.maximumStoredBytes)
        let sourceBytes = try encryptedSource.map {
            try sealRecord($0, context: "FirePrivacy/RawSource/v2/\(report.id.uuidString)", limit: 32 * 1_024 * 1_024)
        }
        let item = ReportSessionDescriptor(id: report.id, importedAt: report.importedAt,
                                           observationCount: report.observations.count, contactCount: report.totalContacts,
                                           encryptedBytes: reportBytes.count, encryptedSourceBytes: sourceBytes?.count ?? 0,
                                           sourceSHA256: report.metadata?.sourceSHA256)
        let previous = index.sessions
        index.sessions.append(item)
        index.selectedReportID = report.id
        try pruneIndex(&index, preserving: report.id)
        try index.validate()
        let history = directory.appendingPathComponent("history", isDirectory: true)
        try prepareDirectory(history)
        let reportURL = history.appendingPathComponent("\(report.id.uuidString).encrypted")
        let sourceURL = history.appendingPathComponent("\(report.id.uuidString).source.encrypted")
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: reportURL)
                try? fileManager.removeItem(at: sourceURL)
            }
        }
        try atomicallyWrite(reportBytes, to: reportURL)
        if let sourceBytes { try atomicallyWrite(sourceBytes, to: sourceURL) }
        try writeWorkspaceIndex(index, directory: directory)
        committed = true
        // Index commit selects the new complete session before old ciphertext
        // is removed. Never remove the previous index on a failed write.
        for old in previous where !index.sessions.contains(where: { $0.id == old.id }) {
            try? fileManager.removeItem(at: history.appendingPathComponent("\(old.id.uuidString).encrypted"))
            try? fileManager.removeItem(at: history.appendingPathComponent("\(old.id.uuidString).source.encrypted"))
        }
        return EncryptedWorkspaceSnapshot(selectedReport: report, sessions: index.sessions,
                                          retention: index.retention, migratedLegacyReport: false)
    }

    func selectSession(_ id: UUID) throws -> EncryptedWorkspaceSnapshot {
        let directory = try directoryURL()
        var index = try readWorkspaceIndex(directory)
        let selected = try loadSession(id, index: index, directory: directory)
        index.selectedReportID = id
        try writeWorkspaceIndex(index, directory: directory)
        return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions,
                                          retention: index.retention, migratedLegacyReport: false)
    }

    func reportSession(_ id: UUID) throws -> PrivacyReport {
        let directory = try directoryURL()
        return try loadSession(id, index: readWorkspaceIndex(directory), directory: directory)
    }

    func deleteSession(_ id: UUID) throws -> EncryptedWorkspaceSnapshot {
        let directory = try directoryURL()
        var index = try readWorkspaceIndex(directory)
        guard index.sessions.contains(where: { $0.id == id }) else { throw ReportStoreError.invalidReport }
        index.sessions.removeAll { $0.id == id }
        if index.selectedReportID == id { index.selectedReportID = index.sessions.last?.id }
        let selected = try index.selectedReportID.map { try loadSession($0, index: index, directory: directory) }
        try writeWorkspaceIndex(index, directory: directory)
        do {
            for suffix in [".encrypted", ".source.encrypted"] {
                let path = directory.appendingPathComponent("history/\(id.uuidString)\(suffix)")
                if fileManager.fileExists(atPath: path.path) { try fileManager.removeItem(at: path) }
            }
        } catch { throw ReportStoreError.deletionFailed }
        return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions,
            retention: index.retention, migratedLegacyReport: false)
    }

    func removeRetainedSources() throws -> EncryptedWorkspaceSnapshot {
        let directory = try directoryURL()
        var index = try readWorkspaceIndex(directory)
        let history = directory.appendingPathComponent("history", isDirectory: true)
        do {
            if fileManager.fileExists(atPath: history.path) {
                for path in try fileManager.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
                    where path.lastPathComponent.hasSuffix(".source.encrypted") { try fileManager.removeItem(at: path) }
            }
        } catch { throw ReportStoreError.deletionFailed }
        index.sessions = index.sessions.map {
            ReportSessionDescriptor(id: $0.id, importedAt: $0.importedAt, observationCount: $0.observationCount,
                contactCount: $0.contactCount, encryptedBytes: $0.encryptedBytes, encryptedSourceBytes: 0,
                sourceSHA256: $0.sourceSHA256)
        }
        try writeWorkspaceIndex(index, directory: directory)
        let selected = try index.selectedReportID.map { try loadSession($0, index: index, directory: directory) }
        return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions,
            retention: index.retention, migratedLegacyReport: false)
    }

    func updateRetention(_ policy: WorkspaceRetentionPolicy) throws -> EncryptedWorkspaceSnapshot {
        try policy.validate()
        let directory = try directoryURL()
        var index = try readWorkspaceIndex(directory)
        let previous = index.sessions
        index.retention = policy
        try pruneIndex(&index, preserving: index.selectedReportID)
        try writeWorkspaceIndex(index, directory: directory)
        let history = directory.appendingPathComponent("history", isDirectory: true)
        for old in previous where !index.sessions.contains(where: { $0.id == old.id }) {
            try? fileManager.removeItem(at: history.appendingPathComponent("\(old.id.uuidString).encrypted"))
            try? fileManager.removeItem(at: history.appendingPathComponent("\(old.id.uuidString).source.encrypted"))
        }
        let selected = try index.selectedReportID.map { try loadSession($0, index: index, directory: directory) }
        return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions,
                                          retention: index.retention, migratedLegacyReport: false)
    }

    func saveFeatureState<Value: Codable & Sendable>(_ value: Value, key: String) throws {
        let url = try featureURL(key)
        if fileManager.fileExists(atPath: url.path) {
            // Authentication must succeed before replacing an existing value.
            let _: Value = try readRecord(from: url, context: "FirePrivacy/Feature/v2/\(key)", limit: 12 * 1_024 * 1_024)
        }
        let bytes = try sealRecord(value, context: "FirePrivacy/Feature/v2/\(key)", limit: 12 * 1_024 * 1_024)
        let siblings = try fileManager.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])
        let replacing = siblings.contains(url)
        guard siblings.count < 24 || (replacing && siblings.count == 24) else { throw ReportStoreError.persistenceFailed }
        var total = bytes.count
        for sibling in siblings where sibling != url {
            let size = try sibling.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow, sum <= 32 * 1_024 * 1_024 else { throw ReportStoreError.persistenceFailed }
            total = sum
        }
        try atomicallyWrite(bytes, to: url)
    }

    func loadFeatureState<Value: Codable & Sendable>(_ type: Value.Type, key: String) throws -> Value? {
        let url = try featureURL(key, createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readRecord(from: url, context: "FirePrivacy/Feature/v2/\(key)", limit: 12 * 1_024 * 1_024)
    }

    func hasLocalData() throws -> Bool {
        let directory = try directoryURL()
        if try keyProvider.readKey() != nil { return true }
        return fileManager.fileExists(atPath: directory.path)
    }

    private func featureURL(_ key: String, createDirectory: Bool = true) throws -> URL {
        guard !key.isEmpty, key.utf8.count <= 48,
              key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw ReportStoreError.persistenceFailed
        }
        let folder = try directoryURL().appendingPathComponent("features", isDirectory: true)
        if createDirectory { try prepareDirectory(folder) }
        return folder.appendingPathComponent("\(key).encrypted")
    }

    private func readWorkspaceIndex(_ directory: URL) throws -> EncryptedWorkspaceIndex {
        let path = directory.appendingPathComponent("workspace.encrypted")
        guard fileManager.fileExists(atPath: path.path) else {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("report.encrypted").path) { _ = try load() }
            return EncryptedWorkspaceIndex()
        }
        let index: EncryptedWorkspaceIndex = try readRecord(from: path, context: "FirePrivacy/Workspace/v2", limit: 262_144)
        try index.validate()
        return index
    }

    private func writeWorkspaceIndex(_ index: EncryptedWorkspaceIndex, directory: URL) throws {
        try index.validate()
        try prepareDirectory(directory)
        let bytes = try sealRecord(index, context: "FirePrivacy/Workspace/v2", limit: 262_144)
        try atomicallyWrite(bytes, to: directory.appendingPathComponent("workspace.encrypted"))
    }

    private func loadSession(_ id: UUID, index: EncryptedWorkspaceIndex, directory: URL) throws -> PrivacyReport {
        guard index.sessions.contains(where: { $0.id == id }) else { throw ReportStoreError.invalidReport }
        let path = directory.appendingPathComponent("history/\(id.uuidString).encrypted")
        let report: PrivacyReport = try readRecord(from: path, context: "FirePrivacy/HistoryReport/v2/\(id.uuidString)", limit: Self.maximumStoredBytes)
        guard report.id == id else { throw ReportStoreError.invalidReport }
        return report
    }

    private func pruneIndex(_ index: inout EncryptedWorkspaceIndex, preserving id: UUID?) throws {
        func total() -> Int { index.sessions.reduce(0) { $0 + $1.encryptedBytes + $1.encryptedSourceBytes } }
        while index.sessions.count > index.retention.maximumReports || total() > index.retention.maximumStoredBytes {
            guard let remove = index.sessions.firstIndex(where: { $0.id != id }) else { throw ReportStoreError.persistenceFailed }
            index.sessions.remove(at: remove)
        }
    }

    private func readRecord<Value: Decodable>(from url: URL, context: String, limit: Int) throws -> Value {
        guard let key = try keyProvider.readKey() else { throw ReportStoreError.missingKey }
        guard key.count == 32 else { throw ReportStoreError.invalidKey }
        do {
            let bytes = try ReportFileIO.readBoundedData(from: url, maximumBytes: limit)
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 2 else { throw ReportStoreError.unsupportedFormat }
            let box = try AES.GCM.SealedBox(combined: envelope.sealedReport)
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(context.utf8))
            return try JSONDecoder().decode(Value.self, from: plaintext)
        } catch let error as ReportStoreError { throw error }
        catch { throw ReportStoreError.invalidReport }
    }

    private func sealRecord<Value: Encodable>(_ value: Value, context: String, limit: Int) throws -> Data {
        let key: Data
        if let existing = try keyProvider.readKey() {
            guard existing.count == 32 else { throw ReportStoreError.invalidKey }
            key = existing
        } else {
            var generated = Data(count: 32)
            let status = generated.withUnsafeMutableBytes { buffer in
                guard let address = buffer.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
            }
            guard status == errSecSuccess else { throw ReportStoreError.keyUnavailable }
            try keyProvider.storeKey(generated)
            key = generated
        }
        do {
            let cleartext = try JSONEncoder().encode(value)
            guard cleartext.count <= limit else { throw ReportStoreError.persistenceFailed }
            let box = try AES.GCM.seal(cleartext, using: SymmetricKey(data: key), authenticating: Data(context.utf8))
            guard let combined = box.combined else { throw ReportStoreError.persistenceFailed }
            let encoded = try JSONEncoder().encode(Envelope(version: 2, sealedReport: combined))
            guard encoded.count <= limit else { throw ReportStoreError.persistenceFailed }
            return encoded
        } catch { throw ReportStoreError.persistenceFailed }
    }

    private func atomicallyWrite(_ data: Data, to destination: URL) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".staged-\(UUID().uuidString).encrypted")
        defer { try? fileManager.removeItem(at: staged) }
        do {
            try ReportFileIO.writeProtectedData(data, to: staged)
            let status = staged.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    guard let source, let target else { return Int32(-1) }
                    return Darwin.rename(source, target)
                }
            }
            guard status == 0 else { throw ReportStoreError.persistenceFailed }
        } catch { throw ReportStoreError.persistenceFailed }
    }

    private func directoryURL() throws -> URL {
        if let injectedDirectoryURL { return injectedDirectoryURL }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ReportStoreError.storageUnavailable
        }
        return support.appendingPathComponent("FirePrivacy", isDirectory: true)
    }

    private func prepareDirectory(_ directory: URL) throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
        } catch {
            throw ReportStoreError.storageUnavailable
        }
    }
}
