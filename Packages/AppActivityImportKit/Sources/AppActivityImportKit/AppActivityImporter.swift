import Foundation
import ObservationCore

/// Imports an App Privacy Report export (§8.1).
///
/// The importer performs **no network access of any kind**. That is a product
/// promise (IMP-010) enforced by a source-level check in
/// `Tests/PrivacyRegression`, not just by intent.
public struct AppActivityImporter: AppActivityImporting {
    public static let acceptedExtensions: Set<String> = ["ndjson", "json", "txt", "jsonl"]

    private let decoderFactory: @Sendable (ImportOptions) -> AppActivityRecordDecoder
    private let normalizer: AppActivityNormalizer

    public init(publicSuffixList: PublicSuffixList = .bundled) {
        self.decoderFactory = { options in
            AppActivityRecordDecoder(
                normalizer: DomainNormalizer(publicSuffixList: publicSuffixList),
                stringLimit: min(512, options.limits.maximumStringFieldBytes),
                now: options.now
            )
        }
        self.normalizer = AppActivityNormalizer()
    }

    // MARK: - Preflight

    public func inspect(_ url: URL, options: ImportOptions = ImportOptions()) async throws -> ImportPreflight {
        let fileExtension = url.pathExtension.lowercased()
        if !fileExtension.isEmpty, !Self.acceptedExtensions.contains(fileExtension) {
            throw ImportError.unsupportedFileType(fileExtension)
        }

        let (digest, byteCount, prefix) = try NDJSONReader.hashFile(at: url)
        guard byteCount > 0 else { throw ImportError.emptyFile }
        guard byteCount <= options.limits.maximumFileBytes else {
            throw ImportError.fileTooLarge(bytes: byteCount, limit: options.limits.maximumFileBytes)
        }

        return ImportPreflight(
            filename: UntrustedText(optional: url.lastPathComponent, limit: 128),
            fileSizeBytes: byteCount,
            sourceHash: digest,
            looksLikeNDJSON: Self.looksLikeNDJSON(prefix),
            isDuplicate: options.knownSourceHashes.contains(digest)
        )
    }

