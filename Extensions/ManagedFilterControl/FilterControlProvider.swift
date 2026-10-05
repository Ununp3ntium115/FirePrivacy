import Foundation
import NetworkExtension

final class FilterControlProvider: NEFilterControlProvider {
    override func startFilter(completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            _ = try ProtectionArtifactStore().validatedManagedPolicy()
            notifyRulesChanged()
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    override func handleNewFlow(_ flow: NEFilterFlow,
                                completionHandler: @escaping @Sendable (NEFilterControlVerdict) -> Void) {
        // Consumer URL protection has no per-app flow telemetry. This provider is
        // reserved for a system-authorized managed deployment and never logs flows.
        completionHandler(.allow(withUpdateRules: false))
    }
}
