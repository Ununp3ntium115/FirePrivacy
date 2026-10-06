import Foundation

public enum FindingSeverity: String, Codable, Equatable, Sendable, Comparable, CaseIterable {
    case info, low, medium, high, critical
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public var displayName: String { rawValue.capitalized }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum FindingSubject: Codable, Equatable, Sendable {
    case report, app(String), domain(String)
    public var key: String {
        switch self { case .report: "report"; case .app(let id): "app:\(id)"; case .domain(let id): "domain:\(id)" }
    }
}

public struct FindingFact: Codable, Equatable, Sendable {
    public let key: String
    public let value: String
    public let evidenceIDs: [UUID]
    public init(key: String, value: String, evidenceIDs: [UUID]) {
        self.key = key; self.value = value; self.evidenceIDs = evidenceIDs
    }
}

public struct FindingInference: Codable, Equatable, Sendable {
    public let statement: String
    public let basis: [UUID]
    public let confidence: Double
    public init(statement: String, basis: [UUID], confidence: Double) {
        self.statement = statement; self.basis = basis; self.confidence = boundedConfidence(confidence)
    }
}

public enum RuleFindingStatus: String, Codable, Equatable, Sendable {
    case new, recurring, accepted, ignored, stale, superseded, notObservedInLatestReport
    public var displayName: String {
        switch self {
        case .new: "New"
        case .recurring: "Observed again"
        case .accepted: "Reviewed: no change"
        case .ignored: "Hidden by you"
        case .stale: "Knowledge may be outdated"
        case .superseded: "Replaced by newer evidence"
        case .notObservedInLatestReport: "Not observed in the latest report"
        }
    }
}

/// Facts remain separate from interpretations and priorities. Confidence is never a safety grade.
public struct RuleFinding: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let ruleID: String
    public let ruleVersion: String
    public let title: String
    public let detail: String
    public let subject: FindingSubject
    public let severity: FindingSeverity
    public let confidence: Double
    public let observedFacts: [FindingFact]
    public let inferences: [FindingInference]
    public let uncertainty: [String]
    public let evidenceIDs: [UUID]
    public let actionIDs: [String]
    public let categoryKeys: [String]
    public let profileRelevance: Double
    public let isStale: Bool
    public let knowledgeSources: [String]
    public let status: RuleFindingStatus

    public init(id: String, ruleID: String, ruleVersion: String, title: String, detail: String,
                subject: FindingSubject, severity: FindingSeverity, confidence: Double,
                observedFacts: [FindingFact], inferences: [FindingInference] = [],
                uncertainty: [String], evidenceIDs: [UUID], actionIDs: [String],
                categoryKeys: [String] = [], profileRelevance: Double = 1, isStale: Bool = false,
                knowledgeSources: [String] = [], status: RuleFindingStatus = .new) {
        self.id = id; self.ruleID = ruleID; self.ruleVersion = ruleVersion
        self.title = title; self.detail = detail; self.subject = subject; self.severity = severity
        self.confidence = boundedConfidence(confidence); self.observedFacts = observedFacts
        self.inferences = inferences; self.uncertainty = uncertainty; self.evidenceIDs = evidenceIDs
        self.actionIDs = actionIDs; self.categoryKeys = categoryKeys
        self.profileRelevance = profileRelevance.isFinite ? max(0, min(3, profileRelevance)) : 1
        self.isStale = isStale; self.knowledgeSources = knowledgeSources
        self.status = status
    }

    public var lifecycleKey: String {
        let components = [ruleID, subject.key] + categoryKeys.sorted()
        return ContentDigest.sha256((try? JSONEncoder().encode(components)) ?? Data())
    }

    public func withStatus(_ status: RuleFindingStatus) -> RuleFinding {
        .init(id: id, ruleID: ruleID, ruleVersion: ruleVersion, title: title, detail: detail,
              subject: subject, severity: severity, confidence: confidence, observedFacts: observedFacts,
              inferences: inferences, uncertainty: uncertainty, evidenceIDs: evidenceIDs, actionIDs: actionIDs,
              categoryKeys: categoryKeys, profileRelevance: profileRelevance, isStale: isStale,
              knowledgeSources: knowledgeSources, status: status)
    }
}

