import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum DetachedSignature {
    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

public enum DomainCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case advertising, analytics, attribution, authentication, contentDelivery, content
    case crashReporting, dataBroker, fraudPrevention, locationIntelligence, messaging
    case payments, personalization, pushNotifications, social, telemetry, dnsResolution, unknown
    public var displayName: String {
        switch self {
        case .contentDelivery: "Content delivery"
        case .crashReporting: "Crash reporting"
        case .dataBroker: "Data broker"
        case .fraudPrevention: "Fraud prevention"
        case .locationIntelligence: "Location intelligence"
        case .pushNotifications: "Push notifications"
        case .dnsResolution: "DNS resolution"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
    public var isCommonInfrastructure: Bool {
        [.contentDelivery, .authentication, .payments, .dnsResolution, .pushNotifications, .fraudPrevention].contains(self)
    }
}
public enum DomainPatternKind: String, Codable, Sendable { case exactHost, domainSuffix }
public enum ClassificationReviewStatus: String, Codable, Sendable { case reviewed, provisional, disputed, retired }
public enum ClassificationSourceType: String, Codable, Sendable { case vendorDocumentation, publishedResearch, registryRecord, internalReview }

public struct KnowledgeSource: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let url: String
    public let type: ClassificationSourceType
    public let retrievedAt: Date
    public let excerpt: String
}
public struct DomainClassification: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let pattern: String
    public let patternKind: DomainPatternKind
    public let organization: String?
    public let sdkFamily: String?
    public let categories: [DomainCategory]
    public let purposes: [String]
    public let confidence: Double
    public let sourceIDs: [String]
    public let lastReviewed: Date
    public let expiresAt: Date?
    public let reviewStatus: ClassificationReviewStatus
    public let notes: String
    public var isHeuristicOnly: Bool { sourceIDs.isEmpty }
}
public struct KnowledgeBasePayload: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let datasetVersion: String
    public let sources: [KnowledgeSource]
    public let classifications: [DomainClassification]
}

public struct KnowledgeBaseManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let datasetVersion: String
    public let sequence: Int64
    public let generatedAt: Int64
    public let expiresAt: Int64
    public let minimumAppVersion: String
    public let recordCount: Int
    public let payloadSHA256: String
    public let signingKeyID: String
    public let signatureBase64: String

    /// Exact detached signing format: UTF-8 domain separator and fixed-order
    /// ASCII fields, each followed by LF, including the last field.
    public var signingRepresentation: Data {
        Data((["FirePrivacy.KnowledgeBase.v1", String(schemaVersion), datasetVersion,
               String(sequence), String(generatedAt), String(expiresAt), minimumAppVersion,
               String(recordCount), payloadSHA256, signingKeyID].joined(separator: "\n") + "\n").utf8)
    }
}
public struct KnowledgeBaseTrustAnchor: Codable, Hashable, Sendable {
    public let keyID: String
    public let publicKey: Data
    public let validFrom: Int64
    public let expiresAt: Int64?
    public init(keyID: String, publicKey: Data, validFrom: Int64 = 0, expiresAt: Int64? = nil) {
        self.keyID = keyID; self.publicKey = publicKey; self.validFrom = validFrom; self.expiresAt = expiresAt
    }
}
public struct KnowledgeBaseHighWaterMark: Codable, Hashable, Sendable {
    public let sequence: Int64
    public let datasetVersion: String
    public let payloadSHA256: String
    public init(sequence: Int64, datasetVersion: String, payloadSHA256: String) {
        self.sequence = sequence; self.datasetVersion = datasetVersion; self.payloadSHA256 = payloadSHA256
    }
}
public struct VerifiedKnowledgeBase: Sendable {
    public let manifest: KnowledgeBaseManifest
    public let payload: KnowledgeBasePayload
    public let manifestData: Data
    public let payloadData: Data
    public var version: String { manifest.datasetVersion }
    public var datasetVersion: String { manifest.datasetVersion }
    public var highWaterMark: KnowledgeBaseHighWaterMark {
        .init(sequence: manifest.sequence, datasetVersion: manifest.datasetVersion, payloadSHA256: manifest.payloadSHA256)
    }
    public func isExpired(now: Date = Date()) -> Bool { now.timeIntervalSince1970 >= Double(manifest.expiresAt) }
    // Only a verifier in this file can create an activation value.
    fileprivate init(manifest: KnowledgeBaseManifest, payload: KnowledgeBasePayload, manifestData: Data, payloadData: Data) {
        self.manifest = manifest; self.payload = payload; self.manifestData = manifestData; self.payloadData = payloadData
    }
}

