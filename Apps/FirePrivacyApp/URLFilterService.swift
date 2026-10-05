import Foundation
import FirePrivacyCore
import NetworkExtension

/// iOS 26 performs PIR/OHTTP lookups. This adapter never sends a visited URL itself.
@available(iOS 26.0, *)
@MainActor
final class URLFilterService {
    private let manager = NEURLFilterManager.shared
    private let bundle: Bundle
    init(bundle: Bundle = .main) { self.bundle = bundle }

    func enable(dataset: ValidatedFilterDataset, authenticationToken: String,
                authorization: ConsentAuthorization,
                checker: any ConsentAuthorizationChecking) async throws -> ProtectionComponentState {
        guard bundle.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String == "url-filter" else {
            throw ProtectionConfigurationError.unapprovedDeployment
        }
        let store = try ProtectionArtifactStore(bundle: bundle)
        let verified = try FilterDatasetVerifier.verify(dataset.signedDataset, trustedKeys: store.trustedKeys)
        let identifier = (bundle.bundleIdentifier ?? "") + ".URLFilterControl"
        let configuration = try verified.urlConfiguration(controlProviderBundleIdentifier: identifier)
        let declaration = bundle.object(forInfoDictionaryKey: "NSPIRConfiguration") as? [String: String]
        guard declaration?["PIRServerURL"] == configuration.pirServerURL.absoluteString,
              (declaration?["PrivacyPassIssuerURL"].flatMap { $0.isEmpty ? nil : $0 }) == configuration.privacyPassIssuerURL?.absoluteString,
              bundle.object(forInfoDictionaryKey: "FirePrivacyApplePIRConfigurationIdentity") as? String == configuration.appleApprovedConfigurationIdentity else {
            throw ProtectionConfigurationError.unapprovedDeployment
        }
        guard !authenticationToken.isEmpty, authenticationToken.utf8.count <= 8_192 else {
            throw ProtectionConfigurationError.invalidEndpoint
        }
        guard authorization.feature == .urlProtection,
              authorization.scopeIdentity == (try configuration.scopeIdentity),
              authorization.disclosureVersion == ConsentDisclosure.currentVersion,
              await checker.validateAuthorization(authorization) else {
            throw ProtectionConfigurationError.consentRequired
        }
        try await manager.loadFromPreferences()
        try store.write(ProtectionArtifactStore.URLFilterEnvelope(signedDataset: verified.signedDataset,
                                                                  allowedUntil: verified.expiresAt), named: "url-prefilter.json")
        try manager.setConfiguration(pirServerURL: configuration.pirServerURL,
                                     pirPrivacyPassIssuerURL: configuration.privacyPassIssuerURL,
                                     pirAuthenticationToken: authenticationToken,
                                     controlProviderBundleIdentifier: identifier)
        manager.localizedDescription = "Fire Privacy URL protection"
        manager.prefilterFetchInterval = 15 * 60
        // Availability failure does not interrupt unrelated networking. A prefilter match
        // is only a potential match; Apple's PIR server must supply the final verdict.
        manager.shouldFailClosed = false
        manager.reportEndpoint = nil // Consumer filtering never enables managed traffic reporting.
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
        } catch NEURLFilterManager.Error.configurationUnchanged {
            // This still requires the same consent and the read-back below.
        } catch {
            try? store.remove(named: "url-prefilter.json")
            throw error
        }
        guard await checker.validateAuthorization(authorization) else {
            try await remove()
            throw ProtectionConfigurationError.consentRevoked
        }
        return await state()
    }

    func state() async -> ProtectionComponentState {
        guard bundle.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String == "url-filter" else {
            return .init(component: .systemURLFilter, phase: .unavailable,
                         detail: "URL filtering requires the separately signed URL-filter edition and a registered Apple PIR/OHTTP service.")
        }
        do {
            try await manager.loadFromPreferences()
            guard manager.isEnabled else {
                return .init(component: .systemURLFilter, phase: .disabled, systemConfirmed: true,
                             detail: "iOS reports URL filtering disabled.", verifiedAt: Date())
            }
            let dataset = try ProtectionArtifactStore(bundle: bundle).validatedURLFilter()
            let expected = try dataset.urlConfiguration(controlProviderBundleIdentifier: (bundle.bundleIdentifier ?? "") + ".URLFilterControl")
            guard manager.pirServerURL == expected.pirServerURL,
                  manager.controlProviderBundleIdentifier == expected.controlProviderBundleIdentifier else {
                return .init(component: .systemURLFilter, phase: .failed, systemConfirmed: true,
                             detail: "The system configuration differs from the service you approved.", verifiedAt: Date())
            }
            let running = await manager.status == .running
            return .init(component: .systemURLFilter, phase: running ? .active : .awaitingUserEnablement,
                         systemConfirmed: true, detail: running ?
                         "iOS confirms the URL filter is running for WebKit, URLSession and other participating URL requests. Arbitrary sockets are outside this scope." :
                         "Configuration is installed; iOS has not confirmed a running filter. Approve it in Settings and verify the registered PIR/OHTTP service.",
                         verifiedAt: Date(), datasetVersion: dataset.manifest.version)
        } catch let error as FilterDatasetError {
            try? await remove()
            return .init(component: .systemURLFilter, phase: error == .expired ? .staleDataset : error == .revoked ? .revokedDataset : .failed,
                         detail: "URL filtering was removed because its signed dataset is unavailable, expired or revoked.", verifiedAt: Date())
        } catch {
            try? await remove()
            return .init(component: .systemURLFilter, phase: .needsConfiguration,
                         detail: "A trusted current Apple-format prefilter, registered PIR/OHTTP service, entitled signing and user authorization are required.", verifiedAt: Date())
        }
    }

    func remove() async throws {
        guard bundle.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String == "url-filter" else { return }
        // Remove the local prefilter first, so future extension requests refuse activation
        // even if the system removal fails and needs a user-visible retry.
        try ProtectionArtifactStore(bundle: bundle).remove(named: "url-prefilter.json")
        try await manager.loadFromPreferences()
        try await manager.removeFromPreferences()
    }
}
