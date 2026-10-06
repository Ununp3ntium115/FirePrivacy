import Foundation
import FirePrivacyCore

/// This App Group stores filtering rules and lifecycle state only. Reports, source bytes,
/// report keys, consent receipts and PIR credentials stay in the app's private storage.
struct ProtectionArtifactStore: Sendable {
    struct SafariEnvelope: Codable, Sendable {
        let configuration: SafariRuleConfiguration
        let signedDataset: SignedFilterDataset
        let allowedUntil: Date
        var revocationList: SignedFilterDataset? = nil
    }
    struct URLFilterEnvelope: Codable, Sendable {
        let signedDataset: SignedFilterDataset
        let allowedUntil: Date
        var revocationList: SignedFilterDataset? = nil
    }
    struct ManagedEnvelope: Codable, Sendable {
        let signedDataset: SignedFilterDataset
        let allowedUntil: Date
        var revocationList: SignedFilterDataset? = nil
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

    func read<T: Decodable>(_ type: T.Type, named name: String,
                           maximumBytes: Int = FilterDatasetVerifier.maximumPayloadBytes * 2 + 128_000) throws -> T {
        let location = directory.appendingPathComponent(name)
        let values = try location.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= maximumBytes else {
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
        let revocations = try currentRevocationList(for: .safariDomainsV1, embedded: envelope.revocationList, now: now)
        let verified = try FilterDatasetVerifier.verify(envelope.signedDataset, trustedKeys: trustedKeys,
            revocations: revocations?.document.revocations ?? .init(), now: now)
        let expected = try verified.safariConfiguration(allowedDomains: envelope.configuration.allowedDomains,
                                                       userBlockedDomains: envelope.configuration.userBlockedDomains)
        guard expected == envelope.configuration else { throw FilterDatasetError.payloadMismatch }
        return (expected, try SafariRuleCompiler.compile(expected))
    }

    func validatedURLFilter(now: Date = Date()) throws -> ValidatedFilterDataset {
        let envelope = try read(URLFilterEnvelope.self, named: "url-prefilter.json")
        guard envelope.allowedUntil > now else { throw ProtectionConfigurationError.consentRevoked }
        let revocations = try currentRevocationList(for: .appleURLBloomV1, embedded: envelope.revocationList, now: now)
        let verified = try FilterDatasetVerifier.verify(envelope.signedDataset, trustedKeys: trustedKeys,
            revocations: revocations?.document.revocations ?? .init(), now: now)
        guard verified.manifest.kind == .appleURLBloomV1 else { throw ProtectionConfigurationError.wrongDatasetKind }
        return verified
    }

    func validatedManagedPolicy(now: Date = Date()) throws -> ManagedPolicy {
        try validatedManagedArtifact(now: now).policy
    }

    func validatedManagedArtifact(now: Date = Date()) throws -> (policy: ManagedPolicy, allowedUntil: Date,
                                                               dataset: ValidatedFilterDataset, revocationList: SignedFilterDataset?) {
        let envelope = try read(ManagedEnvelope.self, named: "managed-policy.json")
        guard envelope.allowedUntil > now else { throw ProtectionConfigurationError.consentRevoked }
        let revocations = try currentRevocationList(for: .managedRulesV1, embedded: envelope.revocationList, now: now)
        let verified = try FilterDatasetVerifier.verify(envelope.signedDataset, trustedKeys: trustedKeys,
            revocations: revocations?.document.revocations ?? .init(), now: now)
        guard verified.manifest.kind == .managedRulesV1 else { throw ProtectionConfigurationError.wrongDatasetKind }
        let policy = try JSONDecoder().decode(ManagedPolicy.self, from: verified.payload)
        guard Double(policy.expiresAtSeconds) > now.timeIntervalSince1970 else { throw FilterDatasetError.expired }
        return (policy, min(envelope.allowedUntil, verified.expiresAt, revocations?.expiresAt ?? verified.expiresAt),
                verified, revocations?.signedDataset)
    }

    private func revocationName(_ kind: FilterPayloadKind) -> String { "revocations-" + kind.rawValue + ".json" }

    private func previousList(_ raw: SignedFilterDataset) throws -> ValidatedFilterRevocationList {
        // Authenticate expired historical context solely for monotonic/superset checks.
        // It is never used to activate a filter or returned as a current authorization.
        let lastValidMoment = Date(timeIntervalSince1970: Double(raw.manifest.expiresAtSeconds) - 1)
        return try FilterDatasetVerifier.verifyRevocationList(raw, trustedKeys: trustedKeys, now: lastValidMoment)
    }

    func currentRevocationList(for kind: FilterPayloadKind, embedded: SignedFilterDataset? = nil,
                               now: Date = Date()) throws -> ValidatedFilterRevocationList? {
        let url = directory.appendingPathComponent(revocationName(kind))
        let latest = FileManager.default.fileExists(atPath: url.path) ? try read(SignedFilterDataset.self, named: revocationName(kind), maximumBytes: 1_048_576) : nil
        guard let selected = latest ?? embedded else { return nil }
        let previous = try embedded.map(previousList)
        let current = try FilterDatasetVerifier.verifyRevocationList(selected, trustedKeys: trustedKeys,
            highestAcceptedVersion: previous?.version ?? 0,
            previousRevocations: previous?.document.revocations ?? .init(), now: now)
        guard current.document.targetKind == kind else { throw ProtectionConfigurationError.wrongDatasetKind }
        if let previous, current.version == previous.version,
           try current.manifestDigest != previous.manifestDigest { throw FilterDatasetError.rollback }
        return current
    }

    func installRevocations(_ list: ValidatedFilterRevocationList) throws {
        let kind = list.document.targetKind
        let url = directory.appendingPathComponent(revocationName(kind))
        let previousRaw = FileManager.default.fileExists(atPath: url.path) ? try read(SignedFilterDataset.self, named: revocationName(kind), maximumBytes: 1_048_576) : nil
        let previous = try previousRaw.map(previousList)
        let checked = try FilterDatasetVerifier.verifyRevocationList(list.signedDataset, trustedKeys: trustedKeys,
            highestAcceptedVersion: previous?.version ?? 0, previousRevocations: previous?.document.revocations ?? .init())
        if let previous, checked.version == previous.version,
           try checked.manifestDigest != previous.manifestDigest { throw FilterDatasetError.rollback }
        try write(checked.signedDataset, named: revocationName(kind))
        // Include the signed current document inside any existing artifact too.
        // Providers also consult the current signed file, so a failed envelope rewrite
        // cannot silently keep using the previous revocation state.
        switch kind {
        case .safariDomainsV1:
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("safari-rules.json").path) {
                var envelope = try read(SafariEnvelope.self, named: "safari-rules.json")
                envelope.revocationList = checked.signedDataset; try write(envelope, named: "safari-rules.json")
            }
        case .appleURLBloomV1:
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("url-prefilter.json").path) {
                var envelope = try read(URLFilterEnvelope.self, named: "url-prefilter.json")
                envelope.revocationList = checked.signedDataset; try write(envelope, named: "url-prefilter.json")
            }
        case .managedRulesV1:
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("managed-policy.json").path) {
                var envelope = try read(ManagedEnvelope.self, named: "managed-policy.json")
                envelope.revocationList = checked.signedDataset; try write(envelope, named: "managed-policy.json")
            }
        case .revocationsV1: throw ProtectionConfigurationError.wrongDatasetKind
        }
    }
}