public struct KnowledgeBaseVerifier: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case oversized, malformedManifest, unsupportedSchema, unknownSigningKey, revoked
        case signatureInvalid, payloadDigestMismatch, expired, futureDated, invalidLifetime
        case rollbackRejected, minimumAppVersionNotMet, malformedPayload, metadataMismatch, invalidSemantics
    }
    public static let maximumPayloadBytes = 4 * 1024 * 1024
    public let trustAnchors: [KnowledgeBaseTrustAnchor]
    public let revokedVersions: Set<String>
    public let revokedKeyIDs: Set<String>
    public init(trustAnchors: [KnowledgeBaseTrustAnchor], revokedVersions: Set<String> = [], revokedKeyIDs: Set<String> = []) {
        self.trustAnchors = trustAnchors; self.revokedVersions = revokedVersions; self.revokedKeyIDs = revokedKeyIDs
    }

    public func verify(manifestData: Data, payloadData: Data, appVersion: String,
                       now: Date = Date(), highWaterMark: KnowledgeBaseHighWaterMark? = nil,
                       restoringCurrent: Bool = false) throws -> VerifiedKnowledgeBase {
        guard !manifestData.isEmpty, manifestData.count <= 16_384, !payloadData.isEmpty,
              payloadData.count <= Self.maximumPayloadBytes else { throw Failure.oversized }
        let manifest: KnowledgeBaseManifest
        do { manifest = try JSONDecoder().decode(KnowledgeBaseManifest.self, from: manifestData) }
        catch { throw Failure.malformedManifest }
        guard manifest.schemaVersion == 1 else { throw Failure.unsupportedSchema }
        guard let version = NumericVersion(manifest.datasetVersion), let minimum = NumericVersion(manifest.minimumAppVersion),
              let current = NumericVersion(appVersion, allowShortAppVersion: true), manifest.sequence > 0, manifest.generatedAt >= 0,
              manifest.expiresAt <= 253_402_300_799, (0...20_000).contains(manifest.recordCount),
              Self.identifier(manifest.signingKeyID), manifest.payloadSHA256.utf8.count == 64,
              manifest.payloadSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.malformedManifest
        }
        guard let anchor = trustAnchors.first(where: { $0.keyID == manifest.signingKeyID }),
              anchor.publicKey.count == 32 else { throw Failure.unknownSigningKey }
        guard !revokedKeyIDs.contains(anchor.keyID), !revokedVersions.contains(manifest.datasetVersion) else { throw Failure.revoked }
        guard let signature = Data(base64Encoded: manifest.signatureBase64),
              DetachedSignature.verify(signature: signature, message: manifest.signingRepresentation, publicKey: anchor.publicKey) else {
            throw Failure.signatureInvalid
        }
        guard ContentDigest.sha256(payloadData) == manifest.payloadSHA256 else { throw Failure.payloadDigestMismatch }
        // No payload JSON is decoded before cryptographic authenticity above.
        let timestamp = now.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0, timestamp <= 253_402_300_799,
              manifest.generatedAt <= Int64(timestamp + 300) else { throw Failure.futureDated }
        guard manifest.expiresAt > manifest.generatedAt,
              manifest.expiresAt - manifest.generatedAt <= 366 * 86_400,
              manifest.generatedAt >= anchor.validFrom,
              anchor.expiresAt.map({ manifest.generatedAt < $0 && timestamp < Double($0) }) ?? true else { throw Failure.invalidLifetime }
        guard timestamp < Double(manifest.expiresAt) else { throw Failure.expired }
        guard current >= minimum else { throw Failure.minimumAppVersionNotMet }
        if let highWaterMark {
            let sameRelease = manifest.sequence == highWaterMark.sequence
                && manifest.datasetVersion == highWaterMark.datasetVersion && manifest.payloadSHA256 == highWaterMark.payloadSHA256
            guard (restoringCurrent && sameRelease) ||
                    (manifest.sequence > highWaterMark.sequence && NumericVersion(highWaterMark.datasetVersion).map({ version > $0 }) == true)
            else { throw Failure.rollbackRejected }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: KnowledgeBasePayload
        do { payload = try decoder.decode(KnowledgeBasePayload.self, from: payloadData) }
        catch { throw Failure.malformedPayload }
        guard payload.schemaVersion == manifest.schemaVersion, payload.datasetVersion == manifest.datasetVersion,
              payload.classifications.count == manifest.recordCount else { throw Failure.metadataMismatch }
        try Self.validate(payload, manifest: manifest)
        return .init(manifest: manifest, payload: payload, manifestData: manifestData, payloadData: payloadData)
    }

    private static func validate(_ payload: KnowledgeBasePayload, manifest: KnowledgeBaseManifest) throws {
        guard payload.sources.count <= 2_000,
              Set(payload.sources.map(\.id)).count == payload.sources.count,
              Set(payload.classifications.map(\.id)).count == payload.classifications.count,
              Set(payload.classifications.map { $0.patternKind.rawValue + ":" + $0.pattern }).count == payload.classifications.count
        else { throw Failure.invalidSemantics }
        let sourceIDs = Set(payload.sources.map(\.id))
        for source in payload.sources {
            guard identifier(source.id), boundedText(source.title, max: 240), boundedText(source.excerpt, max: 2_000),
                  source.url.utf8.count <= 2_048, let url = URL(string: source.url), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, source.retrievedAt.timeIntervalSince1970 >= 0,
                  source.retrievedAt.timeIntervalSince1970 <= Double(manifest.generatedAt + 300) else { throw Failure.invalidSemantics }
        }
        for record in payload.classifications {
            guard identifier(record.id), let host = DomainIdentity(record.pattern), host.value == record.pattern,
                  !host.isPublicSuffix, !record.categories.isEmpty, record.categories.count <= 8,
                  Set(record.categories).count == record.categories.count,
                  record.categories.allSatisfy({ $0 != .unknown }), record.confidence.isFinite, (0...1).contains(record.confidence),
                  !record.sourceIDs.isEmpty, record.sourceIDs.count <= 8, Set(record.sourceIDs).count == record.sourceIDs.count,
                  record.sourceIDs.allSatisfy(sourceIDs.contains), !record.purposes.isEmpty, record.purposes.count <= 8,
                  record.purposes.allSatisfy({ boundedText($0, max: 400) }), boundedText(record.notes, max: 2_000),
                  record.organization.map({ boundedText($0, max: 240) }) ?? true,
                  record.sdkFamily.map({ boundedText($0, max: 240) }) ?? true,
                  record.lastReviewed.timeIntervalSince1970 >= 0,
                  record.lastReviewed.timeIntervalSince1970 <= Double(manifest.generatedAt + 300),
                  record.expiresAt.map({ $0 > record.lastReviewed && $0.timeIntervalSince1970 <= Double(manifest.expiresAt) }) ?? true
            else { throw Failure.invalidSemantics }
        }
    }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)
        }
    }
    private static func boundedText(_ value: String, max: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= max
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
    }
}