public struct FindingLifecycleResult: Codable, Equatable, Sendable {
    public let current: [RuleFinding]
    public let previousOnly: [RuleFinding]
}

public enum FindingLifecycle {
    /// Absence in a new export is deliberately not labeled "resolved" or "safe".
    public static func compare(previous: FindingAnalysis?, current: FindingAnalysis,
                               acceptedKeys: Set<String> = [], ignoredKeys: Set<String> = []) -> FindingLifecycleResult {
        let previousFindings = previous?.findings ?? []
        let priorKeys = Set(previousFindings.map(\.lifecycleKey))
        let currentIDs = Set(current.findings.map(\.id))
        let currentKeys = Set(current.findings.map(\.lifecycleKey))
        let active = current.findings.map { finding -> RuleFinding in
            let status: RuleFindingStatus
            if acceptedKeys.contains(finding.lifecycleKey) { status = .accepted }
            else if ignoredKeys.contains(finding.lifecycleKey) { status = .ignored }
            else if finding.isStale { status = .stale }
            else { status = priorKeys.contains(finding.lifecycleKey) ? .recurring : .new }
            return finding.withStatus(status)
        }
        let previousOnly = previousFindings.filter { !currentIDs.contains($0.id) }.map { finding in
            finding.withStatus(currentKeys.contains(finding.lifecycleKey) ? .superseded : .notObservedInLatestReport)
        }
        return .init(current: active, previousOnly: previousOnly)
    }
}

public struct FindingAnalysis: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let rulesetVersion: String
    public let findings: [RuleFinding]
    public let scores: PostureScores
    public init(reportID: UUID, rulesetVersion: String, findings: [RuleFinding], scores: PostureScores) {
        self.reportID = reportID; self.rulesetVersion = rulesetVersion
        self.findings = findings; self.scores = scores
    }
}

public enum ReviewedDomainCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case advertising, analytics, attribution, telemetry, crashReporting, contentDelivery
    case authentication, payments, fraudPrevention, pushNotifications, dnsResolution, content, messaging
    case social, personalization, dataBroker, locationIntelligence, unknown
    public var isInfrastructure: Bool {
        [.contentDelivery, .authentication, .payments, .fraudPrevention, .pushNotifications, .dnsResolution].contains(self)
    }
    public var isHighImpact: Bool { self == .dataBroker || self == .locationIntelligence }
}

/// Supplied only after the signed knowledge base's trust and source checks succeed.
/// Raw report owner/type fields cannot construct a reviewed classification implicitly.
public struct ReviewedDomainContext: Codable, Equatable, Sendable {
    public let domain: String
    public let organization: String?
    public let categories: [ReviewedDomainCategory]
    public let sourceURLs: [String]
    public let knowledgeBaseVersion: String
    public let isVerified: Bool
    public let expiresAt: Date?
    public let firstPartyBundleIDs: [String]
    public let thirdPartyBundleIDs: [String]
    public let evidenceConfidence: Double
    public init(domain: String, organization: String? = nil, categories: [ReviewedDomainCategory],
                sourceURLs: [String], knowledgeBaseVersion: String, isVerified: Bool,
                expiresAt: Date? = nil, firstPartyBundleIDs: [String] = [], thirdPartyBundleIDs: [String] = [],
                evidenceConfidence: Double = 0.85) {
        self.domain = domain; self.organization = organization; self.categories = categories
        self.sourceURLs = sourceURLs; self.knowledgeBaseVersion = knowledgeBaseVersion
        self.isVerified = isVerified; self.expiresAt = expiresAt; self.firstPartyBundleIDs = firstPartyBundleIDs
        self.thirdPartyBundleIDs = thirdPartyBundleIDs
        self.evidenceConfidence = boundedConfidence(evidenceConfidence)
    }
    public var hasReviewedSources: Bool {
        isVerified && !sourceURLs.isEmpty && sourceURLs.allSatisfy {
            guard let url = URL(string: $0), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
            return true
        }
    }
}

