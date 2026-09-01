import Foundation
import ObservationCore
import FindingEngine

/// A cached explanation (AI-012).
public struct CachedExplanation: Codable, Sendable, Hashable {
    public let output: AdvisoryOutput
    public let inputHash: FireDigest
    public let mode: AdvisorMode
    public let osVersion: String
    public let appVersion: String
    public let promptVersion: String
    public let generatedAt: Date

    public init(
        output: AdvisoryOutput,
        inputHash: FireDigest,
        mode: AdvisorMode,
        osVersion: String,
        appVersion: String,
        promptVersion: String,
        generatedAt: Date
    ) {
        self.output = output
        self.inputHash = inputHash
        self.mode = mode
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.promptVersion = promptVersion
        self.generatedAt = generatedAt
    }
}

/// What happened when an explanation was requested, so the UI can be honest
/// about which mode actually produced the text (§11.7).
public struct AdvisoryResolution: Sendable {
    public let output: AdvisoryOutput
    public let requestedMode: AdvisorMode
    public let effectiveMode: AdvisorMode
    public let fellBack: Bool
    public let fallbackReason: String?
    public let validationViolations: [AdvisoryValidator.Violation]
    public let wasCached: Bool

    public init(
        output: AdvisoryOutput,
        requestedMode: AdvisorMode,
        effectiveMode: AdvisorMode,
        fellBack: Bool,
        fallbackReason: String?,
        validationViolations: [AdvisoryValidator.Violation],
        wasCached: Bool
    ) {
        self.output = output
        self.requestedMode = requestedMode
        self.effectiveMode = effectiveMode
        self.fellBack = fellBack
        self.fallbackReason = fallbackReason
        self.validationViolations = validationViolations
        self.wasCached = wasCached
    }
}

/// Chooses an advisor, validates what it produces, and falls back deterministically.
///
/// Generated text is validated; template text is not, because the template is
/// built from the finding by code in this repository. Untrusted values inside a
/// finding are sanitized at import and again in `AdvisoryInput.make`, so a
/// hostile domain name reaches neither a model's instructions nor the
/// validator's phrase list as a false positive.
public actor AdvisorCoordinator {
    private let template = TemplatePrivacyAdvisor()
    private let validator = AdvisoryValidator()
    private var advisors: [AdvisorMode: any PrivacyAdvisor]
    private var cache: [String: CachedExplanation] = [:]
    private let osVersion: String
    private let appVersion: String
    private let clock: @Sendable () -> Date

    public init(
        advisors: [AdvisorMode: any PrivacyAdvisor] = [:],
        osVersion: String,
        appVersion: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.advisors = advisors
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.clock = clock
    }

    public func register(_ advisor: any PrivacyAdvisor) {
        advisors[advisor.mode] = advisor
    }

    public func availability(of mode: AdvisorMode) async -> AdvisorAvailability {
        switch mode {
        case .off: .disabledByUser
        case .deterministic: .available
        default: await advisors[mode]?.availability() ?? .notConfigured
        }
    }

    public func explain(
        finding: Finding,
        evidence: [Evidence],
        mode: AdvisorMode,
        readingLevel: AdvisoryInput.ReadingLevel = .plain,
        locale: String = "en",
        osMajorVersion: Int
    ) async -> AdvisoryResolution? {
        guard mode != .off else { return nil }

        let available = RecommendationCatalog.available(osMajorVersion: osMajorVersion)
        let input = AdvisoryInput.make(
            finding: finding,
            evidence: evidence,
            availableRecommendations: available,
            readingLevel: readingLevel,
            locale: locale
        )
        let inputHash = Self.hash(input: input, mode: mode)

        if let cached = cache[cacheKey(inputHash: inputHash, mode: mode)],
           cached.promptVersion == AdvisoryPrompt.version,
           cached.appVersion == appVersion {
            return AdvisoryResolution(
                output: cached.output,
                requestedMode: mode,
                effectiveMode: cached.mode,
                fellBack: cached.mode != mode,
                fallbackReason: nil,
                validationViolations: [],
                wasCached: true
            )
        }

        var violations: [AdvisoryValidator.Violation] = []
        var fallbackReason: String?

        if mode != .deterministic, let advisor = advisors[mode] {
            let availability = await advisor.availability()
            if availability.isAvailable {
                do {
                    let output = try await advisor.explain(input)
                    violations = validator.validate(
                        output,
                        against: input,
                        knownEvidenceIDs: Set(evidence.map(\.id)).union(finding.evidenceIDs),
                        availableActionIDs: Set(available.map(\.id))
                    )
                    if violations.isEmpty {
                        store(output: output, inputHash: inputHash, mode: mode)
                        return AdvisoryResolution(
                            output: output,
                            requestedMode: mode,
                            effectiveMode: mode,
                            fellBack: false,
                            fallbackReason: nil,
                            validationViolations: [],
                            wasCached: false
                        )
                    }
                    fallbackReason = "The generated explanation did not pass Fire Privacy's checks."
                } catch {
                    fallbackReason = "The model could not produce an explanation."
                }
            } else {
                fallbackReason = availability.explanation
            }
        }

        guard let output = try? await template.explain(input) else { return nil }
        store(output: output, inputHash: inputHash, mode: .deterministic)
        return AdvisoryResolution(
            output: output,
            requestedMode: mode,
            effectiveMode: .deterministic,
            fellBack: mode != .deterministic,
            fallbackReason: fallbackReason,
            validationViolations: violations,
            wasCached: false
        )
    }

    /// Invalidates cached text when the deterministic finding changed (AI-012).
    public func invalidate(findingID: String) {
        cache = cache.filter { $0.value.output.findingID != findingID }
    }

    public func invalidateAll() {
        cache.removeAll()
    }

    public func cachedExplanations() -> [CachedExplanation] {
        cache.values.sorted { $0.generatedAt < $1.generatedAt }
    }

    private func store(output: AdvisoryOutput, inputHash: FireDigest, mode: AdvisorMode) {
        cache[cacheKey(inputHash: inputHash, mode: mode)] = CachedExplanation(
            output: output,
            inputHash: inputHash,
            mode: mode,
            osVersion: osVersion,
            appVersion: appVersion,
            promptVersion: AdvisoryPrompt.version,
            generatedAt: clock()
        )
    }

    private func cacheKey(inputHash: FireDigest, mode: AdvisorMode) -> String {
        "\(mode.rawValue)|\(inputHash.hexString)"
    }

    static func hash(input: AdvisoryInput, mode: AdvisorMode) -> FireDigest {
        var hasher = FireHasher()
        hasher.update(mode.rawValue)
        hasher.update(input.findingID)
        hasher.update(input.ruleID)
        hasher.update(input.severity)
        hasher.update(String(format: "%.4f", input.confidence))
        hasher.update(input.readingLevel.rawValue)
        hasher.update(input.locale)
        for fact in input.observedFacts {
            hasher.update(fact.key)
            hasher.update(fact.value)
        }
        for action in input.availableActions { hasher.update(action.id) }
        return hasher.finalize()
    }
}
