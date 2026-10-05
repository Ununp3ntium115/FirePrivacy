import Foundation

public struct DetectionRuleDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let version: String
    public let explanation: String
    public init(id: String, version: String = "2.0.0", explanation: String) {
        self.id = id; self.version = version; self.explanation = explanation
    }
}

public enum VersionedRuleSet {
    public static let version = "ruleset-2.0.0"
    public static let all: [DetectionRuleDescriptor] = [
        .init(id: "AGG-APPLE-001", explanation: "Preserve Apple's reported classification values without guessing undocumented numeric meanings."),
        .init(id: "AGG-CROSSAPP-002", explanation: "A destination appears in at least three apps; distinguish app counts from verified publisher identities."),
        .init(id: "LOC-NET-003", explanation: "Location events and a reviewed location-data service appear under the same app in the export."),
        .init(id: "SENSOR-UNEXPECTED-004", explanation: "The user explicitly marked an observed sensor category as unexpected."),
        .init(id: "UNKNOWN-HIGHFANOUT-005", explanation: "At least ten destinations and less than 40% reviewed classification coverage."),
        .init(id: "VENDOR-KNOWN-006", explanation: "A cited, verified, reviewed high-impact service appears in recorded contacts."),
        .init(id: "COVERAGE-GAP-007", explanation: "A working optional filter is available but inactive for reviewed candidate destinations."),
        .init(id: "FRESHNESS-008", explanation: "The latest known activity, or import when activity time is unknown, is more than fourteen days old.")
    ]
}