public struct FindingProtectionContext: Codable, Equatable, Sendable {
    public let urlFilterAvailable: Bool
    public let urlFilterActive: Bool
    public let safariBlockerAvailable: Bool
    public let safariBlockerActive: Bool
    public init(urlFilterAvailable: Bool = false, urlFilterActive: Bool = false,
                safariBlockerAvailable: Bool = false, safariBlockerActive: Bool = false) {
        self.urlFilterAvailable = urlFilterAvailable; self.urlFilterActive = urlFilterActive
        self.safariBlockerAvailable = safariBlockerAvailable; self.safariBlockerActive = safariBlockerActive
    }
}

public struct FindingContext: Sendable {
    public let now: Date
    public let profile: PrivacyProfile
    public let permissionAudit: ManualPermissionAudit
    public let reviewedDomains: [ReviewedDomainContext]
    /// Verified publisher identities only; a reverse-DNS bundle prefix is not an identity.
    public let appPublisherIDs: [String: String]
    public let domainOverrides: DomainOverrideSet
    public let protection: FindingProtectionContext
    public let includeOverallScore: Bool
    public init(now: Date = Date(), profile: PrivacyProfile = .balanced,
                permissionAudit: ManualPermissionAudit = .init(),
                reviewedDomains: [ReviewedDomainContext] = [], appPublisherIDs: [String: String] = [:],
                domainOverrides: DomainOverrideSet = .init(),
                protection: FindingProtectionContext = .init(), includeOverallScore: Bool = false) {
        self.now = now; self.profile = profile; self.permissionAudit = permissionAudit
        self.reviewedDomains = reviewedDomains; self.appPublisherIDs = appPublisherIDs
        self.domainOverrides = domainOverrides
        self.protection = protection; self.includeOverallScore = includeOverallScore
    }
    public func reviewedDomain(_ domain: String) -> ReviewedDomainContext? {
        let matching = reviewedDomains.filter { $0.domain == domain && $0.hasReviewedSources }
        // Conflicting duplicates fail closed rather than selecting an arbitrary owner.
        guard let first = matching.first, matching.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

public extension DomainMatcher {
    /// Convert only verified, reviewed matches to rule inputs. No report owner field grants trust.
    func findingContexts(for report: PrivacyReport, now: Date = Date(),
                         firstPartyApps: [String: [String]] = [:], thirdPartyApps: [String: [String]] = [:]) -> [ReviewedDomainContext] {
        let hosts = Set(report.observations.filter { $0.category == .network }.compactMap(\.domain)).sorted()
        return hosts.compactMap { host in
            let allMatches = matches(for: host, now: now)
            // A disputed or provisional most-specific record must not fall back to a broad reviewed parent.
            guard let best = allMatches.first, best.classification.reviewStatus == .reviewed,
                  !best.classification.isHeuristicOnly, !best.sources.isEmpty else { return nil }
            let snapshotExpiry = Date(timeIntervalSince1970: Double(snapshot.manifest.expiresAt))
            let expiry = min(snapshotExpiry, best.classification.expiresAt ?? snapshotExpiry)
            return ReviewedDomainContext(domain: host, organization: best.classification.organization,
                categories: best.classification.categories.compactMap { ReviewedDomainCategory(rawValue: $0.rawValue) },
                sourceURLs: best.sources.map(\.url).sorted(), knowledgeBaseVersion: snapshot.version,
                isVerified: true, expiresAt: expiry, firstPartyBundleIDs: firstPartyApps[host] ?? [],
                thirdPartyBundleIDs: thirdPartyApps[host] ?? [], evidenceConfidence: best.evidenceConfidence)
        }
    }
}

func boundedConfidence(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

enum FindingUncertainty {
    static let payload = "A contact records a destination, not what data was sent or whether any contact was harmful."
    static let permission = "Exported sensor events do not reveal another app's current permission state."
    static let purpose = "A domain classification describes reviewed service information, not the purpose or contents of this contact."
    static let unknown = "Unknown ownership or classification means unknown, not dangerous."
}
