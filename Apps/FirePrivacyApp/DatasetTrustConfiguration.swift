import Foundation
import FirePrivacyCore

/// Deployed public update authority. Operator keys are configured at build time;
/// they are not fetched, learned from a payload, or persisted in the workspace.
struct DatasetTrustConfiguration: Sendable {
    let verifierAnchors: [KnowledgeBaseTrustAnchor]
    let publicFilterKeys: [String: Data]

    static func load(bundle: Bundle = .main) throws -> Self {
        let maps = try DatasetPublicKeyConfiguration.load(bundle: bundle)
        return Self(maps: maps, pinnedKnowledgeAnchors: KnowledgeBaseResources.trustAnchors)
    }

    init(knowledgeBasePublicKeysJSON: String? = nil, filterPublicKeysJSON: String? = nil,
         pinnedKnowledgeAnchors: [KnowledgeBaseTrustAnchor] = KnowledgeBaseResources.trustAnchors,
         pinnedFilterKeys: [String: Data]? = nil) throws {
        let maps = try DatasetPublicKeyConfiguration(knowledgeBaseJSON: knowledgeBasePublicKeysJSON,
            filterJSON: filterPublicKeysJSON,
            pinnedKnowledgeKeys: DatasetPublicKeyConfiguration.pinnedKnowledgeKeys(pinnedKnowledgeAnchors),
            pinnedFilterKeys: pinnedFilterKeys ?? BundledProtectionDataset.trustedKeys())
        self.init(maps: maps, pinnedKnowledgeAnchors: pinnedKnowledgeAnchors)
    }

    private init(maps: DatasetPublicKeyConfiguration, pinnedKnowledgeAnchors: [KnowledgeBaseTrustAnchor]) {
        let pinnedIDs = Set(pinnedKnowledgeAnchors.map(\.keyID))
        // Never discard a bootstrap anchor's validity window when merging a
        // same-ID/same-key operator declaration. New keys have the Core default
        // epoch/no-expiry window; manifest validity and revocation still apply.
        let configured = maps.knowledgeBaseKeys.compactMap { id, bytes -> KnowledgeBaseTrustAnchor? in
            pinnedIDs.contains(id) ? nil : .init(keyID: id, publicKey: bytes)
        }
        verifierAnchors = (pinnedKnowledgeAnchors + configured).sorted { $0.keyID < $1.keyID }
        publicFilterKeys = maps.filterKeys
    }
}
