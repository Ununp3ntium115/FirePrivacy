import Foundation

/// Revocations deny authority; expiry or an unavailable update never removes
/// entries already authenticated and retained in encrypted private storage.
public struct KnowledgeBaseRevocations: Codable, Hashable, Sendable {
    public let revokedVersions: Set<String>
    public let revokedKeyIDs: Set<String>
    public let revokedPayloadDigests: Set<String>

    public init(revokedVersions: Set<String> = [], revokedKeyIDs: Set<String> = [],
                revokedPayloadDigests: Set<String> = []) {
        self.revokedVersions = revokedVersions
        self.revokedKeyIDs = revokedKeyIDs
        self.revokedPayloadDigests = revokedPayloadDigests
    }

    public func revokes(_ manifest: KnowledgeBaseManifest) -> Bool {
        revokedVersions.contains(manifest.datasetVersion) || revokedKeyIDs.contains(manifest.signingKeyID)
            || revokedPayloadDigests.contains(manifest.payloadSHA256)
    }

    fileprivate func containsAll(_ previous: Self) -> Bool {
        revokedVersions.isSuperset(of: previous.revokedVersions)
            && revokedKeyIDs.isSuperset(of: previous.revokedKeyIDs)
            && revokedPayloadDigests.isSuperset(of: previous.revokedPayloadDigests)
    }

    fileprivate var isValid: Bool {
        revokedVersions.count + revokedKeyIDs.count + revokedPayloadDigests.count <= 10_000
            && revokedVersions.allSatisfy(RevocationBounds.version)
            && revokedKeyIDs.allSatisfy(RevocationBounds.identifier)
            && revokedPayloadDigests.allSatisfy(RevocationBounds.digest)
    }
}

/// Arrays retain duplicate/order evidence during decoding. Publisher payloads
/// use sorted unique strings and this exact closed schema.
public struct KnowledgeBaseRevocationPayload: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sequence: Int64
    public let revokedVersions: [String]
    public let revokedKeyIDs: [String]
    public let revokedPayloadDigests: [String]

    public init(sequence: Int64, revocations: KnowledgeBaseRevocations) {
        schemaVersion = 1
        self.sequence = sequence
        revokedVersions = revocations.revokedVersions.sorted()
        revokedKeyIDs = revocations.revokedKeyIDs.sorted()
        revokedPayloadDigests = revocations.revokedPayloadDigests.sorted()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sequence, revokedVersions, revokedKeyIDs, revokedPayloadDigests
    }
    public init(from decoder: any Decoder) throws {
        try RevocationBounds.closed(decoder, fields: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        sequence = try values.decode(Int64.self, forKey: .sequence)
        revokedVersions = try values.decode([String].self, forKey: .revokedVersions)
        revokedKeyIDs = try values.decode([String].self, forKey: .revokedKeyIDs)
        revokedPayloadDigests = try values.decode([String].self, forKey: .revokedPayloadDigests)
    }

    fileprivate var revocations: KnowledgeBaseRevocations {
        .init(revokedVersions: Set(revokedVersions), revokedKeyIDs: Set(revokedKeyIDs),
              revokedPayloadDigests: Set(revokedPayloadDigests))
    }
    fileprivate var count: Int { revokedVersions.count + revokedKeyIDs.count + revokedPayloadDigests.count }
    fileprivate var isValid: Bool {
        count <= 10_000 && revocations.isValid
            && [revokedVersions, revokedKeyIDs, revokedPayloadDigests].allSatisfy {
                $0 == $0.sorted() && Set($0).count == $0.count
            }
    }
}

public struct KnowledgeBaseRevocationManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sequence: Int64
    public let generatedAt: Int64
    public let expiresAt: Int64
    public let revocationCount: Int
    public let payloadByteCount: Int
    public let payloadSHA256: String
    public let signingKeyID: String
    public let signatureBase64: String

    public init(sequence: Int64, generatedAt: Int64, expiresAt: Int64, revocationCount: Int,
                payloadByteCount: Int, payloadSHA256: String, signingKeyID: String, signatureBase64: String) {
        schemaVersion = 1
        self.sequence = sequence; self.generatedAt = generatedAt; self.expiresAt = expiresAt
        self.revocationCount = revocationCount; self.payloadByteCount = payloadByteCount
        self.payloadSHA256 = payloadSHA256; self.signingKeyID = signingKeyID
        self.signatureBase64 = signatureBase64
    }

    /// UTF-8 fixed-order ASCII fields, each followed by LF, including the last.
    /// The domain separator prevents a KB signature from authorizing revocations.
    public var signingRepresentation: Data {
        Data((["FirePrivacy.KnowledgeBaseRevocations.v1", String(schemaVersion), String(sequence),
               String(generatedAt), String(expiresAt), String(revocationCount), String(payloadByteCount),
               payloadSHA256, signingKeyID].joined(separator: "\n") + "\n").utf8)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sequence, generatedAt, expiresAt, revocationCount, payloadByteCount
        case payloadSHA256, signingKeyID, signatureBase64
    }
    public init(from decoder: any Decoder) throws {
        try RevocationBounds.closed(decoder, fields: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        sequence = try values.decode(Int64.self, forKey: .sequence)
        generatedAt = try values.decode(Int64.self, forKey: .generatedAt)
        expiresAt = try values.decode(Int64.self, forKey: .expiresAt)
        revocationCount = try values.decode(Int.self, forKey: .revocationCount)
        payloadByteCount = try values.decode(Int.self, forKey: .payloadByteCount)
        payloadSHA256 = try values.decode(String.self, forKey: .payloadSHA256)
        signingKeyID = try values.decode(String.self, forKey: .signingKeyID)
        signatureBase64 = try values.decode(String.self, forKey: .signatureBase64)
    }
}

