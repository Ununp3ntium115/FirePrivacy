import Foundation
import FirePrivacyCore

enum DatasetTrustConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidInfoType, oversized, malformedJSON, duplicateKeyID
    case invalidKeyID, invalidPublicKey, pinnedKeyConflict, crossFamilyCollision

    var errorDescription: String? {
        // Public-key configuration still never needs values, paths or payloads
        // in diagnostics. Do not echo malformed build configuration.
        switch self {
        case .invalidInfoType, .malformedJSON: "Dataset public-key configuration is malformed."
        case .oversized: "Dataset public-key configuration exceeds its bound."
        case .duplicateKeyID: "Dataset public-key configuration contains a duplicate identifier."
        case .invalidKeyID, .invalidPublicKey: "Dataset public-key configuration contains an invalid identifier or key."
        case .pinnedKeyConflict: "Dataset public-key configuration conflicts with a pinned key."
        case .crossFamilyCollision: "Knowledge and filter key identifiers must be separate."
        }
    }
}

/// The exact public trust boundary shared by containing apps and all providers.
/// Sources are signed app/extension Info.plist plus pinned package resources,
/// never a download, report, App Group artifact or mutable user preference.
struct DatasetPublicKeyConfiguration: Sendable {
    static let knowledgeInfoKey = "FirePrivacyKnowledgeBasePublicKeysJSON"
    static let filterInfoKey = "FirePrivacyFilterPublicKeysJSON"
    static let legacyFilterInfoKey = "FirePrivacyFilterTrustKeys"
    static let maximumEncodedBytes = 16_384
    static let maximumKeysPerFamily = 32

    let knowledgeBaseKeys: [String: Data]
    let filterKeys: [String: Data]

    init(knowledgeBaseJSON: String? = nil, filterJSON: String? = nil,
         pinnedKnowledgeKeys: [String: Data], pinnedFilterKeys: [String: Data]) throws {
        knowledgeBaseKeys = try Self.merge(pinned: pinnedKnowledgeKeys, configured: Self.parseMap(knowledgeBaseJSON))
        filterKeys = try Self.merge(pinned: pinnedFilterKeys, configured: Self.parseMap(filterJSON))
        guard Set(knowledgeBaseKeys.keys).isDisjoint(with: filterKeys.keys) else {
            throw DatasetTrustConfigurationError.crossFamilyCollision
        }
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        let pinnedKnowledge = try pinnedKnowledgeKeys(KnowledgeBaseResources.trustAnchors)
        let pinnedFilter = try BundledProtectionDataset.trustedKeys()
        // Older bundles explicitly copied these same pinned base64 keys into
        // Info.plist. Preserve those pins without allowing an extra trust path.
        if let raw = bundle.object(forInfoDictionaryKey: legacyFilterInfoKey) {
            guard let legacy = raw as? [String: String], legacy.count <= maximumKeysPerFamily else {
                throw DatasetTrustConfigurationError.invalidInfoType
            }
            for (id, value) in legacy {
                guard let decoded = Data(base64Encoded: value), decoded.count == 32,
                      pinnedFilter[id] == decoded else { throw DatasetTrustConfigurationError.pinnedKeyConflict }
            }
        }
        return try Self(knowledgeBaseJSON: infoString(bundle, knowledgeInfoKey),
                        filterJSON: infoString(bundle, filterInfoKey),
                        pinnedKnowledgeKeys: pinnedKnowledge, pinnedFilterKeys: pinnedFilter)
    }

    static func loadFilterKeys(bundle: Bundle = .main) throws -> [String: Data] {
        try load(bundle: bundle).filterKeys
    }

    static func pinnedKnowledgeKeys(_ anchors: [KnowledgeBaseTrustAnchor]) throws -> [String: Data] {
        guard anchors.count <= maximumKeysPerFamily else { throw DatasetTrustConfigurationError.oversized }
        var keys: [String: Data] = [:]
        for anchor in anchors {
            try validateKeyID(anchor.keyID); try validateBytes(anchor.publicKey)
            guard keys[anchor.keyID] == nil else { throw DatasetTrustConfigurationError.duplicateKeyID }
            keys[anchor.keyID] = anchor.publicKey
        }
        return keys
    }

