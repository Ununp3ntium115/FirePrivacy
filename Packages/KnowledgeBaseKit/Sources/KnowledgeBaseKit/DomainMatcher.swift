import Foundation
import ObservationCore

/// The result of classifying one host.
public struct DomainMatch: Sendable, Hashable {
    public let classification: DomainClassification
    /// True when the rule matched the host exactly rather than as a suffix.
    public let isExactMatch: Bool
    /// Sources backing this classification, resolved from the dataset (KB-005).
    public let sources: [KnowledgeSource]

    public init(classification: DomainClassification, isExactMatch: Bool, sources: [KnowledgeSource]) {
        self.classification = classification
        self.isExactMatch = isExactMatch
        self.sources = sources
    }

    /// Base confidence for evidence built from this match (§13.3): a reviewed
    /// exact-host match is stronger evidence than a reviewed suffix match.
    public var evidenceConfidence: Double {
        let base = isExactMatch ? 0.92 : 0.86
        return min(base, classification.confidence)
    }
}

/// Matches hosts against the installed dataset.
///
/// Suffix matching is label-aware: `example.com` matches `a.example.com` but
/// never `badexample.com`. That single mistake is the most common way a domain
/// blocklist libels an unrelated business, so it is covered by an explicit test.
public struct DomainMatcher: Sendable {
    private let exact: [String: [DomainClassification]]
    private let suffix: [String: [DomainClassification]]
    private let sourcesByID: [String: KnowledgeSource]

    public init(payload: KnowledgeBasePayload) {
        var exact: [String: [DomainClassification]] = [:]
        var suffix: [String: [DomainClassification]] = [:]
        for classification in payload.classifications {
            let key = classification.pattern.lowercased()
            switch classification.patternKind {
            case .exactHost: exact[key, default: []].append(classification)
            case .domainSuffix: suffix[key, default: []].append(classification)
            }
        }
        self.exact = exact
        self.suffix = suffix
        self.sourcesByID = Dictionary(payload.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// All rules matching `host`, most specific first.
    ///
    /// Retired rules are excluded; disputed rules are returned so the UI can
    /// show the dispute rather than silently dropping evidence.
    public func matches(for host: NormalizedHost) -> [DomainMatch] {
        guard !host.isAddressLiteral else { return [] }
        let value = host.value
        var results: [DomainMatch] = []

        for classification in exact[value] ?? [] where classification.reviewStatus != .retired {
            results.append(makeMatch(classification, isExactMatch: true))
        }

        // Walk the label boundaries: a.b.example.com tests a.b.example.com,
        // b.example.com, example.com, com.
        var labels = host.labels
        while !labels.isEmpty {
            let candidate = labels.joined(separator: ".")
            for classification in suffix[candidate] ?? [] where classification.reviewStatus != .retired {
                results.append(makeMatch(classification, isExactMatch: candidate == value))
            }
            labels.removeFirst()
        }

        return results.sorted {
            if $0.classification.specificity != $1.classification.specificity {
                return $0.classification.specificity > $1.classification.specificity
            }
            return $0.classification.id < $1.classification.id
        }
    }

    /// The single most specific match, used where one label is shown.
    public func bestMatch(for host: NormalizedHost) -> DomainMatch? {
        matches(for: host).first
    }

    private func makeMatch(_ classification: DomainClassification, isExactMatch: Bool) -> DomainMatch {
        DomainMatch(
            classification: classification,
            isExactMatch: isExactMatch,
            sources: classification.sourceIDs.compactMap { sourcesByID[$0] }
        )
    }
}

extension Collection where Element == DomainMatch {
    /// Union of categories across matches, deterministically ordered.
    public var categories: [DomainCategory] {
        var seen = Set<DomainCategory>()
        for match in self { seen.formUnion(match.classification.categories) }
        return seen.sorted()
    }

    /// The organization to attribute the host to, if any match names one.
    public var organization: String? {
        first(where: { $0.classification.organization != nil })?.classification.organization
    }

    public var isCommonInfrastructureOnly: Bool {
        guard !isEmpty else { return false }
        let categories = self.categories
        return !categories.isEmpty && categories.allSatisfy(\.isCommonInfrastructure)
    }
}