/// Downloads remain opaque bounded bytes until the verifier authenticates them.
public struct SignedKnowledgeBaseRevocations: Codable, Hashable, Sendable {
    public let manifestData: Data
    public let payloadData: Data
    public init(manifestData: Data, payloadData: Data) {
        self.manifestData = manifestData; self.payloadData = payloadData
    }
}

/// Persist only with the signed document in authenticated encrypted app storage.
/// The retained sets remain effective even if its signed document has expired.
public struct KnowledgeBaseRevocationHighWaterMark: Codable, Hashable, Sendable {
    public let sequence: Int64
    public let documentSHA256: String
    public let revocations: KnowledgeBaseRevocations
    public init(sequence: Int64, documentSHA256: String, revocations: KnowledgeBaseRevocations) {
        self.sequence = sequence; self.documentSHA256 = documentSHA256; self.revocations = revocations
    }
}

public struct VerifiedKnowledgeBaseRevocations: Sendable {
    public let signedDocument: SignedKnowledgeBaseRevocations
    public let manifest: KnowledgeBaseRevocationManifest
    public let revocations: KnowledgeBaseRevocations
    public let highWaterMark: KnowledgeBaseRevocationHighWaterMark
    public var expiresAt: Date { Date(timeIntervalSince1970: Double(manifest.expiresAt)) }
    public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }
    fileprivate init(signed: SignedKnowledgeBaseRevocations, manifest: KnowledgeBaseRevocationManifest,
                     revocations: KnowledgeBaseRevocations, documentSHA256: String) {
        signedDocument = signed; self.manifest = manifest; self.revocations = revocations
        highWaterMark = .init(sequence: manifest.sequence, documentSHA256: documentSHA256, revocations: revocations)
    }
}

