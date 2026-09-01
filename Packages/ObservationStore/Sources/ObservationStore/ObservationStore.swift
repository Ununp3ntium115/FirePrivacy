import Foundation
import ObservationCore
import FindingEngine
import KnowledgeBaseKit

/// What the store holds for one import.
public struct StoredSession: Codable, Sendable {
    public let snapshot: ObservationSnapshot
    public let findings: [Finding]
    public let evidence: [String: Evidence]
    public let scores: PostureScores
    public let ruleSetVersion: String
    public let knowledgeBaseVersion: KnowledgeBaseVersion
    public let evaluatedAt: Date

    public init(
        snapshot: ObservationSnapshot,
        findings: [Finding],
        evidence: [String: Evidence],
        scores: PostureScores,
        ruleSetVersion: String,
        knowledgeBaseVersion: KnowledgeBaseVersion,
        evaluatedAt: Date
    ) {
        self.snapshot = snapshot
        self.findings = findings
        self.evidence = evidence
        self.scores = scores
        self.ruleSetVersion = ruleSetVersion
        self.knowledgeBaseVersion = knowledgeBaseVersion
        self.evaluatedAt = evaluatedAt
    }

    public init(snapshot: ObservationSnapshot, result: FindingEvaluationResult) {
        self.init(
            snapshot: snapshot,
            findings: result.findings,
            evidence: result.evidenceByID,
            scores: result.scores,
            ruleSetVersion: result.ruleSetVersion,
            knowledgeBaseVersion: result.knowledgeBaseVersion,
            evaluatedAt: result.generatedAt
        )
    }
}

/// What "delete" applies to (§23.5).
public enum DeletionScope: Sendable, Hashable {
    case everything
    case session(UUID)
    case findingsOnly
    case explanationsOnly
    case overridesOnly
}

public struct DeletionPreview: Sendable, Hashable {
    public let scope: DeletionScope
    public let sessionCount: Int
    public let observationCount: Int
    public let findingCount: Int
    public let explanationCount: Int
    public let overrideCount: Int
    public let byteCount: Int
    /// Named so the user knows what survives, e.g. protection configuration
    /// (TRU-003).
    public let notIncluded: [String]

    public init(
        scope: DeletionScope,
        sessionCount: Int,
        observationCount: Int,
        findingCount: Int,
        explanationCount: Int,
        overrideCount: Int,
        byteCount: Int,
        notIncluded: [String]
    ) {
        self.scope = scope
        self.sessionCount = sessionCount
        self.observationCount = observationCount
        self.findingCount = findingCount
        self.explanationCount = explanationCount
        self.overrideCount = overrideCount
        self.byteCount = byteCount
        self.notIncluded = notIncluded
    }
}

public struct DeletionReceipt: Sendable, Hashable {
    public let scope: DeletionScope
    public let deletedAt: Date
    public let deletedSessionIDs: [UUID]
    public let removedFileCount: Int
    public let destroyedEncryptionKey: Bool

    public init(scope: DeletionScope, deletedAt: Date, deletedSessionIDs: [UUID], removedFileCount: Int, destroyedEncryptionKey: Bool) {
        self.scope = scope
        self.deletedAt = deletedAt
        self.deletedSessionIDs = deletedSessionIDs
        self.removedFileCount = removedFileCount
        self.destroyedEncryptionKey = destroyedEncryptionKey
    }
}

/// The deletion interface (§23.5).
public protocol PrivacyDataDeleting: Sendable {
    func previewDeletion(scope: DeletionScope) async throws -> DeletionPreview
    func delete(scope: DeletionScope) async throws -> DeletionReceipt
}

public enum ObservationStoreError: Error, Sendable, Equatable {
    case sessionNotFound(UUID)
    case protectedDataUnavailable
    case encodingFailed
}

