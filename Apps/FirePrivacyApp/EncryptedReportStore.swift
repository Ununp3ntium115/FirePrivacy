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
    case staleGeneration
    case cleanupPending
    case rotationUnsupported
    case rotationRecoveryRequired
    case rotationCleanupPending
    case storageInUse
    case preconditionFailed

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
        case .staleGeneration:
            "This operation belongs to an earlier local-data session and was cancelled."
        case .cleanupPending:
            "Encrypted local files are still awaiting deletion. Retry cleanup before saving more data."
        case .rotationUnsupported:
            "This local key provider does not support safe key rotation."
        case .rotationRecoveryRequired:
            "Encryption-key rotation could not be recovered. Your encrypted data has been preserved."
        case .rotationCleanupPending:
            "The active encryption key is ready, but old encrypted data or key material still awaits cleanup. Retry key-rotation cleanup."
        case .storageInUse:
            "Another local-storage instance is already active."
        case .preconditionFailed:
            "Local state changed while this operation was running. Retry using the current state."
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
    var serviceIdentifier: String { service }

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
        // Reset removes both slots even if an interrupted journal cannot decode.
        var failed = false
        for slot in [account, "encrypted-report-key-rotation-v1"] {
            var deletion = query
            deletion[kSecAttrAccount as String] = slot
            let status = SecItemDelete(deletion as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { failed = true }
        }
        if failed { throw ReportStoreError.deletionFailed }
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
    private let fileRemoval: @Sendable (URL) throws -> Void
    private var storageGeneration = UUID()
    private let leaseOwner = UUID()
    private var directoryLease: ReportStorageDirectoryLease?
    private var rotationInProgress = false
    private var observedRotationTransactionID: UUID?
    private let rotationCheckpoint: @Sendable (RotationInterruptionPoint) throws -> Void

    init(directoryURL: URL? = nil, keyProvider: any ReportKeyProvider = KeychainReportKeyProvider(),
         fileRemoval: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
         rotationCheckpoint: @escaping @Sendable (RotationInterruptionPoint) throws -> Void = { _ in }) {
        injectedDirectoryURL = directoryURL
        self.keyProvider = keyProvider
        self.fileRemoval = fileRemoval
        self.rotationCheckpoint = rotationCheckpoint
    }

    deinit {
        if let directoryLease { ReportStorageLeaseRegistry.shared.release(directoryLease) }
    }

    func currentStorageGeneration() -> UUID { storageGeneration }
    private func validateGeneration(_ expected: UUID?) throws {
        if let expected, expected != storageGeneration { throw ReportStoreError.staleGeneration }
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

    func save(_ report: PrivacyReport, expectedGeneration: UUID? = nil) throws {
        try validateGeneration(expectedGeneration)
        let directory = try directoryURL()
        try validateGeneration(expectedGeneration)
        try requireRotationReadyForMutation()
        try ensureExistingCiphertextHasKey(directory)
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
            try RotationDurability.synchronizeDirectory(at: directory)
        } catch {
            throw ReportStoreError.persistenceFailed
        }
    }

    func deleteAll() throws {
        // Invalidate late actor jobs before any operation that can fail.
        storageGeneration = UUID()
        let directory = try leasedRawDirectoryURL()
        do {
            try ReportFileIO.removeAllExportFiles()
            var owned = [directory]
            let parent = directory.deletingLastPathComponent()
            if fileManager.fileExists(atPath: parent.path) {
                let siblings = try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                let prefixes = [directory.lastPathComponent + ".rotation-stage-", directory.lastPathComponent + ".rotation-retired-"]
                for sibling in siblings {
                    for prefix in prefixes where sibling.lastPathComponent.hasPrefix(prefix) {
                        let suffix = String(sibling.lastPathComponent.dropFirst(prefix.count))
                        guard let id = UUID(uuidString: suffix), id.uuidString == suffix else { throw ReportStoreError.deletionFailed }
                        owned.append(sibling)
                    }
                }
            }
            for path in owned where fileManager.fileExists(atPath: path.path) {
                try fileRemoval(path)
                guard !fileManager.fileExists(atPath: path.path) else { throw ReportStoreError.deletionFailed }
            }
            if fileManager.fileExists(atPath: parent.path) { try RotationDurability.synchronizeDirectory(at: parent) }
        } catch { throw ReportStoreError.deletionFailed }
        // Pending keys are deleted only once every owned generation is absent.
        do { try keyProvider.deleteKey() }
        catch { throw ReportStoreError.deletionFailed }
    }

    /// Loads the bounded multi-report workspace. Migration commits an authenticated
    /// index before removing the legacy file; a failed migration preserves it.
    func loadWorkspace() throws -> EncryptedWorkspaceSnapshot {
        let directory = try directoryURL()
        let indexURL = directory.appendingPathComponent("workspace.encrypted")
        if fileManager.fileExists(atPath: indexURL.path) {
            var index: EncryptedWorkspaceIndex = try readRecord(from: indexURL, context: "FirePrivacy/Workspace/v2", limit: 262_144)
            try index.validate()
            // New-key evidence remains readable if retired-key cleanup is pending.
            // Do not mutate this generation until the journal can be cleared.
            if try hasPendingRotation() { return try workspaceSnapshot(index, directory: directory) }
            let original = index.pendingCleanup
            try discoverUnreferencedCiphertext(in: &index, directory: directory)
            if original != index.pendingCleanup { try writeWorkspaceIndex(index, directory: directory) }
            do { try performPendingCleanup(&index, directory: directory) }
            catch ReportStoreError.cleanupPending { /* Keep selected evidence readable and report pending work. */ }
            return try workspaceSnapshot(index, directory: directory)
        }
        if let legacy = try load() {
            let snapshot = try appendSession(legacy)
            return EncryptedWorkspaceSnapshot(selectedReport: snapshot.selectedReport, sessions: snapshot.sessions,
                                              retention: snapshot.retention, migratedLegacyReport: true)
        }
        let empty = EncryptedWorkspaceIndex()
        return EncryptedWorkspaceSnapshot(selectedReport: nil, sessions: [], retention: empty.retention, migratedLegacyReport: false)
    }

    func appendSession(_ report: PrivacyReport, encryptedSource: Data? = nil, expectedGeneration: UUID? = nil) throws -> EncryptedWorkspaceSnapshot {
        try validateGeneration(expectedGeneration)
        let directory = try directoryURL()
        try validateGeneration(expectedGeneration)
        var index = try prepareWorkspaceForMutation(directory)
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
                    index.sessions[position] = ReportSessionDescriptor(id: old.id, importedAt: old.importedAt,
                        observationCount: old.observationCount, contactCount: old.contactCount,
                        encryptedBytes: old.encryptedBytes, encryptedSourceBytes: bytes.count, sourceSHA256: old.sourceSHA256)
                    try pruneIndex(&index, preserving: report.id)
                    index.selectedReportID = report.id
                    try atomicallyWrite(bytes, to: sourceURL)
                    do { try writeWorkspaceIndex(index, directory: directory) }
                    catch { try? fileManager.removeItem(at: sourceURL); throw error }
                    try performPendingCleanup(&index, directory: directory)
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
        try performPendingCleanup(&index, directory: directory)
        return EncryptedWorkspaceSnapshot(selectedReport: report, sessions: index.sessions,
                                          retention: index.retention, migratedLegacyReport: false)
    }

    func selectSession(_ id: UUID, expectedGeneration: UUID? = nil) throws -> EncryptedWorkspaceSnapshot {
        try validateGeneration(expectedGeneration)
        let directory = try directoryURL()
        try validateGeneration(expectedGeneration)
        var index = try prepareWorkspaceForMutation(directory)
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

    func deleteSession(_ id: UUID, expectedGeneration: UUID? = nil) throws -> EncryptedWorkspaceSnapshot {
        try validateGeneration(expectedGeneration)
        storageGeneration = UUID()
        let directory = try directoryURL()
        var index = try prepareWorkspaceForMutation(directory)
        if let item = index.sessions.first(where: { $0.id == id }) {
            index.sessions.removeAll { $0.id == id }
            queueCleanup(item, in: &index)
            if index.selectedReportID == id { index.selectedReportID = index.sessions.last?.id }
            try writeWorkspaceIndex(index, directory: directory)
            try performPendingCleanup(&index, directory: directory)
        }
        // Idempotent after a prior index commit, including a failed cleanup retry.
        return try workspaceSnapshot(index, directory: directory)
    }

    func removeRetainedSources(expectedGeneration: UUID? = nil) throws -> EncryptedWorkspaceSnapshot {
        try validateGeneration(expectedGeneration)
        storageGeneration = UUID()
        let directory = try directoryURL()
        var index = try prepareWorkspaceForMutation(directory)
        for item in index.sessions where item.retainsEncryptedSource {
            addCleanup(CiphertextCleanupTask(kind: .rawSource, identifier: item.id, encryptedBytes: item.encryptedSourceBytes), in: &index)
        }
        index.sessions = index.sessions.map {
            ReportSessionDescriptor(id: $0.id, importedAt: $0.importedAt, observationCount: $0.observationCount,
                contactCount: $0.contactCount, encryptedBytes: $0.encryptedBytes, encryptedSourceBytes: 0, sourceSHA256: $0.sourceSHA256)
        }
        try writeWorkspaceIndex(index, directory: directory)
        try performPendingCleanup(&index, directory: directory)
        return try workspaceSnapshot(index, directory: directory)
    }

    func updateRetention(_ policy: WorkspaceRetentionPolicy, expectedGeneration: UUID? = nil) throws -> EncryptedWorkspaceSnapshot {
        try validateGeneration(expectedGeneration)
        try policy.validate()
        storageGeneration = UUID()
        let directory = try directoryURL()
        var index = try prepareWorkspaceForMutation(directory)
        index.retention = policy
        try pruneIndex(&index, preserving: index.selectedReportID)
        try writeWorkspaceIndex(index, directory: directory)
        try performPendingCleanup(&index, directory: directory)
        let selected = try index.selectedReportID.map { try loadSession($0, index: index, directory: directory) }
        return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions,
                                          retention: index.retention, migratedLegacyReport: false)
    }

    func saveFeatureState<Value: Codable & Sendable>(_ value: Value, key: String, expectedGeneration: UUID? = nil,
                                                   expectedCurrent: FeatureStatePrecondition? = nil) throws {
        try validateGeneration(expectedGeneration)
        let directory = try directoryURL()
        try validateGeneration(expectedGeneration)
        // The state comparison runs in this actor before any file or key creation.
        let existingURL = try featureURL(key, createDirectory: false)
        let currentBytes = fileManager.fileExists(atPath: existingURL.path)
            ? try readPlaintext(from: existingURL, context: "FirePrivacy/Feature/v2/\(key)", limit: 12 * 1_024 * 1_024) : nil
        // Decode as well as authenticate before allowing any replacement. Hash the
        // original plaintext, since Codable Set iteration is not canonical JSON.
        if let currentBytes { _ = try decodeRecord(Value.self, plaintext: currentBytes) }
        let actual: FeatureStatePrecondition = currentBytes.map { .checksum(ContentDigest.sha256($0)) } ?? .absent
        if let expectedCurrent, expectedCurrent != actual { throw ReportStoreError.preconditionFailed }
        _ = try prepareWorkspaceForMutation(directory)
        let url = try featureURL(key)
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

    func loadFeatureSnapshot<Value: Codable & Sendable>(_ type: Value.Type, key: String) throws -> FeatureStateSnapshot<Value> {
        let url = try featureURL(key, createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return FeatureStateSnapshot(value: nil, precondition: .absent) }
        let bytes = try readPlaintext(from: url, context: "FirePrivacy/Feature/v2/\(key)", limit: 12 * 1_024 * 1_024)
        let value = try decodeRecord(type, plaintext: bytes)
        return FeatureStateSnapshot(value: value, precondition: .checksum(ContentDigest.sha256(bytes)))
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

    func retryPendingCleanup(expectedGeneration: UUID? = nil) throws -> EncryptedWorkspaceSnapshot {
        try validateGeneration(expectedGeneration)
        let directory = try directoryURL()
        try validateGeneration(expectedGeneration)
        let index = try prepareWorkspaceForMutation(directory)
        return try workspaceSnapshot(index, directory: directory)
    }

    private func workspaceSnapshot(_ index: EncryptedWorkspaceIndex, directory: URL, migrated: Bool = false) throws -> EncryptedWorkspaceSnapshot {
        let selected = try index.selectedReportID.map { try loadSession($0, index: index, directory: directory) }
        return EncryptedWorkspaceSnapshot(selectedReport: selected, sessions: index.sessions, retention: index.retention,
            migratedLegacyReport: migrated, pendingCleanupCount: index.pendingCleanup.count)
    }

    private func addCleanup(_ task: CiphertextCleanupTask, in index: inout EncryptedWorkspaceIndex) {
        if !index.pendingCleanup.contains(where: { $0.id == task.id }) { index.pendingCleanup.append(task) }
    }

    private func queueCleanup(_ item: ReportSessionDescriptor, in index: inout EncryptedWorkspaceIndex) {
        addCleanup(CiphertextCleanupTask(kind: .historyReport, identifier: item.id, encryptedBytes: item.encryptedBytes), in: &index)
        if item.retainsEncryptedSource {
            addCleanup(CiphertextCleanupTask(kind: .rawSource, identifier: item.id, encryptedBytes: item.encryptedSourceBytes), in: &index)
        }
    }

    private func performPendingCleanup(_ index: inout EncryptedWorkspaceIndex, directory: URL) throws {
        guard !index.pendingCleanup.isEmpty else { return }
        var remaining: [CiphertextCleanupTask] = []
        let original = index.pendingCleanup
        for task in index.pendingCleanup {
            let path = directory.appendingPathComponent(task.relativePath)
            do {
                if fileManager.fileExists(atPath: path.path) { try fileRemoval(path) }
                guard !fileManager.fileExists(atPath: path.path) else { throw ReportStoreError.cleanupPending }
                let parent = path.deletingLastPathComponent()
                try RotationDurability.synchronizeDirectory(at: fileManager.fileExists(atPath: parent.path) ? parent : directory)
            } catch { remaining.append(task) }
        }
        index.pendingCleanup = remaining
        // A failed journal update leaves the previous authenticated tombstones;
        // retrying an already removed path is harmless.
        if original != remaining { try writeWorkspaceIndex(index, directory: directory) }
        if !remaining.isEmpty { throw ReportStoreError.cleanupPending }
    }

    private func prepareWorkspaceForMutation(_ directory: URL) throws -> EncryptedWorkspaceIndex {
        try requireRotationReadyForMutation()
        try ensureExistingCiphertextHasKey(directory)
        var index = try readWorkspaceIndex(directory)
        if !fileManager.fileExists(atPath: directory.appendingPathComponent("workspace.encrypted").path), let legacy = try load() {
            let bytes = try sealRecord(legacy, context: "FirePrivacy/HistoryReport/v2/\(legacy.id.uuidString)", limit: Self.maximumStoredBytes)
            let history = directory.appendingPathComponent("history", isDirectory: true)
            try prepareDirectory(history)
            try atomicallyWrite(bytes, to: history.appendingPathComponent("\(legacy.id.uuidString).encrypted"))
            index.sessions = [ReportSessionDescriptor(id: legacy.id, importedAt: legacy.importedAt,
                observationCount: legacy.observations.count, contactCount: legacy.totalContacts,
                encryptedBytes: bytes.count, encryptedSourceBytes: 0, sourceSHA256: legacy.metadata?.sourceSHA256)]
            index.selectedReportID = legacy.id
            let legacySize = try directory.appendingPathComponent("report.encrypted").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            addCleanup(CiphertextCleanupTask(kind: .legacyReport, identifier: nil, encryptedBytes: legacySize), in: &index)
            try writeWorkspaceIndex(index, directory: directory)
        }
        let before = index.pendingCleanup
        try discoverUnreferencedCiphertext(in: &index, directory: directory)
        if index.pendingCleanup != before { try writeWorkspaceIndex(index, directory: directory) }
        try performPendingCleanup(&index, directory: directory)
        // Verify actual sizes, so orphan bytes and altered file sizes cannot be
        // hidden by authenticated metadata before another write is accepted.
        for item in index.sessions {
            for (relative, expected) in [("history/\(item.id.uuidString).encrypted", item.encryptedBytes),
                                         ("history/\(item.id.uuidString).source.encrypted", item.encryptedSourceBytes)] where expected > 0 {
                let path = directory.appendingPathComponent(relative)
                let values = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == expected else { throw ReportStoreError.invalidReport }
            }
        }
        return index
    }

    private func ensureExistingCiphertextHasKey(_ directory: URL) throws {
        if let key = try keyProvider.readKey() {
            guard key.count == 32 else { throw ReportStoreError.invalidKey }
            return
        }
        for name in ["", "history", "features"] {
            let folder = name.isEmpty ? directory : directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            let paths = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            guard !paths.contains(where: { $0.lastPathComponent.hasSuffix(".encrypted") }) else { throw ReportStoreError.missingKey }
        }
    }

    private func discoverUnreferencedCiphertext(in index: inout EncryptedWorkspaceIndex, directory: URL) throws {
        let legacyURL = directory.appendingPathComponent("report.encrypted")
        if fileManager.fileExists(atPath: directory.appendingPathComponent("workspace.encrypted").path),
           fileManager.fileExists(atPath: legacyURL.path),
           !index.pendingCleanup.contains(where: { $0.kind == .legacyReport }) {
            guard let legacy = try load() else { throw ReportStoreError.invalidReport }
            if !index.sessions.contains(where: { $0.id == legacy.id }) {
                // Preserve distinct evidence from an older interrupted migration.
                // Refuse to silently discard it when the configured quota is full.
                let bytes = try sealRecord(legacy, context: "FirePrivacy/HistoryReport/v2/\(legacy.id.uuidString)", limit: Self.maximumStoredBytes)
                let candidate = ReportSessionDescriptor(id: legacy.id, importedAt: legacy.importedAt,
                    observationCount: legacy.observations.count, contactCount: legacy.totalContacts,
                    encryptedBytes: bytes.count, encryptedSourceBytes: 0, sourceSHA256: legacy.metadata?.sourceSHA256)
                guard index.sessions.count < index.retention.maximumReports,
                      index.sessions.reduce(bytes.count, { $0 + $1.encryptedBytes + $1.encryptedSourceBytes }) <= index.retention.maximumStoredBytes
                else { throw ReportStoreError.persistenceFailed }
                let history = directory.appendingPathComponent("history", isDirectory: true)
                try prepareDirectory(history)
                try atomicallyWrite(bytes, to: history.appendingPathComponent("\(legacy.id.uuidString).encrypted"))
                index.sessions.append(candidate)
                if index.selectedReportID == nil { index.selectedReportID = legacy.id }
            }
            let size = try legacyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            addCleanup(CiphertextCleanupTask(kind: .legacyReport, identifier: nil, encryptedBytes: size), in: &index)
        }
        for folderName in ["", "history", "features"] {
            let folder = folderName.isEmpty ? directory : directory.appendingPathComponent(folderName)
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            let paths = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard paths.count <= 512 else { throw ReportStoreError.cleanupPending }
            for path in paths {
                let name = path.lastPathComponent
                let values = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile != true || values.isSymbolicLink == true {
                    if folderName.isEmpty, ["history", "features"].contains(name), values.isSymbolicLink != true { continue }
                    throw ReportStoreError.invalidReport
                }
                var kind: CiphertextCleanupTask.Kind?
                var identifier: UUID?
                if name.hasPrefix(".staged-"), name.hasSuffix(".encrypted") {
                    identifier = UUID(uuidString: String(name.dropFirst(8).dropLast(10)))
                    kind = folderName == "history" ? .stagedHistory : folderName == "features" ? .stagedFeature : .stagedRoot
                } else if folderName.isEmpty, name.hasPrefix(".report-"), name.hasSuffix(".encrypted") {
                    identifier = UUID(uuidString: String(name.dropFirst(8).dropLast(10)))
                    kind = .legacyStaged
                } else if folderName == "history", name.hasSuffix(".source.encrypted") {
                    identifier = UUID(uuidString: String(name.dropLast(17)))
                    if let identifier, !index.sessions.contains(where: { $0.id == identifier && $0.retainsEncryptedSource }) { kind = .rawSource }
                } else if folderName == "history", name.hasSuffix(".encrypted") {
                    identifier = UUID(uuidString: String(name.dropLast(10)))
                    if let identifier, !index.sessions.contains(where: { $0.id == identifier }) { kind = .historyReport }
                }
                if let kind {
                    guard let identifier else { throw ReportStoreError.invalidReport }
                    let task = CiphertextCleanupTask(kind: kind, identifier: identifier, encryptedBytes: values.fileSize ?? 0)
                    let actualRelative = folderName.isEmpty ? name : folderName + "/" + name
                    guard task.relativePath == actualRelative else { throw ReportStoreError.invalidReport }
                    addCleanup(task, in: &index)
                } else if folderName == "history", identifier == nil { throw ReportStoreError.invalidReport }
                else if folderName == "history", let identifier {
                    let suffix = name.hasSuffix(".source.encrypted") ? ".source.encrypted" : ".encrypted"
                    guard name == identifier.uuidString + suffix else { throw ReportStoreError.invalidReport }
                } else if folderName == "features" {
                    guard name.hasSuffix(".encrypted") else { throw ReportStoreError.invalidReport }
                    let key = String(name.dropLast(10))
                    guard !key.isEmpty, key.utf8.count <= 48,
                          key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                          (values.fileSize ?? 0) <= 12 * 1_024 * 1_024 else { throw ReportStoreError.invalidReport }
                }
            }
        }
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
            let removed = index.sessions.remove(at: remove)
            queueCleanup(removed, in: &index)
        }
    }

    private func readRecord<Value: Decodable>(from url: URL, context: String, limit: Int) throws -> Value {
        try decodeRecord(Value.self, plaintext: readPlaintext(from: url, context: context, limit: limit))
    }

    private func decodeRecord<Value: Decodable>(_ type: Value.Type, plaintext: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: plaintext) }
        catch { throw ReportStoreError.invalidReport }
    }

    private func readPlaintext(from url: URL, context: String, limit: Int) throws -> Data {
        guard let key = try keyProvider.readKey() else { throw ReportStoreError.missingKey }
        guard key.count == 32 else { throw ReportStoreError.invalidKey }
        do {
            let bytes = try ReportFileIO.readBoundedData(from: url, maximumBytes: limit)
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 2 else { throw ReportStoreError.unsupportedFormat }
            let box = try AES.GCM.SealedBox(combined: envelope.sealedReport)
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(context.utf8))
            return plaintext
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
            try RotationDurability.synchronizeDirectory(at: destination.deletingLastPathComponent())
        } catch { throw ReportStoreError.persistenceFailed }
    }

    private struct GenerationMarker: Codable {
        let version: Int
        let bindingID: UUID
        let generationID: UUID
    }
    private struct RotationInventory: Codable {
        struct Entry: Codable { let path: String; let sha256: String }
        let version: Int
        let transactionID: UUID
        let bindingID: UUID
        let entries: [Entry]
    }
    private struct RotationFile {
        let path: String
        let context: String
        let envelopeVersion: Int
        let maximumBytes: Int
    }
    private static let markerName = "generation.encrypted"
    private static let inventoryName = "rotation-inventory.encrypted"
    private static let markerContext = "FirePrivacy/RotationGeneration/v1"

    func rotationStatus() throws -> ReportKeyRotationStatus {
        _ = try leasedRawDirectoryURL()
        guard let provider = keyProvider as? any RotatingReportKeyProvider,
              let journal = try provider.readRotationJournal() else { return .idle }
        switch journal.phase {
        case .staging: return .staging
        case .commitIntent: return .committing
        case .committed: return .cleanupPending
        }
    }

    /// Re-encrypts an entire authenticated generation before changing the key.
    /// Every interruption is resolved using the device-only journal and markers.
    func rotateKey(expectedGeneration: UUID? = nil) throws {
        try validateGeneration(expectedGeneration)
        guard let provider = keyProvider as? any RotatingReportKeyProvider else { throw ReportStoreError.rotationUnsupported }
        let directory = try leasedRawDirectoryURL()
        storageGeneration = UUID()
        rotationInProgress = true
        defer { rotationInProgress = false }
        if let pending = try provider.readRotationJournal() {
            observedRotationTransactionID = pending.transactionID
            try recoverRotation(pending, provider: provider, directory: directory)
            return // Recovery never starts an additional rotation in the same call.
        }
        guard let oldKey = try keyProvider.readKey() else { throw ReportStoreError.missingKey }
        guard oldKey.count == 32 else { throw ReportStoreError.invalidKey }
        try ensureDirectoryIsRegular(directory)
        if fileManager.fileExists(atPath: directory.appendingPathComponent("workspace.encrypted").path) {
            _ = try prepareWorkspaceForMutation(directory) // Drain durable tombstones before staging.
        }
        let files = try rotationFiles(in: directory, key: oldKey)
        let markerURL = directory.appendingPathComponent(Self.markerName)
        let marker: GenerationMarker
        if fileManager.fileExists(atPath: markerURL.path) {
            marker = try readGenerationMarker(in: directory, key: oldKey)
        } else {
            marker = GenerationMarker(version: 1, bindingID: UUID(), generationID: UUID())
            try atomicallyWrite(try sealPlaintext(JSONEncoder().encode(marker), key: oldKey,
                context: Self.markerContext, version: 2, limit: 2_048), to: markerURL)
        }
        var newKey: Data
        repeat { newKey = try randomKey() } while newKey == oldKey
        let journal = try ReportKeyRotationJournal(bindingID: marker.bindingID, oldKey: oldKey, newKey: newKey)
        let stage = rotationDirectory(directory, transactionID: journal.transactionID, retired: false)
        let retired = rotationDirectory(directory, transactionID: journal.transactionID, retired: true)
        guard !fileManager.fileExists(atPath: stage.path), !fileManager.fileExists(atPath: retired.path) else {
            throw ReportStoreError.rotationRecoveryRequired
        }
        observedRotationTransactionID = journal.transactionID
        try provider.beginRotation(journal)
        do {
            try rotationCheckpoint(.journalCreated)
            try prepareDirectory(stage)
            var stagedSizes: [String: Int] = [:]
            for file in files where file.path != "workspace.encrypted" {
                let plaintext = try openRotationFile(file, in: directory, key: oldKey)
                let encrypted = try sealPlaintext(plaintext, key: newKey, context: file.context,
                    version: file.envelopeVersion, limit: file.maximumBytes)
                let destination = stage.appendingPathComponent(file.path)
                try prepareDirectory(destination.deletingLastPathComponent())
                try atomicallyWrite(encrypted, to: destination)
                stagedSizes[file.path] = encrypted.count
            }
            if files.contains(where: { $0.path == "workspace.encrypted" }) {
                let spec = RotationFile(path: "workspace.encrypted", context: "FirePrivacy/Workspace/v2", envelopeVersion: 2, maximumBytes: 262_144)
                var index = try decodeRecord(EncryptedWorkspaceIndex.self, plaintext: openRotationFile(spec, in: directory, key: oldKey))
                index.sessions = try index.sessions.map { item in
                    guard let reportSize = stagedSizes["history/\(item.id.uuidString).encrypted"] else { throw ReportStoreError.invalidReport }
                    let sourceSize = stagedSizes["history/\(item.id.uuidString).source.encrypted"] ?? 0
                    guard (sourceSize > 0) == item.retainsEncryptedSource else { throw ReportStoreError.invalidReport }
                    return ReportSessionDescriptor(id: item.id, importedAt: item.importedAt, observationCount: item.observationCount,
                        contactCount: item.contactCount, encryptedBytes: reportSize, encryptedSourceBytes: sourceSize, sourceSHA256: item.sourceSHA256)
                }
                try index.validate()
                try atomicallyWrite(try sealPlaintext(JSONEncoder().encode(index), key: newKey, context: spec.context,
                    version: 2, limit: spec.maximumBytes), to: stage.appendingPathComponent(spec.path))
            }
            let nextMarker = GenerationMarker(version: 1, bindingID: marker.bindingID, generationID: journal.transactionID)
            try atomicallyWrite(try sealPlaintext(JSONEncoder().encode(nextMarker), key: newKey,
                context: Self.markerContext, version: 2, limit: 2_048), to: stage.appendingPathComponent(Self.markerName))
            let entries = try (files.map(\.path) + [Self.markerName]).sorted().map { path in
                let bytes = try ReportFileIO.readBoundedData(from: stage.appendingPathComponent(path), maximumBytes: rotationFile(for: path)?.maximumBytes ?? 2_048)
                return RotationInventory.Entry(path: path, sha256: ContentDigest.sha256(bytes))
            }
            let inventory = RotationInventory(version: 1, transactionID: journal.transactionID, bindingID: journal.bindingID, entries: entries)
            try atomicallyWrite(try sealPlaintext(JSONEncoder().encode(inventory), key: newKey,
                context: inventoryContext(journal), version: 2, limit: 32_768), to: stage.appendingPathComponent(Self.inventoryName))
            try synchronizeGeneration(stage)
            try verifyStagedGeneration(stage, journal: journal)
            try rotationCheckpoint(.stagedGenerationVerified)
            let intent = try provider.updateRotationPhase(transactionID: journal.transactionID, phase: .commitIntent)
            try rotationCheckpoint(.commitIntentPersisted)
            try recoverRotation(intent, provider: provider, directory: directory)
        } catch let error as ReportStoreError { throw error }
        catch { throw ReportStoreError.persistenceFailed }
    }

    func retryKeyRotationCleanup(expectedGeneration: UUID? = nil) throws {
        try validateGeneration(expectedGeneration)
        guard let provider = keyProvider as? any RotatingReportKeyProvider else { throw ReportStoreError.rotationUnsupported }
        let directory = try leasedRawDirectoryURL()
        guard let journal = try provider.readRotationJournal() else { return }
        storageGeneration = UUID()
        observedRotationTransactionID = journal.transactionID
        rotationInProgress = true
        defer { rotationInProgress = false }
        try recoverRotation(journal, provider: provider, directory: directory)
    }

    private func hasPendingRotation() throws -> Bool {
        guard let provider = keyProvider as? any RotatingReportKeyProvider else { return false }
        return try provider.readRotationJournal() != nil
    }

    private func requireRotationReadyForMutation() throws {
        if !rotationInProgress, try hasPendingRotation() { throw ReportStoreError.rotationCleanupPending }
    }

    private func recoverRotation(_ initial: ReportKeyRotationJournal, provider: any RotatingReportKeyProvider, directory: URL) throws {
        let stage = rotationDirectory(directory, transactionID: initial.transactionID, retired: false)
        let retired = rotationDirectory(directory, transactionID: initial.transactionID, retired: true)
        var journal = initial
        if journal.phase == .staging {
            guard try keyProvider.readKey() == journal.oldKey,
                  !fileManager.fileExists(atPath: retired.path) else { throw ReportStoreError.rotationRecoveryRequired }
            let marker = try readGenerationMarker(in: directory, key: journal.oldKey)
            guard marker.bindingID == journal.bindingID, marker.generationID != journal.transactionID else {
                throw ReportStoreError.rotationRecoveryRequired
            }
            // A verified stage may be the only intact copy after a storage
            // fault. Authenticate all original evidence before discarding it.
            do { _ = try rotationFiles(in: directory, key: journal.oldKey) }
            catch { throw ReportStoreError.rotationRecoveryRequired }
            do {
                try removeRotationPathIfPresent(stage)
                try provider.cancelRotation(transactionID: journal.transactionID)
                observedRotationTransactionID = nil
            } catch { throw ReportStoreError.rotationRecoveryRequired }
            return
        }
        if journal.phase == .commitIntent {
            guard let currentKey = try keyProvider.readKey(), currentKey == journal.oldKey || currentKey == journal.newKey else {
                throw ReportStoreError.rotationRecoveryRequired
            }
            if fileManager.fileExists(atPath: directory.path) {
                if let marker = try? readGenerationMarker(in: directory, key: journal.oldKey), marker.bindingID == journal.bindingID,
                   marker.generationID != journal.transactionID {
                    guard currentKey == journal.oldKey, !fileManager.fileExists(atPath: retired.path) else { throw ReportStoreError.rotationRecoveryRequired }
                    try verifyStagedGeneration(stage, journal: journal)
                    try renameGeneration(directory, to: retired)
                    try rotationCheckpoint(.oldDirectoryRetired)
                } else {
                    try verifyStagedGeneration(directory, journal: journal)
                    guard !fileManager.fileExists(atPath: stage.path), fileManager.fileExists(atPath: retired.path) else {
                        throw ReportStoreError.rotationRecoveryRequired
                    }
                }
            }
            let oldMarker = try readGenerationMarker(in: retired, key: journal.oldKey)
            guard oldMarker.bindingID == journal.bindingID, oldMarker.generationID != journal.transactionID else {
                throw ReportStoreError.rotationRecoveryRequired
            }
            if !fileManager.fileExists(atPath: directory.path) {
                try verifyStagedGeneration(stage, journal: journal)
                try renameGeneration(stage, to: directory)
                try rotationCheckpoint(.newDirectoryActivated)
            }
            try verifyStagedGeneration(directory, journal: journal)
            try provider.installRotatedKey(transactionID: journal.transactionID)
            try rotationCheckpoint(.primaryKeyInstalled)
            journal = try provider.updateRotationPhase(transactionID: journal.transactionID, phase: .committed)
            try rotationCheckpoint(.committedJournalPersisted)
        }
        guard journal.phase == .committed, try keyProvider.readKey() == journal.newKey else {
            throw ReportStoreError.rotationRecoveryRequired
        }
        let activeMarker = try readGenerationMarker(in: directory, key: journal.newKey)
        guard activeMarker.bindingID == journal.bindingID, activeMarker.generationID == journal.transactionID,
              !fileManager.fileExists(atPath: stage.path) else { throw ReportStoreError.rotationRecoveryRequired }
        // Until cleanup completes no ordinary writes are permitted, so the
        // staged proof must still describe the active generation exactly.
        if fileManager.fileExists(atPath: directory.appendingPathComponent(Self.inventoryName).path) {
            try verifyStagedGeneration(directory, journal: journal)
        } else if fileManager.fileExists(atPath: retired.path) {
            throw ReportStoreError.rotationRecoveryRequired
        }
        do {
            if fileManager.fileExists(atPath: retired.path) {
                try ensureDirectoryIsRegular(retired)
                // The committed phase follows authentication of this unique
                // retired generation. An interrupted recursive unlink may
                // already have removed its marker; the complete active proof
                // above remains mandatory before continuing cleanup.
                if fileManager.fileExists(atPath: retired.appendingPathComponent(Self.markerName).path) {
                    let oldMarker = try readGenerationMarker(in: retired, key: journal.oldKey)
                    guard oldMarker.bindingID == journal.bindingID, oldMarker.generationID != journal.transactionID else {
                        throw ReportStoreError.rotationRecoveryRequired
                    }
                }
                try removeRotationPathIfPresent(retired)
            }
            try rotationCheckpoint(.retiredGenerationRemoved)
            try removeRotationPathIfPresent(directory.appendingPathComponent(Self.inventoryName))
            // Old key bytes are removed last, after durable ciphertext cleanup.
            try provider.finishRotationCleanup(transactionID: journal.transactionID)
            observedRotationTransactionID = nil
        } catch { throw ReportStoreError.rotationCleanupPending }
    }

    private func rotationDirectory(_ directory: URL, transactionID: UUID, retired: Bool) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent +
            (retired ? ".rotation-retired-" : ".rotation-stage-") + transactionID.uuidString, isDirectory: true)
    }
    private func inventoryContext(_ journal: ReportKeyRotationJournal) -> String {
        "FirePrivacy/RotationInventory/v1/\(journal.transactionID.uuidString)"
    }
    private func randomKey() throws -> Data {
        var result = Data(count: 32)
        let status = result.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else { throw ReportStoreError.keyUnavailable }
        return result
    }
    private func readGenerationMarker(in directory: URL, key: Data) throws -> GenerationMarker {
        try ensureDirectoryIsRegular(directory)
        let file = RotationFile(path: Self.markerName, context: Self.markerContext, envelopeVersion: 2, maximumBytes: 2_048)
        let marker = try decodeRecord(GenerationMarker.self, plaintext: openRotationFile(file, in: directory, key: key))
        guard marker.version == 1 else { throw ReportStoreError.rotationRecoveryRequired }
        return marker
    }
    private func ensureDirectoryIsRegular(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ReportStoreError.invalidReport }
    }
    private func rotationFile(for path: String) -> RotationFile? {
        switch path {
        case "report.encrypted": return RotationFile(path: path, context: "FirePrivacy/PrivacyReport/v1", envelopeVersion: 1, maximumBytes: Self.maximumStoredBytes)
        case "workspace.encrypted": return RotationFile(path: path, context: "FirePrivacy/Workspace/v2", envelopeVersion: 2, maximumBytes: 262_144)
        case Self.markerName: return RotationFile(path: path, context: Self.markerContext, envelopeVersion: 2, maximumBytes: 2_048)
        default: break
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let filename = String(components[1])
        if components[0] == "history" {
            let raw = filename.hasSuffix(".source.encrypted")
            let suffix = raw ? ".source.encrypted" : ".encrypted"
            guard filename.hasSuffix(suffix), let id = UUID(uuidString: String(filename.dropLast(suffix.count))),
                  filename == id.uuidString + suffix else { return nil }
            return RotationFile(path: path, context: "FirePrivacy/\(raw ? "RawSource" : "HistoryReport")/v2/\(id.uuidString)",
                envelopeVersion: 2, maximumBytes: raw ? 32 * 1_024 * 1_024 : Self.maximumStoredBytes)
        }
        if components[0] == "features", filename.hasSuffix(".encrypted") {
            let key = String(filename.dropLast(10))
            guard !key.isEmpty, key.utf8.count <= 48,
                  key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
            return RotationFile(path: path, context: "FirePrivacy/Feature/v2/\(key)", envelopeVersion: 2, maximumBytes: 12 * 1_024 * 1_024)
        }
        return nil
    }
    private func generationPaths(_ directory: URL) throws -> [String] {
        try ensureDirectoryIsRegular(directory)
        var result: [String] = []
        for folderName in ["", "history", "features"] {
            let folder = folderName.isEmpty ? directory : directory.appendingPathComponent(folderName)
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            try ensureDirectoryIsRegular(folder)
            let paths = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard paths.count <= 64 else { throw ReportStoreError.invalidReport }
            for path in paths {
                if folderName.isEmpty, ["history", "features"].contains(path.lastPathComponent) { continue }
                let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReportStoreError.invalidReport }
                let relative = folderName.isEmpty ? path.lastPathComponent : folderName + "/" + path.lastPathComponent
                guard relative == Self.inventoryName || rotationFile(for: relative) != nil else { throw ReportStoreError.invalidReport }
                result.append(relative)
            }
        }
        guard result.count <= 68, Set(result).count == result.count else { throw ReportStoreError.invalidReport }
        return result.sorted()
    }
    private func rotationFiles(in directory: URL, key: Data) throws -> [RotationFile] {
        let paths = try generationPaths(directory).filter { $0 != Self.markerName && $0 != Self.inventoryName }
        let files = try paths.map { path -> RotationFile in
            guard let spec = rotationFile(for: path) else { throw ReportStoreError.invalidReport }
            return spec
        }
        var total = 0
        var featureTotal = 0
        var featureCount = 0
        var index: EncryptedWorkspaceIndex?
        if let spec = files.first(where: { $0.path == "workspace.encrypted" }) {
            index = try decodeRecord(EncryptedWorkspaceIndex.self, plaintext: openRotationFile(spec, in: directory, key: key))
            try index?.validate()
            guard index?.pendingCleanup.isEmpty == true else { throw ReportStoreError.cleanupPending }
        }
        for spec in files {
            let plaintext = try openRotationFile(spec, in: directory, key: key)
            let bytes = try directory.appendingPathComponent(spec.path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow, sum <= 145 * 1_024 * 1_024 else { throw ReportStoreError.invalidReport }
            total = sum
            if spec.path.hasPrefix("features/") {
                featureCount += 1
                featureTotal += bytes
                guard featureCount <= 24, featureTotal <= 32 * 1_024 * 1_024 else { throw ReportStoreError.invalidReport }
            } else if spec.path == "report.encrypted" {
                _ = try decodeRecord(PrivacyReport.self, plaintext: plaintext)
            } else if spec.path.hasPrefix("history/") {
                guard let index else { throw ReportStoreError.invalidReport }
                if spec.path.hasSuffix(".source.encrypted") {
                    guard let item = index.sessions.first(where: { spec.path == "history/\($0.id.uuidString).source.encrypted" }),
                          item.encryptedSourceBytes == bytes, item.retainsEncryptedSource else { throw ReportStoreError.invalidReport }
                    let raw = try decodeRecord(Data.self, plaintext: plaintext)
                    guard raw.count <= ReportImporter.maximumFileBytes, item.sourceSHA256 == ContentDigest.sha256(raw) else { throw ReportStoreError.invalidReport }
                } else {
                    guard let item = index.sessions.first(where: { spec.path == "history/\($0.id.uuidString).encrypted" }), item.encryptedBytes == bytes else {
                        throw ReportStoreError.invalidReport
                    }
                    let report = try decodeRecord(PrivacyReport.self, plaintext: plaintext)
                    guard report.id == item.id else { throw ReportStoreError.invalidReport }
                }
            }
        }
        if let index {
            for item in index.sessions {
                guard paths.contains("history/\(item.id.uuidString).encrypted"),
                      !item.retainsEncryptedSource || paths.contains("history/\(item.id.uuidString).source.encrypted") else { throw ReportStoreError.invalidReport }
            }
        }
        return files
    }
    private func openRotationFile(_ file: RotationFile, in directory: URL, key: Data) throws -> Data {
        let url = directory.appendingPathComponent(file.path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReportStoreError.invalidReport }
        do {
            let encoded = try ReportFileIO.readBoundedData(from: url, maximumBytes: file.maximumBytes)
            let envelope = try JSONDecoder().decode(Envelope.self, from: encoded)
            guard envelope.version == file.envelopeVersion else { throw ReportStoreError.unsupportedFormat }
            let box = try AES.GCM.SealedBox(combined: envelope.sealedReport)
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(file.context.utf8))
        } catch let error as ReportStoreError { throw error }
        catch { throw ReportStoreError.invalidReport }
    }
    private func sealPlaintext(_ bytes: Data, key: Data, context: String, version: Int, limit: Int) throws -> Data {
        guard key.count == 32, bytes.count <= limit else { throw ReportStoreError.persistenceFailed }
        let sealed = try AES.GCM.seal(bytes, using: SymmetricKey(data: key), authenticating: Data(context.utf8))
        guard let combined = sealed.combined else { throw ReportStoreError.persistenceFailed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(Envelope(version: version, sealedReport: combined))
        guard encoded.count <= limit else { throw ReportStoreError.persistenceFailed }
        return encoded
    }
    private func verifyStagedGeneration(_ directory: URL, journal: ReportKeyRotationJournal) throws {
        let marker = try readGenerationMarker(in: directory, key: journal.newKey)
        guard marker.bindingID == journal.bindingID, marker.generationID == journal.transactionID else { throw ReportStoreError.rotationRecoveryRequired }
        let inventoryFile = RotationFile(path: Self.inventoryName, context: inventoryContext(journal), envelopeVersion: 2, maximumBytes: 32_768)
        let inventory = try decodeRecord(RotationInventory.self, plaintext: openRotationFile(inventoryFile, in: directory, key: journal.newKey))
        guard inventory.version == 1, inventory.transactionID == journal.transactionID, inventory.bindingID == journal.bindingID,
              inventory.entries.count <= 67, Set(inventory.entries.map(\.path)).count == inventory.entries.count,
              inventory.entries.map(\.path).sorted() == (try generationPaths(directory)).filter({ $0 != Self.inventoryName }) else {
            throw ReportStoreError.rotationRecoveryRequired
        }
        for entry in inventory.entries {
            guard let spec = rotationFile(for: entry.path), entry.sha256.count == 64,
                  entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ReportStoreError.rotationRecoveryRequired }
            let bytes = try ReportFileIO.readBoundedData(from: directory.appendingPathComponent(entry.path), maximumBytes: spec.maximumBytes)
            guard ContentDigest.sha256(bytes) == entry.sha256 else { throw ReportStoreError.rotationRecoveryRequired }
            _ = try openRotationFile(spec, in: directory, key: journal.newKey)
        }
        _ = try rotationFiles(in: directory, key: journal.newKey)
    }
    private func synchronizeGeneration(_ directory: URL) throws {
        for path in try generationPaths(directory) { try RotationDurability.synchronizeFile(at: directory.appendingPathComponent(path)) }
        for folder in ["history", "features"] {
            let path = directory.appendingPathComponent(folder)
            if fileManager.fileExists(atPath: path.path) { try RotationDurability.synchronizeDirectory(at: path) }
        }
        try RotationDurability.synchronizeDirectory(at: directory)
        try RotationDurability.synchronizeDirectory(at: directory.deletingLastPathComponent())
    }
    private func renameGeneration(_ source: URL, to destination: URL) throws {
        guard !fileManager.fileExists(atPath: destination.path) else { throw ReportStoreError.rotationRecoveryRequired }
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return Int32(-1) }
                return Darwin.rename(from, to)
            }
        }
        guard result == 0 else { throw ReportStoreError.rotationRecoveryRequired }
        try RotationDurability.synchronizeDirectory(at: destination.deletingLastPathComponent())
    }
    private func removeRotationPathIfPresent(_ path: URL) throws {
        if fileManager.fileExists(atPath: path.path) { try fileRemoval(path) }
        guard !fileManager.fileExists(atPath: path.path) else { throw ReportStoreError.rotationCleanupPending }
        try RotationDurability.synchronizeDirectory(at: path.deletingLastPathComponent())
    }

    private func rawDirectoryURL() throws -> URL {
        if let injectedDirectoryURL { return injectedDirectoryURL }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ReportStoreError.storageUnavailable
        }
        return support.appendingPathComponent("FirePrivacy", isDirectory: true)
    }

    private func leasedRawDirectoryURL() throws -> URL {
        let directory = try rawDirectoryURL()
        if directoryLease == nil { directoryLease = try ReportStorageLeaseRegistry.shared.acquire(directoryURL: directory, owner: leaseOwner) }
        return directory
    }

    private func directoryURL() throws -> URL {
        let directory = try leasedRawDirectoryURL()
        if !rotationInProgress, let provider = keyProvider as? any RotatingReportKeyProvider,
           let journal = try provider.readRotationJournal() {
            if observedRotationTransactionID != journal.transactionID {
                storageGeneration = UUID()
                observedRotationTransactionID = journal.transactionID
            }
            rotationInProgress = true
            defer { rotationInProgress = false }
            do { try recoverRotation(journal, provider: provider, directory: directory) }
            catch ReportStoreError.rotationCleanupPending { /* Reads use the committed new generation; writes remain blocked. */ }
        }
        return directory
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
