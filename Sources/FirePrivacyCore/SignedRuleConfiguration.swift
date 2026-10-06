import Foundation

public struct RuleConfigurationManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configurationVersion: String
    public let sequence: Int64
    public let generatedAt: Int64
    public let expiresAt: Int64
    public let minimumAppVersion: String
    public let ruleCount: Int
    public let payloadSHA256: String
    public let signingKeyID: String
    public let signatureBase64: String

    public init(schemaVersion: Int = 1, configurationVersion: String, sequence: Int64,
                generatedAt: Int64, expiresAt: Int64, minimumAppVersion: String,
                ruleCount: Int = 8, payloadSHA256: String, signingKeyID: String, signatureBase64: String) {
        self.schemaVersion = schemaVersion; self.configurationVersion = configurationVersion; self.sequence = sequence
        self.generatedAt = generatedAt; self.expiresAt = expiresAt; self.minimumAppVersion = minimumAppVersion
        self.ruleCount = ruleCount; self.payloadSHA256 = payloadSHA256; self.signingKeyID = signingKeyID
        self.signatureBase64 = signatureBase64
    }

    /// Domain-separated, fixed-order UTF-8 fields with LF after every field.
    /// Editorial metadata cannot inject LF because the verifier validates each field.
    public var signingRepresentation: Data {
        Data((["FirePrivacy.AnalysisRules.v1", String(schemaVersion), configurationVersion,
            String(sequence), String(generatedAt), String(expiresAt), minimumAppVersion,
            String(ruleCount), payloadSHA256, signingKeyID].joined(separator: "\n") + "\n").utf8)
    }

    public func encoded() throws -> Data { try RuleConfigurationJSON.encode(self) }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, configurationVersion, sequence, generatedAt, expiresAt
        case minimumAppVersion, ruleCount, payloadSHA256, signingKeyID, signatureBase64
    }
    public init(from decoder: any Decoder) throws {
        try RuleConfigurationJSON.closed(decoder, fields: ["schemaVersion", "configurationVersion", "sequence", "generatedAt",
            "expiresAt", "minimumAppVersion", "ruleCount", "payloadSHA256", "signingKeyID", "signatureBase64"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            configurationVersion: try values.decode(String.self, forKey: .configurationVersion),
            sequence: try values.decode(Int64.self, forKey: .sequence),
            generatedAt: try values.decode(Int64.self, forKey: .generatedAt),
            expiresAt: try values.decode(Int64.self, forKey: .expiresAt),
            minimumAppVersion: try values.decode(String.self, forKey: .minimumAppVersion),
            ruleCount: try values.decode(Int.self, forKey: .ruleCount),
            payloadSHA256: try values.decode(String.self, forKey: .payloadSHA256),
            signingKeyID: try values.decode(String.self, forKey: .signingKeyID),
            signatureBase64: try values.decode(String.self, forKey: .signatureBase64))
    }
}

/// The existing explicitly approved update transport can carry this data-only
/// envelope. It does not authorize transmission or supply a new transport.
public struct SignedRuleConfiguration: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 32 * 1_024
    public let manifest: RuleConfigurationManifest
    public let payloadData: Data
    public init(manifest: RuleConfigurationManifest, payloadData: Data) {
        self.manifest = manifest; self.payloadData = payloadData
    }
    public func encoded() throws -> Data {
        let bytes = try RuleConfigurationJSON.encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw RuleConfigurationVerifier.Failure.oversized }
        return bytes
    }
    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumEncodedBytes else { throw RuleConfigurationVerifier.Failure.oversized }
        do {
            try RuleConfigurationJSON.validateShape(bytes, maximumDepth: 2, maximumStringBytes: 24 * 1_024, maximumObjects: 2)
            return try JSONDecoder().decode(Self.self, from: bytes)
        } catch { throw RuleConfigurationVerifier.Failure.malformedManifest }
    }
    private enum CodingKeys: String, CodingKey { case manifest, payloadData }
    public init(from decoder: any Decoder) throws {
        try RuleConfigurationJSON.closed(decoder, fields: ["manifest", "payloadData"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(manifest: try values.decode(RuleConfigurationManifest.self, forKey: .manifest),
            payloadData: try values.decode(Data.self, forKey: .payloadData))
    }
}

/// The complete signed manifest fingerprint binds the current release's expiry,
/// minimum app version and signer; a restore cannot replace them at the same sequence.
public struct RuleConfigurationHighWaterMark: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let configurationVersion: String
    public let payloadSHA256: String
    public let manifestSHA256: String
    public init(sequence: Int64, configurationVersion: String, payloadSHA256: String, manifestSHA256: String) {
        self.sequence = sequence; self.configurationVersion = configurationVersion
        self.payloadSHA256 = payloadSHA256; self.manifestSHA256 = manifestSHA256
    }
}

