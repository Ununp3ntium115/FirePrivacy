import Foundation

public struct ReportExportOptions: Codable, Equatable, Sendable {
    public let redactIdentifiers: Bool
    public let includeTimestamps: Bool
    public let includeContext: Bool
    public let includeOwners: Bool
    public let includeProvenance: Bool
    public let includeImportDate: Bool
    public init(redactIdentifiers: Bool = false, includeTimestamps: Bool = true, includeContext: Bool = true,
                includeOwners: Bool = true, includeProvenance: Bool = true, includeImportDate: Bool = true) {
        self.redactIdentifiers = redactIdentifiers; self.includeTimestamps = includeTimestamps
        self.includeContext = includeContext; self.includeOwners = includeOwners
        self.includeProvenance = includeProvenance; self.includeImportDate = includeImportDate
    }
    public static let full = ReportExportOptions()
    public static let redacted = ReportExportOptions(redactIdentifiers: true, includeTimestamps: false,
        includeContext: false, includeOwners: false, includeProvenance: false, includeImportDate: false)
}

public struct ReportExportDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let dateEncoding: String
    public let syntheticDemo: Bool
    public let redacted: Bool
    public let omittedFields: [String]
    public let disclosures: [String]
    public let report: PrivacyReport
    public let analysis: FindingAnalysis?
}

public enum ReportExporter {
    /// Creates a normalized copy, never the original raw export. No upload occurs here.
    public static func document(report: PrivacyReport, analysis: FindingAnalysis? = nil,
                                options: ReportExportOptions = .full) -> ReportExportDocument {
        let appNames = Array(Set(report.observations.map(\.bundleID))).sorted()
        let domainNames = Array(Set(report.observations.compactMap(\.domain))).sorted()
        let apps = Dictionary(uniqueKeysWithValues: appNames.enumerated().map { ($0.element, "app-\($0.offset + 1)") })
        let domains = Dictionary(uniqueKeysWithValues: domainNames.enumerated().map { ($0.element, "domain-\($0.offset + 1).invalid") })
        var omitted: [String] = []
        if options.redactIdentifiers { omitted += ["original app/domain identifiers", "source fingerprints", "sensor identifiers", "textual reported classification values", "analysis narrative"] }
        if !options.includeTimestamps { omitted.append("record timestamps") }
        if !options.includeContext || options.redactIdentifiers { omitted.append("context") }
        if !options.includeOwners || options.redactIdentifiers { omitted.append("reported owners") }
        if !options.includeProvenance || options.redactIdentifiers { omitted.append("source provenance") }
        if !options.includeImportDate { omitted.append("import date (epoch sentinel used in normalized model)") }
        let observations = report.observations.enumerated().map { index, record in
            Observation(id: options.redactIdentifiers ? ContentDigest.stableID("FirePrivacy/RedactedObservation/v1/\(index)") : record.id,
                bundleID: options.redactIdentifiers ? (apps[record.bundleID] ?? "app-unknown") : record.bundleID,
                domain: record.domain.map { options.redactIdentifiers ? (domains[$0] ?? "domain-unknown.invalid") : $0 },
                category: record.category, accessType: options.redactIdentifiers ? (record.category == .sensor ? redactedCategory(record.sensorCategory) : "networkActivity") : record.accessType,
                count: record.count, timestamp: options.includeTimestamps ? record.timestamp : nil,
                firstTimestamp: options.includeTimestamps ? record.firstTimestamp : nil, lastTimestamp: options.includeTimestamps ? record.lastTimestamp : nil,
                timestampText: options.includeTimestamps ? record.timestampText : nil,
                firstTimestampText: options.includeTimestamps ? record.firstTimestampText : nil,
                lastTimestampText: options.includeTimestamps ? record.lastTimestampText : nil,
                eventKind: options.redactIdentifiers ? redactedEventKind(record.eventKind) : record.eventKind,
                provenance: options.includeProvenance && !options.redactIdentifiers ? record.provenance : nil,
                context: options.includeContext && !options.redactIdentifiers ? record.context : nil,
                domainOwner: options.includeOwners && !options.redactIdentifiers ? record.domainOwner : nil,
                domainType: scalar(record.domainType, redacted: options.redactIdentifiers),
                initiatedType: scalar(record.initiatedType, redacted: options.redactIdentifiers),
                domainClassification: scalar(record.domainClassification, redacted: options.redactIdentifiers),
                sensorIdentifier: options.redactIdentifiers ? nil : record.sensorIdentifier,
                originalDomain: options.redactIdentifiers ? nil : record.originalDomain)
        }
        let metadata = report.metadata.map { metadata in
            ReportMetadata(sourceSHA256: options.includeProvenance && !options.redactIdentifiers ? metadata.sourceSHA256 : nil,
                sourceFilename: options.includeProvenance && !options.redactIdentifiers ? metadata.sourceFilename : nil,
                parserVersion: options.redactIdentifiers ? safeVersion(metadata.parserVersion) : metadata.parserVersion,
                normalizationVersion: options.redactIdentifiers ? safeVersion(metadata.normalizationVersion) : metadata.normalizationVersion,
                reportStart: options.includeTimestamps ? metadata.reportStart : nil,
                reportEnd: options.includeTimestamps ? metadata.reportEnd : nil, status: metadata.status,
                recognizedRecords: metadata.recognizedRecords, skippedRecords: metadata.skippedRecords, isSyntheticDemo: metadata.isSyntheticDemo)
        }
        // Imported issue strings from legacy documents may contain arbitrary private text.
        let issues = options.redactIdentifiers ? report.issues.map { ImportIssue(message: "Record was not imported.", line: $0.line) } : report.issues
        let sanitized = PrivacyReport(id: options.redactIdentifiers ? ContentDigest.stableID("FirePrivacy/RedactedReport/v1") : report.id,
            importedAt: options.includeImportDate ? report.importedAt : Date(timeIntervalSince1970: 0),
            observations: observations, issues: issues, metadata: metadata)
        let matchingAnalysis = analysis?.reportID == report.id ? analysis : nil
        return ReportExportDocument(schemaVersion: "2.0.0", dateEncoding: "unixSeconds", syntheticDemo: report.metadata?.isSyntheticDemo == true,
            redacted: options.redactIdentifiers, omittedFields: omitted,
            disclosures: ["This is a normalized copy of exported records; it is not a complete copy of the original file.",
                          "Recorded contacts do not reveal payloads, causation, harmfulness, or current permissions.",
                          "Redaction removes selected identifiers, not all possible identifying patterns; counts and record ordering remain.",
                          "The core exporter writes data locally and does not transmit it."],
            report: sanitized, analysis: options.redactIdentifiers ? nil : matchingAnalysis)
    }

