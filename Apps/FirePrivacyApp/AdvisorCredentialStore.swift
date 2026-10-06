import Foundation
import FirePrivacyCore
#if canImport(Security)
import Security
#endif

enum AdvisorCredentialError: Error, Equatable, Sendable, LocalizedError {
    case invalidToken
    case invalidConfiguration
    case staleOperation
    case cleanupPending
    case readFailed
    case storageFailed
    case deletionFailed
    case unavailable
    case keychainFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidToken: "Enter a nonempty bearer token containing at most 8,192 printable ASCII characters without spaces."
        case .invalidConfiguration: "Configure a valid HTTPS advisor endpoint before saving a credential."
        case .staleOperation: "The credential operation expired after credentials changed or were deleted."
        case .cleanupPending: "Credential cleanup must finish before saved credentials can be used or changed."
        case .readFailed: "The saved advisor credential could not be read."
        case .storageFailed: "The advisor credential could not be saved."
        case .deletionFailed: "The advisor credential could not be deleted. Retry cleanup before using saved credentials."
        case .unavailable: "Device Keychain credential storage is unavailable."
        case .keychainFailure(let status): "Device Keychain could not complete the credential operation (status \(status))."
        }
    }
}

/// Only this provider handles secret bytes. Its account is the exact validated
/// configuration identity, never an endpoint name, report identifier, or token.
protocol AdvisorCredentialProvider: Sendable {
    func read(identity: String) async throws -> Data?
    func store(_ token: Data, identity: String) async throws
    func delete(identity: String) async throws
    func deleteAll() async throws
}

enum AdvisorCredentialValidation {
    static let maximumTokenBytes = 8_192

    static func tokenData(_ token: String) throws -> Data {
        let bytes = Data(token.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumTokenBytes,
              bytes.allSatisfy({ (33...126).contains($0) }) else {
            throw AdvisorCredentialError.invalidToken
        }
        return bytes
    }

    static func tokenString(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty, bytes.count <= maximumTokenBytes,
              bytes.allSatisfy({ (33...126).contains($0) }),
              let token = String(data: bytes, encoding: .utf8) else {
            throw AdvisorCredentialError.invalidToken
        }
        return token
    }

    static func validateIdentity(_ identity: String) throws {
        guard identity.utf8.count == 64,
              identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AdvisorCredentialError.invalidConfiguration
        }
    }
}

/// Nonsynchronizing, device-only credentials use normal OS Keychain security.
/// There is no access-group override and no certificate/trust bypass. Network
/// use still requires the engine's exact HTTPS request preview and approval.
struct KeychainAdvisorCredentialProvider: AdvisorCredentialProvider {
    let serviceIdentifier: String

    init(service: String? = nil) {
        serviceIdentifier = service ?? "\(Bundle.main.bundleIdentifier ?? "org.fireprivacy.app").advisor-credentials-v1"
    }

    func read(identity: String) async throws -> Data? {
        try AdvisorCredentialValidation.validateIdentity(identity)
        #if canImport(Security)
        var query = accountQuery(identity: identity)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AdvisorCredentialError.keychainFailure(status) }
        guard let attributes = result as? [String: Any],
              (attributes[kSecAttrAccessible as String] as? String) ==
                (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
              let bytes = attributes[kSecValueData as String] as? Data else {
            throw AdvisorCredentialError.readFailed
        }
        _ = try AdvisorCredentialValidation.tokenString(bytes)
        return bytes
        #else
        throw AdvisorCredentialError.unavailable
        #endif
    }

    func store(_ token: Data, identity: String) async throws {
        try AdvisorCredentialValidation.validateIdentity(identity)
        _ = try AdvisorCredentialValidation.tokenString(token)
        #if canImport(Security)
        let query = accountQuery(identity: identity)
        let attributes: [String: Any] = [
            kSecValueData as String: token,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            for (key, value) in attributes { newItem[key] = value }
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AdvisorCredentialError.keychainFailure(status) }
        #else
        throw AdvisorCredentialError.unavailable
        #endif
    }

    func delete(identity: String) async throws {
        try AdvisorCredentialValidation.validateIdentity(identity)
        #if canImport(Security)
        let status = SecItemDelete(accountQuery(identity: identity) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AdvisorCredentialError.keychainFailure(status)
        }
        #else
        throw AdvisorCredentialError.unavailable
        #endif
    }

    func deleteAll() async throws {
        #if canImport(Security)
        let status = SecItemDelete(serviceQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AdvisorCredentialError.keychainFailure(status)
        }
        #else
        throw AdvisorCredentialError.unavailable
        #endif
    }

    #if canImport(Security)
    private var serviceQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: serviceIdentifier,
         kSecAttrSynchronizable as String: false]
    }

    private func accountQuery(identity: String) -> [String: Any] {
        var query = serviceQuery
        query[kSecAttrAccount as String] = identity
        return query
    }
    #endif
}

