import Foundation
import NetworkExtension
import FirePrivacyCore

final class FilterDataProvider: NEFilterDataProvider, @unchecked Sendable {
    private struct Snapshot: Sendable {
        let index: ManagedPolicyIndex
        let artifactPath: String
        let store: ProtectionArtifactStore
        let manifest: FilterDatasetManifest
        let revocationList: SignedFilterDataset?
    }
    private let policyLock = NSLock()
    private var cachedPolicy: Snapshot?

    private func refreshPolicy() throws {
        let store = try ProtectionArtifactStore()
        let artifact = try store.validatedManagedArtifact()
        let snapshot = Snapshot(index: try ManagedPolicyIndex(policy: artifact.policy, authorizationExpiresAt: artifact.allowedUntil),
                                artifactPath: store.directory.appendingPathComponent("managed-policy.json").path,
                                store: store, manifest: artifact.dataset.manifest, revocationList: artifact.revocationList)
        policyLock.withLock { cachedPolicy = snapshot }
    }
    override func startFilter(completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            try refreshPolicy()
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    override func handleRulesChanged() {
        do { try refreshPolicy() }
        catch { policyLock.withLock { cachedPolicy = nil } }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        policyLock.withLock { cachedPolicy = nil }
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // The data provider reads a local signed policy only. It neither reads payload
        // bytes nor writes flow metadata to disk or sends it to a server.
        let snapshot = policyLock.withLock { cachedPolicy }
        // Local revocation deletes this artifact before attempting OS removal.
        // Even when removal fails, subsequent flows use the permissive safe state.
        guard let snapshot, FileManager.default.fileExists(atPath: snapshot.artifactPath) else { return .allow() }
        // Revalidate the small signed revocation list, not the full policy, so a
        // newly revoked key/version/digest or expired revocation context takes
        // effect on the next flow even before an OS rules-changed callback.
        do {
            if let current = try snapshot.store.currentRevocationList(for: .managedRulesV1, embedded: snapshot.revocationList) {
                let revoked = current.document.revocations
                if revoked.keyIDs.contains(snapshot.manifest.keyID) || revoked.versions.contains(snapshot.manifest.version) ||
                    revoked.payloadDigests.contains(snapshot.manifest.payloadSHA256) { return .allow() }
            }
        } catch { return .allow() }
        let host = flow.url?.host ?? (flow as? NEFilterSocketFlow)?.remoteHostname
        return snapshot.index.decision(host: host, sourceAppIdentifier: flow.sourceAppIdentifier) == .drop ? .drop() : .allow()
    }
}
