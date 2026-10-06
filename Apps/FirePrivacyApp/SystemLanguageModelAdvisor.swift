import Foundation
import FirePrivacyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// SystemLanguageModel only. No tools, PCC, server-provider fallback, or URLs.
struct SystemLanguageModelAdvisor: PrivacyAdvisor {
    let mode: AdvisorMode = .appleOnDevice

    func availability() async -> AdvisorAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unsupportedDevice
                case .appleIntelligenceNotEnabled: return .appleIntelligenceDisabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unavailable
                }
            }
        }
        #endif
        return .unsupportedOS(required: 26)
    }

    func assess(_ input: AdvisorInput) async throws -> ValidatedAdvisorAssessment {
        try Task.checkCancellation()
        let state = await availability()
        guard state == .available else { throw AdvisorError.unavailable(state) }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return try await generate(input)
        }
        #endif
        throw AdvisorError.unavailable(.unsupportedOS(required: 26))
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func generate(_ input: AdvisorInput) async throws -> ValidatedAdvisorAssessment {
        let bytes = try input.encoded()
        guard let prompt = String(data: bytes, encoding: .utf8) else { throw AdvisorError.invalidInput }
        // Each request has a fresh session: no other report or prior chat context.
        // Only the static application constant is installed as instructions.
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: AdvisorInstructions.system)
        do {
            let generated = try await session.respond(to: prompt, generating: SystemAdvisorAssessment.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 2_048)).content
            try Task.checkCancellation()
            guard let reportID = UUID(uuidString: generated.reportID) else { throw AdvisorError.invalidAssessment }
            let items = try generated.items.map { item in
                let evidence = try item.evidenceIDs.map { text in
                    guard let id = UUID(uuidString: text) else { throw AdvisorError.invalidAssessment }
                    return id
                }
                return AdvisorAssessmentItem(claimID: item.claimID, ruleID: item.ruleID,
                    evidenceIDs: evidence, actionIDs: item.actionIDs,
                    style: item.style == .steps ? .steps : .plain)
            }
            return try AdvisorValidator.validate(AdvisorAssessment(schemaVersion: generated.schemaVersion,
                reportID: reportID, analysisIdentity: generated.analysisIdentity, items: items), for: input)
        } catch is CancellationError { throw CancellationError() }
        catch let error as AdvisorError { throw error }
        catch let error as LanguageModelSession.GenerationError {
            // SDK 26.2 API; the 27+ LanguageModelError API is deliberately unused.
            switch error {
            case .guardrailViolation, .refusal: throw AdvisorError.guardrailRefusal
            case .exceededContextWindowSize: throw AdvisorError.contextLimitExceeded
            case .unsupportedLanguageOrLocale: throw AdvisorError.unsupportedLanguage
            case .rateLimited: throw AdvisorError.rateLimited
            case .assetsUnavailable: throw AdvisorError.unavailable(.modelNotReady)
            default: throw AdvisorError.generationFailed
            }
        } catch { throw AdvisorError.generationFailed }
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
private enum SystemAdvisorStyle: Equatable {
    case plain, steps
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct SystemAdvisorItem {
    @Guide(description: "Copy the opaque claim id unchanged.") var claimID: String
    @Guide(description: "Copy the claim's rule identifier unchanged.") var ruleID: String
    @Guide(description: "Copy all evidence references for this claim unchanged.") var evidenceIDs: [String]
    @Guide(description: "Copy all reviewed action identifiers for this claim, including keep-as-is.") var actionIDs: [String]
    var style: SystemAdvisorStyle
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct SystemAdvisorAssessment {
    @Guide(description: "Copy schemaVersion unchanged.") var schemaVersion: Int
    @Guide(description: "Copy reportID unchanged.") var reportID: String
    @Guide(description: "Copy analysisIdentity unchanged.") var analysisIdentity: String
    @Guide(description: "Include every input claim once, ordered for reading.") var items: [SystemAdvisorItem]
}
#endif