/// Retention is opt-in: reads and request preparation never save a credential.
/// The engine calls `retain` only from an explicit save action. Secret strings
/// remain transient and have no Codable, preferences, or logging path here.
actor AdvisorCredentialStore {
    private let provider: any AdvisorCredentialProvider
    private var generation = UUID()
    private var enabled = true
    private var deletionPending = false
    private var blockedIdentities: [String: UUID] = [:]
    private var providerBusy = false
    private var providerWaiters: [CheckedContinuation<Void, Never>] = []

    init(provider: any AdvisorCredentialProvider = KeychainAdvisorCredentialProvider()) {
        self.provider = provider
    }

    func currentGeneration() -> UUID { generation }

    func token(for configuration: SelfHostedAdvisorConfiguration,
               expectedGeneration: UUID) async throws -> String? {
        let identity = try checkedIdentity(configuration)
        try requireCurrent(expectedGeneration, identity: identity)
        await acquireProvider()
        defer { releaseProvider() }
        try Task.checkCancellation()
        try requireCurrent(expectedGeneration, identity: identity)
        let bytes: Data?
        do { bytes = try await provider.read(identity: identity) }
        catch { throw sanitized(error, fallback: .readFailed) }
        try requireCurrent(expectedGeneration, identity: identity)
        try Task.checkCancellation()
        return try bytes.map(AdvisorCredentialValidation.tokenString)
    }

    func retain(_ token: String, for configuration: SelfHostedAdvisorConfiguration,
                expectedGeneration: UUID) async throws {
        let identity = try checkedIdentity(configuration)
        let bytes = try AdvisorCredentialValidation.tokenData(token)
        try requireCurrent(expectedGeneration, identity: identity)
        await acquireProvider()
        defer { releaseProvider() }
        try Task.checkCancellation()
        try requireCurrent(expectedGeneration, identity: identity)
        do { try await provider.store(bytes, identity: identity) }
        catch { throw sanitized(error, fallback: .storageFailed) }
        // A deletion may have disabled this actor while the injected provider
        // suspended. The queued deletion runs after this operation releases the
        // FIFO lock; no subsequent read can observe the credential meanwhile.
        try requireCurrent(expectedGeneration, identity: identity)
    }

    /// Rotate the epoch before waiting so an in-flight read cannot return a
    /// credential after an explicit erase action. Failed deletion blocks this
    /// identity until this method or delete-all is successfully retried.
    func erase(for configuration: SelfHostedAdvisorConfiguration,
               expectedGeneration: UUID) async throws {
        let identity = try checkedIdentity(configuration)
        guard expectedGeneration == generation else { throw AdvisorCredentialError.staleOperation }
        guard enabled, !deletionPending else { throw AdvisorCredentialError.cleanupPending }
        generation = UUID()
        let deletionGeneration = generation
        blockedIdentities[identity] = deletionGeneration
        await acquireProvider()
        defer { releaseProvider() }
        do { try await provider.delete(identity: identity) }
        catch { throw sanitized(error, fallback: .deletionFailed) }
        if blockedIdentities[identity] == deletionGeneration {
            blockedIdentities.removeValue(forKey: identity)
        }
    }

    /// Safety cleanup deliberately finishes even if the calling task is
    /// cancelled. The engine persists its own nonsensitive pending-cleanup flag
    /// before invoking this, so failed deletion is also retried after restart.
    func disableAndEraseAll() async throws {
        generation = UUID()
        let deletionGeneration = generation
        enabled = false
        deletionPending = true
        await acquireProvider()
        defer { releaseProvider() }
        do { try await provider.deleteAll() }
        catch { throw sanitized(error, fallback: .deletionFailed) }
        guard generation == deletionGeneration else { throw AdvisorCredentialError.staleOperation }
        blockedIdentities.removeAll()
        deletionPending = false
    }

    /// Successful deletion does not silently turn retained credentials back on.
    /// A new engine setup / explicit save action can resume using the new epoch.
    func resumeAfterDeletion(expectedGeneration: UUID) throws {
        guard expectedGeneration == generation else { throw AdvisorCredentialError.staleOperation }
        guard !deletionPending else { throw AdvisorCredentialError.cleanupPending }
        enabled = true
    }

    private func checkedIdentity(_ configuration: SelfHostedAdvisorConfiguration) throws -> String {
        do { try configuration.validate() }
        catch { throw AdvisorCredentialError.invalidConfiguration }
        let identity = configuration.identity
        try AdvisorCredentialValidation.validateIdentity(identity)
        return identity
    }

    private func requireCurrent(_ expectedGeneration: UUID, identity: String) throws {
        guard expectedGeneration == generation else { throw AdvisorCredentialError.staleOperation }
        guard enabled, !deletionPending, blockedIdentities[identity] == nil else {
            throw AdvisorCredentialError.cleanupPending
        }
    }

    private func sanitized(_ error: any Error, fallback: AdvisorCredentialError) -> AdvisorCredentialError {
        // Never expose an injected provider's NSError userInfo or description,
        // which might contain a credential. Our own errors contain no secrets.
        error as? AdvisorCredentialError ?? fallback
    }

    private func acquireProvider() async {
        if !providerBusy { providerBusy = true; return }
        await withCheckedContinuation { providerWaiters.append($0) }
    }

    private func releaseProvider() {
        if providerWaiters.isEmpty { providerBusy = false }
        else { providerWaiters.removeFirst().resume() }
    }
}
