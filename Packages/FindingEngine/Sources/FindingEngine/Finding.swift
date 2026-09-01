import Foundation
import ObservationCore

/// Potential impact if a rule's interpretation is correct. Independent of
/// confidence (§13.4).
public enum Severity: String, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case info
    case low
    case medium
    case high
    case critical

    public var displayName: String {
        switch self {
        case .info: "Information"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .critical: "Critical"
        }
    }

    /// SF Symbol name. Severity is never communicated by color alone (§11.10).
    public var symbolName: String {
        switch self {
        case .info: "info.circle"
        case .low: "checkmark.circle"
        case .medium: "exclamationmark.circle"
        case .high: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon"
        }
    }

    var rank: Int {
        switch self {
        case .info: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        case .critical: 4
        }
    }

    var weight: Double {
        switch self {
        case .info: 1.0
        case .low: 2.0
        case .medium: 4.0
        case .high: 7.0
        case .critical: 11.0
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }

    /// `Q = 0.50·I + 0.30·B + 0.20·P`, each factor 1–5 (§13.4).
    ///
    /// Critical is reserved for concrete high-impact conditions; routine
    /// advertising or analytics must never reach it, which the caller enforces
    /// by capping `impact`.
    public static func from(impact: Double, breadth: Double, persistence: Double) -> Severity {
        let clamp = { (value: Double) in min(5, max(1, value)) }
        let score = 0.5 * clamp(impact) + 0.3 * clamp(breadth) + 0.2 * clamp(persistence)
        switch score {
        case ..<1.6: return .info
        case ..<2.4: return .low
        case ..<3.2: return .medium
        case ..<4.1: return .high
        default: return .critical
        }
    }
}

/// Where a finding applies.
public enum FindingSubject: Codable, Sendable, Hashable {
    case device
    case application(BundleIdentifier)
    case domain(NormalizedHost)

    public var key: String {
        switch self {
        case .device: "device"
        case .application(let bundleID): "app:\(bundleID.rawValue)"
        case .domain(let host): "domain:\(host.value)"
        }
    }

    public var displayValue: String {
        switch self {
        case .device: "This device"
        case .application(let bundleID): bundleID.rawValue
        case .domain(let host): host.displayValue
        }
    }
}

/// Lifecycle of a finding across imports (DET-010).
public enum FindingStatus: String, Codable, Sendable, Hashable {
    case new
    case recurring
    case resolved
    case ignored
    case accepted
    case stale
    case superseded
}

/// A deterministic, evidence-backed conclusion.
public struct Finding: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let ruleID: String
    public let ruleVersion: String
    public let titleKey: String
    public let title: String
    public let subject: FindingSubject
    public let severity: Severity
    public let confidence: Double
    public var status: FindingStatus
    public let observedFacts: [ObservedFact]
    public let inferences: [Inference]
    /// What this finding explicitly does *not* establish (DET-003, DET-007).
    public let uncertainty: [String]
    public let evidenceIDs: [String]
    public let recommendationIDs: [String]
    public let categoryKeys: [String]
    public let createdAt: Date
    public let supersedes: String?
    /// True when the knowledge base that produced it has expired (KB-006).
    public let isStale: Bool

    public init(
        id: String,
        ruleID: String,
        ruleVersion: String,
        titleKey: String,
        title: String,
        subject: FindingSubject,
        severity: Severity,
        confidence: Double,
        status: FindingStatus = .new,
        observedFacts: [ObservedFact],
        inferences: [Inference],
        uncertainty: [String],
        evidenceIDs: [String],
        recommendationIDs: [String],
        categoryKeys: [String],
        createdAt: Date,
        supersedes: String? = nil,
        isStale: Bool = false
    ) {
        self.id = id
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.titleKey = titleKey
        self.title = title
        self.subject = subject
        self.severity = severity
        self.confidence = confidence
        self.status = status
        self.observedFacts = observedFacts
        self.inferences = inferences
        self.uncertainty = uncertainty
        self.evidenceIDs = evidenceIDs
        self.recommendationIDs = recommendationIDs
        self.categoryKeys = categoryKeys
        self.createdAt = createdAt
        self.supersedes = supersedes
        self.isStale = isStale
    }

    /// Stable across runs: the same rule over the same evidence always produces
    /// the same identifier, which is what makes new/recurring/resolved
    /// meaningful across imports (DET-010, DET-012).
    public static func makeID(ruleID: String, ruleVersion: String, subject: FindingSubject, evidenceIDs: [String]) -> String {
        var hasher = FireHasher()
        hasher.update(ruleID)
        hasher.update("\u{1F}")
        hasher.update(ruleVersion)
        hasher.update("\u{1F}")
        hasher.update(subject.key)
        hasher.update("\u{1F}")
        hasher.update(evidenceIDs.sorted().joined(separator: ","))
        return "f_" + String(hasher.finalize().hexString.prefix(24))
    }
}
