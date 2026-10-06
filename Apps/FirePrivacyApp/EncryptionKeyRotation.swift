import Darwin
import Foundation
import Security

enum ReportKeyRotationStatus: Equatable, Sendable {
    case idle
    case staging
    case committing
    case cleanupPending
}

enum RotationInterruptionPoint: CaseIterable, Equatable, Sendable {
    case journalCreated
    case stagedGenerationVerified
    case commitIntentPersisted
    case oldDirectoryRetired
    case newDirectoryActivated
    case primaryKeyInstalled
    case committedJournalPersisted
    case retiredGenerationRemoved
}

/// The canonical path is captured at acquisition, so renaming a generation
/// cannot prevent its owner from releasing this process-wide reservation.
struct ReportStorageDirectoryLease: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let canonicalPath: String
    fileprivate let owner: UUID

    var description: String { "Protected local-storage lease" }
    var debugDescription: String { "ReportStorageDirectoryLease" }
}

/// Each actor reserves its directory until deinitialization. Repeated
/// acquisition by the same owner is idempotent, not reference counted.
final class ReportStorageLeaseRegistry: @unchecked Sendable {
    static let shared = ReportStorageLeaseRegistry()
    private let lock = NSLock()
    private var owners: [String: UUID] = [:]

    private init() {}

    func acquire(directoryURL: URL, owner: UUID) throws -> ReportStorageDirectoryLease {
        guard directoryURL.isFileURL else { throw ReportStoreError.storageUnavailable }
        let canonicalPath = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard !canonicalPath.isEmpty, canonicalPath != "/" else { throw ReportStoreError.storageUnavailable }
        return try lock.withLock {
            if let existing = owners[canonicalPath], existing != owner { throw ReportStoreError.storageInUse }
            owners[canonicalPath] = owner
            return ReportStorageDirectoryLease(canonicalPath: canonicalPath, owner: owner)
        }
    }

    func release(_ lease: ReportStorageDirectoryLease) {
        lock.withLock {
            if owners[lease.canonicalPath] == lease.owner { owners.removeValue(forKey: lease.canonicalPath) }
        }
    }
}

/// Persist the completed file and rename metadata before advancing a rotation
/// journal. File and directory handles are checked independently; failures are
/// propagated without recording paths or key material.
enum RotationDurability {
    static func synchronizeFile(at url: URL) throws { try synchronize(at: url, directory: false) }
    static func synchronizeDirectory(at url: URL) throws { try synchronize(at: url, directory: true) }

    private static func synchronize(at url: URL, directory: Bool) throws {
        guard url.isFileURL else { throw ReportStoreError.persistenceFailed }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ReportStoreError.persistenceFailed }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw ReportStoreError.persistenceFailed }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(directory ? S_IFDIR : S_IFREG) else { throw ReportStoreError.persistenceFailed }
        var status = Darwin.fsync(descriptor)
        while status != 0 && errno == EINTR { status = Darwin.fsync(descriptor) }
        guard status == 0 else { throw ReportStoreError.persistenceFailed }
    }
}

enum KeyRotationProviderError: LocalizedError, Equatable, Sendable {
    case invalidJournal
    case conflictingRotation
    case invalidPhaseTransition
    case primaryKeyMismatch
    case keyUnavailable
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .invalidJournal:
            "The local key rotation record could not be verified. Your encrypted data has been preserved."
        case .conflictingRotation:
            "A local key rotation is already in progress. Retry its recovery before starting another rotation."
        case .invalidPhaseTransition:
            "The local key rotation could not advance safely. Your encrypted data has been preserved."
        case .primaryKeyMismatch:
            "The saved encryption key does not match the pending rotation. Your encrypted data has been preserved."
        case .keyUnavailable:
            "The local key rotation record is unavailable. Unlock your device and try again."
        case .cleanupFailed:
            "The previous encryption key could not be completely removed. Unlock your device and retry cleanup."
        }
    }
}

enum ReportKeyRotationPhase: String, Codable, Equatable, Sendable {
    case staging
    case commitIntent
    case committed
}

/// Secret recovery state. It belongs only in the device-only Keychain, never in
/// directory markers, diagnostic output, or a report export.
struct ReportKeyRotationJournal: Codable, Equatable, Sendable {
    static let maximumEncodedBytes = 2_048
    static let formatVersion = 1

