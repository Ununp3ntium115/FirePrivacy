import Foundation

/// Observed dimensions, each on a 0–100 scale. Exposure values are not probabilities of harm.
public struct PostureScores: Codable, Equatable, Sendable {
    public let version: String
    public let sensorExposure: Double
    public let thirdPartyReach: Double?
    public let aggregationSignals: Double
    public let repetition: Double
    public let controlGap: Double
    public let evidenceConfidence: Double?
    public let classificationCoverage: Double
    /// An explicitly requested summary of observed dimensions, never a safety grade.
    public let privacyPosture: Int?
    public let explanation: [String: String]
    public init(version: String = "scores-2.0.0", sensorExposure: Double, thirdPartyReach: Double?,
                aggregationSignals: Double, repetition: Double, controlGap: Double,
                evidenceConfidence: Double?, classificationCoverage: Double, privacyPosture: Int?,
                explanation: [String: String]) {
        self.version = version; self.sensorExposure = sensorExposure; self.thirdPartyReach = thirdPartyReach
        self.aggregationSignals = aggregationSignals; self.repetition = repetition; self.controlGap = controlGap
        self.evidenceConfidence = evidenceConfidence; self.classificationCoverage = classificationCoverage
        self.privacyPosture = privacyPosture; self.explanation = explanation
    }
}

