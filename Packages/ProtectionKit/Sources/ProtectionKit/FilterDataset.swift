import Foundation
import ObservationCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Signed metadata for a prefilter release (§14.2).
public struct FilterDatasetManifest: Codable, Sendable, Hashable {
    public let datasetVersion: String
    public let profile: String
    public let generatedAt: Date
    public let expiresAt: Date
    public let bitCount: Int
    public let hashCount: Int
    public let entryCount: Int
    public let falsePositiveRate: Double
    public let payloadDigest: FireDigest
    public let signingKeyID: String
    public let signature: String
    /// The version this release can be rolled back to (§14.3).
    public let rollbackVersion: String?

    public init(
        datasetVersion: String,
        profile: String,
        generatedAt: Date,
        expiresAt: Date,
        bitCount: Int,
        hashCount: Int,
        entryCount: Int,
        falsePositiveRate: Double,
        payloadDigest: FireDigest,
        signingKeyID: String,
        signature: String,
        rollbackVersion: String?
    ) {
        self.datasetVersion = datasetVersion
        self.profile = profile
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.bitCount = bitCount
        self.hashCount = hashCount
        self.entryCount = entryCount
        self.falsePositiveRate = falsePositiveRate
        self.payloadDigest = payloadDigest
        self.signingKeyID = signingKeyID
        self.signature = signature
        self.rollbackVersion = rollbackVersion
    }

    /// Canonical signed bytes, ordered explicitly so a signature survives any
    /// change in JSON encoding.
    public var signedRepresentation: [UInt8] {
        let fields = [
            datasetVersion,
            profile,
            String(Int(generatedAt.timeIntervalSince1970)),
            String(Int(expiresAt.timeIntervalSince1970)),
            String(bitCount),
            String(hashCount),
            String(entryCount),
            payloadDigest.hexString,
            signingKeyID,
        ]
        return Array(fields.joined(separator: "\u{1F}").utf8)
    }
}

/// Verifies a prefilter before the control provider hands it to the system
/// (URLF-005).
public struct FilterDatasetVerifier: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unknownSigningKey(String)
        case signatureInvalid
        case digestMismatch
        case expired(Date)
        case revoked(String)
        case parameterMismatch
        case signatureVerificationUnavailable
    }

    public let publicKeysByID: [String: [UInt8]]
    public let revokedVersions: Set<String>

    public init(publicKeysByID: [String: [UInt8]], revokedVersions: Set<String> = []) {
        self.publicKeysByID = publicKeysByID
        self.revokedVersions = revokedVersions
    }

    public func verify(manifest: FilterDatasetManifest, payload: [UInt8], now: Date) throws {
        guard !revokedVersions.contains(manifest.datasetVersion) else {
            throw Failure.revoked(manifest.datasetVersion)
        }
        guard manifest.expiresAt > now else { throw Failure.expired(manifest.expiresAt) }
        guard manifest.bitCount > 0, manifest.hashCount > 0,
              payload.count * 8 >= manifest.bitCount else {
            throw Failure.parameterMismatch
        }
        guard FireHasher.hash(payload) == manifest.payloadDigest else { throw Failure.digestMismatch }
        guard let key = publicKeysByID[manifest.signingKeyID] else {
            throw Failure.unknownSigningKey(manifest.signingKeyID)
        }
        guard let signature = Data(base64Encoded: manifest.signature) else { throw Failure.signatureInvalid }

        #if canImport(CryptoKit)
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(key)),
              publicKey.isValidSignature(signature, for: Data(manifest.signedRepresentation))
        else { throw Failure.signatureInvalid }
        #else
        throw Failure.signatureVerificationUnavailable
        #endif
    }
}

/// A read-only Bloom filter matching the released prefilter parameters.
///
/// Used to validate a release before it ships (canary and negative sets, §14.2)
/// and in tests. On device the *system* performs the lookup; Fire Privacy never
/// evaluates a user's URLs itself.
public struct BloomFilter: Sendable {
    public let bits: [UInt8]
    public let bitCount: Int
    public let hashCount: Int

    public init?(bits: [UInt8], bitCount: Int, hashCount: Int) {
        guard bitCount > 0, hashCount > 0, hashCount <= 32, bits.count * 8 >= bitCount else { return nil }
        self.bits = bits
        self.bitCount = bitCount
        self.hashCount = hashCount
    }

    /// Membership test. A `true` answer means "possibly present" — the system
    /// resolves it with a private lookup — and `false` means "definitely absent".
    public func mayContain(_ key: String) -> Bool {
        for index in indices(for: key) {
            let byte = index >> 3
            let bit = UInt8(1) << UInt8(index & 7)
            guard byte < bits.count, bits[byte] & bit != 0 else { return false }
        }
        return true
    }

    /// Double hashing over one SHA-256 digest: `h(i) = h1 + i·h2`.
    func indices(for key: String) -> [Int] {
        let digest = FireHasher.hash(key).bytes
        func word(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<8 { value = (value << 8) | UInt64(digest[offset + index]) }
            return value
        }
        let first = word(0)
        let second = word(8) | 1 // odd, so the step never degenerates
        return (0..<hashCount).map { round in
            Int((first &+ UInt64(round) &* second) % UInt64(bitCount))
        }
    }
}
