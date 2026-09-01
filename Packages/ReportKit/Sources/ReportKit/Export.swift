import Foundation
import ObservationCore
import FindingEngine
import KnowledgeBaseKit
import ObservationStore

/// How much detail an export carries (EXP-003).
public enum RedactionPreset: String, Codable, Sendable, Hashable, CaseIterable {
    /// Everything, for the user's own archive.
    case fullPersonalArchive
    /// Full technical detail, minus personal notes.
    case securityPractitioner
    /// Enough for a vendor to investigate a false positive.
    case vendorSupport
    /// Structure and counts only; no bundle IDs, no domains.
    case anonymousBugReport

    public var displayName: String {
        switch self {
        case .fullPersonalArchive: "Full personal archive"
        case .securityPractitioner: "Security practitioner"
        case .vendorSupport: "Vendor support"
        case .anonymousBugReport: "Anonymous bug report"
        }
    }

    public var includesBundleIdentifiers: Bool { self != .anonymousBugReport }
    public var includesDomains: Bool { self != .anonymousBugReport }
    public var includesUserNotes: Bool { self == .fullPersonalArchive }
    public var includesExplanations: Bool { self == .fullPersonalArchive || self == .securityPractitioner }
    public var includesTimestamps: Bool { self != .anonymousBugReport }

    public var description: String {
        switch self {
        case .fullPersonalArchive: "Everything Fire Privacy holds about these imports, including your own notes."
        case .securityPractitioner: "Full technical detail with your personal notes removed."
        case .vendorSupport: "The domains and rule versions involved, without your notes or unrelated apps."
        case .anonymousBugReport: "Counts, versions and rule identifiers only. No app names, no domains."
        }
    }
}

/// Version stamps every export carries (EXP-004).
public struct ExportMetadata: Codable, Sendable, Hashable {
    public let schemaVersion: String
    public let appVersion: String
    public let osVersion: String
    public let parserVersion: String
    public let normalizationVersion: String
    public let ruleSetVersion: String
    public let engineVersion: String
    public let knowledgeBaseVersion: String
    public let filterDatasetVersion: String?
    public let sourceHashes: [String]
    public let redaction: RedactionPreset
    public let generatedAt: Date

    public init(
        appVersion: String,
        osVersion: String,
        sessions: [StoredSession],
        filterDatasetVersion: String?,
        redaction: RedactionPreset,
        generatedAt: Date
    ) {
        self.schemaVersion = ComponentVersion.schema
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.parserVersion = sessions.first?.snapshot.session.parserVersion ?? ComponentVersion.parser
        self.normalizationVersion = sessions.first?.snapshot.session.normalizationVersion ?? ComponentVersion.normalization
        self.ruleSetVersion = sessions.first?.ruleSetVersion ?? "unknown"
        self.engineVersion = ComponentVersion.engine
        self.knowledgeBaseVersion = sessions.first?.knowledgeBaseVersion.datasetVersion ?? "unknown"
        self.filterDatasetVersion = filterDatasetVersion
        self.sourceHashes = sessions.map(\.snapshot.session.sourceHash.hexString)
        self.redaction = redaction
        self.generatedAt = generatedAt
    }
}

/// What the user sees before exporting (EXP-002).
public struct ExportPreview: Sendable, Hashable {
    public let sessionCount: Int
    public let bundleIdentifiers: [String]
    public let domains: [String]
    public let includesUserNotes: Bool
    public let includesExplanations: Bool
    public let redaction: RedactionPreset
    public let estimatedByteCount: Int

    public init(
        sessionCount: Int,
        bundleIdentifiers: [String],
        domains: [String],
        includesUserNotes: Bool,
        includesExplanations: Bool,
        redaction: RedactionPreset,
        estimatedByteCount: Int
    ) {
        self.sessionCount = sessionCount
        self.bundleIdentifiers = bundleIdentifiers
        self.domains = domains
        self.includesUserNotes = includesUserNotes
        self.includesExplanations = includesExplanations
        self.redaction = redaction
        self.estimatedByteCount = estimatedByteCount
    }
}

