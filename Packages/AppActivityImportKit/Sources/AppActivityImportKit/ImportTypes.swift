import Foundation
import ObservationCore

/// Options for one import (§10.2).
public struct ImportOptions: Sendable {
    public var limits: ImportLimits
    /// User-supplied label when several sessions are kept side by side.
    public var label: String?
    /// Marks the session as the bundled synthetic dataset (IMP-011).
    public var isDemoData: Bool
    /// Hashes of files already imported, for duplicate detection (IMP-006).
    public var knownSourceHashes: Set<FireDigest>
    /// Clock injected so imports are reproducible in tests.
    public var now: Date

    public init(
        limits: ImportLimits = .default,
        label: String? = nil,
        isDemoData: Bool = false,
        knownSourceHashes: Set<FireDigest> = [],
        now: Date = Date()
    ) {
        self.limits = limits
        self.label = label
        self.isDemoData = isDemoData
        self.knownSourceHashes = knownSourceHashes
        self.now = now
    }
}

/// What the import screen shows while work is in progress (§11.2, screen 6).
public struct ImportProgress: Hashable, Sendable {
    public enum Stage: String, Hashable, Sendable {
        case readingFile
        case validatingRecords
        case normalizing
        case finished
    }

    public let stage: Stage
    public let bytesRead: Int
    public let totalBytes: Int
    public let recordsAccepted: Int

    public init(stage: Stage, bytesRead: Int, totalBytes: Int, recordsAccepted: Int) {
        self.stage = stage
        self.bytesRead = bytesRead
        self.totalBytes = totalBytes
        self.recordsAccepted = recordsAccepted
    }

    /// `nil` when the total size is unknown, so the UI shows an indeterminate
    /// indicator instead of a wrong percentage.
    public var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(bytesRead) / Double(totalBytes))
    }
}

/// A recoverable problem with one line or one field.
///
/// Invalid lines are quarantined as counts plus line numbers, never silently
/// discarded (§8.1).
public struct ImportWarning: Hashable, Sendable, Codable {
    public enum Code: String, Hashable, Sendable, Codable {
        case invalidJSON = "line_invalid_json"
        case lineTooLong = "line_too_long"
        case invalidUTF8 = "invalid_utf8"
        case excessiveNesting = "excessive_nesting"
        case missingDiscriminator = "missing_discriminator"
        case unknownRecordType = "unknown_record_type"
        case invalidBundleIdentifier = "invalid_bundle_id"
        case invalidDomain = "invalid_domain"
        case invalidTimestamp = "invalid_timestamp"
        case invalidHitCount = "invalid_hit_count"
        case fieldTruncated = "field_truncated"
        case recordLimitReached = "record_limit_reached"
        case emptyRecord = "empty_record"
        case duplicateSourceFile = "duplicate_source_file"
    }

    public let code: Code
    public let lineNumber: Int?
    /// Short, non-sensitive detail. Never contains a raw domain or bundle ID.
    public let detail: String?

    public init(code: Code, lineNumber: Int?, detail: String? = nil) {
        self.code = code
        self.lineNumber = lineNumber
        self.detail = detail
    }
}

/// Counts shown on the import summary screen (IMP-008).
public struct ImportCounts: Hashable, Sendable, Codable {
    public var totalLines = 0
    public var networkRecords = 0
    public var sensorRecords = 0
    public var invalidLines = 0
    public var unknownRecordTypes = 0
    public var skippedOversizeLines = 0

    public init() {}

    public var acceptedRecords: Int { networkRecords + sensorRecords }

    public var invalidRatio: Double {
        guard totalLines > 0 else { return 0 }
        return Double(invalidLines) / Double(totalLines)
    }
}

/// The outcome of one import.
public struct ImportResult: Sendable {
    public let snapshot: ObservationSnapshot
    public let counts: ImportCounts
    public let warnings: [ImportWarning]
    /// True when a file with the same SHA-256 was already imported (IMP-006).
    public let isDuplicateOfExistingImport: Bool

    public init(
        snapshot: ObservationSnapshot,
        counts: ImportCounts,
        warnings: [ImportWarning],
        isDuplicateOfExistingImport: Bool
    ) {
        self.snapshot = snapshot
        self.counts = counts
        self.warnings = warnings
        self.isDuplicateOfExistingImport = isDuplicateOfExistingImport
    }

    /// The first ten line-level reasons, as required by the summary screen.
    public var firstWarningReasons: [ImportWarning] { Array(warnings.prefix(10)) }

    /// Whether the user should be told results may be incomplete.
    public var mayBeIncomplete: Bool {
        counts.invalidLines > 0 || counts.unknownRecordTypes > 0 || counts.skippedOversizeLines > 0
    }
}

/// What the app can learn about a file before committing to parse it (IMP-001).
public struct ImportPreflight: Sendable {
    public let filename: UntrustedText?
    public let fileSizeBytes: Int
    public let sourceHash: FireDigest
    public let looksLikeNDJSON: Bool
    public let isDuplicate: Bool

    public init(
        filename: UntrustedText?,
        fileSizeBytes: Int,
        sourceHash: FireDigest,
        looksLikeNDJSON: Bool,
        isDuplicate: Bool
    ) {
        self.filename = filename
        self.fileSizeBytes = fileSizeBytes
        self.sourceHash = sourceHash
        self.looksLikeNDJSON = looksLikeNDJSON
        self.isDuplicate = isDuplicate
    }
}

public enum ImportError: Error, Sendable, Equatable {
    case unreadableFile
    case emptyFile
    case fileTooLarge(bytes: Int, limit: Int)
    case unsupportedFileType(String)
    case securityScopedAccessDenied
    case tooManyInvalidLines(ratio: Double, limit: Double)
    case cancelled

    /// Stable code used in diagnostics; never contains a filename (§16.7).
    public var code: String {
        switch self {
        case .unreadableFile: "import.unreadable_file"
        case .emptyFile: "import.empty_file"
        case .fileTooLarge: "import.file_too_large"
        case .unsupportedFileType: "import.unsupported_file_type"
        case .securityScopedAccessDenied: "import.security_scoped_access_denied"
        case .tooManyInvalidLines: "import.too_many_invalid_lines"
        case .cancelled: "import.cancelled"
        }
    }
}

/// The interface the app depends on (§23.1).
public protocol AppActivityImporting: Sendable {
    func inspect(_ url: URL, options: ImportOptions) async throws -> ImportPreflight
    func importReport(
        from url: URL,
        options: ImportOptions,
        progress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportResult
}
