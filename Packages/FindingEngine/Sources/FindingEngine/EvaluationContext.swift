import Foundation
import ObservationCore
import KnowledgeBaseKit
import PrivacyProfileKit

/// What protection is currently doing, as far as the rules need to know.
///
/// Declared here rather than imported from ProtectionKit so the engine stays
/// free of Network Extension types and can be evaluated in tests and on any
/// platform.
public struct ProtectionCoverage: Sendable, Hashable {
    public let urlFilterIsActive: Bool
    public let urlFilterProfileName: String?
    public let filterDatasetVersion: String?
    public let safariBlockerIsActive: Bool
    public let encryptedDNSIsActive: Bool
    /// Major iOS version of the device, used to decide which recommendations
    /// are even possible (AI-007).
    public let osMajorVersion: Int

    public init(
        urlFilterIsActive: Bool = false,
        urlFilterProfileName: String? = nil,
        filterDatasetVersion: String? = nil,
        safariBlockerIsActive: Bool = false,
        encryptedDNSIsActive: Bool = false,
        osMajorVersion: Int = 18
    ) {
        self.urlFilterIsActive = urlFilterIsActive
        self.urlFilterProfileName = urlFilterProfileName
        self.filterDatasetVersion = filterDatasetVersion
        self.safariBlockerIsActive = safariBlockerIsActive
        self.encryptedDNSIsActive = encryptedDNSIsActive
        self.osMajorVersion = osMajorVersion
    }

    public var supportsURLFilter: Bool { osMajorVersion >= 26 }
}

/// Everything one evaluation sees. Rules read only from here, which is what
/// makes an evaluation reproducible (DET-012).
public struct FindingEvaluationContext: Sendable {
    public let index: AnalysisIndex
    public let knowledgeBaseVersion: KnowledgeBaseVersion
    public let knowledgeBaseIsStale: Bool
    public let profile: PrivacyProfile
    public let overrides: DomainOverrideSet
    public let permissions: SelfReportedPermissionSet
    public let protection: ProtectionCoverage
    /// Fixed for the whole evaluation so every finding in a run agrees about
    /// "now".
    public let now: Date

    public init(
        index: AnalysisIndex,
        knowledgeBaseVersion: KnowledgeBaseVersion,
        knowledgeBaseIsStale: Bool,
        profile: PrivacyProfile,
        overrides: DomainOverrideSet,
        permissions: SelfReportedPermissionSet,
        protection: ProtectionCoverage,
        now: Date
    ) {
        self.index = index
        self.knowledgeBaseVersion = knowledgeBaseVersion
        self.knowledgeBaseIsStale = knowledgeBaseIsStale
        self.profile = profile
        self.overrides = overrides
        self.permissions = permissions
        self.protection = protection
        self.now = now
    }

    public var snapshot: ObservationSnapshot { index.snapshot }
}

/// A rule's output: findings plus the evidence they cite.
public struct RuleOutput: Sendable {
    public var findings: [Finding]
    public var evidence: [Evidence]

    public init(findings: [Finding] = [], evidence: [Evidence] = []) {
        self.findings = findings
        self.evidence = evidence
    }

    public mutating func merge(_ other: RuleOutput) {
        findings.append(contentsOf: other.findings)
        evidence.append(contentsOf: other.evidence)
    }
}

/// A deterministic, versioned rule (DET-001).
public protocol DetectionRule: Sendable {
    var id: String { get }
    var version: String { get }
    func evaluate(_ context: FindingEvaluationContext) -> RuleOutput
}

/// Builds the evidence records rules cite. Centralized so that every rule
/// describes the same observation the same way.
public enum EvidenceFactory {
    public static func network(_ observation: NetworkObservation) -> Evidence {
        var detail: [String: String] = [
            "host": observation.host.value,
            "registrable_domain": observation.ownerKey.value,
        ]
        if let bundleID = observation.bundleID { detail["bundle_id"] = bundleID.rawValue }
        if let hits = observation.hits { detail["contact_count"] = String(hits) }
        if let owner = observation.domainOwner { detail["reported_owner"] = owner.value }
        if let initiated = observation.initiatedType { detail["initiated_type"] = initiated.value }
        if let context = observation.context { detail["web_context"] = context.value }
        if observation.mergedRecordCount > 1 { detail["report_lines"] = String(observation.mergedRecordCount) }
        if !observation.normalizationWarnings.identifiers.isEmpty {
            detail["normalization"] = observation.normalizationWarnings.identifiers.joined(separator: ",")
        }

        let appLabel = observation.bundleID?.rawValue ?? "an app the report did not name"
        let hitText = observation.hits.map { " \($0) time\($0 == 1 ? "" : "s")" } ?? ""
        return Evidence(
            id: observation.evidenceID,
            kind: .appleNetworkObservation,
            summary: "Apple's report records \(appLabel) contacting \(observation.host.displayValue)\(hitText).",
            confidence: EvidenceKind.appleNetworkObservation.baseConfidence,
            observationIDs: [observation.id],
            sourceLineNumbers: [observation.sourceLineNumber],
            detail: detail
        )
    }