public enum PostureCalculator {
    public static func evaluate(report: PrivacyReport, findings: [RuleFinding], context: FindingContext) -> PostureScores {
        let sensors = report.observations.filter { $0.category == .sensor }
        let contacts = report.observations.filter { $0.category == .network && $0.domain != nil && $0.count > 0 }
        let groups = Dictionary(grouping: contacts, by: { $0.domain! })
        var sensorTotal = 0.0
        // A begin/end pair is counted once here when the report supplies both for the same app/category.
        // The dimension uses unique categories per app, avoiding false frequency claims from event records.
        let sensorGroups = Dictionary(grouping: sensors, by: { $0.bundleID + "\u{0}" + $0.sensorCategory })
        for records in sensorGroups.values {
            guard let first = records.first else { continue }
            var weight = sensorWeight(first.sensorCategory)
            if context.permissionAudit.entry(bundleID: first.bundleID, category: first.sensorCategory)?.isExpected == true { weight *= 0.5 }
            sensorTotal += weight
        }
        let sensorExposure = rounded(100 * (1 - exp(-sensorTotal / 120)))

        let reviewed = groups.keys.compactMap { domain -> ReviewedDomainContext? in context.reviewedDomain(domain) }
        let coverage = groups.isEmpty ? 0 : Double(reviewed.count) / Double(groups.count)
        var weightedReach = 0.0
        var reachMagnitude = 0.0
        var verifiedThirdPartyCount = 0
        for knowledge in reviewed {
            guard let records = groups[knowledge.domain] else { continue }
            guard knowledge.categories.contains(where: { $0 != .unknown }) else { continue }
            let apps = Set(records.map(\.bundleID))
            guard !apps.allSatisfy({ knowledge.firstPartyBundleIDs.contains($0) }) else { continue }
            // Domain classification alone does not establish the relationship to the contacting app.
            guard apps.allSatisfy({ knowledge.thirdPartyBundleIDs.contains($0) }) else { continue }
            verifiedThirdPartyCount += 1
            let magnitude = log1p(Double(sumContacts(records)))
            weightedReach += categoryWeight(knowledge.categories) * magnitude
            reachMagnitude += magnitude
        }
        let thirdPartyReach: Double? = verifiedThirdPartyCount == 0 ? nil : rounded(reachMagnitude > 0 ? 100 * weightedReach / reachMagnitude : 0)
        let shared = findings.contains { $0.ruleID == "AGG-CROSSAPP-002" }
        let highImpact = findings.contains { $0.ruleID == "VENDOR-KNOWN-006" }
        // At most one contribution per independent rule family, never per duplicate evidence record.
        let aggregation = rounded(100 * (1 - (shared ? 0.75 : 1) * (highImpact ? 0.65 : 1)))
        let hits = sumContacts(contacts)
        let repetition = rounded(100 * min(1, log1p(Double(hits)) / log(100_001)))
        let reviewedSensors = sensorGroups.values.filter { records in
            guard let first = records.first else { return false }
            return context.permissionAudit.entry(bundleID: first.bundleID, category: first.sensorCategory) != nil
        }.count
        var controlGap = sensorGroups.isEmpty ? 0 : 50 * (1 - Double(reviewedSensors) / Double(sensorGroups.count))
        if findings.contains(where: { $0.ruleID == "COVERAGE-GAP-007" }) { controlGap += 25 }
        if findings.contains(where: { $0.ruleID == "FRESHNESS-008" }) { controlGap += 15 }
        if findings.contains(where: \.isStale) { controlGap += 10 }
        controlGap = rounded(controlGap)
        let confidence = findings.isEmpty ? nil : rounded(100 * findings.reduce(0) { $0 + $1.confidence } / Double(findings.count))

        // With incomplete reviewed coverage, an overall score would manufacture certainty about unknowns.
        var overall: Int?
        let relationshipCoverage = groups.keys.allSatisfy { domain in
            guard let knowledge = context.reviewedDomain(domain), let records = groups[domain] else { return false }
            guard knowledge.categories.contains(where: { $0 != .unknown }),
                  !(knowledge.expiresAt.map { $0 <= context.now } ?? false) else { return false }
            return records.allSatisfy { knowledge.firstPartyBundleIDs.contains($0.bundleID) || knowledge.thirdPartyBundleIDs.contains($0.bundleID) }
        }
        if context.includeOverallScore && !report.observations.isEmpty && (groups.isEmpty || (coverage == 1 && relationshipCoverage)) {
            let exposure = 0.24 * sensorExposure + 0.24 * (thirdPartyReach ?? 0)
                + 0.24 * aggregation + 0.14 * repetition + 0.14 * controlGap
            overall = Int(max(0, min(100, (100 - exposure).rounded())))
        }
        return .init(sensorExposure: sensorExposure, thirdPartyReach: thirdPartyReach,
            aggregationSignals: aggregation, repetition: repetition, controlGap: controlGap,
            evidenceConfidence: confidence, classificationCoverage: rounded(100 * coverage), privacyPosture: overall,
            explanation: [
                "sensorExposure": "Unique app/category pairs: \(sensorGroups.count). Location 22, microphone 22, camera 18, contacts 18, photos 12, other 10; user-marked expected access halves the weight. 100 × (1 − exp(−weight/120)). Event-record count is not access duration.",
                "thirdPartyReach": "Only \(reviewed.count) of \(groups.count) destinations have verified reviewed classifications; \(verifiedThirdPartyCount) have a verified third-party relationship to every contacting app. Category-weighted log(1 + contacts), normalized over those verified third parties. Unknown ownership or relationship is excluded; no verified third-party data means no score.",
                "aggregationSignals": "Shared-destination rule contributes 0.25; reviewed high-impact-service rule contributes 0.35. 100 × (1 − product(1 − contributions)); this is a review signal, not proof that activity was linked.",
                "repetition": "100 × min(1, log(1 + \(hits) contacts)/log(100001)). Contacts measure frequency, not data volume or background activity.",
                "controlGap": "Up to 50 points for app/category pairs without a manual review, 25 for available inactive filtering, 15 for an old report, 10 for expired knowledge. Missing review does not mean denied protection.",
                "evidenceConfidence": "Mean of \(findings.count) finding-confidence values. Repeated evidence does not increase a finding's confidence; no findings means unknown confidence.",
                "privacyPosture": "Optional: 100 − (0.24×sensor + 0.24×reviewed reach + 0.24×aggregation + 0.14×repetition + 0.14×control gap). Hidden without full reviewed classification and app-relationship coverage or observations. It is not a safety grade.",
                "limits": "All dimensions describe the imported window. Absence of observations is not evidence of absence, and Fire Privacy cannot see transmitted contents or current permissions."
            ])
    }

    private static func sensorWeight(_ category: String) -> Double {
        switch category { case "location", "microphone": 22; case "camera", "contacts": 18; case "photos": 12; default: 10 }
    }
    private static func categoryWeight(_ categories: [ReviewedDomainCategory]) -> Double {
        categories.map { category in
            switch category {
            case .advertising, .dataBroker: 1.0
            case .locationIntelligence: 0.95
            case .attribution: 0.9
            case .personalization: 0.8
            case .social: 0.7
            case .analytics: 0.65
            case .telemetry: 0.5
            case .messaging: 0.45
            case .content, .crashReporting: 0.3
            case .pushNotifications: 0.2
            case .payments, .authentication, .fraudPrevention, .dnsResolution: 0.15
            case .contentDelivery: 0.1
            case .unknown: 0
            }
        }.max() ?? 0
    }
    private static func rounded(_ value: Double) -> Double { (max(0, min(100, value)) * 10).rounded() / 10 }
}