public struct KnowledgeBaseRevocationVerifier: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case oversized, malformedManifest, unsupportedSchema, unknownSigningKey, revokedSigningKey
        case signatureInvalid, payloadDigestMismatch, futureDated, invalidLifetime, expired
        case malformedPayload, metadataMismatch, invalidSemantics, invalidPreviousState
        case rollbackRejected, stickyRevocationRemoved
    }
    public static let maximumPayloadBytes = 1_024 * 1_024
    public let trustAnchors: [KnowledgeBaseTrustAnchor]
    public init(trustAnchors: [KnowledgeBaseTrustAnchor] = KnowledgeBaseResources.trustAnchors) {
        self.trustAnchors = trustAnchors
    }

    public func verify(_ signed: SignedKnowledgeBaseRevocations, now: Date = Date(),
                       highWaterMark: KnowledgeBaseRevocationHighWaterMark? = nil,
                       restoringCurrent: Bool = false) throws -> VerifiedKnowledgeBaseRevocations {
        guard !signed.manifestData.isEmpty, signed.manifestData.count <= 16_384,
              !signed.payloadData.isEmpty, signed.payloadData.count <= Self.maximumPayloadBytes else {
            throw Failure.oversized
        }
        let manifest: KnowledgeBaseRevocationManifest
        do {
            guard RevocationBounds.uniqueRootFields(signed.manifestData) else { throw Failure.malformedManifest }
            manifest = try JSONDecoder().decode(KnowledgeBaseRevocationManifest.self, from: signed.manifestData)
        }
        catch { throw Failure.malformedManifest }
        guard manifest.schemaVersion == 1 else { throw Failure.unsupportedSchema }
        guard manifest.sequence > 0, manifest.generatedAt >= 0,
              manifest.expiresAt <= 253_402_300_799, (0...10_000).contains(manifest.revocationCount),
              (1...Self.maximumPayloadBytes).contains(manifest.payloadByteCount),
              RevocationBounds.digest(manifest.payloadSHA256), RevocationBounds.identifier(manifest.signingKeyID) else {
            throw Failure.malformedManifest
        }
        if let previous = highWaterMark,
           previous.sequence <= 0 || !RevocationBounds.digest(previous.documentSHA256) || !previous.revocations.isValid {
            throw Failure.invalidPreviousState
        }
        let matchingAnchors = trustAnchors.filter { $0.keyID == manifest.signingKeyID }
        guard matchingAnchors.count == 1, let anchor = matchingAnchors.first, anchor.publicKey.count == 32 else {
            throw Failure.unknownSigningKey
        }
        guard let signature = Data(base64Encoded: manifest.signatureBase64),
              DetachedSignature.verify(signature: signature, message: manifest.signingRepresentation, publicKey: anchor.publicKey) else {
            throw Failure.signatureInvalid
        }
        guard signed.payloadData.count == manifest.payloadByteCount,
              ContentDigest.sha256(signed.payloadData) == manifest.payloadSHA256 else { throw Failure.payloadDigestMismatch }
        let documentDigest = ContentDigest.sha256(manifest.signingRepresentation + signature + signed.payloadData)
        let exactRestore = restoringCurrent && highWaterMark?.sequence == manifest.sequence
            && highWaterMark?.documentSHA256 == documentDigest
        if highWaterMark?.revocations.revokedKeyIDs.contains(manifest.signingKeyID) == true && !exactRestore {
            throw Failure.revokedSigningKey
        }
        let timestamp = now.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0, timestamp <= 253_402_300_799,
              manifest.generatedAt <= Int64(timestamp + 300) else { throw Failure.futureDated }
        guard manifest.expiresAt > manifest.generatedAt,
              manifest.expiresAt - manifest.generatedAt <= 90 * 86_400,
              manifest.generatedAt >= anchor.validFrom,
              anchor.expiresAt.map({ manifest.generatedAt < $0 && timestamp < Double($0) }) ?? true else {
            throw Failure.invalidLifetime
        }
        guard timestamp < Double(manifest.expiresAt) else { throw Failure.expired }
        if let previous = highWaterMark {
            guard exactRestore || manifest.sequence > previous.sequence else { throw Failure.rollbackRejected }
        }
        // A malformed or substituted payload is never decoded before its
        // authentic signature, exact byte count and SHA-256 digest are checked.
        let payload: KnowledgeBaseRevocationPayload
        do {
            guard RevocationBounds.uniqueRootFields(signed.payloadData) else { throw Failure.malformedPayload }
            payload = try JSONDecoder().decode(KnowledgeBaseRevocationPayload.self, from: signed.payloadData)
        }
        catch { throw Failure.malformedPayload }
        guard payload.schemaVersion == manifest.schemaVersion, payload.sequence == manifest.sequence,
              payload.count == manifest.revocationCount else { throw Failure.metadataMismatch }
        guard payload.isValid else { throw Failure.invalidSemantics }
        let revocations = payload.revocations
        if let previous = highWaterMark {
            guard revocations.containsAll(previous.revocations) else { throw Failure.stickyRevocationRemoved }
            guard !exactRestore || revocations == previous.revocations else { throw Failure.invalidPreviousState }
        }
        return .init(signed: signed, manifest: manifest, revocations: revocations, documentSHA256: documentDigest)
    }
}

private enum RevocationBounds {
    /// JSONDecoder's keyed containers collapse duplicate fields. Reject them
    /// before decoding, including escaped spellings of an existing field. Full
    /// JSON syntax and the closed typed schema remain JSONDecoder's job.
    static func uniqueRootFields(_ data: Data) -> Bool {
        let bytes = Array(data)
        let whitespace: Set<UInt8> = [9, 10, 13, 32]
        guard bytes.first(where: { !whitespace.contains($0) }) == 123 else { return false }
        var index = 0, objects = 0, arrays = 0
        var expectingKey = false
        var keys = Set<String>()
        while index < bytes.count {
            switch bytes[index] {
            case 123:
                objects += 1
                if objects == 1 && arrays == 0 { expectingKey = true }
            case 125: objects -= 1
            case 91: arrays += 1
            case 93: arrays -= 1
            case 44:
                if objects == 1 && arrays == 0 { expectingKey = true }
            case 58:
                if objects == 1 && arrays == 0 { expectingKey = false }
            case 34:
                let start = index
                index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { closed = true; break }
                    index += 1
                }
                guard closed else { return false }
                if objects == 1 && arrays == 0 && expectingKey {
                    guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index])),
                          keys.insert(key).inserted else { return false }
                }
            default: break
            }
            // Both schemas consist of one object and scalar/string-array values.
            guard objects >= 0, arrays >= 0, objects + arrays <= 2 else { return false }
            index += 1
        }
        return objects == 0 && arrays == 0
    }

    struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func closed(_ decoder: any Decoder, fields: Set<String>) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard Set(values.allKeys.map(\.stringValue)) == fields else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected revocation fields."))
        }
    }
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func version(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3 && components.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 9 && ($0.count == 1 || $0.first != "0")
                && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
}