/// Deterministic analysis. It neither reads system permissions nor establishes what was transmitted.
public enum VersionedFindingEngine {
    public static func evaluate(report: PrivacyReport, context: FindingContext = .init()) -> FindingAnalysis {
        let network = report.observations.filter { $0.category == .network && $0.domain != nil && $0.count > 0 }
        let groups = Dictionary(grouping: network, by: { $0.domain! })
        let appGroups = Dictionary(grouping: report.observations, by: \.bundleID)
        var findings: [RuleFinding] = []

        // Apple's fields are preserved as observed facts. Numeric encodings have no inferred meaning.
        for domain in groups.keys.sorted() {
            let records = sortedEvidence(groups[domain]!)
            let flagged = records.filter { record in
                [record.domainClassification, record.domainType].contains { value in
                    guard let value else { return false }
                    if case .null = value { return false }
                    return true
                }
            }
            guard !flagged.isEmpty else { continue }
            let facts = flagged.prefix(8).flatMap { record -> [FindingFact] in
                var result: [FindingFact] = []
                if let value = record.domainClassification {
                    result.append(.init(key: "reported_domain_classification", value: value.displayValue, evidenceIDs: [record.id]))
                }
                if let value = record.domainType {
                    result.append(.init(key: "reported_domain_type", value: value.displayValue, evidenceIDs: [record.id]))
                }
                return result
            }
            findings.append(makeFinding(ruleID: "AGG-APPLE-001", subject: .domain(domain),
                title: "Reported classification for \(domain)",
                detail: "The export includes domain classification or type fields. Their original values are shown with the source records.",
                severity: .info, confidence: 0.98, records: flagged, facts: facts,
                uncertainty: ["An undocumented value is not interpreted as tracking, aggregation, ownership, or harm.", FindingUncertainty.payload],
                actions: [ActionCatalog.reviewDomain.id, ActionCatalog.learnLimits.id], categories: ["reported-classification"], context: context))
        }

        for domain in groups.keys.sorted() {
            let records = sortedEvidence(groups[domain]!)
            let apps = Set(records.map(\.bundleID)).sorted()
            let knowledge = context.reviewedDomain(domain)
            let isInfrastructure = knowledge.map { !$0.categories.isEmpty && $0.categories.allSatisfy(\.isInfrastructure) } ?? false
            guard apps.count >= 3, !isInfrastructure else { continue }
            let publishers = apps.compactMap { context.appPublisherIDs[$0] }
            let verifiedUnrelated = publishers.count == apps.count && Set(publishers).count >= 3
            var facts = [FindingFact(key: "apps", value: apps.joined(separator: ", "), evidenceIDs: records.map(\.id)),
                         FindingFact(key: "contacts", value: String(sumContacts(records)), evidenceIDs: records.map(\.id))]
            if verifiedUnrelated {
                facts.append(.init(key: "verified_publishers", value: String(Set(publishers).count), evidenceIDs: records.map(\.id)))
            }
            let inference = verifiedUnrelated
                ? "A shared destination across verified unrelated publishers is consistent with a service used across apps; this does not show that activity was linked."
                : "A shared destination is worth understanding, but the apps may share a publisher or ordinary infrastructure."
            findings.append(makeFinding(ruleID: "AGG-CROSSAPP-002", subject: .domain(domain),
                title: "\(domain) appears across \(apps.count) apps",
                detail: "The same destination appears under several app identifiers within this export.",
                severity: .low, confidence: verifiedUnrelated ? 0.8 : 0.65, records: records, facts: facts,
                inference: inference, uncertainty: [FindingUncertainty.payload, FindingUncertainty.purpose] + (knowledge == nil ? [FindingUncertainty.unknown] : []),
                actions: [ActionCatalog.reviewDomain.id, ActionCatalog.learnCrossApp.id, ActionCatalog.markExpected.id],
                categories: ["shared-destination"], knowledge: knowledge, context: context))
        }

        for app in appGroups.keys.sorted() {
            let allRecords = sortedEvidence(appGroups[app]!)
            let location = allRecords.filter { $0.category == .sensor && $0.sensorCategory == "location" }
            let locationContacts = allRecords.filter { record in
                guard record.category == .network, record.count > 0, let domain = record.domain,
                      let knowledge = context.reviewedDomain(domain) else { return false }
                return knowledge.categories.contains(.locationIntelligence)
            }
            if !location.isEmpty && !locationContacts.isEmpty {
                let domains = Set(locationContacts.compactMap(\.domain)).sorted()
                let evidence = location + locationContacts
                let knowledge = domains.compactMap { context.reviewedDomain($0) }
                findings.append(makeFinding(ruleID: "LOC-NET-003", subject: .app(app),
                    title: "Location events and reviewed location services",
                    detail: "\(app) has location event records and contacts with \(domains.joined(separator: ", ")) in the same export.",
                    severity: .medium, confidence: 0.75, records: evidence,
                    facts: [.init(key: "location_event_records", value: String(location.count), evidenceIDs: location.map(\.id)),
                            .init(key: "reviewed_location_destinations", value: domains.joined(separator: ", "), evidenceIDs: locationContacts.map(\.id))],
                    inference: "These two kinds of recorded activity can guide a review of why the app needs location access.",
                    uncertainty: ["Co-occurrence in an export does not establish timing, causation, or transmission of location.", FindingUncertainty.payload, FindingUncertainty.permission],
                    actions: [ActionCatalog.reviewLocation.id, ActionCatalog.reviewDomain.id, ActionCatalog.reviewApp.id],
                    categories: ["location", "locationIntelligence"], knowledgeList: knowledge, context: context))
            }

            let sensors = Dictionary(grouping: allRecords.filter { $0.category == .sensor }, by: \.sensorCategory)
            for category in sensors.keys.sorted() {
                guard let audit = context.permissionAudit.entry(bundleID: app, category: category), audit.isExpected == false else { continue }
                let records = sensors[category]!
                findings.append(makeFinding(ruleID: "SENSOR-UNEXPECTED-004", subject: .app(app), discriminator: category,
                    title: "You marked \(category) access as unexpected",
                    detail: "Your manual review marks \(app)'s recorded \(category) events as unexpected.",
                    severity: .medium, confidence: 0.9, records: records,
                    facts: [.init(key: "sensor_category", value: category, evidenceIDs: records.map(\.id)),
                            .init(key: "event_records", value: String(records.count), evidenceIDs: records.map(\.id)),
                            .init(key: "user_reported_expectation", value: "unexpected", evidenceIDs: [])],
                    uncertainty: ["The expectation is your own assessment, not a device permission reading.", FindingUncertainty.permission],
                    actions: [category == "location" ? ActionCatalog.reviewLocation.id : ActionCatalog.reviewSensor.id, ActionCatalog.reviewApp.id],
                    categories: [category], context: context))
            }

            let contacts = allRecords.filter { $0.category == .network && $0.domain != nil && $0.count > 0 }
            let domains = Set(contacts.compactMap(\.domain)).sorted()
            let reviewedCount = domains.filter { context.reviewedDomain($0) != nil }.count
            if domains.count >= 10 && Double(reviewedCount) / Double(domains.count) < 0.4 {
                findings.append(makeFinding(ruleID: "UNKNOWN-HIGHFANOUT-005", subject: .app(app),
                    title: "Many destinations remain unreviewed",
                    detail: "\(app) contacted \(domains.count) distinct destinations; \(domains.count - reviewedCount) have no verified reviewed classification in this analysis.",
                    severity: .low, confidence: 0.6, records: contacts,
                    facts: [.init(key: "distinct_destinations", value: String(domains.count), evidenceIDs: contacts.map(\.id)),
                            .init(key: "reviewed_destinations", value: String(reviewedCount), evidenceIDs: contacts.map(\.id))],
                    uncertainty: [FindingUncertainty.unknown, "These destinations are not assumed to be third parties or trackers.", FindingUncertainty.payload],
                    actions: [ActionCatalog.reviewDomain.id, ActionCatalog.learnLimits.id], categories: ["unknown"], context: context))
            }
        }

        var filterCandidates: [Observation] = []
        for domain in groups.keys.sorted() {
            guard let knowledge = context.reviewedDomain(domain) else { continue }
            let records = sortedEvidence(groups[domain]!)
            if knowledge.categories.contains(where: \.isHighImpact) {
                findings.append(makeFinding(ruleID: "VENDOR-KNOWN-006", subject: .domain(domain),
                    title: "A reviewed service appears in contacts",
                    detail: "Reviewed sources classify \(domain) as \(knowledge.categories.map(\.rawValue).sorted().joined(separator: ", ")). The export records contacts with that destination.",
                    severity: .medium, confidence: 0.85, records: records,
                    facts: [.init(key: "contacts", value: String(sumContacts(records)), evidenceIDs: records.map(\.id)),
                            .init(key: "reviewed_categories", value: knowledge.categories.map(\.rawValue).sorted().joined(separator: ", "), evidenceIDs: [])],
                    uncertainty: [FindingUncertainty.payload, FindingUncertainty.purpose],
                    actions: [ActionCatalog.reviewDomain.id, ActionCatalog.reviewApp.id],
                    categories: knowledge.categories.map(\.rawValue), knowledge: knowledge, context: context))
            }
            if knowledge.categories.contains(where: { [.advertising, .attribution, .dataBroker, .locationIntelligence].contains($0) }) {
                filterCandidates.append(contentsOf: records)
            }
        }

        // Availability describes a real working capability, not merely an API or OS version.
        if !filterCandidates.isEmpty &&
            ((context.protection.urlFilterAvailable && !context.protection.urlFilterActive) ||
             (context.protection.safariBlockerAvailable && !context.protection.safariBlockerActive)) {
            var actions: [String] = []
            if context.protection.urlFilterAvailable && !context.protection.urlFilterActive { actions.append(ActionCatalog.enableURLFilter.id) }
            if context.protection.safariBlockerAvailable && !context.protection.safariBlockerActive { actions.append(ActionCatalog.enableSafari.id) }
            findings.append(makeFinding(ruleID: "COVERAGE-GAP-007", subject: .report,
                title: "Review available filtering controls",
                detail: "Reviewed candidate destinations appear in this report, and an available optional filter is turned off.",
                severity: .low, confidence: 0.85, records: filterCandidates,
                facts: [.init(key: "candidate_destinations", value: String(Set(filterCandidates.compactMap(\.domain)).count), evidenceIDs: filterCandidates.map(\.id))],
                uncertainty: ["A category alone does not prove this destination appears in the installed block list.",
                              "Safari rules cover browser resources. URL filters cover supported networking; other apps may not participate.",
                              "Blocking can affect app or website features."],
                actions: actions, categories: ["protection"], context: context))
        }

        let datedRecords = report.observations.filter { observation in
            observation.timestamp != nil || observation.firstTimestamp != nil || observation.lastTimestamp != nil
        }
        let activityEnd = datedRecords.flatMap { [$0.timestamp, $0.firstTimestamp, $0.lastTimestamp].compactMap { $0 } }.max()
        let reference = activityEnd ?? report.importedAt
        let age = context.now.timeIntervalSince(reference)
        if age.isFinite && age > 14 * 86_400 {
            let days = min(Int.max / 2, Int(min(Double(Int.max / 2), age / 86_400)))
            findings.append(makeFinding(ruleID: "FRESHNESS-008", subject: .report,
                title: activityEnd == nil ? "This import is \(days) days old" : "Latest recorded activity is \(days) days old",
                detail: "This analysis describes an exported observation window rather than what apps are doing now.",
                severity: .info, confidence: 0.98, records: datedRecords,
                facts: [.init(key: activityEnd == nil ? "import_age_days" : "latest_activity_age_days", value: String(days), evidenceIDs: datedRecords.map(\.id))],
                uncertainty: activityEnd == nil
                    ? ["The export has no usable activity timestamps; its actual activity window is unknown.", "No newer report means no newer evidence, not that nothing changed."]
                    : ["No newer report means no newer evidence, not that nothing changed."],
                actions: [ActionCatalog.importFresh.id, ActionCatalog.learnLimits.id], categories: ["freshness"], context: context))
        }

        findings.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.profileRelevance != $1.profileRelevance { return $0.profileRelevance > $1.profileRelevance }
            return $0.id < $1.id
        }
        return .init(reportID: report.id, rulesetVersion: VersionedRuleSet.version, findings: findings,
                     scores: PostureCalculator.evaluate(report: report, findings: findings, context: context))
    }

    private static func makeFinding(
        ruleID: String, subject: FindingSubject, discriminator: String = "", title: String, detail: String,
        severity: FindingSeverity, confidence: Double, records: [Observation], facts: [FindingFact],
        inference: String? = nil, uncertainty: [String], actions: [String], categories: [String],
        knowledge: ReviewedDomainContext? = nil, knowledgeList: [ReviewedDomainContext] = [], context: FindingContext
    ) -> RuleFinding {
        let evidence = Array(Set(records.map(\.id))).sorted { $0.uuidString < $1.uuidString }
        let knowledgeRecords = knowledgeList + (knowledge.map { [$0] } ?? [])
        let stale = knowledgeRecords.contains { $0.expiresAt.map { $0 <= context.now } ?? false }
        let version = VersionedRuleSet.all.first { $0.id == ruleID }!.version
        // JSON component encoding prevents ambiguous separator collisions in imported text.
        let identity = [ruleID, version, subject.key, discriminator]
            + knowledgeRecords.map(\.knowledgeBaseVersion).sorted() + evidence.map(\.uuidString)
        let data = (try? JSONEncoder().encode(identity)) ?? Data()
        let sourceBoundConfidence = min(confidence, knowledgeRecords.map(\.evidenceConfidence).min() ?? confidence)
        let effectiveConfidence = stale ? sourceBoundConfidence * 0.75 : sourceBoundConfidence
        var displayedSeverity = severity
        var localUncertainty: [String] = []
        if case .domain(let domain) = subject, let host = DomainIdentity(domain),
           let local = context.domainOverrides.override(for: host) {
            switch local.disposition {
            case .trusted, .localAllow:
                displayedSeverity = FindingSeverity.allCases[max(0, severity.rank - 1)]
                localUncertainty.append("Your local expected/allow preference reduces review priority; it does not change the evidence or install an OS filtering exception.")
            case .alwaysReview, .localBlockRequest:
                displayedSeverity = max(severity, .medium)
                localUncertainty.append("Your local review/block-request preference changes priority; it does not establish harm or install an OS block.")
            case .customCategory:
                localUncertainty.append("Your custom category is a local opinion and does not replace the reviewed classification.")
            }
        }
        return .init(id: "finding." + ContentDigest.sha256(data), ruleID: ruleID, ruleVersion: version,
                     title: title, detail: detail, subject: subject, severity: displayedSeverity,
                     confidence: effectiveConfidence, observedFacts: facts,
                     inferences: inference.map { [.init(statement: $0, basis: evidence, confidence: effectiveConfidence)] } ?? [],
                     uncertainty: uncertainty + localUncertainty + (stale ? ["The reviewed knowledge source is past its declared expiry; its classification may be outdated."] : []),
                     evidenceIDs: evidence,
                     actionIDs: Array(Set(actions.filter(ActionCatalog.contains) + [ActionCatalog.keepAsIs.id])).sorted(),
                     categoryKeys: Array(Set(categories)).sorted(),
                     profileRelevance: context.profile.relevanceMultiplier(forCategoryKeys: Set(categories)),
                     isStale: stale, knowledgeSources: Array(Set(knowledgeRecords.flatMap(\.sourceURLs))).sorted())
    }
}

func sortedEvidence(_ records: [Observation]) -> [Observation] { records.sorted { $0.id.uuidString < $1.id.uuidString } }

func sumContacts(_ records: [Observation]) -> Int {
    records.reduce(0) { total, observation in
        let (sum, overflow) = total.addingReportingOverflow(max(0, observation.count))
        return overflow ? Int.max : sum
    }
}