    public static func json(report: PrivacyReport, analysis: FindingAnalysis? = nil,
                            options: ReportExportOptions = .full) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // Numeric seconds retain Foundation Date precision; exact source lexical precision
        // remains in timestampText. ISO8601DateFormatter's default would drop fractions.
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(document(report: report, analysis: analysis, options: options))
    }

    public static func csv(report: PrivacyReport, options: ReportExportOptions = .full) -> Data {
        let export = document(report: report, options: options)
        let copy = export.report
        var rows = [["synthetic_demo", "redacted", "evidence_id", "app", "record_category", "access_type", "domain", "recorded_count", "timestamp", "first_timestamp", "last_timestamp", "event_kind", "sensor_identifier", "context", "reported_owner", "domain_type", "initiated_type", "domain_classification", "source_line", "source_line_sha256"]]
        for record in copy.observations {
            rows.append([String(export.syntheticDemo), String(export.redacted), record.id.uuidString, record.bundleID, record.category.rawValue, record.accessType, record.domain ?? "", String(record.count),
                         timeText(record.timestampText, record.timestamp), timeText(record.firstTimestampText, record.firstTimestamp),
                         timeText(record.lastTimestampText, record.lastTimestamp), record.eventKind ?? "", record.sensorIdentifier ?? "", record.context ?? "",
                         record.domainOwner ?? "", record.domainType?.displayValue ?? "", record.initiatedType?.displayValue ?? "", record.domainClassification?.displayValue ?? "",
                         record.provenance.map { String($0.sourceLine) } ?? "", record.provenance?.sourceSHA256 ?? ""])
        }
        return Data((rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }

    public static func markdown(report: PrivacyReport, analysis: FindingAnalysis? = nil,
                                options: ReportExportOptions = .full) -> Data {
        let export = document(report: report, analysis: analysis, options: options)
        let copy = export.report
        var lines = ["# Fire Privacy report", "", export.syntheticDemo ? "Synthetic demonstration data." : "Imported App Privacy Report evidence.", "",
                     "Recorded network contacts: \(copy.totalContacts). Sensor event records: \(copy.observations.filter { $0.category == .sensor }.count).", "",
                     "Contacts do not establish payloads, harmfulness, or transmission of sensor data. Sensor history does not establish current permissions.", ""]
        if export.redacted { lines += ["Identifiers are replaced with export-local labels. Selected private fields and analysis narrative are omitted; count patterns remain.", ""] }
        lines += ["| App | Record | Resource | Recorded count | Timestamp |", "| --- | --- | --- | ---: | --- |"]
        for record in copy.observations {
            let resource = record.domain ?? record.accessType
            lines.append("| \(markdownCell(record.bundleID)) | \(record.category.rawValue) | \(markdownCell(resource)) | \(record.count) | \(markdownCell(timeText(record.timestampText, record.timestamp))) |")
        }
        if let analysis = export.analysis {
            lines += ["", "## Deterministic findings", ""]
            for finding in analysis.findings {
                lines += ["### \(markdownCell(finding.title))", "", markdownCell(finding.detail), "", "Rule: \(markdownCell(finding.ruleID)), version \(markdownCell(finding.ruleVersion)).", ""]
                for fact in finding.observedFacts { lines.append("- Observed: \(markdownCell(fact.key)): \(markdownCell(fact.value)).") }
                for inference in finding.inferences { lines.append("- Inference: \(markdownCell(inference.statement)) (confidence \(inference.confidence)).") }
                for uncertainty in finding.uncertainty { lines.append("- Uncertainty: \(markdownCell(uncertainty)).") }
                lines.append("")
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func scalar(_ value: ReportedValue?, redacted: Bool) -> ReportedValue? {
        guard redacted, let value else { return value }
        switch value {
        case .text: return nil
        case .number(let token):
            return token.utf8.count <= 128 && token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil ? value : nil
        default: return value
        }
    }
    private static func safeVersion(_ value: String) -> String {
        value.utf8.count <= 64 && value.range(of: #"^[0-9]+([.-][0-9]+)*$"#, options: .regularExpression) != nil ? value : "unavailable"
    }
    private static func redactedCategory(_ value: String) -> String {
        ["camera", "microphone", "location", "contacts", "photos"].contains(value) ? value : "unrecognized-sensor-category"
    }
    private static func redactedEventKind(_ value: String?) -> String? {
        guard let value else { return nil }
        return ["intervalbegin", "intervalend", "instantaneous"].contains(value.lowercased()) ? value : "unrecognized-event-kind"
    }
    private static func timeText(_ original: String?, _ date: Date?) -> String {
        if let original { return original }
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }
    private static func csvCell(_ text: String) -> String {
        var safe = ImportedText.sanitize(text, maximumCharacters: 4_096)
        // Spreadsheet formula execution is independent of RFC CSV quoting.
        if let first = safe.trimmingCharacters(in: .whitespacesAndNewlines).first, "=+-@".contains(first) { safe = "'" + safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func markdownCell(_ text: String) -> String {
        var safe = ImportedText.sanitize(text, maximumCharacters: 4_096)
        for (source, replacement) in [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\\", "\\\\"),
                                       ("|", "\\|"), ("`", "\\`"), ("*", "\\*"), ("_", "\\_"), ("[", "\\["), ("]", "\\]"), ("#", "\\#")] {
            safe = safe.replacingOccurrences(of: source, with: replacement)
        }
        return safe
    }
}

public enum DiagnosticEventCode: String, Codable, Sendable {
    case importRejected, partialImport, storageUnavailable, storageMigrationFailed, consentRequired
    case networkDenied, updateRejected, modelUnavailable, exportFailed
}

/// Deliberately excludes identifiers, report content, source hashes, user notes, URLs, and arbitrary messages.
public struct SanitizedDiagnostics: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let appVersion: String
    public let osVersion: String
    public let parserVersion: String?
    public let normalizationVersion: String?
    public let reportCount: Int
    public let observationCount: Int
    public let skippedLineCount: Int
    public let eventCodes: [DiagnosticEventCode]
}

public enum DiagnosticsBuilder {
    public static func build(reports: [PrivacyReport], appVersion: String, osVersion: String,
                             eventCodes: [DiagnosticEventCode] = []) -> SanitizedDiagnostics {
        // Version fields use a strict token alphabet so they cannot become a private-message channel.
        func version(_ value: String) -> String {
            guard !value.isEmpty, value.utf8.count <= 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 || $0 == 45 }) else { return "unavailable" }
            return value
        }
        return SanitizedDiagnostics(schemaVersion: "1.0.0", appVersion: version(appVersion), osVersion: version(osVersion),
            parserVersion: reports.last?.metadata.map { version($0.parserVersion) },
            normalizationVersion: reports.last?.metadata.map { version($0.normalizationVersion) },
            reportCount: reports.count, observationCount: reports.reduce(0) { $0 + $1.observations.count },
            skippedLineCount: reports.reduce(0) { $0 + $1.issues.count }, eventCodes: Array(eventCodes.prefix(100)))
    }
    public static func json(_ diagnostics: SanitizedDiagnostics) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(diagnostics)
    }
}