private struct NumericVersion: Comparable {
    let parts: [Int]
    init?(_ value: String, allowShortAppVersion: Bool = false) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (components.count == 3 || (allowShortAppVersion && components.count == 2)), components.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 9 && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let parsed = components.compactMap { Int($0) }
        parts = parsed + Array(repeating: 0, count: 3 - parsed.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public struct DomainMatch: Hashable, Sendable {
    public let classification: DomainClassification
    public let sources: [KnowledgeSource]
    public let isExactMatch: Bool
    public let isStale: Bool
    public var evidenceConfidence: Double { min(classification.confidence, isExactMatch ? 0.95 : 0.85) }
}
public struct DomainMatcher: Sendable {
    public let snapshot: VerifiedKnowledgeBase
    private let exact: [String: DomainClassification]
    private let suffix: [String: DomainClassification]
    private let sources: [String: KnowledgeSource]
    public init(snapshot: VerifiedKnowledgeBase) {
        self.snapshot = snapshot
        exact = Dictionary(uniqueKeysWithValues: snapshot.payload.classifications.filter { $0.patternKind == .exactHost }.map { ($0.pattern, $0) })
        suffix = Dictionary(uniqueKeysWithValues: snapshot.payload.classifications.filter { $0.patternKind == .domainSuffix }.map { ($0.pattern, $0) })
        sources = Dictionary(uniqueKeysWithValues: snapshot.payload.sources.map { ($0.id, $0) })
    }
    public func matches(for rawHost: String, now: Date = Date()) -> [DomainMatch] {
        guard let host = DomainIdentity(rawHost) else { return [] }
        return matches(for: host, now: now)
    }
    public func matches(for host: DomainIdentity, now: Date = Date()) -> [DomainMatch] {
        var records: [DomainClassification] = []
        if let record = exact[host.value] { records.append(record) }
        let labels = host.value.split(separator: ".")
        for index in labels.indices {
            if let record = suffix[labels[index...].joined(separator: ".")] { records.append(record) }
        }
        return records.filter { $0.reviewStatus != .retired }.sorted { left, right in
            if left.patternKind != right.patternKind { return left.patternKind == .exactHost }
            return left.pattern.count == right.pattern.count ? left.id < right.id : left.pattern.count > right.pattern.count
        }.map { record in
            .init(classification: record, sources: record.sourceIDs.compactMap { sources[$0] },
                  isExactMatch: record.pattern == host.value,
                  isStale: snapshot.isExpired(now: now) || (record.expiresAt.map { $0 <= now } ?? false))
        }
    }
}

/// User opinions are separate local values; they never change the signed data
/// or claim that an OS protection action was installed.
public struct DomainOverride: Codable, Hashable, Sendable, Identifiable {
    public enum Disposition: String, Codable, Sendable { case trusted, alwaysReview, customCategory, localAllow, localBlockRequest }
    public var id: String { host.value }
    public let host: DomainIdentity
    public let disposition: Disposition
    public let customCategories: [DomainCategory]
    public let note: String?
    public let createdAt: Date
    public init(host: DomainIdentity, disposition: Disposition, customCategories: [DomainCategory] = [], note: String? = nil, createdAt: Date = Date()) {
        self.host = host; self.disposition = disposition
        self.customCategories = Array(Set(customCategories)).sorted { $0.rawValue < $1.rawValue }.prefix(8).map { $0 }
        self.note = note.map { String($0.prefix(2_000)) }; self.createdAt = createdAt
    }
}
public struct DomainOverrideSet: Codable, Hashable, Sendable {
    public private(set) var overrides: [String: DomainOverride]
    public init(overrides: [DomainOverride] = []) {
        self.overrides = Dictionary(overrides.map { ($0.host.value, $0) }, uniquingKeysWith: { _, last in last })
    }
    public func override(for host: DomainIdentity) -> DomainOverride? { overrides[host.value] }
    public mutating func set(_ value: DomainOverride) { overrides[value.host.value] = value }
    public mutating func remove(host: DomainIdentity) { overrides.removeValue(forKey: host.value) }
    public var sorted: [DomainOverride] { overrides.values.sorted { $0.host.value < $1.host.value } }
}
