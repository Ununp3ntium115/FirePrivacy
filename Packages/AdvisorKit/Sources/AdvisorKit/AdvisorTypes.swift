import Foundation
import ObservationCore
import FindingEngine

/// Where an explanation is produced (AI-002).
///
/// The mode is always visible in the UI, because "on-device" and "sent to a
/// server" are different promises and the user is entitled to know which one is
/// in effect (§11.7).
public enum AdvisorMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// No explanations at all.
    case off
    /// Deterministic templates. No model involved.
    case deterministic
    /// Apple's on-device system language model.
    case appleOnDevice
    /// Apple Private Cloud Compute. Server-side Apple processing, iOS 27+.
    case applePrivateCloudCompute
    /// A model endpoint the user operates and selected.
    case userLocalEndpoint

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .deterministic: "Deterministic explanations"
        case .appleOnDevice: "Apple on-device model"
        case .applePrivateCloudCompute: "Apple Private Cloud Compute"
        case .userLocalEndpoint: "Your own model endpoint"
        }
    }

    /// Whether anything leaves the iPhone in this mode.
    public var sendsDataOffDevice: Bool {
        switch self {
        case .off, .deterministic, .appleOnDevice: false
        case .applePrivateCloudCompute, .userLocalEndpoint: true
        }
    }

    /// One sentence shown next to the mode selector.
    public var dataFlowDescription: String {
        switch self {
        case .off: "Explanations are not generated."
        case .deterministic: "Text is assembled on this iPhone from the finding itself. Nothing leaves the device."
        case .appleOnDevice: "Apple's on-device model runs on this iPhone. Nothing leaves the device."
        case .applePrivateCloudCompute: "This is server-side processing on Apple's Private Cloud Compute, not on-device processing."
        case .userLocalEndpoint: "The structured summary shown in the preview is sent to the endpoint you configured."
        }
    }
}

/// Why a mode is or is not usable right now (AI-004).
public enum AdvisorAvailability: Sendable, Hashable {
    case available
    case unsupportedDevice
    case unsupportedOSVersion(required: Int)
    case appleIntelligenceDisabled
    case modelAssetsUnavailable
    case languageUnsupported(String)
    case rateLimited
    case quotaExhausted
    case notConfigured
    case disabledByUser
    case preRelease

    public var isAvailable: Bool { self == .available }

    /// Explains the state without blaming the user.
    public var explanation: String {
        switch self {
        case .available: "Ready."
        case .unsupportedDevice: "This iPhone does not support Apple's on-device model."
        case .unsupportedOSVersion(let required): "This needs iOS \(required) or later."
        case .appleIntelligenceDisabled: "Apple Intelligence is turned off in Settings."
        case .modelAssetsUnavailable: "The model is still downloading or is unavailable."
        case .languageUnsupported(let language): "The model does not support \(language) yet."
        case .rateLimited: "The model is busy. Deterministic explanations are being used instead."
        case .quotaExhausted: "The quota for this model is used up. The finding itself is unaffected."
        case .notConfigured: "No endpoint has been set up."
        case .disabledByUser: "You turned this off."
        case .preRelease: "This depends on a pre-release Apple feature and is not enabled in this build."
        }
    }
}

/// The typed summary a model is allowed to see (AI-005).
///
/// Raw report lines, browsing context, device identifiers, file names and free
/// text are excluded by construction: this struct is the entire surface, so
/// there is no path by which an unreviewed field reaches a model.
public struct AdvisoryInput: Codable, Sendable, Hashable {
    public enum ReadingLevel: String, Codable, Sendable, Hashable, CaseIterable {
        case plain
        case detailed
        case technical
    }

    public let findingID: String
    public let ruleID: String
    public let severity: String
    public let confidence: Double
    public let observedFacts: [ObservedFact]
    public let uncertainty: [String]
    public let availableActions: [AvailableAction]
    public let readingLevel: ReadingLevel
    public let locale: String
    public let schemaVersion: String

    public init(
        findingID: String,
        ruleID: String,
        severity: String,
        confidence: Double,
        observedFacts: [ObservedFact],
        uncertainty: [String],
        availableActions: [AvailableAction],
        readingLevel: ReadingLevel,
        locale: String,
        schemaVersion: String = ComponentVersion.advisory
    ) {
        self.findingID = findingID
        self.ruleID = ruleID
        self.severity = severity
        self.confidence = confidence
        self.observedFacts = observedFacts
        self.uncertainty = uncertainty
        self.availableActions = availableActions
        self.readingLevel = readingLevel
        self.locale = locale
        self.schemaVersion = schemaVersion
    }

    public struct AvailableAction: Codable, Sendable, Hashable {
        public let id: String
        public let title: String
        public let isNoAction: Bool

        public init(id: String, title: String, isNoAction: Bool) {
            self.id = id
            self.title = title
            self.isNoAction = isNoAction
        }
    }

    /// Builds the input from a finding, dropping everything not on the allow list.
    public static func make(
        finding: Finding,
        evidence: [Evidence],
        availableRecommendations: [Recommendation],
        readingLevel: ReadingLevel = .plain,
        locale: String = "en"
    ) -> AdvisoryInput {
        let actions = finding.recommendationIDs
            .compactMap { id in availableRecommendations.first { $0.id == id } }
            .map { AvailableAction(id: $0.id, title: $0.title, isNoAction: $0.isNoAction) }

        // Facts are re-sanitized here even though they were sanitized on import:
        // this is the last boundary before text reaches a model (AI-008).
        let facts = finding.observedFacts.map { fact in
            ObservedFact(
                key: UntrustedText(fact.key, limit: 64).value,
                value: UntrustedText(fact.value, limit: 240).value,
                evidenceIDs: fact.evidenceIDs
            )
        }

        return AdvisoryInput(
            findingID: finding.id,
            ruleID: finding.ruleID,
            severity: finding.severity.rawValue,
            confidence: finding.confidence,
            observedFacts: facts,
            uncertainty: finding.uncertainty,
            availableActions: actions,
            readingLevel: readingLevel,
            locale: locale
        )
    }
}

/// What an advisor must return (AI-006).
public struct AdvisoryOutput: Codable, Sendable, Hashable {
    public let findingID: String
    public let headline: String
    public let explanation: String
    public let whyItMatters: String
    public let uncertainty: String
    public let evidenceIDs: [String]
    public let actionIDs: [String]
    public let noActionExplanation: String
    public let mode: AdvisorMode

    public init(
        findingID: String,
        headline: String,
        explanation: String,
        whyItMatters: String,
        uncertainty: String,
        evidenceIDs: [String],
        actionIDs: [String],
        noActionExplanation: String,
        mode: AdvisorMode
    ) {
        self.findingID = findingID
        self.headline = headline
        self.explanation = explanation
        self.whyItMatters = whyItMatters
        self.uncertainty = uncertainty
        self.evidenceIDs = evidenceIDs
        self.actionIDs = actionIDs
        self.noActionExplanation = noActionExplanation
        self.mode = mode
    }
}

public enum AdvisorError: Error, Sendable, Equatable {
    case unavailable(String)
    case validationFailed([AdvisoryValidator.Violation])
    case cancelled
    case timedOut
    case guardrailRefusal
    case contextLimitExceeded
}

/// The adapter every advisor implements (§15.1).
public protocol PrivacyAdvisor: Sendable {
    var mode: AdvisorMode { get }
    func availability() async -> AdvisorAvailability
    func explain(_ input: AdvisoryInput) async throws -> AdvisoryOutput
}
