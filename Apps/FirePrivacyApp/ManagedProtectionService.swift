import Foundation
import FirePrivacyCore
import NetworkExtension

@MainActor
final class ManagedProtectionService {
    private let manager = NEFilterManager.shared()
    private let bundle: Bundle
    init(bundle: Bundle = .main) { self.bundle = bundle }

    func enable(dataset: ValidatedFilterDataset, authorization: ConsentAuthorization,
                checker: any ConsentAuthorizationChecking) async throws -> ProtectionComponentState {
        guard bundle.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String == "managed" else {
            throw ProtectionConfigurationError.unapprovedDeployment
        }
        let store = try ProtectionArtifactStore(bundle: bundle)
        let verified = try FilterDatasetVerifier.verify(dataset.signedDataset, trustedKeys: store.trustedKeys)
        guard verified.manifest.kind == .managedRulesV1 else { throw ProtectionConfigurationError.wrongDatasetKind }
        let policy = try JSONDecoder().decode(ManagedPolicy.self, from: verified.payload)
        try policy.validate()
        guard Double(policy.expiresAtSeconds) > Date().timeIntervalSince1970 else { throw FilterDatasetError.expired }
        guard authorization.feature == .managedProtection,
              authorization.scopeIdentity == (try policy.scopeIdentity),
              authorization.disclosureVersion == ConsentDisclosure.currentVersion,
              await checker.validateAuthorization(authorization) else {
            throw ProtectionConfigurationError.consentRequired
        }
        try await manager.loadFromPreferences()
        // Per-app enrollment/ContentFilterUUID is installed by MDM, never fabricated
        // by a consumer app. A system-wide filter is accepted only on authorized devices.
        if policy.deploymentMode == .mdmPerApp {
            guard manager.isEnabled, manager.providerConfiguration != nil else {
                throw ProtectionConfigurationError.unapprovedDeployment
            }
        } else {
            let configuration = NEFilterProviderConfiguration()
            configuration.filterBrowsers = true
            configuration.filterSockets = true
            configuration.vendorConfiguration = ["FirePrivacyPolicyDigest": verified.manifest.payloadSHA256,
                                                 "FirePrivacyDeploymentMode": policy.deploymentMode.rawValue]
            manager.providerConfiguration = configuration
            manager.localizedDescription = "Fire Privacy managed flow policy"
            manager.isEnabled = true
        }
        try store.write(ProtectionArtifactStore.ManagedEnvelope(signedDataset: verified.signedDataset,
                                                                allowedUntil: min(verified.expiresAt, Date(timeIntervalSince1970: Double(policy.expiresAtSeconds)))),
                        named: "managed-policy.json")
        do { try await manager.saveToPreferences() }
        catch { try? store.remove(named: "managed-policy.json"); throw error }
        guard await checker.validateAuthorization(authorization) else {
            try await remove()
            throw ProtectionConfigurationError.consentRevoked
        }
        return await state()
    }

    func state() async -> ProtectionComponentState {
        guard bundle.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String == "managed" else {
            return .init(component: .managed, phase: .unavailable,
                         detail: "Managed flow filtering requires the separately signed managed edition and system-authorized supervision or MDM per-app deployment.")
        }
        do {
            try await manager.loadFromPreferences()
            guard manager.isEnabled, manager.providerConfiguration != nil else {
                return .init(component: .managed, phase: .disabled, systemConfirmed: true,
                             detail: "No enabled Fire Privacy managed filter is reported by iOS.", verifiedAt: Date())
            }
            let policy = try ProtectionArtifactStore(bundle: bundle).validatedManagedPolicy()
            return .init(component: .managed, phase: .active, systemConfirmed: true,
                         detail: "iOS confirms an enabled managed content-filter configuration. Flow attribution is available only where the managed OS exposes it; policy never inspects encrypted payloads.",
                         verifiedAt: Date(), datasetVersion: policy.version)
        } catch let error as FilterDatasetError {
            try? await remove()
            return .init(component: .managed, phase: error == .expired ? .staleDataset : error == .revoked ? .revokedDataset : .failed,
                         detail: "The managed policy is unusable. Filtering was removed or needs an administrator removal retry.", verifiedAt: Date())
        } catch {
            try? await remove()
            return .init(component: .managed, phase: .unavailable,
                         detail: "Managed protection requires an authorized managed deployment, entitled signing and a current signed policy. A consumer app cannot grant supervision or MDM enrollment.", verifiedAt: Date())
        }
    }
    func remove() async throws {
        guard bundle.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String == "managed" else { return }
        try ProtectionArtifactStore(bundle: bundle).remove(named: "managed-policy.json")
        try await manager.loadFromPreferences()
        try await manager.removeFromPreferences()
    }
}
