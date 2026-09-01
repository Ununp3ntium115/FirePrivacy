import Foundation
import ObservationCore
import KnowledgeBaseKit

/// The kinds of evidence a finding may rest on (DET-002).
public enum EvidenceKind: String, Codable, Sendable, Hashable {
    case appleNetworkObservation
    case appleSensorObservation
    case appleDomainClassification
    case knowledgeBaseMatch
    case crossAppRecurrence
    case userReportedPermission
    case protectionStatus
    case reportComparison
    case managedFlowObservation

    /// Base confidence for this kind of evidence (§13.3).
    public var baseConfidence: Double {
        switch self {
        case .appleNetworkObservation, .appleSensorObservation: 0.98
        case .appleDomainClassification: 0.95
        case .knowledgeBaseMatch: 0.92
        case .crossAppRecurrence: 0.80
        case .userReportedPermission: 0.90
        case .protectionStatus: 0.95
        case .reportComparison: 0.85
        case .managedFlowObservation: 0.95
        }
    }

    /// Evidence of the same kind drawn from the same export is correlated, so
    /// combining ten of them must not read as ten independent confirmations
    /// (§13.3).
    public var correlationGroup: String {
        switch self {
        case .appleNetworkObservation, .appleSensorObservation, .appleDomainClassification: "apple-export"
        case .knowledgeBaseMatch: "knowledge-base"
        case .crossAppRecurrence: "apple-export"
        case .userReportedPermission: "user"
        case .protectionStatus: "device"
        case .reportComparison: "apple-export"
        case .managedFlowObservation: "managed"
        }
    }
}

/// One item of evidence, addressable by ID so a finding — and any generated
/// explanation of it — can be traced back to what produced it (DET-011).
public struct Evidence: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: EvidenceKind
    /// Plain-language summary. Contains only sanitized values.
    public let summary: String
    public let confidence: Double
    public let observationIDs: [UUID]
    public let sourceLineNumbers: [Int]
    public let knowledgeBaseRuleIDs: [String]
    /// Small structured details shown in the raw evidence view.
    public let detail: [String: String]

    public init(
        id: String,
        kind: EvidenceKind,
        summary: String,
        confidence: Double,
        observationIDs: [UUID] = [],
        sourceLineNumbers: [Int] = [],
        knowledgeBaseRuleIDs: [String] = [],
        detail: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.confidence = confidence
        self.observationIDs = observationIDs
        self.sourceLineNumbers = sourceLineNumbers
        self.knowledgeBaseRuleIDs = knowledgeBaseRuleIDs
        self.detail = detail
    }
}

/// A direct record field. Never an interpretation (DET-003).
public struct ObservedFact: Codable, Sendable, Hashable {
    public let key: String
    public let value: String
    public let evidenceIDs: [String]

    public init(key: String, value: String, evidenceIDs: [String]) {
        self.key = key
        self.value = value
        self.evidenceIDs = evidenceIDs
    }
}

/// A rule's interpretation of facts, always separated from the facts (DET-003).
public struct Inference: Codable, Sendable, Hashable {
    public let statement: String
    public let basis: [String]
    public let confidence: Double

    public init(statement: String, basis: [String], confidence: Double) {
        self.statement = statement
        self.basis = basis
        self.confidence = confidence
    }
}

/// The complete evidence chain behind one finding (§23.6).
public struct EvidenceGraph: Codable, Sendable, Hashable {
    public let findingID: String
    public let evidence: [Evidence]
    public let observedFacts: [ObservedFact]
    public let inferences: [Inference]
    public let unknowns: [String]

    public init(
        findingID: String,
        evidence: [Evidence],
        observedFacts: [ObservedFact],
        inferences: [Inference],
        unknowns: [String]
    ) {
        self.findingID = findingID
        self.evidence = evidence
        self.observedFacts = observedFacts
        self.inferences = inferences
        self.unknowns = unknowns
    }
}

/// Combines confidences (§13.3).
public enum ConfidenceCalculator {
    /// `C = 1 - Π(1 - cᵢ)`, with a penalty applied to items that share a
    /// correlation group so that repeated readings of one source do not
    /// masquerade as independent corroboration.
    public static func combine(_ evidence: [Evidence]) -> Double {
        guard !evidence.isEmpty else { return 0 }
        var groupCounts: [String: Int] = [:]
        var complement = 1.0
        for item in evidence.sorted(by: { $0.confidence > $1.confidence }) {
            let group = item.kind.correlationGroup
            let seen = groupCounts[group, default: 0]
            groupCounts[group] = seen + 1
            // First item in a group counts fully; each subsequent one counts
            // for progressively less.
            let discount = pow(0.35, Double(seen))
            let effective = min(0.99, max(0, item.confidence * discount))
            complement *= (1 - effective)
        }
        return min(0.99, 1 - complement)
    }
}