/// Encrypted, file-backed local storage.
///
/// One encrypted file per import session plus a small index. Raw report lines
/// are never written here or anywhere else by default (IMP-009), and nothing
/// from an import is written to the App Group the extensions can read (§12.2).
public actor EncryptedObservationStore: PrivacyDataDeleting {
    private let directory: URL
    private let cryptoBox: CryptoBox
    private let keyProvider: any DataKeyProviding
    private let fileManager = FileManager.default
    private let clock: @Sendable () -> Date

    private var index: [UUID: String] = [:]
    private var overrides = DomainOverrideSet()
    private var explanationCount = 0
    /// Set while iOS reports that protected data is unavailable, so work pauses
    /// instead of failing halfway (§16.5).
    private var protectedDataAvailable = true

    public init(
        directory: URL,
        keyProvider: any DataKeyProviding,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.directory = directory
        self.keyProvider = keyProvider
        self.cryptoBox = CryptoBox(keyProvider: keyProvider)
        self.clock = clock
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.applyFileProtection(to: directory)
    }

    public func setProtectedDataAvailable(_ available: Bool) {
        protectedDataAvailable = available
    }

    // MARK: - Sessions

    public func save(_ session: StoredSession) throws {
        guard protectedDataAvailable else { throw ObservationStoreError.protectedDataUnavailable }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(session) else { throw ObservationStoreError.encodingFailed }

        let sealed = try cryptoBox.seal(Array(data))
        let filename = "session-\(session.snapshot.session.id.uuidString).fpdata"
        let url = directory.appendingPathComponent(filename)
        try Data(sealed).write(to: url, options: [.atomic, .completeFileProtection])
        index[session.snapshot.session.id] = filename
    }

    public func load(sessionID: UUID) throws -> StoredSession {
        guard protectedDataAvailable else { throw ObservationStoreError.protectedDataUnavailable }
        guard let filename = index[sessionID] else { throw ObservationStoreError.sessionNotFound(sessionID) }
        let url = directory.appendingPathComponent(filename)
        let bytes = try Data(contentsOf: url)
        let plaintext = try cryptoBox.open(Array(bytes))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredSession.self, from: Data(plaintext))
    }

    public func allSessionIDs() -> [UUID] {
        index.keys.sorted { $0.uuidString < $1.uuidString }
    }

    public func loadAll() -> [StoredSession] {
        allSessionIDs().compactMap { try? load(sessionID: $0) }
            .sorted { $0.snapshot.session.importedAt < $1.snapshot.session.importedAt }
    }

    public func mostRecentSession() -> StoredSession? {
        loadAll().last
    }

    /// Hashes of files already imported, for duplicate detection (IMP-006).
    public func knownSourceHashes() -> Set<FireDigest> {
        Set(loadAll().map(\.snapshot.session.sourceHash))
    }

    // MARK: - Overrides

    public func setOverride(_ override: DomainOverride) {
        overrides.set(override)
    }

    public func removeOverride(host: NormalizedHost) {
        overrides.remove(host: host)
    }

    public func currentOverrides() -> DomainOverrideSet { overrides }

    public func recordExplanationCount(_ count: Int) {
        explanationCount = count
    }

    // MARK: - Inventory

    public func byteCount() -> Int {
        index.values.reduce(0) { total, filename in
            let url = directory.appendingPathComponent(filename)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? 0
            return total + size
        }
    }

    // MARK: - Deletion

    public func previewDeletion(scope: DeletionScope) throws -> DeletionPreview {
        let sessions: [StoredSession] = switch scope {
        case .everything, .findingsOnly, .explanationsOnly, .overridesOnly: loadAll()
        case .session(let id): (try? load(sessionID: id)).map { [$0] } ?? []
        }

        let notIncluded: [String] = switch scope {
        case .everything: ["Protection configurations, which are removed separately if you choose."]
        case .session: ["Other import sessions", "Protection configurations", "Your privacy profile"]
        case .findingsOnly: ["Imported observations", "Protection configurations"]
        case .explanationsOnly: ["Findings and observations"]
        case .overridesOnly: ["Findings, observations and explanations"]
        }

        return DeletionPreview(
            scope: scope,
            sessionCount: sessions.count,
            observationCount: sessions.reduce(0) { $0 + $1.snapshot.networkObservations.count + $1.snapshot.sensorObservations.count },
            findingCount: sessions.reduce(0) { $0 + $1.findings.count },
            explanationCount: explanationCount,
            overrideCount: overrides.overrides.count,
            byteCount: byteCount(),
            notIncluded: notIncluded
        )
    }

    @discardableResult
    public func delete(scope: DeletionScope) throws -> DeletionReceipt {
        var removedFiles = 0
        var deletedIDs: [UUID] = []
        var destroyedKey = false

        switch scope {
        case .everything:
            for (id, filename) in index {
                let url = directory.appendingPathComponent(filename)
                if (try? fileManager.removeItem(at: url)) != nil { removedFiles += 1 }
                deletedIDs.append(id)
            }
            index.removeAll()
            overrides = DomainOverrideSet()
            explanationCount = 0
            // Destroying the key makes any ciphertext that survived unreadable.
            try keyProvider.destroyKey()
            destroyedKey = true

        case .session(let id):
            if let filename = index[id] {
                let url = directory.appendingPathComponent(filename)
                if (try? fileManager.removeItem(at: url)) != nil { removedFiles += 1 }
                index.removeValue(forKey: id)
                deletedIDs.append(id)
            }

        case .findingsOnly:
            for session in loadAll() {
                let stripped = StoredSession(
                    snapshot: session.snapshot,
                    findings: [],
                    evidence: [:],
                    scores: .empty,
                    ruleSetVersion: session.ruleSetVersion,
                    knowledgeBaseVersion: session.knowledgeBaseVersion,
                    evaluatedAt: session.evaluatedAt
                )
                try save(stripped)
                deletedIDs.append(session.snapshot.session.id)
            }

        case .explanationsOnly:
            explanationCount = 0

        case .overridesOnly:
            overrides = DomainOverrideSet()
        }

        return DeletionReceipt(
            scope: scope,
            deletedAt: clock(),
            deletedSessionIDs: deletedIDs.sorted { $0.uuidString < $1.uuidString },
            removedFileCount: removedFiles,
            destroyedEncryptionKey: destroyedKey
        )
    }

    private static func applyFileProtection(to url: URL) throws {
        #if canImport(Darwin)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }
}