    static func looksLikeNDJSON(_ prefix: [UInt8]) -> Bool {
        for byte in prefix {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            case UInt8(ascii: "{"): return true
            default: return false
            }
        }
        return false
    }

    // MARK: - Import

    public func importReport(
        from url: URL,
        options: ImportOptions = ImportOptions(),
        progress: @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportResult {
        let preflight = try await inspect(url, options: options)
        let decoder = decoderFactory(options)
        let reader = NDJSONReader(limits: options.limits)

        // Accumulated in a reference so that the progress callback and the line
        // handler can both see it without two closures capturing the same
        // mutable local.
        let state = ImportState(warningLimit: options.limits.retainedWarningCount)

        progress(ImportProgress(stage: .readingFile, bytesRead: 0, totalBytes: preflight.fileSizeBytes, recordsAccepted: 0))

        _ = try reader.read(
            url: url,
            onChunk: { bytesRead in
                progress(ImportProgress(
                    stage: .validatingRecords,
                    bytesRead: bytesRead,
                    totalBytes: preflight.fileSizeBytes,
                    recordsAccepted: state.counts.acceptedRecords
                ))
            },
            handler: { event in
                switch event {
                case .oversizeLine(let number):
                    state.counts.totalLines += 1
                    state.counts.skippedOversizeLines += 1
                    state.note(ImportWarning(code: .lineTooLong, lineNumber: number))
                    return true

                case .line(let number, let bytes):
                    state.counts.totalLines += 1
                    guard state.counts.acceptedRecords < options.limits.maximumRecordCount else {
                        if !state.hitRecordLimit {
                            state.hitRecordLimit = true
                            state.note(ImportWarning(code: .recordLimitReached, lineNumber: number))
                        }
                        return false
                    }

                    let lineHash = FireHasher.hash(bytes)
                    let parsed: JSONParser.Output
                    do {
                        parsed = try JSONParser.parse(bytes, options: JSONParser.Options(limits: options.limits))
                    } catch let failure as JSONParser.Failure {
                        state.counts.invalidLines += 1
                        state.note(ImportWarning(
                            code: Self.warningCode(for: failure),
                            lineNumber: number,
                            detail: Self.detail(for: failure)
                        ))
                        return true
                    }
                    if parsed.truncatedFieldCount > 0 {
                        state.note(ImportWarning(code: .fieldTruncated, lineNumber: number))
                    }

                    do {
                        var lineWarnings: [ImportWarning] = []
                        let record = try decoder.decode(
                            parsed.value,
                            lineNumber: number,
                            lineHash: lineHash,
                            warnings: &lineWarnings
                        )
                        for warning in lineWarnings { state.note(warning) }
                        state.records.append(record)
                        switch record.kind {
                        case .networkActivity: state.counts.networkRecords += 1
                        case .access: state.counts.sensorRecords += 1
                        }
                    } catch AppActivityRecordDecoder.DecodeFailure.unknownRecordType {
                        // Unknown record families are preserved as a warning, not
                        // treated as corruption: Apple adds record types.
                        state.counts.unknownRecordTypes += 1
                        state.note(ImportWarning(code: .unknownRecordType, lineNumber: number))
                    } catch AppActivityRecordDecoder.DecodeFailure.missingDiscriminator {
                        state.counts.invalidLines += 1
                        state.note(ImportWarning(code: .missingDiscriminator, lineNumber: number))
                    } catch AppActivityRecordDecoder.DecodeFailure.notAnObject {
                        state.counts.invalidLines += 1
                        state.note(ImportWarning(code: .emptyRecord, lineNumber: number))
                    } catch {
                        state.counts.invalidLines += 1
                        state.note(ImportWarning(code: .invalidJSON, lineNumber: number))
                    }
                    return true
                }
            }
        )

        if Task.isCancelled { throw ImportError.cancelled }
        progress(ImportProgress(
            stage: .normalizing,
            bytesRead: preflight.fileSizeBytes,
            totalBytes: preflight.fileSizeBytes,
            recordsAccepted: state.counts.acceptedRecords
        ))

        if state.counts.totalLines > 0, state.counts.invalidRatio > options.limits.maximumInvalidLineRatio {
            throw ImportError.tooManyInvalidLines(
                ratio: state.counts.invalidRatio,
                limit: options.limits.maximumInvalidLineRatio
            )
        }

        let sessionID = DeterministicUUID.make(
            namespace: .importSession,
            name: "\(preflight.sourceHash.hexString)|\(options.now.timeIntervalSince1970)|\(options.label ?? "")"
        )
        let aggregate = normalizer.aggregate(records: state.records, sessionID: sessionID)

        if preflight.isDuplicate {
            state.note(ImportWarning(code: .duplicateSourceFile, lineNumber: nil))
        }

        let session = ImportSession(
            id: sessionID,
            sourceHash: preflight.sourceHash,
            sourceFilename: preflight.filename,
            importedAt: options.now,
            reportStart: aggregate.reportStart,
            reportEnd: aggregate.reportEnd,
            recordCount: state.counts.acceptedRecords,
            invalidCount: state.counts.invalidLines,
            unknownCount: state.counts.unknownRecordTypes,
            rawCopyState: .none,
            status: statusFor(counts: state.counts),
            warningCodes: Array(Set(state.warnings.map(\.code.rawValue))).sorted(),
            label: UntrustedText(optional: options.label, limit: 64),
            isDemoData: options.isDemoData
        )

        let snapshot = ObservationSnapshot(
            session: session,
            applications: aggregate.applications,
            networkObservations: aggregate.networkObservations,
            sensorObservations: aggregate.sensorObservations
        ).sorted()

        progress(ImportProgress(
            stage: .finished,
            bytesRead: preflight.fileSizeBytes,
            totalBytes: preflight.fileSizeBytes,
            recordsAccepted: state.counts.acceptedRecords
        ))

        return ImportResult(
            snapshot: snapshot,
            counts: state.counts,
            warnings: state.warnings,
            isDuplicateOfExistingImport: preflight.isDuplicate
        )
    }

    private func statusFor(counts: ImportCounts) -> ImportSession.Status {
        if counts.acceptedRecords == 0 { return .failed }
        if counts.invalidLines > 0 || counts.unknownRecordTypes > 0 || counts.skippedOversizeLines > 0 {
            return .partial
        }
        return .complete
    }

    private static func warningCode(for failure: JSONParser.Failure) -> ImportWarning.Code {
        switch failure {
        case .depthExceeded: .excessiveNesting
        case .invalidUTF8: .invalidUTF8
        case .empty: .emptyRecord
        default: .invalidJSON
        }
    }

    private static func detail(for failure: JSONParser.Failure) -> String? {
        switch failure {
        case .duplicateKey: "duplicate_key"
        case .invalidEscape: "invalid_escape"
        case .invalidNumber: "invalid_number"
        case .trailingData: "trailing_data"
        case .unexpectedEnd: "unexpected_end"
        case .unexpectedByte: "unexpected_byte"
        default: nil
        }
    }
}

/// Mutable accumulator for one import.
///
/// A reference type on purpose: the progress callback and the line handler are
/// two separate closures over the same counters, and sharing a reference keeps
/// that legal and obvious rather than relying on capture semantics.
private final class ImportState {
    var counts = ImportCounts()
    var warnings: [ImportWarning] = []
    var records: [DecodedRecord] = []
    var hitRecordLimit = false

    private let warningLimit: Int

    init(warningLimit: Int) {
        self.warningLimit = warningLimit
    }

    /// Retains a bounded number of warnings: a file with a million bad lines
    /// must not turn into a million-entry array.
    func note(_ warning: ImportWarning) {
        guard warnings.count < warningLimit else { return }
        warnings.append(warning)
    }
}