    let version: Int
    let transactionID: UUID
    let bindingID: UUID
    let oldKey: Data
    let newKey: Data
    let phase: ReportKeyRotationPhase

    init(transactionID: UUID = UUID(), bindingID: UUID, oldKey: Data, newKey: Data,
         phase: ReportKeyRotationPhase = .staging) throws {
        guard oldKey.count == 32, newKey.count == 32, oldKey != newKey else {
            throw KeyRotationProviderError.invalidJournal
        }
        version = Self.formatVersion
        self.transactionID = transactionID
        self.bindingID = bindingID
        self.oldKey = oldKey
        self.newKey = newKey
        self.phase = phase
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw KeyRotationProviderError.invalidJournal }
        return bytes
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumEncodedBytes else { throw KeyRotationProviderError.invalidJournal }
        do { return try JSONDecoder().decode(Self.self, from: bytes) }
        catch { throw KeyRotationProviderError.invalidJournal }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, transactionID, bindingID, oldKey, newKey, phase
    }

    private struct FieldKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: FieldKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw KeyRotationProviderError.invalidJournal
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.formatVersion else {
            throw KeyRotationProviderError.invalidJournal
        }
        try self.init(transactionID: container.decode(UUID.self, forKey: .transactionID),
                      bindingID: container.decode(UUID.self, forKey: .bindingID),
                      oldKey: container.decode(Data.self, forKey: .oldKey),
                      newKey: container.decode(Data.self, forKey: .newKey),
                      phase: container.decode(ReportKeyRotationPhase.self, forKey: .phase))
    }
}

/// An explicit capability: ordinary providers cannot rotate by deleting and
/// replacing their primary key. The owning store serializes these operations
/// with its filesystem transaction and epoch gate.
protocol RotatingReportKeyProvider: ReportKeyProvider {
    func readRotationJournal() throws -> ReportKeyRotationJournal?
    func beginRotation(_ journal: ReportKeyRotationJournal) throws
    func updateRotationPhase(transactionID: UUID, phase: ReportKeyRotationPhase) throws -> ReportKeyRotationJournal
    func installRotatedKey(transactionID: UUID) throws
    /// Called only after the retired generation has been removed durably.
    func finishRotationCleanup(transactionID: UUID) throws
    /// Called only before commit intent, after staging ciphertext is removed.
    func cancelRotation(transactionID: UUID) throws
}

