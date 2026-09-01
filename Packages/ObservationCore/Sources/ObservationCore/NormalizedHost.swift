import Foundation

/// A host name reduced to a single canonical form so that two spellings of the
/// same destination compare equal.
///
/// `value` is always lowercase ASCII (internationalized labels are punycode
/// encoded) with no trailing dot, port, scheme or path. `displayValue` is the
/// Unicode form shown to the user — the two differ only for internationalized
/// names, and the UI shows both so a homograph cannot hide behind a nice label.
public struct NormalizedHost: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, Codable {
        case domain
        case singleLabel
        case ipv4
        case ipv6
    }

    public let value: String
    public let displayValue: String
    public let kind: Kind

    public init(value: String, displayValue: String? = nil, kind: Kind) {
        self.value = value
        self.displayValue = displayValue ?? value
        self.kind = kind
    }

    public var labels: [String] { value.split(separator: ".").map(String.init) }

    /// True when the host is an address literal, where owner attribution from a
    /// domain knowledge base does not apply (DET-009).
    public var isAddressLiteral: Bool { kind == .ipv4 || kind == .ipv6 }

    public var description: String { value }

    public static func < (lhs: NormalizedHost, rhs: NormalizedHost) -> Bool {
        lhs.value < rhs.value
    }
}

/// Non-fatal observations made while canonicalizing an imported value.
///
/// Stored per observation as a bitset (§12.1) so the evidence view can explain
/// exactly how a raw string became a normalized one.
public struct NormalizationWarnings: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let trailingDot = NormalizationWarnings(rawValue: 1 << 0)
    public static let caseFolded = NormalizationWarnings(rawValue: 1 << 1)
    public static let internationalized = NormalizationWarnings(rawValue: 1 << 2)
    public static let schemeRemoved = NormalizationWarnings(rawValue: 1 << 3)
    public static let userInfoRemoved = NormalizationWarnings(rawValue: 1 << 4)
    public static let pathRemoved = NormalizationWarnings(rawValue: 1 << 5)
    public static let portRemoved = NormalizationWarnings(rawValue: 1 << 6)
    public static let addressLiteral = NormalizationWarnings(rawValue: 1 << 7)
    public static let singleLabel = NormalizationWarnings(rawValue: 1 << 8)
    public static let unknownPublicSuffix = NormalizationWarnings(rawValue: 1 << 9)
    public static let textSanitized = NormalizationWarnings(rawValue: 1 << 10)
    public static let truncated = NormalizationWarnings(rawValue: 1 << 11)
    public static let mixedScripts = NormalizationWarnings(rawValue: 1 << 12)

    /// Stable identifiers used in exports and in the evidence UI.
    public var identifiers: [String] {
        var result: [String] = []
        let mapping: [(NormalizationWarnings, String)] = [
            (.trailingDot, "trailing_dot"),
            (.caseFolded, "case_folded"),
            (.internationalized, "internationalized"),
            (.schemeRemoved, "scheme_removed"),
            (.userInfoRemoved, "user_info_removed"),
            (.pathRemoved, "path_removed"),
            (.portRemoved, "port_removed"),
            (.addressLiteral, "address_literal"),
            (.singleLabel, "single_label"),
            (.unknownPublicSuffix, "unknown_public_suffix"),
            (.textSanitized, "text_sanitized"),
            (.truncated, "truncated"),
            (.mixedScripts, "mixed_scripts"),
        ]
        for (option, identifier) in mapping where contains(option) {
            result.append(identifier)
        }
        return result
    }
}
