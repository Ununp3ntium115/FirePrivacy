import Foundation

/// An application identifier as recorded by iOS, for example `com.example.app`.
///
/// The imported value is preserved exactly after validation (IMP-005, DASH-004):
/// when Fire Privacy has no trustworthy display name, the bundle identifier is
/// what the user sees, so it must never be "cleaned up" into something else.
public struct BundleIdentifier: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public static let maximumLength = 255

    /// Returns `nil` for values that cannot be an iOS bundle identifier. Being
    /// strict here keeps hostile strings out of the UI and out of model input.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumLength else { return nil }
        guard trimmed.unicodeScalars.allSatisfy(Self.isAllowed) else { return nil }
        guard !trimmed.hasPrefix("."), !trimmed.hasSuffix("."), !trimmed.contains("..") else { return nil }
        self.rawValue = trimmed
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        case ".", "-", "_": true
        default: false
        }
    }

    /// The reverse-DNS prefix used to group apps by likely publisher. Two apps
    /// sharing this prefix are treated as *related* when scoring cross-app
    /// aggregation (DET-004).
    public var publisherPrefix: String {
        let parts = rawValue.split(separator: ".")
        guard parts.count >= 2 else { return rawValue.lowercased() }
        return parts.prefix(2).joined(separator: ".").lowercased()
    }

    /// The final component, which is often the product name and frequently
    /// matches the app's own domain (`com.example.weathernow` →
    /// `weathernow.example`).
    public var lastComponent: String {
        rawValue.split(separator: ".").last.map { $0.lowercased() } ?? rawValue.lowercased()
    }

    public var description: String { rawValue }

    public static func < (lhs: BundleIdentifier, rhs: BundleIdentifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = BundleIdentifier(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid bundle identifier")
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