extension KeychainReportKeyProvider: RotatingReportKeyProvider {
    private var rotationQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: serviceIdentifier,
         kSecAttrAccount as String: "encrypted-report-key-rotation-v1",
         kSecAttrSynchronizable as String: false]
    }

    private var rotationPrimaryQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: serviceIdentifier,
         kSecAttrAccount as String: "encrypted-report-key-v1",
         kSecAttrSynchronizable as String: false]
    }

    func readRotationJournal() throws -> ReportKeyRotationJournal? {
        var lookup = rotationQuery
        lookup[kSecReturnData as String] = true
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any],
              let bytes = item[kSecValueData as String] as? Data else { throw KeyRotationProviderError.keyUnavailable }
        guard item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              (item[kSecAttrSynchronizable as String] as? Bool) != true else {
            throw KeyRotationProviderError.invalidJournal
        }
        return try ReportKeyRotationJournal.decode(bytes)
    }

    func beginRotation(_ journal: ReportKeyRotationJournal) throws {
        guard journal.phase == .staging else { throw KeyRotationProviderError.invalidPhaseTransition }
        try requirePrimaryKey(journal.oldKey)
        if let existing = try readRotationJournal() {
            guard existing == journal else { throw KeyRotationProviderError.conflictingRotation }
            return
        }
        var item = rotationQuery
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = try journal.encoded()
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return }
        // A retry can encounter an already persisted identical record. Never
        // replace a different transaction or assume an ambiguous write failed.
        if let persisted = try readRotationJournal(), persisted == journal {
            try requirePrimaryKey(journal.oldKey)
            return
        }
        throw status == errSecDuplicateItem ? KeyRotationProviderError.conflictingRotation : .keyUnavailable
    }

    func updateRotationPhase(transactionID: UUID, phase: ReportKeyRotationPhase) throws -> ReportKeyRotationJournal {
        let current = try requireJournal(transactionID)
        if phase == current.phase {
            try requirePrimaryKey(for: current)
            return current
        }
        switch (current.phase, phase) {
        case (.staging, .commitIntent): try requirePrimaryKey(current.oldKey)
        case (.commitIntent, .committed): try requirePrimaryKey(current.newKey)
        default: throw KeyRotationProviderError.invalidPhaseTransition
        }
        let advanced = try ReportKeyRotationJournal(transactionID: current.transactionID, bindingID: current.bindingID,
                                                   oldKey: current.oldKey, newKey: current.newKey, phase: phase)
        let updates: [String: Any] = [kSecValueData as String: try advanced.encoded(),
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(rotationQuery as CFDictionary, updates as CFDictionary)
        if status != errSecSuccess {
            guard let persisted = try readRotationJournal(), persisted == advanced else { throw KeyRotationProviderError.keyUnavailable }
        }
        // Cross-check the transaction even after a reported success. The store
        // serializes access; Keychain does not provide a multi-item transaction.
        guard let persisted = try readRotationJournal(), persisted == advanced else { throw KeyRotationProviderError.conflictingRotation }
        return persisted
    }

    func installRotatedKey(transactionID: UUID) throws {
        let journal = try requireJournal(transactionID)
        guard journal.phase == .commitIntent || journal.phase == .committed else {
            throw KeyRotationProviderError.invalidPhaseTransition
        }
        guard let existing = try readKey(), existing.count == 32,
              existing == journal.oldKey || existing == journal.newKey else { throw KeyRotationProviderError.primaryKeyMismatch }
        if existing == journal.newKey { return }
        let updates: [String: Any] = [kSecValueData as String: journal.newKey,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(rotationPrimaryQuery as CFDictionary, updates as CFDictionary)
        // Read back even an ambiguous failure. The recovery journal remains
        // intact until the store has removed the old ciphertext generation.
        let observed = try readKey()
        guard observed == journal.newKey else {
            if observed == journal.oldKey, status != errSecSuccess { throw KeyRotationProviderError.keyUnavailable }
            throw KeyRotationProviderError.primaryKeyMismatch
        }
        guard try requireJournal(transactionID) == journal else { throw KeyRotationProviderError.conflictingRotation }
    }

    func finishRotationCleanup(transactionID: UUID) throws {
        let journal = try requireJournal(transactionID)
        guard journal.phase == .committed else { throw KeyRotationProviderError.invalidPhaseTransition }
        try requirePrimaryKey(journal.newKey)
        try removeRotationJournal(transactionID)
    }

    func cancelRotation(transactionID: UUID) throws {
        let journal = try requireJournal(transactionID)
        guard journal.phase == .staging else { throw KeyRotationProviderError.invalidPhaseTransition }
        try requirePrimaryKey(journal.oldKey)
        try removeRotationJournal(transactionID)
    }

    private func requireJournal(_ transactionID: UUID) throws -> ReportKeyRotationJournal {
        guard let journal = try readRotationJournal() else { throw KeyRotationProviderError.invalidJournal }
        guard journal.transactionID == transactionID else { throw KeyRotationProviderError.conflictingRotation }
        return journal
    }

    private func requirePrimaryKey(_ expected: Data) throws {
        guard let existing = try readKey(), existing.count == 32, existing == expected else {
            throw KeyRotationProviderError.primaryKeyMismatch
        }
    }

    private func requirePrimaryKey(for journal: ReportKeyRotationJournal) throws {
        switch journal.phase {
        case .staging: try requirePrimaryKey(journal.oldKey)
        case .committed: try requirePrimaryKey(journal.newKey)
        case .commitIntent:
            guard let existing = try readKey(), existing.count == 32,
                  existing == journal.oldKey || existing == journal.newKey else { throw KeyRotationProviderError.primaryKeyMismatch }
        }
    }

    private func removeRotationJournal(_ transactionID: UUID) throws {
        _ = try requireJournal(transactionID)
        let status = SecItemDelete(rotationQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyRotationProviderError.cleanupFailed }
        do {
            guard try readRotationJournal() == nil else { throw KeyRotationProviderError.cleanupFailed }
        } catch { throw KeyRotationProviderError.cleanupFailed }
    }
}