public struct VerifiedRuleConfiguration: Sendable {
    public let signed: SignedRuleConfiguration
    public let configuration: DeclarativeRuleConfiguration
    public let manifestSHA256: String
    public var manifest: RuleConfigurationManifest { signed.manifest }
    public var highWaterMark: RuleConfigurationHighWaterMark {
        .init(sequence: manifest.sequence, configurationVersion: manifest.configurationVersion,
            payloadSHA256: manifest.payloadSHA256, manifestSHA256: manifestSHA256)
    }
    public func isExpired(now: Date = Date()) -> Bool {
        !now.timeIntervalSince1970.isFinite || now.timeIntervalSince1970 >= Double(manifest.expiresAt)
    }
    fileprivate init(signed: SignedRuleConfiguration, configuration: DeclarativeRuleConfiguration, manifestSHA256: String) {
        self.signed = signed; self.configuration = configuration; self.manifestSHA256 = manifestSHA256
    }
}

/// Shares the operator's pinned Ed25519 trust family with knowledge updates, but
/// uses an independent signature domain, lifetime, release sequence and revocation scope.
public struct RuleConfigurationVerifier: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case oversized, malformedManifest, unsupportedSchema, unknownSigningKey, ambiguousSigningKey
        case revoked, signatureInvalid, payloadDigestMismatch, expired, futureDated, invalidLifetime
        case minimumAppVersionNotMet, invalidHighWaterMark, rollbackRejected, equivocationRejected
        case malformedPayload, metadataMismatch
    }
    public static let maximumLifetime: Int64 = 90 * 86_400
    public let trustAnchors: [KnowledgeBaseTrustAnchor]
    public let revokedKeyIDs: Set<String>
    public let revokedPayloadDigests: Set<String>
    public init(trustAnchors: [KnowledgeBaseTrustAnchor], revokedKeyIDs: Set<String> = [],
                revokedPayloadDigests: Set<String> = []) {
        self.trustAnchors = trustAnchors; self.revokedKeyIDs = revokedKeyIDs; self.revokedPayloadDigests = revokedPayloadDigests
    }

    public func verify(_ signed: SignedRuleConfiguration, appVersion: String, now: Date = Date(),
                       highWaterMark: RuleConfigurationHighWaterMark? = nil,
                       restoringCurrent: Bool = false) throws -> VerifiedRuleConfiguration {
        guard !signed.payloadData.isEmpty, signed.payloadData.count <= DeclarativeRuleConfiguration.maximumDocumentBytes,
              (try? signed.manifest.encoded().count).map({ $0 <= 4_096 }) == true else { throw Failure.oversized }
        let manifest = signed.manifest
        guard manifest.schemaVersion == DeclarativeRuleConfiguration.schemaVersion else { throw Failure.unsupportedSchema }
        guard let version = RuleNumericVersion(manifest.configurationVersion),
              let minimum = RuleNumericVersion(manifest.minimumAppVersion),
              let current = RuleNumericVersion(appVersion, allowShortAppVersion: true),
              manifest.sequence > 0, manifest.generatedAt >= 0, manifest.generatedAt <= 253_402_300_799,
              manifest.expiresAt <= 253_402_300_799,
              manifest.ruleCount == DetectorRuleID.allCases.count, Self.identifier(manifest.signingKeyID),
              Self.digest(manifest.payloadSHA256), manifest.signatureBase64.utf8.count == 88 else { throw Failure.malformedManifest }
        let anchors = trustAnchors.filter { $0.keyID == manifest.signingKeyID }
        guard !anchors.isEmpty, anchors[0].publicKey.count == 32 else { throw Failure.unknownSigningKey }
        guard anchors.count == 1 else { throw Failure.ambiguousSigningKey }
        let anchor = anchors[0]
        guard !revokedKeyIDs.contains(manifest.signingKeyID), !revokedPayloadDigests.contains(manifest.payloadSHA256) else {
            throw Failure.revoked
        }
        guard let signature = Data(base64Encoded: manifest.signatureBase64),
              DetachedSignature.verify(signature: signature, message: manifest.signingRepresentation, publicKey: anchor.publicKey) else {
            throw Failure.signatureInvalid
        }
        guard ContentDigest.sha256(signed.payloadData) == manifest.payloadSHA256 else { throw Failure.payloadDigestMismatch }
        // No configuration JSON is decoded before signature and raw byte digest validation.
        let timestamp = now.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0, timestamp <= 253_402_300_799,
              Double(manifest.generatedAt) <= timestamp + 300 else { throw Failure.futureDated }
        guard manifest.expiresAt > manifest.generatedAt,
              manifest.expiresAt - manifest.generatedAt <= Self.maximumLifetime,
              anchor.validFrom >= 0, manifest.generatedAt >= anchor.validFrom,
              anchor.expiresAt.map({ $0 > anchor.validFrom && manifest.generatedAt < $0 && timestamp < Double($0) }) ?? true else {
            throw Failure.invalidLifetime
        }
        guard timestamp < Double(manifest.expiresAt) else { throw Failure.expired }
        guard current >= minimum else { throw Failure.minimumAppVersionNotMet }
        let manifestDigest = ContentDigest.sha256(try manifest.encoded())
        if let prior = highWaterMark {
            guard prior.sequence > 0, let priorVersion = RuleNumericVersion(prior.configurationVersion),
                  Self.digest(prior.payloadSHA256), Self.digest(prior.manifestSHA256) else { throw Failure.invalidHighWaterMark }
            if manifest.sequence == prior.sequence {
                guard manifest.configurationVersion == prior.configurationVersion,
                      manifest.payloadSHA256 == prior.payloadSHA256, manifestDigest == prior.manifestSHA256 else {
                    throw Failure.equivocationRejected
                }
                guard restoringCurrent else { throw Failure.rollbackRejected }
            } else {
                guard !restoringCurrent, manifest.sequence > prior.sequence, version > priorVersion else { throw Failure.rollbackRejected }
            }
        } else if restoringCurrent { throw Failure.invalidHighWaterMark }
        let configuration: DeclarativeRuleConfiguration
        do { configuration = try DeclarativeRuleConfiguration.decode(signed.payloadData) }
        catch { throw Failure.malformedPayload }
        guard configuration.schemaVersion == manifest.schemaVersion, configuration.version == manifest.configurationVersion,
              configuration.rules.count == manifest.ruleCount else { throw Failure.metadataMismatch }
        return .init(signed: signed, configuration: configuration, manifestSHA256: manifestDigest)
    }

    private static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

private struct RuleNumericVersion: Comparable {
    let parts: [Int]
    init?(_ value: String, allowShortAppVersion: Bool = false) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 || (allowShortAppVersion && fields.count == 2),
              fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 6 && ($0.count == 1 || $0.first != "0")
                  && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let parsed = fields.compactMap { Int($0) }
        parts = parsed + Array(repeating: 0, count: 3 - parsed.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}
