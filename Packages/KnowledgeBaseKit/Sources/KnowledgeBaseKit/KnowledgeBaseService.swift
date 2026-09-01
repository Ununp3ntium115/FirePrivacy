import Foundation
import ObservationCore

/// The interface the rest of the app depends on (§23.2).
public protocol DomainKnowledgeProviding: Sendable {
    var activeVersion: KnowledgeBaseVersion { get async }
    var isStale: Bool { get async }
    func classify(_ host: NormalizedHost) async -> [DomainMatch]
    func matcher() async -> DomainMatcher
    func updateIfNeeded(now: Date) async throws -> KnowledgeBaseUpdateResult
    func rollback() async throws
}

public enum KnowledgeBaseUpdateResult: Sendable, Equatable {
    case notAttempted(reason: String)
    case upToDate(version: String)
    case installed(version: String)
    case rejected(reason: String)
}

/// Fetches candidate releases. Deliberately abstract: the MVP ships **no**
/// transport, so the app makes no knowledge-base request at all until updates
/// are switched on with a real one (TRU-005, §18.4).
public protocol KnowledgeBaseTransport: Sendable {
    func fetchLatest() async throws -> (manifest: KnowledgeBaseManifest, payloadBytes: [UInt8])
}

/// The transport used when knowledge-base updating is off.
public struct DisabledKnowledgeBaseTransport: KnowledgeBaseTransport {
    public init() {}

    public func fetchLatest() async throws -> (manifest: KnowledgeBaseManifest, payloadBytes: [UInt8]) {
        throw KnowledgeBaseServiceError.updatesDisabled
    }
}

public enum KnowledgeBaseServiceError: Error, Sendable, Equatable {
    case updatesDisabled
    case noRollbackAvailable
    case malformedPayload
}

/// Holds the active dataset and the single previous version kept for rollback
/// (§12.3).
public actor KnowledgeBaseService: DomainKnowledgeProviding {
    private var current: KnowledgeBaseSnapshot
    private var previous: KnowledgeBaseSnapshot?
    private var cachedMatcher: DomainMatcher
    private let verifier: KnowledgeBaseVerifier
    private let transport: any KnowledgeBaseTransport
    private let appVersion: String

    public init(
        snapshot: KnowledgeBaseSnapshot = BundledKnowledgeBase.snapshot,
        verifier: KnowledgeBaseVerifier = KnowledgeBaseVerifier(trustAnchors: []),
        transport: any KnowledgeBaseTransport = DisabledKnowledgeBaseTransport(),
        appVersion: String = "1.0.0"
    ) {
        self.current = snapshot
        self.cachedMatcher = DomainMatcher(payload: snapshot.payload)
        self.verifier = verifier
        self.transport = transport
        self.appVersion = appVersion
    }

    public var activeVersion: KnowledgeBaseVersion { current.version }

    public var isStale: Bool { current.isExpired(now: Date()) }

    public func classify(_ host: NormalizedHost) -> [DomainMatch] {
        cachedMatcher.matches(for: host)
    }

    public func matcher() -> DomainMatcher { cachedMatcher }

    public func snapshot() -> KnowledgeBaseSnapshot { current }

    public func updateIfNeeded(now: Date = Date()) async throws -> KnowledgeBaseUpdateResult {
        let fetched: (manifest: KnowledgeBaseManifest, payloadBytes: [UInt8])
        do {
            fetched = try await transport.fetchLatest()
        } catch KnowledgeBaseServiceError.updatesDisabled {
            return .notAttempted(reason: "updates_disabled")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(KnowledgeBasePayload.self, from: Data(fetched.payloadBytes)) else {
            return .rejected(reason: "malformed_payload")
        }

        do {
            try verifier.verify(
                manifest: fetched.manifest,
                payloadBytes: fetched.payloadBytes,
                payload: payload,
                installedVersion: current.payload.datasetVersion,
                appVersion: appVersion,
                now: now
            )
        } catch let failure as KnowledgeBaseVerifier.Failure {
            if case .rollbackRejected = failure {
                return .upToDate(version: current.payload.datasetVersion)
            }
            return .rejected(reason: String(describing: failure))
        }

        previous = current
        current = KnowledgeBaseSnapshot(
            manifest: fetched.manifest,
            payload: payload,
            origin: .downloaded,
            installedAt: now
        )
        cachedMatcher = DomainMatcher(payload: payload)
        return .installed(version: payload.datasetVersion)
    }

    public func rollback() throws {
        guard let previous else { throw KnowledgeBaseServiceError.noRollbackAvailable }
        current = previous
        cachedMatcher = DomainMatcher(payload: previous.payload)
        self.previous = nil
    }
}
