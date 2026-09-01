import Foundation
import ObservationCore
import FindingEngine

/// Builds an explanation from the finding itself, with no model involved.
///
/// This is the fallback for every other mode and the default on devices without
/// Apple Intelligence, which is what makes AI-001 true: turning AI off costs the
/// user nothing but phrasing.
public struct TemplatePrivacyAdvisor: PrivacyAdvisor {
    public let mode: AdvisorMode = .deterministic

    public init() {}

    public func availability() async -> AdvisorAvailability { .available }

    public func explain(_ input: AdvisoryInput) async throws -> AdvisoryOutput {
        AdvisoryOutput(
            findingID: input.findingID,
            headline: headline(for: input),
            explanation: explanation(for: input),
            whyItMatters: whyItMatters(for: input),
            uncertainty: uncertainty(for: input),
            evidenceIDs: Array(Set(input.observedFacts.flatMap(\.evidenceIDs))).sorted(),
            actionIDs: input.availableActions.map(\.id),
            noActionExplanation: "Choosing to change nothing is a valid outcome. Fire Privacy records that you reviewed this and stops raising it first.",
            mode: mode
        )
    }

    private func headline(for input: AdvisoryInput) -> String {
        switch input.ruleID {
        case "AGG-APPLE-001": "Apple's report flags this destination as a possible cross-app collector"
        case "AGG-CROSSAPP-002": "One destination, several unrelated apps"
        case "LOC-NET-003": "Location access and location-data infrastructure in the same window"
        case "SENSOR-UNEXPECTED-004": "You marked this access as unexpected"
        case "UNKNOWN-HIGHFANOUT-005": "Many destinations, few of them classified"
        case "VENDOR-KNOWN-006": "A documented data business was contacted"
        case "COVERAGE-GAP-007": "Protection is available but off"
        case "FRESHNESS-008": "This report describes the past"
        default: "Something in this report is worth a look"
        }
    }

    private func explanation(for input: AdvisoryInput) -> String {
        var sentences: [String] = []
        for fact in input.observedFacts.prefix(4) {
            sentences.append("\(Self.readable(fact.key)): \(fact.value).")
        }
        if sentences.isEmpty {
            sentences.append("This finding rests on records in the report you imported.")
        }
        sentences.append("Confidence in this reading is \(Self.confidenceWord(input.confidence)) (\(Int(input.confidence * 100)) out of 100).")
        return sentences.joined(separator: " ")
    }

    private func whyItMatters(for input: AdvisoryInput) -> String {
        switch input.ruleID {
        case "AGG-APPLE-001", "AGG-CROSSAPP-002":
            "When one company receives activity from apps that have nothing to do with each other, those separate activities can be joined into one picture of you."
        case "LOC-NET-003":
            "Where you are is among the most revealing things a phone knows. An app that reads it and also talks to a location-data business is worth understanding."
        case "SENSOR-UNEXPECTED-004":
            "An access you did not expect is the clearest signal you have that an app's behaviour and its purpose have drifted apart."
        case "UNKNOWN-HIGHFANOUT-005":
            "A wide spread of destinations makes it hard for anyone, including you, to say where information goes."
        case "VENDOR-KNOWN-006":
            "Companies in this category exist to combine and license information about people or places."
        case "COVERAGE-GAP-007":
            "iOS can deny these requests for you, and it can do it without telling Fire Privacy which addresses you visit."
        case "FRESHNESS-008":
            "Decisions are easier to make from current information than from a window that has already closed."
        default:
            "It affects how much of your activity is visible to companies you did not choose."
        }
    }

    private func uncertainty(for input: AdvisoryInput) -> String {
        guard !input.uncertainty.isEmpty else {
            return "The report shows that contacts happened, not what they contained."
        }
        return input.uncertainty.joined(separator: " ")
    }

    static func readable(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    static func confidenceWord(_ confidence: Double) -> String {
        switch confidence {
        case ..<0.5: "low"
        case ..<0.75: "moderate"
        case ..<0.9: "strong"
        default: "very strong"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
