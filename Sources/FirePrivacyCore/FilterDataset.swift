import Foundation

public enum FilterPayloadKind: String, Codable, Sendable {
    case safariDomainsV1, appleURLBloomV1, managedRulesV1, revocationsV1
}

/// The signed representation includes every field, including parameters and deployment binding.
public struct FilterDatasetManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: UInt64
    public let kind: FilterPayloadKind
    public let tag: String
    public let issuedAtSeconds: Int64
    public let expiresAtSeconds: Int64
    public let payloadSHA256: String
    public let payloadByteCount: Int
    public let keyID: String
    public let bitCount: Int?
    public let hashCount: Int?
    public let murmurSeed: UInt32?
    public let hashAlgorithm: String?
    public let pirServerURL: URL?
    public let privacyPassIssuerURL: URL?
    public let appleConfigurationIdentity: String?
    public let rollbackFromVersion: UInt64?

    public init(version: UInt64, kind: FilterPayloadKind, tag: String, issuedAtSeconds: Int64,
                expiresAtSeconds: Int64, payloadSHA256: String, payloadByteCount: Int, keyID: String,
                bitCount: Int? = nil, hashCount: Int? = nil, murmurSeed: UInt32? = nil,
                hashAlgorithm: String? = nil, pirServerURL: URL? = nil,
                privacyPassIssuerURL: URL? = nil, appleConfigurationIdentity: String? = nil,
                rollbackFromVersion: UInt64? = nil) {
        schemaVersion = 1; self.version = version; self.kind = kind; self.tag = tag
        self.issuedAtSeconds = issuedAtSeconds; self.expiresAtSeconds = expiresAtSeconds
        self.payloadSHA256 = payloadSHA256; self.payloadByteCount = payloadByteCount; self.keyID = keyID
        self.bitCount = bitCount; self.hashCount = hashCount; self.murmurSeed = murmurSeed
        self.hashAlgorithm = hashAlgorithm; self.pirServerURL = pirServerURL
        self.privacyPassIssuerURL = privacyPassIssuerURL; self.appleConfigurationIdentity = appleConfigurationIdentity
        self.rollbackFromVersion = rollbackFromVersion
    }
    public func signedRepresentation() throws -> Data { try ProtectionCanonicalization.encode(self) }
}

public struct SignedFilterDataset: Codable, Equatable, Sendable {
    public let manifest: FilterDatasetManifest
    public let payload: Data
    public let signature: Data
    public init(manifest: FilterDatasetManifest, payload: Data, signature: Data) {
        self.manifest = manifest; self.payload = payload; self.signature = signature
    }
}

public struct FilterRevocations: Codable, Equatable, Sendable {
    public var keyIDs: Set<String>
    public var versions: Set<UInt64>
    public var payloadDigests: Set<String>
    public init(keyIDs: Set<String> = [], versions: Set<UInt64> = [], payloadDigests: Set<String> = []) {
        self.keyIDs = keyIDs; self.versions = versions; self.payloadDigests = payloadDigests
    }
}

public struct FilterRevocationDocument: Codable, Equatable, Sendable {
    public let targetKind: FilterPayloadKind
    public let revocations: FilterRevocations
    public init(targetKind: FilterPayloadKind, revocations: FilterRevocations) {
        self.targetKind = targetKind; self.revocations = revocations
    }
    public func validate() throws {
        guard targetKind != .revocationsV1, revocations.keyIDs.count <= 1_000,
              revocations.versions.count <= 5_000, revocations.payloadDigests.count <= 5_000,
              revocations.keyIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 120 && $0.utf8.allSatisfy { $0 >= 33 && $0 <= 126 } }),
              revocations.versions.allSatisfy({ $0 > 0 }),
              revocations.payloadDigests.allSatisfy({ value in value.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) } }) else {
            throw FilterDatasetError.invalidPayload
        }
    }
}

public struct ValidatedFilterRevocationList: Sendable, Equatable {
    public let signedDataset: SignedFilterDataset
    public let document: FilterRevocationDocument
    public var version: UInt64 { signedDataset.manifest.version }
    public var expiresAt: Date { Date(timeIntervalSince1970: Double(signedDataset.manifest.expiresAtSeconds)) }
    public var manifestDigest: String { get throws { ContentDigest.sha256(try signedDataset.manifest.signedRepresentation()) } }
    fileprivate init(_ signed: SignedFilterDataset, document: FilterRevocationDocument) {
        signedDataset = signed; self.document = document
    }
}

