import Foundation

/// Turns a raw string from an imported report into a canonical host plus its
/// registrable domain, recording every transformation it applied.
///
/// It is deliberately total: any input yields either a normalized host or a
/// structured reason why not. A parser that throws on a hostile hostname would
/// let one bad line hide the rest of the report (IMP-004).
public struct DomainNormalizer: Sendable {
    public struct Result: Hashable, Sendable {
        public let host: NormalizedHost?
        public let registrableDomain: NormalizedHost?
        public let warnings: NormalizationWarnings
        public let rejectionReason: RejectionReason?

        public var isValid: Bool { host != nil }
    }

    public enum RejectionReason: String, Hashable, Sendable, Codable {
        case empty
        case tooLong
        case emptyLabel
        case labelTooLong
        case invalidCharacter
        case punycodeFailed
        case invalidAddressLiteral
    }

    /// Maximum length of a host name in its ASCII form (RFC 1035).
    public static let maximumHostLength = 253
    public static let maximumLabelLength = 63

    public let publicSuffixList: PublicSuffixList

    public init(publicSuffixList: PublicSuffixList = .bundled) {
        self.publicSuffixList = publicSuffixList
    }

    public func normalize(_ raw: String) -> Result {
        var warnings: NormalizationWarnings = []
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .empty) }

        // Exports carry bare host names, but a context field may carry a URL and
        // a user override may be pasted. Strip the parts that are not the host.
        if let schemeRange = working.range(of: "://") {
            working = String(working[schemeRange.upperBound...])
            warnings.insert(.schemeRemoved)
        }
        if let atIndex = working.lastIndex(of: "@") {
            working = String(working[working.index(after: atIndex)...])
            warnings.insert(.userInfoRemoved)
        }
        if let separatorIndex = working.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            working = String(working[working.startIndex..<separatorIndex])
            warnings.insert(.pathRemoved)
        }

        // IPv6 literals are bracketed; anything else may carry a `:port`.
        var isBracketedIPv6 = false
        if working.hasPrefix("["), let closing = working.firstIndex(of: "]") {
            isBracketedIPv6 = true
            let inner = working[working.index(after: working.startIndex)..<closing]
            if working.index(after: closing) < working.endIndex { warnings.insert(.portRemoved) }
            working = String(inner)
        } else if let colonIndex = working.lastIndex(of: ":"), !working.contains("::"),
                  working.filter({ $0 == ":" }).count == 1 {
            let port = working[working.index(after: colonIndex)...]
            if !port.isEmpty, port.allSatisfy(\.isNumber) {
                working = String(working[working.startIndex..<colonIndex])
                warnings.insert(.portRemoved)
            }
        }

        while working.hasSuffix(".") {
            working = String(working.dropLast())
            warnings.insert(.trailingDot)
        }
        guard !working.isEmpty else { return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .empty) }

        let lowered = working.lowercased()
        if lowered != working { warnings.insert(.caseFolded) }
        working = lowered

        if isBracketedIPv6 || working.contains(":") {
            guard Self.isIPv6Literal(working) else {
                return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .invalidAddressLiteral)
            }
            warnings.insert(.addressLiteral)
            let host = NormalizedHost(value: working, kind: .ipv6)
            return Result(host: host, registrableDomain: nil, warnings: warnings, rejectionReason: nil)
        }

        if Self.isIPv4Literal(working) {
            warnings.insert(.addressLiteral)
            let host = NormalizedHost(value: working, kind: .ipv4)
            return Result(host: host, registrableDomain: nil, warnings: warnings, rejectionReason: nil)
        }

        var asciiLabels: [String] = []
        var displayLabels: [String] = []
        var sawNonASCII = false
        var sawLatin = false
        var sawNonLatin = false

        for label in working.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else {
                return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .emptyLabel)
            }
            let text = String(label)
            if text.allSatisfy(\.isASCII) {
                guard text.unicodeScalars.allSatisfy(Self.isAllowedASCII) else {
                    return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .invalidCharacter)
                }
                guard text.count <= Self.maximumLabelLength else {
                    return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .labelTooLong)
                }
                asciiLabels.append(text)
                if text.hasPrefix(Punycode.acePrefix), let decoded = Punycode.decode(labelBody: String(text.dropFirst(Punycode.acePrefix.count))) {
                    displayLabels.append(decoded)
                    warnings.insert(.internationalized)
                    Self.classifyScripts(decoded, sawLatin: &sawLatin, sawNonLatin: &sawNonLatin)
                } else {
                    displayLabels.append(text)
                    if text.contains(where: \.isLetter) { sawLatin = true }
                }
            } else {
                sawNonASCII = true
                guard let encoded = Punycode.encode(label: text) else {
                    return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .punycodeFailed)
                }
                let aLabel = Punycode.acePrefix + encoded
                guard aLabel.count <= Self.maximumLabelLength else {
                    return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .labelTooLong)
                }
                asciiLabels.append(aLabel)
                displayLabels.append(text)
                Self.classifyScripts(text, sawLatin: &sawLatin, sawNonLatin: &sawNonLatin)
            }
        }

        if sawNonASCII { warnings.insert(.internationalized) }
        if sawLatin, sawNonLatin { warnings.insert(.mixedScripts) }

        let value = asciiLabels.joined(separator: ".")
        guard value.count <= Self.maximumHostLength else {
            return Result(host: nil, registrableDomain: nil, warnings: warnings, rejectionReason: .tooLong)
        }
        if asciiLabels.count == 1 { warnings.insert(.singleLabel) }

        let display = displayLabels.joined(separator: ".")
        let host = NormalizedHost(value: value, displayValue: display, kind: asciiLabels.count == 1 ? .singleLabel : .domain)
        let registrable = publicSuffixList.registrableDomain(of: host)
        if !publicSuffixList.publicSuffixIsKnown(for: host) { warnings.insert(.unknownPublicSuffix) }

        return Result(host: host, registrableDomain: registrable, warnings: warnings, rejectionReason: nil)
    }

    private static func classifyScripts(_ text: String, sawLatin: inout Bool, sawNonLatin: inout Bool) {
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if scalar.value < 0x0250 {
                sawLatin = true
            } else {
                sawNonLatin = true
            }
        }
    }

    private static func isAllowedASCII(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "0"..."9", "-", "_": true
        default: false
        }
    }

    static func isIPv4Literal(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let number = Int(part) else { return false }
            return number <= 255
        }
    }

    static func isIPv6Literal(_ value: String) -> Bool {
        guard value.contains(":"), value.count <= 45 else { return false }
        let groups = value.components(separatedBy: ":")
        guard groups.count >= 3, groups.count <= 9 else { return false }
        var emptyGroups = 0
        for group in groups {
            if group.isEmpty {
                emptyGroups += 1
                continue
            }
            if group.contains("."), isIPv4Literal(group) { continue }
            guard group.count <= 4, group.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        // A single `::` produces at most two adjacent empty components, plus one
        // more when the address starts or ends with it.
        return emptyGroups <= 3
    }
}
