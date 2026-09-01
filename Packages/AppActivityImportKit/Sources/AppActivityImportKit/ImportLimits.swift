import Foundation

/// Hard limits applied while reading an imported file (IMP-003).
///
/// The defaults are the values in the specification. They are overridable so
/// that tests can drive the limit paths with small fixtures instead of
/// generating a 250 MB file.
public struct ImportLimits: Hashable, Sendable, Codable {
    /// Largest file the picker will accept.
    public var maximumFileBytes: Int
    /// Largest single line. A longer line is skipped, not truncated, because a
    /// truncated JSON object cannot be validated.
    public var maximumLineBytes: Int
    /// Largest accepted string field; longer values are truncated and flagged.
    public var maximumStringFieldBytes: Int
    /// Fraction of lines that may be invalid before the import is treated as
    /// failed rather than partial.
    public var maximumInvalidLineRatio: Double
    /// Largest number of records read from one file.
    public var maximumRecordCount: Int
    /// Largest JSON nesting depth accepted in a line.
    public var maximumNestingDepth: Int
    /// Number of line-level warnings retained for the import summary.
    public var retainedWarningCount: Int

    public static let `default` = ImportLimits(
        maximumFileBytes: 250 * 1024 * 1024,
        maximumLineBytes: 2 * 1024 * 1024,
        maximumStringFieldBytes: 64 * 1024,
        maximumInvalidLineRatio: 0.05,
        maximumRecordCount: 2_000_000,
        maximumNestingDepth: 32,
        retainedWarningCount: 200
    )

    public init(
        maximumFileBytes: Int,
        maximumLineBytes: Int,
        maximumStringFieldBytes: Int,
        maximumInvalidLineRatio: Double,
        maximumRecordCount: Int,
        maximumNestingDepth: Int,
        retainedWarningCount: Int
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumLineBytes = maximumLineBytes
        self.maximumStringFieldBytes = maximumStringFieldBytes
        self.maximumInvalidLineRatio = maximumInvalidLineRatio
        self.maximumRecordCount = maximumRecordCount
        self.maximumNestingDepth = maximumNestingDepth
        self.retainedWarningCount = retainedWarningCount
    }
}
