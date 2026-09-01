import Foundation

/// A versioned public-suffix dataset used to compute the registrable domain
/// (eTLD+1) that groups hosts under a likely owner (§9.4).
///
/// The list is versioned and replaceable because suffix boundaries change: a
/// finding says which list version produced its grouping, and a comparison
/// between two reports can attribute a difference to a list update rather than
/// to a behavior change (DASH-008).
public struct PublicSuffixList: Sendable {
    public let version: String
    private let rules: Set<String>
    private let wildcardParents: Set<String>
    private let exceptions: Set<String>

    /// Parses publicsuffix.org-format lines: `!` marks an exception rule, `*.`
    /// a wildcard rule, `//` a comment.
    public init(version: String, lines: some Sequence<String>) {
        var rules = Set<String>()
        var wildcardParents = Set<String>()
        var exceptions = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
            if trimmed.hasPrefix("!") {
                exceptions.insert(String(trimmed.dropFirst()))
            } else if trimmed.hasPrefix("*.") {
                wildcardParents.insert(String(trimmed.dropFirst(2)))
            } else {
                rules.insert(trimmed)
            }
        }

        self.version = version
        self.rules = rules
        self.wildcardParents = wildcardParents
        self.exceptions = exceptions
    }

    /// The public suffix of `host`, or `nil` for address literals.
    ///
    /// When no rule matches, the algorithm falls back to the rightmost label, as
    /// the publicsuffix.org algorithm specifies. Callers that need to know
    /// whether the answer was a guess should use ``publicSuffixIsKnown(for:)``.
    public func publicSuffix(of host: NormalizedHost) -> String? {
        guard !host.isAddressLiteral else { return nil }
        let labels = host.labels
        guard !labels.isEmpty else { return nil }
        return labels.suffix(matchedLabelCount(labels).count).joined(separator: ".")
    }

    /// True when an explicit rule (not the fallback) covered the host.
    public func publicSuffixIsKnown(for host: NormalizedHost) -> Bool {
        guard !host.isAddressLiteral else { return false }
        return matchedLabelCount(host.labels).isExplicit
    }

    /// The registrable domain (eTLD+1), for example `example.co.uk`.
    ///
    /// Returns `nil` when the host *is* a public suffix, or is an address
    /// literal, or has no label to spare.
    public func registrableDomain(of host: NormalizedHost) -> NormalizedHost? {
        guard !host.isAddressLiteral else { return nil }
        let labels = host.labels
        let suffixLength = matchedLabelCount(labels).count
        guard labels.count > suffixLength else { return nil }
        let value = labels.suffix(suffixLength + 1).joined(separator: ".")
        return NormalizedHost(value: value, kind: .domain)
    }

    private func matchedLabelCount(_ labels: [String]) -> (count: Int, isExplicit: Bool) {
        guard !labels.isEmpty else { return (0, false) }

        // Exception rules win outright, and the longest exception is reached
        // first because candidates are generated left to right.
        for index in labels.indices {
            let candidate = labels[index...].joined(separator: ".")
            if exceptions.contains(candidate) {
                return (labels.count - index - 1, true)
            }
        }

        var best = 0
        for index in labels.indices {
            let candidate = labels[index...].joined(separator: ".")
            let length = labels.count - index
            if rules.contains(candidate) {
                best = max(best, length)
            }
            if length >= 2 {
                let parent = labels[(index + 1)...].joined(separator: ".")
                if wildcardParents.contains(parent) {
                    best = max(best, length)
                }
            }
        }
        if best == 0 {
            // publicsuffix.org default rule "*": the rightmost label is the suffix.
            return (1, false)
        }
        return (best, true)
    }
}
