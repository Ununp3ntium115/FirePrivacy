import Foundation

public enum AnalysisHistoryError: Error, Equatable, Sendable {
    case unsupportedSchema, invalidRecord, reportMismatch, invalidEvidenceReference, oversizedRecord, oversizedHistory
}

/// Recorded changes are concurrent inputs, not proof that one input caused a finding.
public enum AnalysisChangeDimension: String, Codable, CaseIterable, Sendable {
    case reportIdentity, sourceIdentity, normalizedEvidence, evidenceReferences, importTime, reportMetadata
    case parserVersion, normalizationVersion, rulesetVersion, scoringVersion, actionCatalogVersion
    case knowledgeVersion, reviewedKnowledge, profile, permissionAudit, domainOverrides
    case publisherIdentities, protection, scoringPreference, findingDecisions, evaluationTime, analysisOutput
}

/// Local fingerprints retain provenance without duplicating the raw imported report.
public struct AnalysisInputRevision: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let importedAt: Date
    public let sourceSHA256: String?
    public let normalizedEvidenceSHA256: String
    public let evidenceReferencesSHA256: String
    public let reportMetadataSHA256: String
    public let parserVersion: String?
    public let normalizationVersion: String?
    public let rulesetVersion: String
    public let scoringVersion: String
    public let actionCatalogVersion: String
    public let knowledgeBaseVersion: String?
    public let reviewedKnowledgeVersions: [String]
    public let reviewedKnowledgeSHA256: String
    public let profileID: UUID
    public let profileSHA256: String
    public let permissionAuditSHA256: String
    public let domainOverridesSHA256: String
    public let publisherIdentitiesSHA256: String
    public let protectionSHA256: String
    public let includeOverallScore: Bool

    public var analysisRevision: AnalysisRevision {
        .init(parserVersion: parserVersion, normalizationVersion: normalizationVersion,
              ruleVersion: rulesetVersion, knowledgeVersion: knowledgeBaseVersion, profileID: profileID)
    }

    public init(report: PrivacyReport, analysis: FindingAnalysis, context: FindingContext,
                knowledgeBaseVersion: String? = nil, actionCatalogVersion: String = ActionCatalog.version) throws {
        guard report.id == analysis.reportID else { throw AnalysisHistoryError.reportMismatch }
        reportID = report.id
        importedAt = report.importedAt
        sourceSHA256 = report.metadata?.sourceSHA256
        normalizedEvidenceSHA256 = try AnalysisHistoryCanonical.evidenceDigest(report)
        evidenceReferencesSHA256 = try AnalysisHistoryCanonical.digest(report.observations.map(\.id).sorted { $0.uuidString < $1.uuidString })
        reportMetadataSHA256 = try AnalysisHistoryCanonical.digest(ReportProvenance(metadata: report.metadata, issues: report.issues))
        parserVersion = report.metadata?.parserVersion
        normalizationVersion = report.metadata?.normalizationVersion
        rulesetVersion = analysis.rulesetVersion
        scoringVersion = analysis.scores.version
        self.actionCatalogVersion = actionCatalogVersion
        self.knowledgeBaseVersion = knowledgeBaseVersion
        reviewedKnowledgeVersions = Array(Set(context.reviewedDomains.map(\.knowledgeBaseVersion))).sorted()
        reviewedKnowledgeSHA256 = try AnalysisHistoryCanonical.digest(context.reviewedDomains.map {
            try AnalysisHistoryCanonical.digest($0)
        }.sorted())
        profileID = context.profile.id
        profileSHA256 = try AnalysisHistoryCanonical.digest(context.profile)
        permissionAuditSHA256 = try AnalysisHistoryCanonical.digest(context.permissionAudit)
        domainOverridesSHA256 = try AnalysisHistoryCanonical.digest(context.domainOverrides.sorted)
        publisherIdentitiesSHA256 = try AnalysisHistoryCanonical.digest(context.appPublisherIDs)
        protectionSHA256 = try AnalysisHistoryCanonical.digest(context.protection)
        includeOverallScore = context.includeOverallScore
        try validate()
    }

    fileprivate func validate() throws {
        let digests = [normalizedEvidenceSHA256, evidenceReferencesSHA256, reportMetadataSHA256,
                       reviewedKnowledgeSHA256, profileSHA256, permissionAuditSHA256,
                       domainOverridesSHA256, publisherIdentitiesSHA256, protectionSHA256]
        let versions = [parserVersion, normalizationVersion, knowledgeBaseVersion].compactMap { $0 }
            + [rulesetVersion, scoringVersion, actionCatalogVersion] + reviewedKnowledgeVersions
        guard importedAt.timeIntervalSince1970.isFinite,
              digests.allSatisfy(AnalysisHistoryCanonical.isDigest),
              sourceSHA256.map(AnalysisHistoryCanonical.isDigest) ?? true,
              versions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 120 }),
              reviewedKnowledgeVersions.count <= 256,
              reviewedKnowledgeVersions == Array(Set(reviewedKnowledgeVersions)).sorted() else {
            throw AnalysisHistoryError.invalidRecord
        }
    }

    private struct ReportProvenance: Encodable {
        let metadata: ReportMetadata?
        let issues: [ImportIssue]
    }
}

