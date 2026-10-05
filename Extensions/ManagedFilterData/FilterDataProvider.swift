import Foundation
import NetworkExtension
import FirePrivacyCore

final class FilterDataProvider: NEFilterDataProvider {
    override func startFilter(completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            _ = try ProtectionArtifactStore().validatedManagedPolicy()
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // The data provider reads a local signed policy only. It neither reads payload
        // bytes nor writes flow metadata to disk or sends it to a server.
        guard let policy = try? ProtectionArtifactStore().validatedManagedPolicy() else { return .allow() }
        let host = flow.url?.host ?? (flow as? NEFilterSocketFlow)?.remoteHostname
        return policy.decision(host: host, sourceAppIdentifier: flow.sourceAppIdentifier) == .drop ? .drop() : .allow()
    }
}
