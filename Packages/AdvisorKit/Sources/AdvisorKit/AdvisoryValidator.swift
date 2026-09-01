import Foundation
import ObservationCore
import FindingEngine

/// Checks generated text before it is ever shown (AI-007).
///
/// Everything a model returns is treated as untrusted. The validator is not a
/// politeness filter: it enforces the product's accuracy boundary — no invented
/// evidence, no claim to see payloads, no claim about a current permission, no
/// legal conclusion, no certainty beyond the deterministic finding.
public struct AdvisoryValidator: Sendable {
    public enum Violation: Error, Equatable, Sendable, Hashable {
        case findingIDMismatch
        case unknownEvidenceID(String)
        case unknownActionID(String)
        case unavailableAction(String)
        case missingNoActionOption
        case emptyField(String)
        case fieldTooLong(String)
        case claimsPayloadVisibility(String)
        case claimsCurrentPermission(String)
        case legalConclusion(String)
        case overclaimsCertainty(String)
        case containsMarkup(String)
        case containsInstruction(String)

        public var explanation: String {
            switch self {
            case .findingIDMismatch: "The explanation referred to a different finding."
            case .unknownEvidenceID(let id): "Cited evidence that does not exist: \(id)."
            case .unknownActionID(let id): "Suggested an action that does not exist: \(id)."
            case .unavailableAction(let id): "Suggested an action unavailable on this device: \(id)."
            case .missingNoActionOption: "Did not offer the option to change nothing."
            case .emptyField(let field): "Left \(field) empty."
            case .fieldTooLong(let field): "\(field) was longer than the limit."
            case .claimsPayloadVisibility(let phrase): "Claimed to see what was sent (\"\(phrase)\")."
            case .claimsCurrentPermission(let phrase): "Claimed to know a current permission setting (\"\(phrase)\")."
            case .legalConclusion(let phrase): "Made a legal claim (\"\(phrase)\")."
            case .overclaimsCertainty(let phrase): "Claimed more certainty than the evidence supports (\"\(phrase)\")."
            case .containsMarkup(let phrase): "Contained markup or code (\"\(phrase)\")."
            case .containsInstruction(let phrase): "Contained an embedded instruction (\"\(phrase)\")."
            }
        }
    }

    public static let maximumFieldLength = 1200

    /// Phrases that assert visibility Fire Privacy does not have (§3.1).
    static let payloadClaims = [
        "was sent to", "sent your data", "uploaded your", "transmitted your",
        "we can see the contents", "the payload contained", "read the contents of",
        "your data was shared with", "exfiltrated",
    ]

    /// Phrases that assert a current permission state (PER-001).
    static let permissionClaims = [
        "currently has permission", "currently allowed", "is allowed to access",
        "has access right now", "the app can currently", "permission is set to",
    ]

    /// Legal characterizations (DASH-009).
    static let legalClaims = [
        "illegal", "unlawful", "violates the law", "breaks the law", "gdpr violation",
        "ccpa violation", "criminal", "sue", "malicious", "malware", "spyware", "stole", "stolen",
    ]

    /// Certainty that outruns the evidence.
    static let certaintyClaims = [
        "definitely", "certainly", "guaranteed", "proves that", "without a doubt",
        "there is no question", "always tracks you", "100% ",
    ]

    static let markupMarkers = ["<script", "</", "<img", "javascript:", "data:text/html", "```", "<iframe"]

    static let instructionMarkers = [
        "ignore previous", "ignore prior", "disregard the", "system prompt",
        "you are now", "as an ai", "override the", "new instructions",
    ]

    public init() {}

    public func validate(
        _ output: AdvisoryOutput,
        against input: AdvisoryInput,
        knownEvidenceIDs: Set<String>,
        availableActionIDs: Set<String>
    ) -> [Violation] {
        var violations: [Violation] = []

        guard output.findingID == input.findingID else {
            return [.findingIDMismatch]
        }

        let fields: [(String, String)] = [
            ("headline", output.headline),
            ("explanation", output.explanation),
            ("whyItMatters", output.whyItMatters),
            ("uncertainty", output.uncertainty),
            ("noActionExplanation", output.noActionExplanation),
        ]
        for (name, text) in fields {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(.emptyField(name))
            }
            if text.count > Self.maximumFieldLength {
                violations.append(.fieldTooLong(name))
            }
            violations.append(contentsOf: scan(text))
        }

        for id in output.evidenceIDs where !knownEvidenceIDs.contains(id) {
            violations.append(.unknownEvidenceID(id))
        }
        for id in output.actionIDs {
            if !RecommendationCatalog.exists(id: id) {
                violations.append(.unknownActionID(id))
            } else if !availableActionIDs.contains(id) {
                violations.append(.unavailableAction(id))
            }
        }
        if !output.actionIDs.contains(where: { RecommendationCatalog.recommendation(id: $0)?.isNoAction == true }) {
            violations.append(.missingNoActionOption)
        }

        return violations
    }

    private func scan(_ text: String) -> [Violation] {
        let lowered = text.lowercased()
        var violations: [Violation] = []
        for phrase in Self.payloadClaims where lowered.contains(phrase) {
            violations.append(.claimsPayloadVisibility(phrase))
        }
        for phrase in Self.permissionClaims where lowered.contains(phrase) {
            violations.append(.claimsCurrentPermission(phrase))
        }
        for phrase in Self.legalClaims where lowered.contains(phrase) {
            violations.append(.legalConclusion(phrase))
        }
        for phrase in Self.certaintyClaims where lowered.contains(phrase) {
            violations.append(.overclaimsCertainty(phrase))
        }
        for phrase in Self.markupMarkers where lowered.contains(phrase) {
            violations.append(.containsMarkup(phrase))
        }
        for phrase in Self.instructionMarkers where lowered.contains(phrase) {
            violations.append(.containsInstruction(phrase))
        }
        return violations
    }
}