/// Builds exports. Nothing here uploads anything: the caller hands the result to
/// the share sheet or the Files picker (EXP-005).
public struct ExportBuilder: Sendable {
    public let appVersion: String
    public let osVersion: String
    public let filterDatasetVersion: String?

    public init(appVersion: String, osVersion: String, filterDatasetVersion: String? = nil) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.filterDatasetVersion = filterDatasetVersion
    }

    public func preview(sessions: [StoredSession], redaction: RedactionPreset) -> ExportPreview {
        let bundleIDs = redaction.includesBundleIdentifiers
            ? Array(Set(sessions.flatMap { $0.snapshot.applications.map(\.bundleID.rawValue) })).sorted()
            : []
        let domains = redaction.includesDomains
            ? Array(Set(sessions.flatMap { $0.snapshot.networkObservations.map(\.host.value) })).sorted()
            : []
        let json = (try? makeJSON(sessions: sessions, redaction: redaction, generatedAt: Date())) ?? Data()

        return ExportPreview(
            sessionCount: sessions.count,
            bundleIdentifiers: bundleIDs,
            domains: domains,
            includesUserNotes: redaction.includesUserNotes,
            includesExplanations: redaction.includesExplanations,
            redaction: redaction,
            estimatedByteCount: json.count
        )
    }

    // MARK: - JSON

    public func makeJSON(sessions: [StoredSession], redaction: RedactionPreset, generatedAt: Date) throws -> Data {
        let document = ExportDocument(
            metadata: ExportMetadata(
                appVersion: appVersion,
                osVersion: osVersion,
                sessions: sessions,
                filterDatasetVersion: filterDatasetVersion,
                redaction: redaction,
                generatedAt: generatedAt
            ),
            sessions: sessions.map { ExportedSession(session: $0, redaction: redaction) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    // MARK: - CSV

    /// One row per network observation. Values are quoted and internal quotes
    /// doubled, so a hostile field cannot break out of its cell.
    public func makeNetworkCSV(sessions: [StoredSession], redaction: RedactionPreset) -> String {
        var rows = ["session_id,bundle_id,host,registrable_domain,categories,organization,contacts,first_seen,last_seen,report_lines,evidence_id"]
        for session in sessions {
            for observation in session.snapshot.networkObservations {
                let fields = [
                    session.snapshot.session.id.uuidString,
                    redaction.includesBundleIdentifiers ? (observation.bundleID?.rawValue ?? "") : "redacted",
                    redaction.includesDomains ? observation.host.value : "redacted",
                    redaction.includesDomains ? (observation.registrableDomain?.value ?? "") : "redacted",
                    "",
                    redaction.includesDomains ? (observation.domainOwner?.value ?? "") : "redacted",
                    observation.hits.map(String.init) ?? "",
                    redaction.includesTimestamps ? Self.iso(observation.firstTimestamp) : "",
                    redaction.includesTimestamps ? Self.iso(observation.lastTimestamp) : "",
                    String(observation.mergedRecordCount),
                    observation.evidenceID,
                ]
                rows.append(fields.map(Self.csvEscape).joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    public func makeFindingsCSV(sessions: [StoredSession], redaction: RedactionPreset) -> String {
        var rows = ["session_id,finding_id,rule_id,rule_version,subject,severity,confidence,status,categories,evidence_ids"]
        for session in sessions {
            for finding in session.findings {
                let fields = [
                    session.snapshot.session.id.uuidString,
                    finding.id,
                    finding.ruleID,
                    finding.ruleVersion,
                    redaction.includesBundleIdentifiers ? finding.subject.key : "redacted",
                    finding.severity.rawValue,
                    String(format: "%.4f", finding.confidence),
                    finding.status.rawValue,
                    finding.categoryKeys.joined(separator: " "),
                    finding.evidenceIDs.joined(separator: " "),
                ]
                rows.append(fields.map(Self.csvEscape).joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Markdown

    public func makeMarkdown(sessions: [StoredSession], redaction: RedactionPreset, generatedAt: Date) -> String {
        var lines: [String] = ["# Fire Privacy report", ""]
        lines.append("Generated \(Self.iso(generatedAt)) · redaction: \(redaction.displayName)")
        lines.append("")
        lines.append("This report describes what an App Privacy Report export recorded. It shows that contacts happened; it does not show what was sent.")
        lines.append("")

        for session in sessions {
            let importSession = session.snapshot.session
            lines.append("## Import \(importSession.importedAt.formattedDay)")
            if importSession.isDemoData { lines.append("**Demo data — not from your device.**") }
            lines.append("")
            lines.append("- Apps observed: \(session.snapshot.applications.count)")
            lines.append("- Domains observed: \(Set(session.snapshot.networkObservations.map(\.host.value)).count)")
            lines.append("- Sensor access records: \(session.snapshot.sensorObservations.count)")
            lines.append("- Rule set: \(session.ruleSetVersion) · knowledge base: \(session.knowledgeBaseVersion.datasetVersion)")
            if importSession.status != .complete {
                lines.append("- Import status: \(importSession.status.rawValue) — some lines could not be read, so results may be incomplete.")
            }
            lines.append("")
            lines.append("### Posture")
            lines.append("")
            lines.append("| Dimension | Score |")
            lines.append("| --- | ---: |")
            lines.append("| Sensor exposure | \(session.scores.sensorExposure) |")
            lines.append("| Third-party reach | \(session.scores.thirdPartyReach) |")
            lines.append("| Aggregation signals | \(session.scores.aggregationSignals) |")
            lines.append("| Repetition | \(session.scores.repetition) |")
            lines.append("| Control gap | \(session.scores.controlGap) |")
            lines.append("| Evidence confidence | \(session.scores.evidenceConfidence) |")
            lines.append("")
            lines.append("### Findings")
            lines.append("")
            for finding in session.findings {
                let subject = redaction.includesBundleIdentifiers ? finding.subject.displayValue : "redacted"
                lines.append("#### \(finding.severity.displayName) · \(finding.ruleID)")
                lines.append("")
                lines.append(redaction.includesDomains ? finding.title : "Details redacted for this export preset.")
                lines.append("")
                lines.append("- Subject: \(subject)")
                lines.append("- Confidence: \(Int(finding.confidence * 100))/100")
                lines.append("- Status: \(finding.status.rawValue)")
                for item in finding.uncertainty {
                    lines.append("- Not established: \(item)")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func csvEscape(_ value: String) -> String {
        // A leading =, +, - or @ makes a spreadsheet treat a cell as a formula.
        let needsGuard = value.first.map { "=+-@".contains($0) } ?? false
        let guarded = needsGuard ? "'" + value : value
        return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func iso(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }
}

struct ExportDocument: Codable, Sendable {
    let metadata: ExportMetadata
    let sessions: [ExportedSession]
}

struct ExportedSession: Codable, Sendable {
    let sessionID: UUID
    let importedAt: Date?
    let reportStart: Date?
    let reportEnd: Date?
    let sourceHash: String
    let status: String
    let recordCount: Int
    let invalidCount: Int
    let unknownCount: Int
    let isDemoData: Bool
    let applications: [String]
    let networkObservations: [NetworkObservation]
    let sensorObservations: [SensorObservation]
    let findings: [Finding]
    let scores: PostureScores

    init(session: StoredSession, redaction: RedactionPreset) {
        let importSession = session.snapshot.session
        self.sessionID = importSession.id
        self.importedAt = redaction.includesTimestamps ? importSession.importedAt : nil
        self.reportStart = redaction.includesTimestamps ? importSession.reportStart : nil
        self.reportEnd = redaction.includesTimestamps ? importSession.reportEnd : nil
        self.sourceHash = importSession.sourceHash.hexString
        self.status = importSession.status.rawValue
        self.recordCount = importSession.recordCount
        self.invalidCount = importSession.invalidCount
        self.unknownCount = importSession.unknownCount
        self.isDemoData = importSession.isDemoData
        self.applications = redaction.includesBundleIdentifiers
            ? session.snapshot.applications.map(\.bundleID.rawValue)
            : []
        self.networkObservations = redaction.includesDomains ? session.snapshot.networkObservations : []
        self.sensorObservations = redaction.includesBundleIdentifiers ? session.snapshot.sensorObservations : []
        self.findings = session.findings
        self.scores = session.scores
    }
}

extension Date {
    var formattedDay: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: self)
    }
}
