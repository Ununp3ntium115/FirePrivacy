import Foundation

/// Version identifiers stamped onto everything Fire Privacy produces.
///
/// Every finding, export and comparison names the versions that made it, so a
/// difference between two runs can always be attributed to a code change, a rule
/// change or a data change rather than guessed at (EXP-004, DET-012).
public enum ComponentVersion {
    /// Streaming importer and record validators.
    public static let parser = "parser-1.0.0"
    /// Domain/timestamp/sensor canonicalization.
    public static let normalization = "normalization-1.0.0"
    /// Deterministic rules and scoring engine.
    public static let engine = "engine-1.0.0"
    /// On-disk and export schema.
    public static let schema = "fireprivacy.schema/1"
    /// Structured advisory input/output contract.
    public static let advisory = "advisory-1.0.0"
}