public struct AnalysisHistoryChange: Codable, Equatable, Sendable {
    public let earlierRecordID: String
    public let earlierReportID: UUID
    public let laterReportID: UUID
    public let dimensions: [AnalysisChangeDimension]
    /// Unknown if either import has no recorded source hash.
    public let sourceBytesChanged: Bool?
    public let normalizedEvidenceChanged: Bool
    public let findings: FindingHistoryComparison
    public let limitations: [String]

    public var isSameEvidenceReanalysis: Bool { earlierReportID == laterReportID && !normalizedEvidenceChanged }
    public var interpretationInputsChanged: Bool {
        dimensions.contains { [.parserVersion, .normalizationVersion, .rulesetVersion, .scoringVersion,
            .actionCatalogVersion, .knowledgeVersion, .reviewedKnowledge, .profile, .permissionAudit,
            .domainOverrides, .publisherIdentities, .protection, .scoringPreference].contains($0) }
    }
}

public struct AnalysisHistoryRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let evaluatedAt: Date
    public let inputs: AnalysisInputRevision
    /// Immutable rule output; decisions and display status remain in lifecycle.
    public let analysis: FindingAnalysis
    public let analysisSHA256: String
    public let acceptedKeys: [String]
    public let ignoredKeys: [String]
    public let lifecycle: FindingLifecycleResult
    public let comparison: AnalysisHistoryChange?
    public var priorRecordID: String? { comparison?.earlierRecordID }
}