public enum FilterDatasetError: Error, Equatable, Sendable {
    case unsupportedSchema, malformedManifest, excessivePayload, payloadMismatch, unknownSigningKey
    case invalidSignature, notYetValid, expired, revoked, rollback, incompatibleBloomFilter, invalidPayload
}

/// Only the verifier constructs this type. Revalidation is necessary before every activation/fetch.
public struct ValidatedFilterDataset: Sendable, Equatable {
    public let signedDataset: SignedFilterDataset
    public var manifest: FilterDatasetManifest { signedDataset.manifest }
    public var payload: Data { signedDataset.payload }
    public var manifestDigest: String { get throws {
        ContentDigest.sha256(try manifest.signedRepresentation())
    } }
    fileprivate init(_ signed: SignedFilterDataset) { signedDataset = signed }
    public var expiresAt: Date { Date(timeIntervalSince1970: Double(manifest.expiresAtSeconds)) }
    public func safariConfiguration(allowedDomains: [String] = [], userBlockedDomains: [String] = []) throws -> SafariRuleConfiguration {
        guard manifest.kind == .safariDomainsV1 else { throw ProtectionConfigurationError.wrongDatasetKind }
        return SafariRuleConfiguration(blockedDomains: try JSONDecoder().decode([String].self, from: payload),
                                       allowedDomains: allowedDomains, userBlockedDomains: userBlockedDomains,
                                       datasetVersion: manifest.version, manifestDigest: try manifestDigest)
    }
    public func urlConfiguration(controlProviderBundleIdentifier: String) throws -> URLFilterServiceConfiguration {
        guard manifest.kind == .appleURLBloomV1, let pirServerURL = manifest.pirServerURL,
              let identity = manifest.appleConfigurationIdentity else {
            throw ProtectionConfigurationError.wrongDatasetKind
        }
        return URLFilterServiceConfiguration(pirServerURL: pirServerURL,
                                            privacyPassIssuerURL: manifest.privacyPassIssuerURL,
                                            controlProviderBundleIdentifier: controlProviderBundleIdentifier,
                                            datasetDigest: try manifestDigest,
                                            appleApprovedConfigurationIdentity: identity)
    }
}

public enum FilterDatasetVerifier {
    public static let maximumPayloadBytes = 16 * 1_024 * 1_024
    public static let appleBloomAlgorithm = "fnv1a32-murmur3-x86-32-double-hash/1"

