import Foundation
import AdvisorKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The one file that touches Apple's Foundation Models framework.
///
/// It is isolated here on purpose (see `LanguageModelBridging`): the framework
/// is iOS 26+, its API is re-verified against every SDK, and no package in this
/// repository depends on it. When the framework is missing — older SDK, other
/// platform, unsupported hardware — the bridge reports unavailability and the
/// deterministic advisor produces the explanation instead, which costs no
/// detection at all (AI-001).
///
/// TODO(Gate 4): verify the session/guided-generation calls against the shipping
/// iOS 26 SDK before enabling this path in a release build. Until that
/// verification is recorded in `Documentation/ADR`, this bridge deliberately
/// reports `.modelAssetsUnavailable` rather than guessing at API shape.
struct FoundationModelsBridge: LanguageModelBridging {
    let mode: AdvisorMode = .appleOnDevice

    func availability() async -> AdvisorAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            // Availability is checked dynamically on every call, never cached
            // across launches (AI-004).
            return .modelAssetsUnavailable
        }
        return .unsupportedOSVersion(required: 26)
        #else
        return .unsupportedOSVersion(required: 26)
        #endif
    }

    func generate(system: String, input: AdvisoryInput) async throws -> AdvisoryCandidate {
        throw AdvisorError.unavailable("The on-device model adapter is not enabled in this build.")
    }
}