    public static func sensor(_ observation: SensorObservation) -> Evidence {
        var detail: [String: String] = ["sensor": observation.sensorType.identifier]
        if let bundleID = observation.bundleID { detail["bundle_id"] = bundleID.rawValue }
        if let count = observation.count { detail["access_count"] = String(count) }
        if let first = observation.firstTimestamp { detail["first_observed"] = ISO8601DateFormatter().string(from: first) }
        if let last = observation.lastTimestamp { detail["last_observed"] = ISO8601DateFormatter().string(from: last) }

        let appLabel = observation.bundleID?.rawValue ?? "an app the report did not name"
        let countText = observation.count.map { " \($0) time\($0 == 1 ? "" : "s")" } ?? ""
        return Evidence(
            id: observation.evidenceID,
            kind: .appleSensorObservation,
            summary: "Apple's report records \(appLabel) accessing \(observation.sensorType.identifier)\(countText) during the report window.",
            confidence: EvidenceKind.appleSensorObservation.baseConfidence,
            observationIDs: [observation.id],
            sourceLineNumbers: [observation.sourceLineNumber],
            detail: detail
        )
    }

    public static func appleClassification(_ observation: NetworkObservation) -> Evidence {
        var detail: [String: String] = ["host": observation.host.value]
        if let value = observation.domainType.rawValue { detail["domain_type"] = String(value) }
        if let label = observation.domainType.rawLabel { detail["domain_classification"] = label.value }
        return Evidence(
            id: "apple-class:\(observation.sourceLineHash.shortHexString)",
            kind: .appleDomainClassification,
            summary: "Apple's own report marks \(observation.host.displayValue) as a domain that may collect information about you across apps and websites.",
            confidence: EvidenceKind.appleDomainClassification.baseConfidence,
            observationIDs: [observation.id],
            sourceLineNumbers: [observation.sourceLineNumber],
            detail: detail
        )
    }

    public static func knowledgeBase(_ match: DomainMatch, host: NormalizedHost) -> Evidence {
        var detail: [String: String] = [
            "pattern": match.classification.pattern,
            "match_kind": match.isExactMatch ? "exact_host" : "domain_suffix",
            "categories": match.classification.categories.map(\.rawValue).joined(separator: ","),
            "review_status": match.classification.reviewStatus.rawValue,
            "source_type": match.classification.sourceType.rawValue,
            "last_reviewed": ISO8601DateFormatter().string(from: match.classification.lastReviewed),
        ]
        if let organization = match.classification.organization { detail["organization"] = organization }
        if let sdk = match.classification.sdkFamily { detail["sdk_family"] = sdk }
        if !match.sources.isEmpty {
            detail["sources"] = match.sources.map(\.title).joined(separator: "; ")
        }
        if match.classification.isHeuristicOnly { detail["provenance"] = "heuristic_only" }

        let organization = match.classification.organization ?? "an unidentified operator"
        let categories = match.classification.categories.map(\.displayName).joined(separator: ", ")
        return Evidence(
            id: "kb:\(match.classification.id)@\(host.value)",
            kind: .knowledgeBaseMatch,
            summary: "Fire Privacy's knowledge base records \(host.displayValue) as \(organization) infrastructure used for: \(categories).",
            confidence: match.evidenceConfidence,
            knowledgeBaseRuleIDs: [match.classification.id],
            detail: detail
        )
    }

    public static func crossApp(_ group: DomainGroup) -> Evidence {
        let apps = group.bundleIDs.sorted().map(\.rawValue)
        return Evidence(
            id: "xapp:\(group.key.value)",
            kind: .crossAppRecurrence,
            summary: "In this one report, \(group.key.displayValue) was contacted by \(apps.count) apps from \(group.unrelatedPublisherCount) unrelated publishers.",
            confidence: EvidenceKind.crossAppRecurrence.baseConfidence,
            observationIDs: group.observations.map(\.id),
            sourceLineNumbers: group.observations.map(\.sourceLineNumber).sorted(),
            detail: [
                "apps": apps.joined(separator: ","),
                "publishers": String(group.unrelatedPublisherCount),
                "total_contacts": String(group.totalHits),
                "web_context_contacts": String(group.webContextCount),
            ]
        )
    }

    public static func userPermission(_ entry: SelfReportedPermission) -> Evidence {
        Evidence(
            id: "perm:\(entry.bundleID.rawValue)|\(entry.sensorType.identifier)",
            kind: .userReportedPermission,
            summary: "You recorded this access as \(entry.isExpected == false ? "unexpected" : "reviewed"), with the permission set to \(entry.state.displayName).",
            confidence: EvidenceKind.userReportedPermission.baseConfidence,
            detail: [
                "state": entry.state.rawValue,
                "expected": entry.isExpected.map(String.init) ?? "unknown",
                "recorded_at": ISO8601DateFormatter().string(from: entry.recordedAt),
                "source": "user_entered",
            ]
        )
    }

    public static func protectionState(_ coverage: ProtectionCoverage) -> Evidence {
        Evidence(
            id: "protection:url-filter",
            kind: .protectionStatus,
            summary: coverage.urlFilterIsActive
                ? "Fire Privacy's system URL filter is on."
                : "Fire Privacy's system URL filter is off.",
            confidence: EvidenceKind.protectionStatus.baseConfidence,
            detail: [
                "url_filter_active": String(coverage.urlFilterIsActive),
                "supported": String(coverage.supportsURLFilter),
                "dataset_version": coverage.filterDatasetVersion ?? "none",
            ]
        )
    }
}