/// Bounded Codable state. The app persists it in its encrypted, generation-checked feature store.
/// A caller explicitly chooses any cross-report baseline; selecting a report is never a baseline.
public struct AnalysisHistory: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumRecords = 24
    public static let maximumRecordBytes = 2 * 1_024 * 1_024
    public static let maximumEncodedBytes = 8 * 1_024 * 1_024
    public let version: Int
    public private(set) var records: [AnalysisHistoryRecord]

    public init() { version = Self.schemaVersion; records = [] }
    public func latest(for reportID: UUID) -> AnalysisHistoryRecord? { records.last { $0.inputs.reportID == reportID } }
    public mutating func remove(reportID: UUID) {
        retain(reportIDs: Set(records.map { $0.inputs.reportID }).subtracting([reportID]))
    }
    public mutating func retain(reportIDs: Set<UUID>) {
        var remapped: [String: String] = [:]
        var rewritten: [String: AnalysisHistoryRecord] = [:]
        records = records.filter { reportIDs.contains($0.inputs.reportID) }.compactMap { record in
            let removedBaseline = record.comparison.map { !reportIDs.contains($0.earlierReportID) } ?? false
            let comparison = removedBaseline ? nil : record.comparison.map { old in
                AnalysisHistoryChange(earlierRecordID: remapped[old.earlierRecordID] ?? old.earlierRecordID,
                    earlierReportID: old.earlierReportID, laterReportID: old.laterReportID,
                    dimensions: old.dimensions, sourceBytesChanged: old.sourceBytesChanged,
                    normalizedEvidenceChanged: old.normalizedEvidenceChanged, findings: old.findings,
                    limitations: old.limitations)
            }
            // Previous-only facts and semantic comparison keys may belong to a removed report.
            let earlierSameReport = rewritten.values.contains { $0.inputs.reportID == record.inputs.reportID }
            let survivingBaseline = record.priorRecordID.flatMap { rewritten[$0] }
            let baselineStatuses = survivingBaseline.map {
                Dictionary($0.lifecycle.current.map { ($0.lifecycleKey, $0.status) }, uniquingKeysWith: { first, _ in first })
            } ?? [:]
            let unchangedSameReportEvidence = survivingBaseline.map {
                $0.inputs.reportID == record.inputs.reportID
                    && $0.inputs.normalizedEvidenceSHA256 == record.inputs.normalizedEvidenceSHA256
            } ?? false
            let current = record.lifecycle.current.map { finding -> RuleFinding in
                guard finding.status == .recurring else { return finding }
                if removedBaseline && !earlierSameReport { return finding.withStatus(.new) }
                // Propagate that reset through later interpretations of unchanged evidence.
                if unchangedSameReportEvidence && baselineStatuses[finding.lifecycleKey] == .new {
                    return finding.withStatus(.new)
                }
                return finding
            }
            let lifecycle = FindingLifecycleResult(current: current,
                previousOnly: removedBaseline ? [] : record.lifecycle.previousOnly)
            let identity = RecordIdentity(inputs: record.inputs, analysisSHA256: record.analysisSHA256,
                acceptedKeys: record.acceptedKeys, ignoredKeys: record.ignoredKeys,
                evaluatedAt: record.evaluatedAt, lifecycle: lifecycle, comparison: comparison)
            guard let id = try? AnalysisHistoryCanonical.digest(identity) else { return nil }
            remapped[record.id] = id
            let revised = AnalysisHistoryRecord(id: id, evaluatedAt: record.evaluatedAt, inputs: record.inputs,
                analysis: record.analysis, analysisSHA256: record.analysisSHA256, acceptedKeys: record.acceptedKeys,
                ignoredKeys: record.ignoredKeys, lifecycle: lifecycle, comparison: comparison)
            rewritten[record.id] = revised
            return revised
        }
    }

    /// Reopening an unchanged report returns its prior revision, preserving first-seen status.
    /// Evaluation time is recorded when results or inputs change; time alone creates no revision.
    @discardableResult
    public mutating func record(report: PrivacyReport, analysis: FindingAnalysis, context: FindingContext,
                                knowledgeBaseVersion: String? = nil, acceptedKeys: Set<String> = [],
                                ignoredKeys: Set<String> = [], baselineReportID: UUID? = nil,
                                actionCatalogVersion: String = ActionCatalog.version) throws -> AnalysisHistoryRecord {
        let inputs = try AnalysisInputRevision(report: report, analysis: analysis, context: context,
            knowledgeBaseVersion: knowledgeBaseVersion, actionCatalogVersion: actionCatalogVersion)
        let evidenceIDs = Set(report.observations.map(\.id))
        let references = analysis.findings.flatMap { $0.evidenceIDs
            + $0.observedFacts.flatMap(\.evidenceIDs) + $0.inferences.flatMap(\.basis) }
        guard references.allSatisfy(evidenceIDs.contains) else { throw AnalysisHistoryError.invalidEvidenceReference }
        let outputDigest = try AnalysisHistoryCanonical.digest(analysis)
        let accepted = acceptedKeys.sorted(), ignored = ignoredKeys.sorted()
        let prior = latest(for: report.id)
        if let prior, prior.inputs == inputs, prior.analysisSHA256 == outputDigest,
           prior.acceptedKeys == accepted, prior.ignoredKeys == ignored { return prior }
        let baseline = prior ?? baselineReportID.flatMap { latest(for: $0) }
        let change = try baseline.map { try Self.compare(earlier: $0, inputs: inputs, analysis: analysis,
            outputDigest: outputDigest, evaluatedAt: context.now, accepted: accepted, ignored: ignored) }
        var lifecycle = FindingLifecycle.compare(previous: baseline?.analysis, current: analysis,
            acceptedKeys: acceptedKeys, ignoredKeys: ignoredKeys)
        if let baseline, baseline.inputs.reportID == report.id,
           baseline.inputs.normalizedEvidenceSHA256 == inputs.normalizedEvidenceSHA256 {
            // A preference/knowledge revision is not an additional exported observation.
            let statuses = Dictionary(baseline.lifecycle.current.map { ($0.lifecycleKey, $0.status) },
                uniquingKeysWith: { first, _ in first })
            let current = lifecycle.current.map { finding -> RuleFinding in
                guard finding.status == .recurring, let status = statuses[finding.lifecycleKey],
                      status == .new || status == .recurring else { return finding }
                return finding.withStatus(status)
            }
            lifecycle = .init(current: current, previousOnly: lifecycle.previousOnly)
        }
        let identity = RecordIdentity(inputs: inputs, analysisSHA256: outputDigest, acceptedKeys: accepted,
            ignoredKeys: ignored, evaluatedAt: context.now, lifecycle: lifecycle, comparison: change)
        let revision = AnalysisHistoryRecord(id: try AnalysisHistoryCanonical.digest(identity), evaluatedAt: context.now,
            inputs: inputs, analysis: analysis, analysisSHA256: outputDigest, acceptedKeys: accepted,
            ignoredKeys: ignored, lifecycle: lifecycle, comparison: change)
        try Self.validate(revision)
        var candidate = self
        candidate.records.append(revision)
        while candidate.records.count > Self.maximumRecords { candidate.records.removeFirst() }
        while try AnalysisHistoryCanonical.encode(candidate).count > Self.maximumEncodedBytes {
            guard candidate.records.count > 1 else { throw AnalysisHistoryError.oversizedHistory }
            candidate.records.removeFirst()
        }
        self = candidate
        return revision
    }

    public func encoded() throws -> Data {
        try validate()
        let bytes = try AnalysisHistoryCanonical.encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw AnalysisHistoryError.oversizedHistory }
        return bytes
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw AnalysisHistoryError.oversizedHistory }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func validate() throws {
        guard version == Self.schemaVersion else { throw AnalysisHistoryError.unsupportedSchema }
        guard records.count <= Self.maximumRecords, Set(records.map(\.id)).count == records.count else {
            throw AnalysisHistoryError.invalidRecord
        }
        for record in records { try Self.validate(record) }
        guard try AnalysisHistoryCanonical.encode(self).count <= Self.maximumEncodedBytes else {
            throw AnalysisHistoryError.oversizedHistory
        }
    }

    private enum CodingKeys: String, CodingKey { case version, records }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        records = try c.decode([AnalysisHistoryRecord].self, forKey: .records)
        try validate()
    }

    private struct RecordIdentity: Encodable {
        let inputs: AnalysisInputRevision
        let analysisSHA256: String
        let acceptedKeys: [String]
        let ignoredKeys: [String]
        let evaluatedAt: Date
        let lifecycle: FindingLifecycleResult
        let comparison: AnalysisHistoryChange?
    }

    private static func validate(_ record: AnalysisHistoryRecord) throws {
        guard try AnalysisHistoryCanonical.encode(record).count <= maximumRecordBytes else {
            throw AnalysisHistoryError.oversizedRecord
        }
        try record.inputs.validate()
        let analysis = record.analysis
        let scores = analysis.scores
        let dimensions = [scores.sensorExposure, scores.aggregationSignals, scores.repetition,
            scores.controlGap, scores.classificationCoverage] + [scores.thirdPartyReach, scores.evidenceConfidence].compactMap { $0 }
        let identity = RecordIdentity(inputs: record.inputs, analysisSHA256: record.analysisSHA256,
            acceptedKeys: record.acceptedKeys, ignoredKeys: record.ignoredKeys, evaluatedAt: record.evaluatedAt,
            lifecycle: record.lifecycle, comparison: record.comparison)
        guard record.evaluatedAt.timeIntervalSince1970.isFinite,
              analysis.reportID == record.inputs.reportID, analysis.rulesetVersion == record.inputs.rulesetVersion,
              scores.version == record.inputs.scoringVersion, dimensions.allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              scores.privacyPosture.map({ (0...100).contains($0) }) ?? true,
              analysis.findings.count <= 4_096, Set(analysis.findings.map(\.id)).count == analysis.findings.count,
              record.acceptedKeys.count <= 4_096, record.ignoredKeys.count <= 4_096,
              record.acceptedKeys == Array(Set(record.acceptedKeys)).sorted(),
              record.ignoredKeys == Array(Set(record.ignoredKeys)).sorted(),
              (record.acceptedKeys + record.ignoredKeys).allSatisfy(AnalysisHistoryCanonical.isDigest),
              record.analysisSHA256 == (try AnalysisHistoryCanonical.digest(analysis)),
              record.id == (try AnalysisHistoryCanonical.digest(identity)),
              record.lifecycle.current.map({ $0.withStatus(.new) }) == analysis.findings.map({ $0.withStatus(.new) }),
              record.lifecycle.previousOnly.count <= 4_096,
              record.lifecycle.previousOnly.allSatisfy({ $0.status == .superseded || $0.status == .notObservedInLatestReport }),
              record.lifecycle.current.allSatisfy({ finding in
                  if record.acceptedKeys.contains(finding.lifecycleKey) { return finding.status == .accepted }
                  if record.ignoredKeys.contains(finding.lifecycleKey) { return finding.status == .ignored }
                  if finding.isStale { return finding.status == .stale }
                  return finding.status == .new || finding.status == .recurring
              }),
              (analysis.findings + record.lifecycle.previousOnly).allSatisfy({ finding in
                  finding.confidence.isFinite && (0...1).contains(finding.confidence)
                      && finding.profileRelevance.isFinite && (0...3).contains(finding.profileRelevance)
                      && finding.inferences.allSatisfy { $0.confidence.isFinite && (0...1).contains($0.confidence) }
              }) else { throw AnalysisHistoryError.invalidRecord }
        if let comparison = record.comparison {
            guard AnalysisHistoryCanonical.isDigest(comparison.earlierRecordID),
                  comparison.laterReportID == analysis.reportID,
                  comparison.dimensions == Array(Set(comparison.dimensions)).sorted(by: Self.dimensionOrder) else {
                throw AnalysisHistoryError.invalidRecord
            }
        }
    }

    private static func dimensionOrder(_ lhs: AnalysisChangeDimension, _ rhs: AnalysisChangeDimension) -> Bool {
        AnalysisChangeDimension.allCases.firstIndex(of: lhs)! < AnalysisChangeDimension.allCases.firstIndex(of: rhs)!
    }

    private static func compare(earlier: AnalysisHistoryRecord, inputs: AnalysisInputRevision,
                                analysis: FindingAnalysis, outputDigest: String, evaluatedAt: Date,
                                accepted: [String], ignored: [String]) throws -> AnalysisHistoryChange {
        let before = earlier.inputs
        var changed: [AnalysisChangeDimension] = []
        func add(_ dimension: AnalysisChangeDimension, _ differs: Bool) { if differs { changed.append(dimension) } }
        add(.reportIdentity, before.reportID != inputs.reportID)
        add(.sourceIdentity, before.sourceSHA256 != inputs.sourceSHA256)
        add(.normalizedEvidence, before.normalizedEvidenceSHA256 != inputs.normalizedEvidenceSHA256)
        add(.evidenceReferences, before.evidenceReferencesSHA256 != inputs.evidenceReferencesSHA256)
        add(.importTime, before.importedAt != inputs.importedAt)
        add(.reportMetadata, before.reportMetadataSHA256 != inputs.reportMetadataSHA256)
        add(.parserVersion, before.parserVersion != inputs.parserVersion)
        add(.normalizationVersion, before.normalizationVersion != inputs.normalizationVersion)
        add(.rulesetVersion, before.rulesetVersion != inputs.rulesetVersion)
        add(.scoringVersion, before.scoringVersion != inputs.scoringVersion)
        add(.actionCatalogVersion, before.actionCatalogVersion != inputs.actionCatalogVersion)
        add(.knowledgeVersion, before.knowledgeBaseVersion != inputs.knowledgeBaseVersion
            || before.reviewedKnowledgeVersions != inputs.reviewedKnowledgeVersions)
        add(.reviewedKnowledge, before.reviewedKnowledgeSHA256 != inputs.reviewedKnowledgeSHA256)
        add(.profile, before.profileSHA256 != inputs.profileSHA256)
        add(.permissionAudit, before.permissionAuditSHA256 != inputs.permissionAuditSHA256)
        add(.domainOverrides, before.domainOverridesSHA256 != inputs.domainOverridesSHA256)
        add(.publisherIdentities, before.publisherIdentitiesSHA256 != inputs.publisherIdentitiesSHA256)
        add(.protection, before.protectionSHA256 != inputs.protectionSHA256)
        add(.scoringPreference, before.includeOverallScore != inputs.includeOverallScore)
        add(.findingDecisions, earlier.acceptedKeys != accepted || earlier.ignoredKeys != ignored)
        add(.evaluationTime, earlier.evaluatedAt != evaluatedAt)
        add(.analysisOutput, earlier.analysisSHA256 != outputDigest)
        let sourceChanged = before.sourceSHA256.flatMap { first in inputs.sourceSHA256.map { first != $0 } }
        let baseFindings = FindingHistoryComparator.compare(earlier: earlier.analysis, later: analysis)
        let versionDimensions: Set<AnalysisChangeDimension> = [.parserVersion, .normalizationVersion,
            .rulesetVersion, .scoringVersion, .actionCatalogVersion, .knowledgeVersion, .reviewedKnowledge, .profile]
        let findings = FindingHistoryComparison(introducedKeys: baseFindings.introducedKeys,
            removedKeys: baseFindings.removedKeys, changedKeys: baseFindings.changedKeys,
            unchangedKeys: baseFindings.unchangedKeys,
            analysisVersionsChanged: baseFindings.analysisVersionsChanged || changed.contains { versionDimensions.contains($0) },
            evidenceUnchanged: before.normalizedEvidenceSHA256 == inputs.normalizedEvidenceSHA256,
            limitations: baseFindings.limitations)
        return .init(earlierRecordID: earlier.id, earlierReportID: before.reportID, laterReportID: inputs.reportID,
            dimensions: changed, sourceBytesChanged: sourceChanged,
            normalizedEvidenceChanged: before.normalizedEvidenceSHA256 != inputs.normalizedEvidenceSHA256,
            findings: findings,
            limitations: [
                "Changes identify recorded inputs and outputs; they do not establish which update caused a finding.",
                "A new rule, knowledge, preference, or evaluation-time revision is not new exported activity.",
                "A finding absent from revised analysis does not establish that the underlying activity stopped.",
                "Reviewed and hidden decisions apply to the semantic rule/subject/category key, including later evidence; review changed details before relying on an earlier decision.",
                "This bounded history may omit older revisions; a missing baseline is unknown."])
    }
}

private enum AnalysisHistoryCanonical {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func digest<T: Encodable>(_ value: T) throws -> String { ContentDigest.sha256(try encode(value)) }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func evidenceDigest(_ report: PrivacyReport) throws -> String {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        // Mirror ReportComparator semantics: ignore generated IDs, line order and provenance,
        // retain duplicate records, exact timestamp strings and every normalized reported scalar.
        let records = try report.observations.map { record -> String in
            let normalized = Observation(id: zero, bundleID: record.bundleID, domain: record.domain,
                category: record.category, accessType: record.accessType, count: record.count,
                timestamp: record.timestamp, firstTimestamp: record.firstTimestamp, lastTimestamp: record.lastTimestamp,
                timestampText: record.timestampText, firstTimestampText: record.firstTimestampText,
                lastTimestampText: record.lastTimestampText, eventKind: record.eventKind,
                context: record.context, domainOwner: record.domainOwner, domainType: record.domainType,
                initiatedType: record.initiatedType, domainClassification: record.domainClassification,
                sensorIdentifier: record.sensorIdentifier)
            return try digest(normalized)
        }.sorted()
        return try digest(records)
    }
}
