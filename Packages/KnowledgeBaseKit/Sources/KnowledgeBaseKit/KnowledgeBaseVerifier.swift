import Foundation
import ObservationCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A public key trusted to sign knowledge-base releases.
public struct TrustAnchor: Sendable, Hashable {
    public let keyID: String
    /// Raw Ed25519 public key, 32 bytes.
    public let publicKey: [UInt8]
    public let addedAt: Date

    public init(keyID: String, publicKey: [UInt8], addedAt: Date) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.addedAt = addedAt
    }
}

/// Verifies a downloaded knowledge base before it can become active (KB-002).
///
/// Every check is a hard gate. There is deliberately no "verify but install
/// anyway" path: a knowledge base decides what the user is told about other
/// companies, so poisoned data is a product-integrity problem, not a warning.
public struct KnowledgeBaseVerifier: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unknownSigningKey(String)
        case signatureInvalid
        case payloadDigestMismatch
        case unsupportedSchema(String)
        case expired(Date)
        case revokedVersion(String)
        case rollbackRejected(installed: String, candidate: String)
        case minimumAppVersionNotMet(required: String, current: String)
        case recordCountMismatch(declared: Int, actual: Int)
        case signatureVerificationUnavailable
    }

    public static let supportedSchemaVersions: Set<String> = ["fireprivacy.kb/1"]

    public let trustAnchors: [TrustAnchor]
    public let revokedVersions: Set<String>

    public init(trustAnchors: [TrustAnchor], revokedVersions: Set<String> = []) {
        self.trustAnchors = trustAnchors
        self.revokedVersions = revokedVersions
    }

    public func verify(
        manifest: KnowledgeBaseManifest,
        payloadBytes: [UInt8],
        payload: KnowledgeBasePayload,
        installedVersion: String?,
        appVersion: String,
        now: Date
    ) throws {
        guard Self.supportedSchemaVersions.contains(manifest.schemaVersion) else {
            throw Failure.unsupportedSchema(manifest.schemaVersion)
        }
        guard !revokedVersions.contains(manifest.datasetVersion) else {
            throw Failure.revokedVersion(manifest.datasetVersion)
        }
        guard DatasetVersion(appVersion) >= DatasetVersion(manifest.minimumAppVersion) else {
            throw Failure.minimumAppVersionNotMet(required: manifest.minimumAppVersion, current: appVersion)
        }
        if let installedVersion {
            guard DatasetVersion(manifest.datasetVersion) > DatasetVersion(installedVersion) else {
                throw Failure.rollbackRejected(installed: installedVersion, candidate: manifest.datasetVersion)
            }
        }
        guard manifest.expiresAt > now else {
            throw Failure.expired(manifest.expiresAt)
        }
        guard FireHasher.hash(payloadBytes) == manifest.payloadDigest else {
            throw Failure.payloadDigestMismatch
        }
        guard payload.classifications.count == manifest.recordCount else {
            throw Failure.recordCountMismatch(declared: manifest.recordCount, actual: payload.classifications.count)
        }
        guard let anchor = trustAnchors.first(where: { $0.keyID == manifest.signingKeyID }) else {
            throw Failure.unknownSigningKey(manifest.signingKeyID)
        }
        guard let signature = Data(base64Encoded: manifest.signature) else {
            throw Failure.signatureInvalid
        }
        guard try Self.isValidEd25519Signature(
            signature: [UInt8](signature),
            message: manifest.signedRepresentation,
            publicKey: anchor.publicKey
        ) else {
            throw Failure.signatureInvalid
        }
    }

    static func isValidEd25519Signature(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) throws -> Bool {
        #if canImport(CryptoKit)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(publicKey)) else {
            throw Failure.unknownSigningKey("malformed")
        }
        return key.isValidSignature(Data(signature), for: Data(message))
        #else
        // No verified signature means no activation. Refusing is the safe
        // outcome; the bundled dataset stays in use.
        throw Failure.signatureVerificationUnavailable
        #endif
    }
}

/// Orders dataset and app versions made of dot-separated numbers with an
/// optional non-numeric prefix (`kb-2026.08.31`, `1.4.0`).
public struct DatasetVersion: Comparable, Sendable, Hashable {
    public let components: [Int]
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
        let digitsOnly = raw.drop(while: { !$0.isNumber })
        self.components = digitsOnly
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    public static func < (lhs: DatasetVersion, rhs: DatasetVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: DatasetVersion, rhs: DatasetVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
