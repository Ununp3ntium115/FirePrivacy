import Foundation
import FirePrivacyCore

/// This App Group stores filtering rules and lifecycle state only. Reports, source bytes,
/// report keys, consent receipts and PIR credentials stay in the app's private storage.
struct ProtectionArtifactStore: Sendable {
    struct SafariEnvelope: Codable, Sendable {
        let configuration: SafariRuleConfiguration
        let signedDataset: SignedFilterDataset
        let allowedUntil: Date
    }
    struct URLFilterEnvelope: Codable, Sendable {
        let signedDataset: SignedFilterDataset
        let allowedUntil: Date
    }
    struct ManagedEnvelope: Codable, Sendable {
        let signedDataset: SignedFilterDataset
        let allowedUntil: Date
    }
    let directory: URL
    let trustedKeys: [String: Data]

    init(directory: URL, trustedKeys: [String: Data]) {
        self.directory = directory
        self.trustedKeys = trustedKeys
    }

    init(bundle: Bundle = .main) throws {
        guard let group = bundle.object(forInfoDictionaryKey: "FirePrivacyAppGroup") as? String,
              !group.isEmpty, !group.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ProtectionConfigurationError.appGroupUnavailable
        }
        directory = container.appendingPathComponent("ProtectionRules", isDirectory: true)
        let encoded = bundle.object(forInfoDictionaryKey: "FirePrivacyFilterTrustKeys") as? [String: String] ?? [:]
        trustedKeys = encoded.compactMapValues { value in
            guard let data = Data(base64Encoded: value), data.count == 32 else { return nil }
            return data
        }
    }

    func write<T: Encodable>(_ value: T, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var location = directory
        var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true
        try location.setResourceValues(resourceValues)
        let data = try JSONEncoder().encode(value)
        guard data.count <= FilterDatasetVerifier.maximumPayloadBytes * 2 + 128_000 else {
            throw FilterDatasetError.excessivePayload
        }
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
        let location = directory.appendingPathComponent(name)
        let values = try location.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= FilterDatasetVerifier.maximumPayloadBytes * 2 + 128_000 else {
            throw FilterDatasetError.excessivePayload
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: location))
    }

    func remove(named name: String) throws {
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func validatedSafari(now: Date = Date()) throws -> (SafariRuleConfiguration, Data) {
        let envelope = try read(SafariEnvelope.self, named: "safari-rules.json")
        guard envelope.allowedUntil > now else { throw ProtectionConfigurationError.consentRevoked }
        let verified = try FilterDatasetVerifier.verify(envelope.signedDataset, trustedKeys: trustedKeys, now: now)
        let expected = try verified.safariConfiguration(allowedDomains: envelope.configuration.allowedDomains)
        guard expected == envelope.configuration else { throw FilterDatasetError.payloadMismatch }
        return (expected, try SafariRuleCompiler.compile(expected))
    }

    func validatedURLFilter(now: Date = Date()) throws -> ValidatedFilterDataset {
        let envelope = try read(URLFilterEnvelope.self, named: "url-prefilter.json")
        guard envelope.allowedUntil > now else { throw ProtectionConfigurationError.consentRevoked }
        let verified = try FilterDatasetVerifier.verify(envelope.signedDataset, trustedKeys: trustedKeys, now: now)
        guard verified.manifest.kind == .appleURLBloomV1 else { throw ProtectionConfigurationError.wrongDatasetKind }
        return verified
    }

    func validatedManagedPolicy(now: Date = Date()) throws -> ManagedPolicy {
        let envelope = try read(ManagedEnvelope.self, named: "managed-policy.json")
        guard envelope.allowedUntil > now else { throw ProtectionConfigurationError.consentRevoked }
        let verified = try FilterDatasetVerifier.verify(envelope.signedDataset, trustedKeys: trustedKeys, now: now)
        guard verified.manifest.kind == .managedRulesV1 else { throw ProtectionConfigurationError.wrongDatasetKind }
        let policy = try JSONDecoder().decode(ManagedPolicy.self, from: verified.payload)
        guard Double(policy.expiresAtSeconds) > now.timeIntervalSince1970 else { throw FilterDatasetError.expired }
        return policy
    }
}
