import Foundation
import FirePrivacyCore
import NetworkExtension
import SafariServices

/// Calls the real OS APIs. Saving a configuration is never reported as activation.
@MainActor
final class ProtectionService {
    private let dnsManager = NEDNSSettingsManager.shared()
    private let bundle: Bundle
    init(bundle: Bundle = .main) { self.bundle = bundle }

    var safariBundleIdentifier: String {
        (bundle.bundleIdentifier ?? "") + ".SafariContentBlocker"
    }

    private func require(_ authorization: ConsentAuthorization, feature: ConsentFeature,
                         scope: String, checker: any ConsentAuthorizationChecking) async throws {
        guard authorization.feature == feature, authorization.scopeIdentity == scope,
              authorization.disclosureVersion == ConsentDisclosure.currentVersion,
              await checker.validateAuthorization(authorization) else {
            throw ProtectionConfigurationError.consentRequired
        }
    }

    func enableSafari(dataset: ValidatedFilterDataset, allowedDomains: [String] = [],
                      userBlockedDomains: [String] = [],
                      revocationList: ValidatedFilterRevocationList? = nil,
                      authorization: ConsentAuthorization,
                      checker: any ConsentAuthorizationChecking) async throws -> ProtectionComponentState {
        let store = try ProtectionArtifactStore(bundle: bundle)
        if let revocationList { try store.installRevocations(revocationList) }
        let revoked = try store.currentRevocationList(for: .safariDomainsV1)
        let current = try FilterDatasetVerifier.verify(dataset.signedDataset, trustedKeys: store.trustedKeys,
            revocations: revoked?.document.revocations ?? .init())
        let configuration = try current.safariConfiguration(allowedDomains: allowedDomains, userBlockedDomains: userBlockedDomains)
        try await require(authorization, feature: .safariProtection, scope: configuration.scopeIdentity, checker: checker)
        try store.write(ProtectionArtifactStore.SafariEnvelope(configuration: configuration,
                        signedDataset: current.signedDataset, allowedUntil: min(current.expiresAt, revoked?.expiresAt ?? current.expiresAt),
                        revocationList: revoked?.signedDataset), named: "safari-rules.json")
        do { try await reloadSafari() }
        catch { try? store.remove(named: "safari-rules.json"); throw error }
        guard await checker.validateAuthorization(authorization) else {
            try await removeSafari()
            throw ProtectionConfigurationError.consentRevoked
        }
        return await safariState()
    }

    func applyRevocations(_ list: ValidatedFilterRevocationList) throws {
        try ProtectionArtifactStore(bundle: bundle).installRevocations(list)
    }

