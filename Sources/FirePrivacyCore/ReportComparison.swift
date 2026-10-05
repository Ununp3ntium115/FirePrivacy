import Foundation

public struct AnalysisRevision: Codable, Equatable, Sendable {
    public let parserVersion: String?
    public let normalizationVersion: String?
    public let ruleVersion: String?
    public let knowledgeVersion: String?
    public let profileID: UUID?
    public init(parserVersion: String? = nil, normalizationVersion: String? = nil, ruleVersion: String? = nil,
                knowledgeVersion: String? = nil, profileID: UUID? = nil) {
        self.parserVersion = parserVersion
        self.normalizationVersion = normalizationVersion
        self.ruleVersion = ruleVersion
        self.knowledgeVersion = knowledgeVersion
        self.profileID = profileID
    }
}

public struct RecordedCountChange: Identifiable, Codable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let earlierCount: Int
    public let laterCount: Int
    public let delta: Int?
    public init(key: String, earlierCount: Int, laterCount: Int) {
        self.key = key; self.earlierCount = earlierCount; self.laterCount = laterCount
        let subtraction = laterCount.subtractingReportingOverflow(earlierCount)
        self.delta = subtraction.overflow ? nil : subtraction.partialValue
    }
}

public struct ReportComparison: Codable, Equatable, Sendable {
    public enum Coverage: String, Codable, Sendable { case unknown, sameInferredBounds, overlappingInferredBounds, differentInferredBounds }
    public let earlierReportID: UUID
    public let laterReportID: UUID
    public let appsPresentOnlyLater: [String]
    public let appsPresentOnlyEarlier: [String]
    public let domainsPresentOnlyLater: [String]
    public let domainsPresentOnlyEarlier: [String]
    public let appContactChanges: [RecordedCountChange]
    public let domainContactChanges: [RecordedCountChange]
    public let totalContactChange: RecordedCountChange
    public let sensorEventRecordChange: RecordedCountChange
    public let sensorBeginRecordChange: RecordedCountChange
    public let coverage: Coverage
    public let sourceBytesChanged: Bool?
    public let normalizedEvidenceChanged: Bool
    public let analysisRevisionChanged: Bool?
    public let warnings: [String]
}

