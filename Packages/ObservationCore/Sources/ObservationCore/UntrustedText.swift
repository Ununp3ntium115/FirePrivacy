import Foundation

/// Text that came from an imported file and must never be treated as markup, as
/// a shell/SQL fragment, or as model instructions (§9.4, §16.10, AI-008).
///
/// The type exists so that "did anyone sanitize this?" is answerable by the type
/// checker rather than by code review. Values are sanitized on construction:
/// control characters are removed, bidirectional overrides are removed, the
/// string is length-bounded, and Unicode is normalized.
public struct UntrustedText: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Sanitized value safe to place in a SwiftUI `Text`, a JSON export, or a
    /// structured model field.
    public let value: String
    /// True when sanitization changed the input; surfaced as an evidence note.
    public let wasModified: Bool
    /// True when the input was longer than the limit and was truncated.
    public let wasTruncated: Bool

    public static let defaultLimit = 512

    public init(_ raw: String, limit: Int = UntrustedText.defaultLimit) {
        let sanitized = UntrustedText.sanitize(raw, limit: limit)
        self.value = sanitized.text
        self.wasModified = sanitized.modified
        self.wasTruncated = sanitized.truncated
    }

    public var description: String { value }
    public var isEmpty: Bool { value.isEmpty }

    static func sanitize(_ raw: String, limit: Int) -> (text: String, modified: Bool, truncated: Bool) {
        var modified = false
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if Self.forbidden.contains(scalar) {
                modified = true
                continue
            }
            // Newlines and tabs become spaces: imported fields are single-line
            // values, and a multi-line value in a prompt or a CSV cell is a
            // structural break, not content.
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                modified = true
                scalars.append(" ")
                continue
            }
            scalars.append(scalar)
        }
        var text = String(scalars).precomposedStringWithCanonicalMapping
        if text != String(scalars) { modified = true }
        text = text.trimmingCharacters(in: .whitespaces)

        var truncated = false
        if text.count > limit {
            text = String(text.prefix(limit))
            truncated = true
            modified = true
        }
        return (text, modified, truncated)
    }

    /// Scalars removed outright: C0/C1 controls, bidi overrides, zero-width and
    /// invisible formatting characters used to disguise text.
    private static let forbidden: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        for value in 0x00...0x1F { if let scalar = Unicode.Scalar(value) { set.insert(scalar) } }
        for value in 0x7F...0x9F { if let scalar = Unicode.Scalar(value) { set.insert(scalar) } }
        let explicit: [UInt32] = [
            0x200B, 0x200C, 0x200D, 0x200E, 0x200F, // zero width + LTR/RTL marks
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // bidi embedding/override
            0x2066, 0x2067, 0x2068, 0x2069, // bidi isolates
            0xFEFF, // BOM / zero-width no-break space
        ]
        for value in explicit { if let scalar = Unicode.Scalar(value) { set.insert(scalar) } }
        return set
    }()

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension UntrustedText {
    /// Convenience for optional imported fields.
    public init?(optional raw: String?, limit: Int = UntrustedText.defaultLimit) {
        guard let raw, !raw.isEmpty else { return nil }
        self.init(raw, limit: limit)
        if value.isEmpty { return nil }
    }
}