    func safariState() async -> ProtectionComponentState {
        do {
            let store = try ProtectionArtifactStore(bundle: bundle)
            let (configuration, _) = try store.validatedSafari()
            let enabled = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: safariBundleIdentifier) { state, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: state?.isEnabled == true) }
                }
            }
            return .init(component: .safari, phase: enabled ? .active : .awaitingUserEnablement,
                         systemConfirmed: true,
                         detail: enabled ? "Safari confirms this content blocker is enabled. Rules apply to third-party Safari resources." :
                         "Rules are installed. Enable Fire Privacy in Settings → Apps → Safari → Extensions.",
                         verifiedAt: Date(), datasetVersion: configuration.datasetVersion)
        } catch let error as FilterDatasetError {
            do { try await removeSafari() }
            catch {
                return .init(component: .safari, phase: .failed,
                    detail: "The signed dataset is unusable and Safari rejected the empty-rule reload. Cached rules may remain; disable Fire Privacy in Safari Settings and retry.", verifiedAt: Date())
            }
            return .init(component: .safari, phase: error == .expired ? .staleDataset : error == .revoked ? .revokedDataset : .failed,
                         systemConfirmed: true,
                         detail: "Safari accepted empty rules because the signed dataset is unusable. The extension switch may remain enabled in Settings.", verifiedAt: Date())
        } catch ProtectionConfigurationError.consentRevoked {
            do { try await removeSafari() }
            catch {
                return .init(component: .safari, phase: .failed,
                    detail: "Authorization expired and Safari rejected the empty-rule reload. Cached rules may remain; disable Fire Privacy in Safari Settings and retry.", verifiedAt: Date())
            }
            return .init(component: .safari, phase: .disabled, systemConfirmed: true,
                         detail: "Safari accepted empty rules after authorization expired. The extension switch may remain enabled in Settings.", verifiedAt: Date())
        } catch {
            return .init(component: .safari, phase: .needsConfiguration,
                         detail: "Install a trusted, current rule dataset before enabling Safari protection.", verifiedAt: Date())
        }
    }

    private func reloadSafari() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            SFContentBlockerManager.reloadContentBlocker(withIdentifier: safariBundleIdentifier) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func removeSafari() async throws {
        var localFailure: (any Error)?
        do { try ProtectionArtifactStore(bundle: bundle).remove(named: "safari-rules.json") }
        catch { localFailure = error }
        // Still ask Safari to reload if local cleanup failed; never call it disabled
        // unless both the empty local artifact and the OS reload are confirmed.
        try await reloadSafari()
        if let localFailure { throw localFailure }
    }

    func enableDNS(configuration: DNSResolverConfiguration, authorization: ConsentAuthorization,
                   checker: any ConsentAuthorizationChecking) async throws -> ProtectionComponentState {
        try configuration.validate()
        try await require(authorization, feature: .encryptedDNS, scope: configuration.scopeIdentity, checker: checker)
        try await dnsManager.loadFromPreferences()
        let settings: NEDNSSettings
        switch configuration.transport {
        case .https:
            let https = NEDNSOverHTTPSSettings(servers: configuration.servers)
            https.serverURL = configuration.serverURL
            settings = https
        case .tls:
            let tls = NEDNSOverTLSSettings(servers: configuration.servers)
            tls.serverName = configuration.serverName
            settings = tls
        }
        dnsManager.dnsSettings = settings
        dnsManager.localizedDescription = "Fire Privacy · " + configuration.operatorName
        try await dnsManager.saveToPreferences()
        guard await checker.validateAuthorization(authorization) else {
            try await dnsManager.removeFromPreferences()
            throw ProtectionConfigurationError.consentRevoked
        }
        return await dnsState(expected: configuration)
    }

    func dnsState(expected: DNSResolverConfiguration? = nil) async -> ProtectionComponentState {
        do {
            try await dnsManager.loadFromPreferences()
            guard let settings = dnsManager.dnsSettings else {
                return .init(component: .encryptedDNS, phase: .disabled, systemConfirmed: true,
                             detail: "No Fire Privacy encrypted DNS configuration is installed.", verifiedAt: Date())
            }
            if let expected {
                let matches: Bool
                switch expected.transport {
                case .https:
                    matches = (settings as? NEDNSOverHTTPSSettings)?.serverURL == expected.serverURL && settings.servers == expected.servers
                case .tls:
                    matches = (settings as? NEDNSOverTLSSettings)?.serverName == expected.serverName && settings.servers == expected.servers
                }
                guard matches else {
                    return .init(component: .encryptedDNS, phase: .failed, systemConfirmed: true,
                                 detail: "The installed resolver differs from the configuration you approved.", verifiedAt: Date())
                }
            }
            return .init(component: .encryptedDNS, phase: dnsManager.isEnabled ? .active : .awaitingUserEnablement,
                         systemConfirmed: true, detail: dnsManager.isEnabled ?
                         "iOS confirms this encrypted DNS configuration is enabled. The resolver receives domain lookups; encryption alone does not block trackers." :
                         "Configuration is installed. Select it in Settings → General → VPN & Device Management → DNS.", verifiedAt: Date())
        } catch {
            return .init(component: .encryptedDNS, phase: .failed,
                         detail: "iOS could not read the encrypted DNS configuration. Signing capability or device authorization may be unavailable.", verifiedAt: Date())
        }
    }
    func removeDNS() async throws {
        try await dnsManager.loadFromPreferences()
        try await dnsManager.removeFromPreferences()
    }
}