public enum ReportComparator {
    public static func compare(earlier: PrivacyReport, later: PrivacyReport,
                               earlierRevision: AnalysisRevision? = nil, laterRevision: AnalysisRevision? = nil) -> ReportComparison {
        let earlierApps = Dictionary(uniqueKeysWithValues: earlier.apps.map { ($0.bundleID, $0.contacts) })
        let laterApps = Dictionary(uniqueKeysWithValues: later.apps.map { ($0.bundleID, $0.contacts) })
        let earlierDomains = Dictionary(uniqueKeysWithValues: earlier.domains.map { ($0.domain, $0.contacts) })
        let laterDomains = Dictionary(uniqueKeysWithValues: later.domains.map { ($0.domain, $0.contacts) })
        let appKeys = Set(earlierApps.keys).union(laterApps.keys)
        let domainKeys = Set(earlierDomains.keys).union(laterDomains.keys)
        let earlierTimes = bounds(earlier), laterTimes = bounds(later)
        let coverage: ReportComparison.Coverage
        if let earlierTimes, let laterTimes {
            if earlierTimes == laterTimes { coverage = .sameInferredBounds }
            else if earlierTimes.0 <= laterTimes.1 && laterTimes.0 <= earlierTimes.1 { coverage = .overlappingInferredBounds }
            else { coverage = .differentInferredBounds }
        } else { coverage = .unknown }
        let sourceChanged: Bool?
        if let first = earlier.metadata?.sourceSHA256, let second = later.metadata?.sourceSHA256 { sourceChanged = first != second }
        else { sourceChanged = nil }
        let revisionChanged: Bool? = earlierRevision != nil && laterRevision != nil ? earlierRevision != laterRevision : nil
        var warnings = [
            "Presence means present in an export, not installed, removed, blocked, or no longer active.",
            "Counts are recorded totals. Export windows may overlap or have different coverage; changes do not establish a change in underlying behavior.",
            "Timestamp bounds are inferred from records, not a verified report coverage interval."
        ]
        if !earlier.issues.isEmpty || !later.issues.isEmpty { warnings.append("At least one import skipped unsupported or invalid lines; comparison is incomplete.") }
        if earlier.metadata == nil || later.metadata == nil { warnings.append("Legacy evidence has no source provenance; byte identity is unavailable.") }
        if revisionChanged == true { warnings.append("Analysis versions or preferences changed. Reanalyze the same evidence under both revisions before attributing a finding change to a knowledge or rule update.") }
        return ReportComparison(earlierReportID: earlier.id, laterReportID: later.id,
            appsPresentOnlyLater: Set(laterApps.keys).subtracting(earlierApps.keys).sorted(),
            appsPresentOnlyEarlier: Set(earlierApps.keys).subtracting(laterApps.keys).sorted(),
            domainsPresentOnlyLater: Set(laterDomains.keys).subtracting(earlierDomains.keys).sorted(),
            domainsPresentOnlyEarlier: Set(earlierDomains.keys).subtracting(laterDomains.keys).sorted(),
            appContactChanges: appKeys.sorted().map { RecordedCountChange(key: $0, earlierCount: earlierApps[$0] ?? 0, laterCount: laterApps[$0] ?? 0) },
            domainContactChanges: domainKeys.sorted().map { RecordedCountChange(key: $0, earlierCount: earlierDomains[$0] ?? 0, laterCount: laterDomains[$0] ?? 0) },
            totalContactChange: RecordedCountChange(key: "contacts", earlierCount: earlier.totalContacts, laterCount: later.totalContacts),
            sensorEventRecordChange: RecordedCountChange(key: "sensor-event-records", earlierCount: earlier.observations.filter { $0.category == .sensor }.count, laterCount: later.observations.filter { $0.category == .sensor }.count),
            sensorBeginRecordChange: RecordedCountChange(key: "sensor-begin-records", earlierCount: earlier.observations.filter(\.isSensorBeginRecord).count, laterCount: later.observations.filter(\.isSensorBeginRecord).count),
            coverage: coverage, sourceBytesChanged: sourceChanged,
            normalizedEvidenceChanged: semanticDigest(earlier) != semanticDigest(later),
            analysisRevisionChanged: revisionChanged, warnings: warnings)
    }

    private static func bounds(_ report: PrivacyReport) -> (Date, Date)? {
        let timestamps = report.observations.flatMap { [$0.timestamp, $0.firstTimestamp, $0.lastTimestamp].compactMap { $0 } }
        guard let first = timestamps.min(), let last = timestamps.max() else { return nil }
        return (first, last)
    }

    /// Ignores import date, generated IDs, physical line order and provenance; preserves record multiplicity.
    private static func semanticDigest(_ report: PrivacyReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = report.observations.map { record -> String in
            let normalized = Observation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                bundleID: record.bundleID, domain: record.domain, category: record.category, accessType: record.accessType,
                count: record.count, timestamp: record.timestamp, firstTimestamp: record.firstTimestamp, lastTimestamp: record.lastTimestamp,
                timestampText: record.timestampText, firstTimestampText: record.firstTimestampText, lastTimestampText: record.lastTimestampText,
                eventKind: record.eventKind, context: record.context, domainOwner: record.domainOwner, domainType: record.domainType,
                initiatedType: record.initiatedType, domainClassification: record.domainClassification, sensorIdentifier: record.sensorIdentifier)
            return ContentDigest.sha256((try? encoder.encode(normalized)) ?? Data())
        }.sorted().joined(separator: "|")
        return ContentDigest.sha256(Data(records.utf8))
    }
}

public struct LocalWeeklySummary: Codable, Equatable, Sendable {
    public let periodStart: Date
    public let periodEnd: Date
    public let reportIDs: [UUID]
    public let uniqueReportCount: Int
    public let latestReportID: UUID?
    public let latestRecordedContacts: Int?
    public let latestRecordedSensorEvents: Int?
    public let comparisonToPrevious: ReportComparison?
    public let limitations: [String]
}

