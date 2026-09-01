import Foundation
import ObservationCore
import KnowledgeBaseKit
import PrivacyProfileKit

/// The result of one evaluation.
public struct FindingEvaluationResult: Sendable {
    public let findings: [Finding]
    public let evidenceByID: [String: Evidence]
    public let scores: PostureScores
    public let ruleSetVersion: String
    public let engineVersion: String
    public let knowledgeBaseVersion: KnowledgeBaseVersion
    public let generatedAt: Date

    public init(
        findings: [Finding],
        evidenceByID: [String: Evidence],
        scores: PostureScores,
        ruleSetVersion: String,
        engineVersion: String,
        knowledgeBaseVersion: KnowledgeBaseVersion,
        generatedAt: Date
    ) {
        self.findings = findings
        self.evidenceByID = evidenceByID
        self.scores = scores
        self.ruleSetVersion = ruleSetVersion
        self.engineVersion = engineVersion
        self.knowledgeBaseVersion = knowledgeBaseVersion
        self.generatedAt = generatedAt
    }

    /// The five findings the first screen shows (DASH-003).
    public var priorityFindings: [Finding] { Array(findings.prefix(5)) }

    /// The full evidence chain behind one finding (DET-011, §23.6).
    public func evidenceGraph(for findingID: String) -> EvidenceGraph? {
        guard let finding = findings.first(where: { $0.id == findingID }) else { return nil }
        let evidence = finding.evidenceIDs.compactMap { evidenceByID[$0] }
        var unknowns = finding.uncertainty
        if evidence.count < finding.evidenceIDs.count {
            unknowns.append("Some evidence for this finding is no longer available in the current data set.")
        }
        return EvidenceGraph(
            findingID: findingID,
            evidence: evidence,
            observedFacts: finding.observedFacts,
            inferences: finding.inferences,
            unknowns: unknowns
        )
    }

    public func findings(for subject: FindingSubject) -> [Finding] {
        findings.filter { $0.subject.key == subject.key }
    }
}

/// The interface the app depends on (§23.3).
public protocol FindingEvaluating: Sendable {
    func evaluate(_ context: FindingEvaluationContext) -> FindingEvaluationResult
}

/// Runs every rule and ranks the results.
///
/// The engine is pure: same observations, same knowledge base, same rule set and
/// same profile produce the same findings, byte for byte, apart from the
/// injected timestamp (DET-012).
public struct DeterministicFindingEngine: FindingEvaluating {
    public let rules: [any DetectionRule]

    public init(rules: [any DetectionRule] = RuleSet.all) {
        self.rules = rules
    }

    public func evaluate(_ context: FindingEvaluationContext) -> FindingEvaluationResult {
        var findings: [Finding] = []
        var evidenceByID: [String: Evidence] = [:]

        for rule in rules.sorted(by: { $0.id < $1.id }) {
            let output = rule.evaluate(context)
            findings.append(contentsOf: output.findings)
            for item in output.evidence where evidenceByID[item.id] == nil {
                evidenceByID[item.id] = item
            }
        }

        // Two rules can legitimately reach the same conclusion; keep the first
        // by rule order and mark nothing as duplicated evidence.
        var seen = Set<String>()
        findings = findings.filter { seen.insert($0.id).inserted }

        let ranked = rank(findings, context: context)
        let scores = PostureCalculator.evaluate(
            index: context.index,
            permissions: context.permissions,
            protection: context.protection,
            findings: ranked,
            knowledgeBaseIsStale: context.knowledgeBaseIsStale,
            reportIsStale: ranked.contains { $0.ruleID == ReportFreshnessRule().id }
        )

        return FindingEvaluationResult(
            findings: ranked,
            evidenceByID: evidenceByID,
            scores: scores,
            ruleSetVersion: RuleSet.version,
            engineVersion: ComponentVersion.engine,
            knowledgeBaseVersion: context.knowledgeBaseVersion,
            generatedAt: context.now
        )
    }

    /// `priority = severityWeight × (0.6 + 0.4·C) × profileRelevance × freshness`
    /// with the documented tie-breakers (§13.6).
    func rank(_ findings: [Finding], context: FindingEvaluationContext) -> [Finding] {
        let freshness = freshnessFactor(context: context)
        return findings
            .map { finding -> (Finding, Double) in
                let relevance = context.profile.relevanceMultiplier(forCategoryKeys: Set(finding.categoryKeys))
                let priority = finding.severity.weight
                    * (0.6 + 0.4 * finding.confidence)
                    * relevance
                    * (finding.ruleID == ReportFreshnessRule().id ? 1.0 : freshness)
                return (finding, priority)
            }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                if left.0.confidence != right.0.confidence { return left.0.confidence > right.0.confidence }
                if left.0.status != right.0.status {
                    return statusRank(left.0.status) < statusRank(right.0.status)
                }
                return left.0.id < right.0.id
            }
            .map(\.0)
    }

    /// Old reports rank slightly lower, so a fresh import outranks a stale one
    /// without hiding anything.
    private func freshnessFactor(context: FindingEvaluationContext) -> Double {
        let reference = context.snapshot.session.reportEnd ?? context.snapshot.session.importedAt
        let ageDays = context.now.timeIntervalSince(reference) / 86_400
        guard ageDays > 0 else { return 1 }
        return max(0.6, 1 - min(0.4, ageDays / 90))
    }

    private func statusRank(_ status: FindingStatus) -> Int {
        switch status {
        case .new: 0
        case .recurring: 1
        case .stale: 2
        case .accepted: 3
        case .ignored: 4
        case .resolved: 5
        case .superseded: 6
        }
    }
}

extension FindingEvaluationResult {
    /// Applies the lifecycle transitions between two evaluations (DET-010).
    ///
    /// A finding present in both runs is `recurring`; one that disappeared is
    /// `resolved`; a user's `ignored`/`accepted` decision carries forward.
    public func withLifecycle(comparedTo previous: FindingEvaluationResult?) -> FindingEvaluationResult {
        guard let previous else { return self }
        let previousByID = Dictionary(previous.findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let updated = findings.map { finding -> Finding in
            guard let old = previousByID[finding.id] else { return finding }
            var copy = finding
            switch old.status {
            case .ignored, .accepted:
                copy.status = old.status
            case .new, .recurring, .resolved, .stale, .superseded:
                copy.status = finding.status == .stale ? .stale : .recurring
            }
            return copy
        }

        return FindingEvaluationResult(
            findings: updated,
            evidenceByID: evidenceByID,
            scores: scores,
            ruleSetVersion: ruleSetVersion,
            engineVersion: engineVersion,
            knowledgeBaseVersion: knowledgeBaseVersion,
            generatedAt: generatedAt
        )
    }

    /// Findings that were present before and are gone now (DET-010).
    public func resolvedFindings(comparedTo previous: FindingEvaluationResult) -> [Finding] {
        let currentIDs = Set(findings.map(\.id))
        return previous.findings
            .filter { !currentIDs.contains($0.id) }
            .map { finding in
                var copy = finding
                copy.status = .resolved
                return copy
            }
    }
}