    public static func verify(_ signed: SignedFilterDataset, trustedKeys: [String: Data],
                              highestAcceptedVersion: UInt64 = 0,
                              revocations: FilterRevocations = .init(), now: Date = Date()) throws -> ValidatedFilterDataset {
        let m = signed.manifest
        guard m.schemaVersion == 1 else { throw FilterDatasetError.unsupportedSchema }
        let lifetime = m.expiresAtSeconds.subtractingReportingOverflow(m.issuedAtSeconds)
        guard m.version > 0, !m.tag.isEmpty, m.tag.utf8.count <= 120,
              !m.keyID.isEmpty, m.keyID.utf8.count <= 120,
              m.tag.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              m.expiresAtSeconds > m.issuedAtSeconds,
              !lifetime.overflow, lifetime.partialValue <= 90 * 24 * 60 * 60,
              m.payloadSHA256.count == 64 else { throw FilterDatasetError.malformedManifest }
        guard signed.payload.count <= maximumPayloadBytes, m.payloadByteCount >= 0,
              m.payloadByteCount <= maximumPayloadBytes else { throw FilterDatasetError.excessivePayload }
        guard signed.payload.count == m.payloadByteCount,
              ContentDigest.sha256(signed.payload) == m.payloadSHA256 else { throw FilterDatasetError.payloadMismatch }
        guard let key = trustedKeys[m.keyID] else { throw FilterDatasetError.unknownSigningKey }
        guard DetachedSignature.verify(signature: signed.signature, message: try m.signedRepresentation(), publicKey: key) else {
            throw FilterDatasetError.invalidSignature
        }
        if revocations.keyIDs.contains(m.keyID) || revocations.versions.contains(m.version) ||
            revocations.payloadDigests.contains(m.payloadSHA256) { throw FilterDatasetError.revoked }
        let seconds = now.timeIntervalSince1970
        guard Double(m.issuedAtSeconds) <= seconds + 300 else { throw FilterDatasetError.notYetValid }
        guard Double(m.expiresAtSeconds) > seconds else { throw FilterDatasetError.expired }
        guard m.version >= highestAcceptedVersion || m.rollbackFromVersion == highestAcceptedVersion else {
            throw FilterDatasetError.rollback
        }
        switch m.kind {
        case .safariDomainsV1:
            guard m.bitCount == nil, m.hashCount == nil, m.murmurSeed == nil, m.hashAlgorithm == nil,
                  m.pirServerURL == nil, m.privacyPassIssuerURL == nil, m.appleConfigurationIdentity == nil else {
                throw FilterDatasetError.malformedManifest
            }
            do {
                let configuration = SafariRuleConfiguration(blockedDomains: try JSONDecoder().decode([String].self, from: signed.payload),
                                                            datasetVersion: m.version)
                try configuration.validate()
            } catch { throw FilterDatasetError.invalidPayload }
        case .appleURLBloomV1:
            guard m.hashAlgorithm == appleBloomAlgorithm, let bits = m.bitCount, let hashes = m.hashCount,
                  m.murmurSeed != nil, bits > 0, bits <= maximumPayloadBytes * 8,
                  (bits + 7) / 8 == signed.payload.count, hashes >= 1, hashes <= 32 else {
                throw FilterDatasetError.incompatibleBloomFilter
            }
            guard let pir = m.pirServerURL, let identity = m.appleConfigurationIdentity,
                  !identity.isEmpty, identity.utf8.count <= 200 else { throw FilterDatasetError.malformedManifest }
            try ProtectionCanonicalization.requireHTTPS(pir)
            if let issuer = m.privacyPassIssuerURL { try ProtectionCanonicalization.requireHTTPS(issuer) }
        case .managedRulesV1:
            guard m.bitCount == nil, m.hashCount == nil, m.murmurSeed == nil, m.hashAlgorithm == nil else {
                throw FilterDatasetError.malformedManifest
            }
            do { try JSONDecoder().decode(ManagedPolicy.self, from: signed.payload).validate() }
            catch { throw FilterDatasetError.invalidPayload }
        case .revocationsV1:
            guard m.rollbackFromVersion == nil, m.bitCount == nil, m.hashCount == nil, m.murmurSeed == nil,
                  m.hashAlgorithm == nil, m.pirServerURL == nil, m.privacyPassIssuerURL == nil,
                  m.appleConfigurationIdentity == nil, signed.payload.count <= 512 * 1_024 else {
                throw FilterDatasetError.malformedManifest
            }
            try JSONDecoder().decode(FilterRevocationDocument.self, from: signed.payload).validate()
        }
        return ValidatedFilterDataset(signed)
    }

    public static func verifyRevocationList(_ signed: SignedFilterDataset, trustedKeys: [String: Data],
                                            highestAcceptedVersion: UInt64 = 0,
                                            previousRevocations: FilterRevocations = .init(),
                                            now: Date = Date()) throws -> ValidatedFilterRevocationList {
        guard signed.manifest.kind == .revocationsV1 else { throw ProtectionConfigurationError.wrongDatasetKind }
        guard signed.manifest.version >= highestAcceptedVersion, signed.manifest.rollbackFromVersion == nil else {
            throw FilterDatasetError.rollback
        }
        _ = try verify(signed, trustedKeys: trustedKeys, highestAcceptedVersion: highestAcceptedVersion, now: now)
        let document = try JSONDecoder().decode(FilterRevocationDocument.self, from: signed.payload)
        guard document.revocations.keyIDs.isSuperset(of: previousRevocations.keyIDs),
              document.revocations.versions.isSuperset(of: previousRevocations.versions),
              document.revocations.payloadDigests.isSuperset(of: previousRevocations.payloadDigests) else {
            throw FilterDatasetError.rollback
        }
        return .init(signed, document: document)
    }
}