public enum WeeklySummaryBuilder {
    /// Summarizes reports imported in the preceding seven days, without summing overlapping snapshots.
    public static func build(reports: [PrivacyReport], now: Date = Date()) -> LocalWeeklySummary {
        let start = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let ordered = reports.filter { $0.importedAt <= now }.sorted {
            $0.importedAt == $1.importedAt ? $0.id.uuidString < $1.id.uuidString : $0.importedAt < $1.importedAt
        }
        let recent = ordered.filter { $0.importedAt >= start }
        let latest = recent.last
        let previous = latest.flatMap { selected in ordered.last { $0.importedAt < selected.importedAt && $0.id != selected.id } }
        return LocalWeeklySummary(periodStart: start, periodEnd: now, reportIDs: recent.map(\.id), uniqueReportCount: Set(recent.map(\.id)).count,
            latestReportID: latest?.id, latestRecordedContacts: latest?.totalContacts,
            latestRecordedSensorEvents: latest?.observations.filter { $0.category == .sensor }.count,
            comparisonToPrevious: previous.flatMap { first in latest.map { ReportComparator.compare(earlier: first, later: $0) } },
            limitations: ["This period describes import dates, not continuously monitored activity.",
                          "The latest snapshot supplies totals; overlapping exports are not added together.",
                          "Weekly summaries are produced locally when requested; they do not establish background monitoring."])
    }
}

public struct FindingHistoryComparison: Codable, Equatable, Sendable {
    public let introducedKeys: [String]
    public let removedKeys: [String]
    public let changedKeys: [String]
    public let unchangedKeys: [String]
    public let analysisVersionsChanged: Bool
    public let evidenceUnchanged: Bool?
    public let limitations: [String]
}

public enum FindingHistoryComparator {
    /// Matches semantic rule/subject keys, not evidence-derived finding identifiers.
    public static func compare(earlier: FindingAnalysis, later: FindingAnalysis,
                               evidenceComparison: ReportComparison? = nil) -> FindingHistoryComparison {
        let before = fingerprints(earlier.findings), after = fingerprints(later.findings)
        let both = Set(before.keys).intersection(after.keys)
        let matchingEvidence = evidenceComparison.flatMap { comparison -> Bool? in
            guard comparison.earlierReportID == earlier.reportID, comparison.laterReportID == later.reportID else { return nil }
            return !comparison.normalizedEvidenceChanged
        }
        return FindingHistoryComparison(introducedKeys: Set(after.keys).subtracting(before.keys).sorted(),
            removedKeys: Set(before.keys).subtracting(after.keys).sorted(),
            changedKeys: both.filter { before[$0] != after[$0] }.sorted(),
            unchangedKeys: both.filter { before[$0] == after[$0] }.sorted(),
            analysisVersionsChanged: earlier.rulesetVersion != later.rulesetVersion || evidenceComparison?.analysisRevisionChanged == true,
            evidenceUnchanged: matchingEvidence,
            limitations: ["Finding keys group the same rule and subject; evidence IDs may change between exports.",
                          "A version change alone does not prove that a knowledge update caused a finding change. Reanalysis of the same evidence under both revisions is required."])
    }

    private static func fingerprints(_ findings: [RuleFinding]) -> [String: [String]] {
        Dictionary(grouping: findings, by: { $0.ruleID + "|" + $0.subject.key }).mapValues { group in
            group.map { finding in
                // Source-specific evidence IDs are intentionally excluded; observed values are retained.
                let facts = finding.observedFacts.map { $0.key + "=" + $0.value }.sorted().joined(separator: "\u{1F}")
                let inferences = finding.inferences.map { $0.statement + "|" + String($0.confidence) }.sorted().joined(separator: "\u{1F}")
                let fields = [finding.ruleVersion, finding.title, finding.detail, finding.severity.rawValue,
                              String(finding.confidence), facts, inferences, finding.uncertainty.sorted().joined(separator: "|"),
                              finding.actionIDs.sorted().joined(separator: "|"), finding.categoryKeys.sorted().joined(separator: "|"),
                              String(finding.profileRelevance), String(finding.isStale), finding.knowledgeSources.sorted().joined(separator: "|")]
                let encoder = JSONEncoder()
                return ContentDigest.sha256((try? encoder.encode(fields)) ?? Data())
            }.sorted()
        }
    }
}