    private static func infoString(_ bundle: Bundle, _ key: String) throws -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) else { return nil }
        guard let string = raw as? String else { throw DatasetTrustConfigurationError.invalidInfoType }
        return string
    }

    private static func merge(pinned: [String: Data], configured: [String: Data]) throws -> [String: Data] {
        guard pinned.count <= maximumKeysPerFamily, configured.count <= maximumKeysPerFamily else {
            throw DatasetTrustConfigurationError.oversized
        }
        var result = pinned
        for (id, bytes) in pinned { try validateKeyID(id); try validateBytes(bytes) }
        for (id, bytes) in configured {
            if let previous = result[id], previous != bytes { throw DatasetTrustConfigurationError.pinnedKeyConflict }
            result[id] = bytes
        }
        return result
    }

    static func validateKeyID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 80,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else {
            throw DatasetTrustConfigurationError.invalidKeyID
        }
    }

    private static func validateBytes(_ bytes: Data) throws {
        guard bytes.count == 32, bytes.contains(where: { $0 != 0 }) else {
            throw DatasetTrustConfigurationError.invalidPublicKey
        }
    }

    private static func hexBytes(_ value: String) throws -> Data {
        let input = Array(value.utf8)
        guard input.count == 64, input.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DatasetTrustConfigurationError.invalidPublicKey
        }
        func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
        let bytes = Data(stride(from: 0, to: input.count, by: 2).map { nibble(input[$0]) * 16 + nibble(input[$0 + 1]) })
        try validateBytes(bytes)
        return bytes
    }

    static func parseMap(_ value: String?) throws -> [String: Data] {
        guard let value, !value.isEmpty else { return [:] }
        guard value.utf8.count <= maximumEncodedBytes else { throw DatasetTrustConfigurationError.oversized }
        var parser = RawMapParser(bytes: Array(value.utf8))
        return try parser.parse()
    }

    /// Decode one bounded JSON object of string pairs. JSONDecoder's dictionary
    /// alone collapses duplicate keys; retaining raw pairs catches duplicates,
    /// including differently escaped spellings, before selecting any authority.
    private struct RawMapParser {
        let bytes: [UInt8]
        var offset = 0

        mutating func whitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }
        mutating func consume(_ value: UInt8) throws {
            whitespace()
            guard offset < bytes.count, bytes[offset] == value else { throw DatasetTrustConfigurationError.malformedJSON }
            offset += 1
        }
        mutating func string() throws -> String {
            whitespace()
            let start = offset
            guard offset < bytes.count, bytes[offset] == 34 else { throw DatasetTrustConfigurationError.malformedJSON }
            offset += 1
            while offset < bytes.count {
                let current = bytes[offset]; offset += 1
                if current == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                    catch { throw DatasetTrustConfigurationError.malformedJSON }
                }
                if current == 92 {
                    guard offset < bytes.count else { throw DatasetTrustConfigurationError.malformedJSON }
                    offset += 1
                }
            }
            throw DatasetTrustConfigurationError.malformedJSON
        }
        mutating func parse() throws -> [String: Data] {
            try consume(123)
            whitespace()
            var result: [String: Data] = [:]
            if offset < bytes.count, bytes[offset] == 125 { offset += 1 }
            else {
                while true {
                    let id = try string()
                    try DatasetPublicKeyConfiguration.validateKeyID(id)
                    guard result[id] == nil else { throw DatasetTrustConfigurationError.duplicateKeyID }
                    try consume(58)
                    result[id] = try DatasetPublicKeyConfiguration.hexBytes(string())
                    guard result.count <= DatasetPublicKeyConfiguration.maximumKeysPerFamily else {
                        throw DatasetTrustConfigurationError.oversized
                    }
                    whitespace()
                    guard offset < bytes.count else { throw DatasetTrustConfigurationError.malformedJSON }
                    if bytes[offset] == 125 { offset += 1; break }
                    try consume(44)
                }
            }
            whitespace()
            guard offset == bytes.count else { throw DatasetTrustConfigurationError.malformedJSON }
            return result
        }
    }
}