public enum BundledProtectionDataset {
    /// Independent publisher trust root; this is not a known test private key.
    public static func trustedKeys() throws -> [String: Data] {
        guard let location = Bundle.module.url(forResource: "filter-trust-roots", withExtension: "json") else {
            throw FilterDatasetError.unknownSigningKey
        }
        let encoded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: location))
        let keys = encoded.compactMapValues { Data(base64Encoded: $0) }
        guard keys.count == encoded.count, keys.values.allSatisfy({ $0.count == 32 }) else {
            throw FilterDatasetError.unknownSigningKey
        }
        return keys
    }
    /// A deliberately narrow opt-in rule: Segment's cited HTTP analytics API,
    /// blocked only as a third-party Safari resource. Allow it when a site needs it.
    /// The bundled dataset is still subject to signature and expiry checks.
    public static func safariStarter(now: Date = Date()) throws -> ValidatedFilterDataset {
        guard let location = Bundle.module.url(forResource: "safari-starter.signed", withExtension: "json") else {
            throw ProtectionConfigurationError.missingDataset
        }
        let dataset = try JSONDecoder().decode(SignedFilterDataset.self, from: Data(contentsOf: location))
        return try FilterDatasetVerifier.verify(dataset, trustedKeys: trustedKeys(), now: now)
    }
    public static let safariStarterSourceURL = URL(string: "https://github.com/segment-boneyard/segment-docs/blob/develop/src/connections/sources/catalog/libraries/server/http-api/index.md")!
}

/// Compatible with Apple's FilteringTrafficByURL sample: 32-bit wrapping double
/// hashing and LSB-first bytes. A positive result is never a final blocking verdict.
public struct AppleURLBloomFilter: Sendable, Equatable {
    public let data: Data
    public let bitCount: Int
    public let hashCount: Int
    public let murmurSeed: UInt32

    public init(items: [String], falsePositiveTolerance: Double = 0.001, murmurSeed: UInt32) throws {
        guard !items.isEmpty, items.count <= 1_000_000,
              falsePositiveTolerance.isFinite, falsePositiveTolerance > 0,
              falsePositiveTolerance < 1, items.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8_192 && $0.utf8.allSatisfy { $0 >= 33 && $0 <= 126 } }) else {
            throw FilterDatasetError.invalidPayload
        }
        let bits = ceil(-Double(items.count) * log(falsePositiveTolerance) / pow(log(2), 2))
        guard bits >= 1, bits <= Double(FilterDatasetVerifier.maximumPayloadBytes * 8) else {
            throw FilterDatasetError.excessivePayload
        }
        bitCount = Int(bits)
        hashCount = Int(ceil(Double(bitCount) / Double(items.count) * log(2)))
        guard hashCount >= 1, hashCount <= 32 else { throw FilterDatasetError.incompatibleBloomFilter }
        self.murmurSeed = murmurSeed
        var bytes = Data(count: (bitCount + 7) / 8)
        for item in items {
            let input = Array(item.utf8)
            let first = Self.fnv1a(input), second = Self.murmur3(input, seed: murmurSeed)
            for index in 0..<hashCount {
                let bit = Int((first &+ UInt32(index) &* second) % UInt32(bitCount))
                bytes[bit / 8] |= UInt8(1 << (bit % 8))
            }
        }
        data = bytes
    }

    public func possiblyContains(_ item: String) -> Bool {
        let input = Array(item.utf8)
        let first = Self.fnv1a(input), second = Self.murmur3(input, seed: murmurSeed)
        for index in 0..<hashCount {
            let bit = Int((first &+ UInt32(index) &* second) % UInt32(bitCount))
            if data[bit / 8] & UInt8(1 << (bit % 8)) == 0 { return false }
        }
        return true
    }

    private static func fnv1a(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0x811c9dc5)) { ($0 ^ UInt32($1)) &* 0x01000193 }
    }
    private static func rotate(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
    private static func murmur3(_ bytes: [UInt8], seed: UInt32) -> UInt32 {
        var result = seed
        let bodyEnd = bytes.count / 4 * 4
        for offset in stride(from: 0, to: bodyEnd, by: 4) {
            var block = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
                UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            block = rotate(block &* 0xcc9e2d51, by: 15) &* 0x1b873593
            result = rotate(result ^ block, by: 13) &* 5 &+ 0xe6546b64
        }
        if bodyEnd < bytes.count {
            var tail: UInt32 = 0
            for offset in bodyEnd..<bytes.count { tail |= UInt32(bytes[offset]) << UInt32((offset - bodyEnd) * 8) }
            result ^= rotate(tail &* 0xcc9e2d51, by: 15) &* 0x1b873593
        }
        result ^= UInt32(bytes.count)
        result = (result ^ (result >> 16)) &* 0x85ebca6b
        result = (result ^ (result >> 13)) &* 0xc2b2ae35
        return result ^ (result >> 16)
    }
}

/* Apple sample compatibility portions:
Copyright © 2026 Apple Inc.
Permission is hereby granted, free of charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions: The above copyright notice and this permission notice shall
be included in all copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
