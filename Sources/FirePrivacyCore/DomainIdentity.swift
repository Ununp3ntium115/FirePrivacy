import Foundation

/// A canonical bare DNS host. URLs, address literals and malformed labels are
/// rejected rather than being guessed into a different endpoint identity.
public struct DomainIdentity: Codable, Hashable, Sendable {
    public let value: String
    public let registrableDomain: String?
    public let publicSuffix: String?
    public let usedPrivateSuffix: Bool
    public let wasInternationalized: Bool
    public var isPublicSuffix: Bool { publicSuffix == value }

    public init?(_ rawHost: String, suffixList: PublicSuffixList = .bundled) {
        guard let canonical = Self.asciiHost(rawHost), canonical.contains("."),
              !canonical.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        value = canonical
        wasInternationalized = rawHost.unicodeScalars.contains { !$0.isASCII } || canonical.contains("xn--")
        let suffix = suffixList.suffix(for: canonical)
        publicSuffix = suffix?.value
        usedPrivateSuffix = suffix?.isPrivate ?? false
        if let suffix, canonical != suffix.value {
            let labels = canonical.split(separator: ".")
            registrableDomain = labels.suffix(suffix.labelCount + 1).joined(separator: ".")
        } else {
            registrableDomain = nil
        }
    }

    /// Foundation's URL parser applies IDNA encoding; subsequent strict ASCII
    /// validation ensures URL syntax, escaped separators and invalid labels
    /// cannot become an endpoint match. Unicode presentation is never a key.
    static func asciiHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 1024,
              !host.contains(where: { "/\\:@?#%[]".contains($0) || $0.isWhitespace || $0.isNewline }),
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.hasSuffix("."), let parsed = URL(string: "https://\(host)/"),
              URLComponents(url: parsed, resolvingAgainstBaseURL: false)?.host != nil,
              let ascii = parsed.host?.lowercased(), ascii.utf8.count <= 253,
              ascii.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return ascii
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let host = try values.decode(String.self, forKey: .value)
        guard let identity = Self(host), identity.value == host else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: values, debugDescription: "Invalid canonical DNS host")
        }
        self = identity
    }
}

/// The complete pinned Public Suffix List, including private hosting suffixes
/// by default. A private suffix preserves tenant boundaries (a.github.io and
/// b.github.io are distinct registrable domains). Unknown suffixes stay unknown.
public struct PublicSuffixList: Sendable {
    public enum Failure: Error { case malformed, tooLarge }
    struct Suffix { let value: String; let labelCount: Int; let isPrivate: Bool }
    private let exact: [String: Bool]
    private let wildcard: [String: Bool]
    private let exceptions: [String: Bool]
    public let includesPrivate: Bool

    public init(text: String, includePrivate: Bool = true) throws {
        guard text.utf8.count <= 1_048_576 else { throw Failure.tooLarge }
        var exact: [String: Bool] = [:], wildcard: [String: Bool] = [:], exceptions: [String: Bool] = [:]
        var privateSection = false
        var count = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "// ===BEGIN PRIVATE DOMAINS===" { privateSection = true }
            if line.isEmpty || line.hasPrefix("//") || (privateSection && !includePrivate) { continue }
            count += 1
            guard count <= 30_000 else { throw Failure.tooLarge }
            let isException = line.hasPrefix("!")
            let isWildcard = line.hasPrefix("*.")
            let body = isException ? String(line.dropFirst()) : isWildcard ? String(line.dropFirst(2)) : line
            guard let host = DomainIdentity.asciiHost(body) else { throw Failure.malformed }
            if isException { exceptions[host] = privateSection }
            else if isWildcard { wildcard[host] = privateSection }
            else { exact[host] = privateSection }
        }
        self.exact = exact
        self.wildcard = wildcard
        self.exceptions = exceptions
        includesPrivate = includePrivate
    }

    public static let bundled: PublicSuffixList = {
        // An absent/corrupt resource yields no registrable-domain assertion;
        // it never silently substitutes a truncated list for the pinned PSL.
        let text = KnowledgeBaseResources.publicSuffixText ?? ""
        return (try? PublicSuffixList(text: text)) ?? (try! PublicSuffixList(text: ""))
    }()

    func suffix(for host: String) -> Suffix? {
        let labels = host.split(separator: ".")
        var best: Suffix?
        for index in labels.indices {
            let candidate = labels[index...].joined(separator: ".")
            let count = labels.count - index
            if let isPrivate = exceptions[candidate] {
                return Suffix(value: labels[(index + 1)...].joined(separator: "."), labelCount: count - 1, isPrivate: isPrivate)
            }
            if let isPrivate = exact[candidate], count > (best?.labelCount ?? 0) {
                best = Suffix(value: candidate, labelCount: count, isPrivate: isPrivate)
            }
            if index > 0, let isPrivate = wildcard[candidate], count + 1 > (best?.labelCount ?? 0) {
                best = Suffix(value: labels[(index - 1)...].joined(separator: "."), labelCount: count + 1, isPrivate: isPrivate)
            }
        }
        return best
    }
}
