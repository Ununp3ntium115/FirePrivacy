import Foundation
import CoreFoundation

public enum AppUsageError: Error, LocalizedError, Equatable, Sendable {
    case invalidRange, invalidReference, invalidTimeline, invalidJSON, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidRange: "Usage timestamps must form a valid range with an explicit time zone."
        case .invalidReference: "The supplied usage reference is incomplete or inconsistent."
        case .invalidTimeline: "The usage timeline exceeds its supported limits or contains duplicate references."
        case .invalidJSON: "Choose a valid FirePrivacy usage-reference JSON file."
        case .tooLarge: "Choose a usage-reference JSON file smaller than 1 MB."
        }
    }
}

/// These identify how evidence was supplied, never independently verified OS telemetry.
public enum AppUsageProvenance: String, Codable, CaseIterable, Sendable {
    case userRecollection, userTranscribedSystemUsage, importedUsageLog
    public var label: String {
        switch self {
        case .userRecollection: "User recollection"
        case .userTranscribedSystemUsage: "User-transcribed system usage"
        case .importedUsageLog: "Imported usage log"
        }
    }
    public var independentlyVerified: Bool { false }
}

public enum AppUsageDeviceScope: String, Codable, CaseIterable, Sendable {
    case sameDeviceAsReport, otherDeviceOrCombined, unspecified
}

/// Closed boundaries are intentionally conservative: an event exactly at either
/// boundary is treated as overlapping rather than inventing a background event.
public struct UsageTimeRange: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let startTimestampText: String?
    public let endTimestampText: String?
    public init(start: Date, end: Date, startTimestampText: String? = nil, endTimestampText: String? = nil) throws {
        let lower = try usageInstant(start, text: startTimestampText)
        let upper = try usageInstant(end, text: endTimestampText)
        guard lower <= upper, lower.seconds >= -62_135_596_800, upper.seconds <= 253_402_300_799 else { throw AppUsageError.invalidRange }
        self.start = start; self.end = end
        self.startTimestampText = startTimestampText; self.endTimestampText = endTimestampText
    }
    public init(startTimestampText: String, endTimestampText: String) throws {
        let parser = TimestampParser()
        guard let start = try? parser.read(["timeStamp": startTimestampText], key: "timeStamp").date,
              let end = try? parser.read(["timeStamp": endTimestampText], key: "timeStamp").date else { throw AppUsageError.invalidRange }
        try self.init(start: start, end: end, startTimestampText: startTimestampText, endTimestampText: endTimestampText)
    }
    private enum CodingKeys: String, CodingKey { case start, end, startTimestampText, endTimestampText }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: c.decode(Date.self, forKey: .start), end: c.decode(Date.self, forKey: .end),
            startTimestampText: c.decodeIfPresent(String.self, forKey: .startTimestampText), endTimestampText: c.decodeIfPresent(String.self, forKey: .endTimestampText))
    }
}

/// Aggregate Screen Time totals contain no session locations. They cannot be
/// combined with foreground windows or assert completeness of those windows.
public struct AppUsageReference: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let bundleID: String
    public let provenance: AppUsageProvenance
    public let deviceScope: AppUsageDeviceScope
    public let comparisonReportID: UUID?
    public let coverage: UsageTimeRange
    public let claimsCompleteForegroundWindows: Bool
    public let foregroundWindows: [UsageTimeRange]
    public let aggregateForegroundSeconds: Double?
    public let sourceLabel: String?
    public let suppliedAt: Date
    public var independentlyVerified: Bool { false }
    public var isAggregate: Bool { aggregateForegroundSeconds != nil }
    public init(id: UUID = UUID(), bundleID: String, provenance: AppUsageProvenance, coverage: UsageTimeRange,
                claimsCompleteForegroundWindows: Bool = false, foregroundWindows: [UsageTimeRange] = [],
                aggregateForegroundSeconds: Double? = nil, sourceLabel: String? = nil, suppliedAt: Date = Date(),
                deviceScope: AppUsageDeviceScope = .unspecified, comparisonReportID: UUID? = nil) throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 255, ImportedText.sanitize(bundleID) == bundleID,
              !bundleID.contains(where: \.isWhitespace), foregroundWindows.count <= 128,
              suppliedAt.timeIntervalSince1970.isFinite else { throw AppUsageError.invalidReference }
        let coverageStart = try usageInstant(coverage.start, text: coverage.startTimestampText)
        let coverageEnd = try usageInstant(coverage.end, text: coverage.endTimestampText)
        for window in foregroundWindows {
            guard try usageInstant(window.start, text: window.startTimestampText) >= coverageStart,
                  try usageInstant(window.end, text: window.endTimestampText) <= coverageEnd else { throw AppUsageError.invalidReference }
        }
        if let total = aggregateForegroundSeconds {
            guard total.isFinite, total >= 0, total <= coverageEnd.timeIntervalSince(coverageStart),
                  foregroundWindows.isEmpty, !claimsCompleteForegroundWindows else { throw AppUsageError.invalidReference }
        }
        self.id = id; self.bundleID = bundleID; self.provenance = provenance; self.deviceScope = deviceScope; self.comparisonReportID = comparisonReportID; self.coverage = coverage
        self.claimsCompleteForegroundWindows = claimsCompleteForegroundWindows; self.foregroundWindows = foregroundWindows
        self.aggregateForegroundSeconds = aggregateForegroundSeconds
        self.sourceLabel = sourceLabel.map { ImportedText.sanitize($0, maximumCharacters: 160) }
        self.suppliedAt = suppliedAt
    }
    private enum CodingKeys: String, CodingKey { case id, bundleID, provenance, deviceScope, comparisonReportID, coverage, claimsCompleteForegroundWindows, foregroundWindows, aggregateForegroundSeconds, sourceLabel, suppliedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), bundleID: c.decode(String.self, forKey: .bundleID),
            provenance: c.decode(AppUsageProvenance.self, forKey: .provenance), coverage: c.decode(UsageTimeRange.self, forKey: .coverage),
            claimsCompleteForegroundWindows: c.decode(Bool.self, forKey: .claimsCompleteForegroundWindows),
            foregroundWindows: c.decode([UsageTimeRange].self, forKey: .foregroundWindows),
            aggregateForegroundSeconds: c.decodeIfPresent(Double.self, forKey: .aggregateForegroundSeconds),
            sourceLabel: c.decodeIfPresent(String.self, forKey: .sourceLabel), suppliedAt: c.decode(Date.self, forKey: .suppliedAt),
            deviceScope: c.decodeIfPresent(AppUsageDeviceScope.self, forKey: .deviceScope) ?? .unspecified,
            comparisonReportID: c.decodeIfPresent(UUID.self, forKey: .comparisonReportID))
    }
}

/// Codable state is intended for the app's authenticated encrypted feature store.
public struct AppUsageTimeline: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let references: [AppUsageReference]
    public static let empty = try! AppUsageTimeline()
    public init(references: [AppUsageReference] = []) throws {
        guard references.count <= 128, Set(references.map(\.id)).count == references.count,
              references.reduce(0, { $0 + $1.foregroundWindows.count }) <= 2_048,
              Dictionary(grouping: references, by: \.bundleID).values.allSatisfy({ $0.count <= 8 }) else { throw AppUsageError.invalidTimeline }
        schemaVersion = 1; self.references = references
    }
    /// Call only when the user explicitly supplies same-device evidence for the
    /// selected report. A prior binding is preserved and never silently reassigned.
    public func bindingClaims(to reportID: UUID) throws -> AppUsageTimeline {
        try AppUsageTimeline(references: references.map { reference in
            guard reference.deviceScope == .sameDeviceAsReport, reference.comparisonReportID == nil else { return reference }
            return try AppUsageReference(id: ContentDigest.stableID("FirePrivacy/UsageClaimBinding/v1|" + reference.id.uuidString + "|" + reportID.uuidString), bundleID: reference.bundleID, provenance: reference.provenance,
                coverage: reference.coverage, claimsCompleteForegroundWindows: reference.claimsCompleteForegroundWindows,
                foregroundWindows: reference.foregroundWindows, aggregateForegroundSeconds: reference.aggregateForegroundSeconds,
                sourceLabel: reference.sourceLabel, suppliedAt: reference.suppliedAt, deviceScope: reference.deviceScope, comparisonReportID: reportID)
        })
    }
    /// Matching IDs are accepted only for byte-equivalent semantic references;
    /// conflicting revisions require an explicit edit rather than an import overwrite.
    public func merging(_ other: AppUsageTimeline) throws -> AppUsageTimeline {
        var combined = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0) })
        for reference in other.references {
            if let existing = combined[reference.id] {
                guard existing.bundleID == reference.bundleID, existing.provenance == reference.provenance, existing.deviceScope == reference.deviceScope, existing.comparisonReportID == reference.comparisonReportID,
                      existing.coverage == reference.coverage, existing.claimsCompleteForegroundWindows == reference.claimsCompleteForegroundWindows,
                      existing.foregroundWindows == reference.foregroundWindows, existing.aggregateForegroundSeconds == reference.aggregateForegroundSeconds,
                      existing.sourceLabel == reference.sourceLabel else { throw AppUsageError.invalidTimeline }
            } else { combined[reference.id] = reference }
        }
        return try AppUsageTimeline(references: combined.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, references }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw AppUsageError.invalidTimeline }
        try self.init(references: c.decode([AppUsageReference].self, forKey: .references))
    }
}

public enum AppUsageAlignment: String, Codable, Sendable {
    case outsideClaimedWindows, overlapsSuppliedWindows, mixedReportedTimestamps, unknown, conflictingReferences, activityDuringZeroReportedForegroundUsage
}
public enum AppActivityPrecision: String, Codable, Sendable {
    case timestampPoint, networkBounds, sensorMatchedInterval, incompleteTimestamp, incompleteSensorInterval, unknown
}
public struct AppActivityTimestamp: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case event, firstContact, lastContact, sensorBegin, sensorEnd }
    public let role: Role
    public let timestamp: Date
    public let timestampText: String?
    public let evidenceID: UUID
}
public struct UsageTimestampAssessment: Codable, Equatable, Sendable {
    public let timestamp: AppActivityTimestamp
    public let alignment: AppUsageAlignment
}
public struct AppUsageReferenceAssessment: Codable, Equatable, Sendable {
    public let referenceID: UUID
    public let provenance: AppUsageProvenance
    public let sourceLabel: String?
    public let deviceScope: AppUsageDeviceScope
    public let comparisonReportID: UUID?
    public let coverage: UsageTimeRange
    public let claimsCompleteForegroundWindows: Bool
    public let aggregateForegroundSeconds: Double?
    public let alignment: AppUsageAlignment
    public let timestamps: [UsageTimestampAssessment]
    public let limitations: [String]
    public var independentlyVerified: Bool { false }
}
public struct AppUsageActivityComparison: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let bundleID: String
    public let evidenceIDs: [UUID]
    public let category: ObservationCategory
    public let sensorCategory: String?
    public let domain: String?
    public let reportedContactCount: Int?
    public let sensorEventRecordCount: Int
    public let start: Date?
    public let end: Date?
    public let precision: AppActivityPrecision
    /// Relates recorded timestamps to supplied windows; never locates every hit.
    public let reportedTimestampAlignment: AppUsageAlignment
    /// Unpaired begin/end records have unknown interval extent even when a
    /// confirmed timestamp lies outside a supplied complete foreground history.
    public let alignment: AppUsageAlignment
    public let reviewSuggested: Bool
    public let timestampEvidence: [AppActivityTimestamp]
    public let rawAPRContexts: [String]
    public let sourceAssessments: [AppUsageReferenceAssessment]
    public let limitations: [String]
}
public struct AppUsageAppComparison: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let activities: [AppUsageActivityComparison]
    public let outsideClaimedWindowActivities: Int
    public let conflictingActivities: Int
    public let zeroReportedUsageActivities: Int
    public let unknownActivities: Int
    /// Total hits in the report, never a background-hit estimate or data volume.
    public let networkContactCount: Int
    public let sensorEventRecords: Int
}
public struct AppUsageTimelineComparison: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let timelineDigest: String
    public let apps: [AppUsageAppComparison]
    public let comparedActivityCount: Int
    public let omittedActivityCount: Int
    public let reachedLimit: Bool
    public let limitations: [String]
}

private func usageInstant(_ date: Date, text: String?) throws -> ExactExportTimestamp {
    guard let instant = ExactExportTimestamp(date: date) else { throw AppUsageError.invalidRange }
    if let text {
        guard let parsed = try? TimestampParser().read(["timeStamp": text], key: "timeStamp"), let exact = parsed.instant,
              parsed.date == date else { throw AppUsageError.invalidRange }
        return exact
    }
    return instant
}

public enum AppUsageTimelineAnalyzer {
    private struct PreparedReference {
        let reference: AppUsageReference
        let start: ExactExportTimestamp
        let end: ExactExportTimestamp
        let windows: [(ExactExportTimestamp, ExactExportTimestamp)]
        init(_ reference: AppUsageReference) throws {
            self.reference = reference
            start = try usageInstant(reference.coverage.start, text: reference.coverage.startTimestampText)
            end = try usageInstant(reference.coverage.end, text: reference.coverage.endTimestampText)
            let sorted = try reference.foregroundWindows.map {
                (try usageInstant($0.start, text: $0.startTimestampText), try usageInstant($0.end, text: $0.endTimestampText))
            }.sorted { $0.0 < $1.0 }
            var merged: [(ExactExportTimestamp, ExactExportTimestamp)] = []
            for window in sorted {
                if let last = merged.last, window.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, window.1) }
                else { merged.append(window) }
            }
            windows = merged
        }
        func alignment(at instant: ExactExportTimestamp, reportID: UUID) -> AppUsageAlignment {
            guard reference.deviceScope == .sameDeviceAsReport, reference.comparisonReportID == reportID, instant >= start, instant <= end else { return .unknown }
            if let total = reference.aggregateForegroundSeconds {
                return total == 0 ? .activityDuringZeroReportedForegroundUsage : .unknown
            }
            var lower = 0, upper = windows.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if windows[middle].0 <= instant { lower = middle + 1 } else { upper = middle }
            }
            if lower > 0, instant <= windows[lower - 1].1 { return .overlapsSuppliedWindows }
            return reference.claimsCompleteForegroundWindows ? .outsideClaimedWindows : .unknown
        }
    }
    private struct Activity {
        let id: String
        let records: [Observation]
        let timestamps: [AppActivityTimestamp]
        let precision: AppActivityPrecision
    }
    public static func analyze(report: PrivacyReport, timeline: AppUsageTimeline, maximumActivities: Int = 5_000) -> AppUsageTimelineComparison {
        let limit = max(0, min(10_000, maximumActivities))
        let prepared = timeline.references.compactMap { try? PreparedReference($0) }
        let references = Dictionary(grouping: prepared, by: { $0.reference.bundleID })
        var activities: [Activity] = []
        let records = Dictionary(report.observations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let intervals = report.sensorIntervals
        let paired = Set(intervals.flatMap(\.evidenceIDs))
        for interval in intervals {
            let matching = interval.evidenceIDs.compactMap { records[$0] }
            let points = matching.compactMap { timestamp($0, role: $0.isSensorBeginRecord ? .sensorBegin : .sensorEnd, date: $0.timestamp, text: $0.timestampText) }
            activities.append(Activity(id: interval.id, records: matching, timestamps: points, precision: .sensorMatchedInterval))
        }
        for observation in report.observations where !paired.contains(observation.id) {
            var points: [AppActivityTimestamp] = []
            let precision: AppActivityPrecision
            if observation.category == .network {
                if let point = timestamp(observation, role: .firstContact, date: observation.firstTimestamp, text: observation.firstTimestampText) { points.append(point) }
                if let point = timestamp(observation, role: .lastContact, date: observation.lastTimestamp, text: observation.lastTimestampText) { points.append(point) }
                if let single = observation.timestampText {
                    // Observation.timestamp can prefer lastTimeStamp for legacy
                    // callers. The separately retained timeStamp text may differ.
                    let date = (try? TimestampParser().read(["timeStamp": single], key: "timeStamp"))?.date
                    if let point = timestamp(observation, role: .event, date: date, text: single) { points.append(point) }
                } else if observation.firstTimestamp == nil && observation.lastTimestamp == nil {
                    if let point = timestamp(observation, role: .event, date: observation.timestamp, text: nil) { points.append(point) }
                }
                precision = points.count >= 2 ? .networkBounds : points.isEmpty ? .unknown : (observation.firstTimestamp != nil || observation.lastTimestamp != nil) ? .incompleteTimestamp : .timestampPoint
            } else {
                if let point = timestamp(observation, role: observation.isSensorBeginRecord ? .sensorBegin : observation.isSensorEndRecord ? .sensorEnd : .event,
                    date: observation.timestamp, text: observation.timestampText) { points.append(point) }
                precision = points.isEmpty ? .unknown : (observation.isSensorBeginRecord || observation.isSensorEndRecord) ? .incompleteSensorInterval : .timestampPoint
            }
            activities.append(Activity(id: "usage:" + observation.id.uuidString, records: [observation], timestamps: points, precision: precision))
        }
        activities.sort { $0.id < $1.id }
        var output: [AppUsageActivityComparison] = []
        for activity in activities.prefix(limit) {
            guard let observation = activity.records.first else { continue }
            var limitations: [String] = []
            if observation.category == .network {
                limitations.append("Network timestamp fields do not locate every reported hit; intermediate hits are not located in time, and hits do not measure data volume.")
                if activity.precision == .networkBounds || activity.precision == .incompleteTimestamp {
                    limitations.append("Network first/last timestamps bracket recorded contacts; a missing endpoint leaves the bracket incomplete.")
                }
            }
            if activity.precision == .sensorMatchedInterval {
                limitations.append("Matched sensor begin/end records are candidate pairs; the export identifier's semantics and continuous sensor access between endpoints are not independently established.")
            }
            if activity.precision == .incompleteSensorInterval {
                limitations.append("This sensor begin/end record has no unambiguous complete pair; its interval extent is unknown.")
            }
            if activity.timestamps.isEmpty { limitations.append("No supported activity timestamp is available; absence of a timestamp does not establish inactivity.") }
            if observation.category == .network && observation.count == 0 { limitations.append("This record reports zero hits; it does not establish a contact occurred.") }
            let timedPoints = activity.timestamps.map { ($0, try? usageInstant($0.timestamp, text: $0.timestampText)) }
            let assessments = (references[observation.bundleID] ?? []).sorted { $0.reference.id.uuidString < $1.reference.id.uuidString }.map { reference in
                let points = timedPoints.map { point, instant in
                    let relation: AppUsageAlignment = observation.category == .network && observation.count == 0 ? .unknown : instant.map { reference.alignment(at: $0, reportID: report.id) } ?? .unknown
                    return UsageTimestampAssessment(timestamp: point, alignment: relation)
                }
                var caveats = ["This supplied usage reference and its completeness claim are independently unverified."]
                if reference.reference.comparisonReportID != report.id { caveats.append("The same-device claim has not been explicitly bound to this selected report; its timestamps cannot establish this report's device usage.") }
                if reference.reference.deviceScope != .sameDeviceAsReport { caveats.append("The reference is not explicitly claimed to describe the same device as this APR export; cross-device or combined usage cannot establish this device's foreground history.") }
                if reference.reference.isAggregate { caveats.append("An aggregate usage duration has no session locations. A zero total can be compared with a covered APR timestamp, but does not independently prove inactivity or background state.") }
                else if !reference.reference.claimsCompleteForegroundWindows { caveats.append("Missing supplied foreground windows may reflect incomplete recollection or logging.") }
                if points.contains(where: { $0.alignment == .unknown }) { caveats.append("At least one timestamp is outside the supplied coverage, has incomplete usage evidence, or cannot be compared.") }
                return AppUsageReferenceAssessment(referenceID: reference.reference.id, provenance: reference.reference.provenance,
                    sourceLabel: reference.reference.sourceLabel, deviceScope: reference.reference.deviceScope, comparisonReportID: reference.reference.comparisonReportID, coverage: reference.reference.coverage,
                    claimsCompleteForegroundWindows: reference.reference.claimsCompleteForegroundWindows,
                    aggregateForegroundSeconds: reference.reference.aggregateForegroundSeconds, alignment: combine(points.map(\.alignment)),
                    timestamps: points, limitations: caveats)
            }
            let relation = combineReferences(assessments)
            let review = assessments.contains { $0.timestamps.contains { $0.alignment == .outsideClaimedWindows || $0.alignment == .activityDuringZeroReportedForegroundUsage } }
            let ordered = activity.timestamps.sorted {
                let a = try? usageInstant($0.timestamp, text: $0.timestampText), b = try? usageInstant($1.timestamp, text: $1.timestampText)
                return a == b ? $0.role.rawValue < $1.role.rawValue : (a ?? ExactExportTimestamp(seconds: 0, nanoseconds: 0)) < (b ?? ExactExportTimestamp(seconds: 0, nanoseconds: 0))
            }
            output.append(AppUsageActivityComparison(id: activity.id, bundleID: observation.bundleID, evidenceIDs: activity.records.map(\.id).sorted { $0.uuidString < $1.uuidString },
                category: observation.category, sensorCategory: observation.category == .sensor ? observation.sensorCategory : nil, domain: observation.domain,
                reportedContactCount: observation.category == .network ? observation.count : nil, sensorEventRecordCount: observation.category == .sensor ? activity.records.count : 0,
                start: ordered.first?.timestamp, end: (activity.precision == .incompleteSensorInterval || activity.precision == .incompleteTimestamp) ? nil : ordered.last?.timestamp,
                precision: activity.precision, reportedTimestampAlignment: relation, alignment: activity.precision == .incompleteSensorInterval ? .unknown : relation,
                reviewSuggested: review, timestampEvidence: ordered, rawAPRContexts: Array(Set(activity.records.compactMap(\.context))).sorted(),
                sourceAssessments: assessments, limitations: limitations))
        }
        let grouped = Dictionary(grouping: output, by: \.bundleID)
        let summaries = report.apps.map { app in
            let rows = (grouped[app.bundleID] ?? []).sorted { a, b in
                a.start == b.start ? a.id < b.id : (a.start ?? .distantFuture) < (b.start ?? .distantFuture)
            }
            return AppUsageAppComparison(bundleID: app.bundleID, activities: rows,
                outsideClaimedWindowActivities: rows.filter { row in row.sourceAssessments.contains { $0.timestamps.contains { $0.alignment == .outsideClaimedWindows } } }.count,
                conflictingActivities: rows.filter { $0.reportedTimestampAlignment == .conflictingReferences }.count,
                zeroReportedUsageActivities: rows.filter { row in row.sourceAssessments.contains { $0.timestamps.contains { $0.alignment == .activityDuringZeroReportedForegroundUsage } } }.count,
                unknownActivities: rows.filter { $0.alignment == .unknown }.count, networkContactCount: app.contacts, sensorEventRecords: app.sensorAccesses)
        }.sorted { $0.bundleID < $1.bundleID }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = (try? AppUsageTimeline(references: timeline.references.sorted { $0.id.uuidString < $1.id.uuidString })) ?? .empty
        let digest = ContentDigest.sha256((try? encoder.encode(canonical)) ?? Data())
        return AppUsageTimelineComparison(reportID: report.id, timelineDigest: digest, apps: summaries, comparedActivityCount: output.count,
            omittedActivityCount: activities.count - output.count, reachedLimit: activities.count > output.count,
            limitations: ["Outside supplied foreground windows is a comparison with an unverified usage claim, not proof that iOS classified an app as background.",
                "Legitimate background refresh, notifications, uploads, navigation, audio, extensions, or system services may explain activity. Timing does not establish misuse, deception, or transmission of sensor data.",
                "No outside-window result does not certify inactivity or privacy; APR and supplied usage evidence can be incomplete.",
                "APR context and initiatedType meanings are not treated as verified foreground/background state."])
    }
    private static func timestamp(_ observation: Observation, role: AppActivityTimestamp.Role, date: Date?, text: String?) -> AppActivityTimestamp? {
        guard let date, (try? usageInstant(date, text: text)) != nil else { return nil }
        return AppActivityTimestamp(role: role, timestamp: date, timestampText: text, evidenceID: observation.id)
    }
    private static func combine(_ relations: [AppUsageAlignment]) -> AppUsageAlignment {
        let outside = relations.contains(.outsideClaimedWindows), inside = relations.contains(.overlapsSuppliedWindows)
        if outside && inside { return .mixedReportedTimestamps }
        if outside { return .outsideClaimedWindows }
        if inside { return .overlapsSuppliedWindows }
        if relations.contains(.activityDuringZeroReportedForegroundUsage) { return .activityDuringZeroReportedForegroundUsage }
        return .unknown
    }
    private static func combineReferences(_ assessments: [AppUsageReferenceAssessment]) -> AppUsageAlignment {
        // Compare the same timestamp across sources. Different coverage at
        // different endpoints is not itself a contradictory usage claim.
        let points = assessments.flatMap(\.timestamps)
        let grouped = Dictionary(grouping: points, by: { $0.timestamp.evidenceID.uuidString + ":" + $0.timestamp.role.rawValue })
        for values in grouped.values {
            let inside = values.contains { $0.alignment == .overlapsSuppliedWindows }
            let outside = values.contains { $0.alignment == .outsideClaimedWindows || $0.alignment == .activityDuringZeroReportedForegroundUsage }
            if inside && outside { return .conflictingReferences }
        }
        return combine(points.map(\.alignment))
    }
}

/// Optional import of independently supplied references. This is a FirePrivacy
/// interchange format, not a claimed Apple Screen Time export format.
public enum AppUsageTimelineImporter {
    public static let maximumFileBytes = 1_024 * 1_024
    public static func parse(_ data: Data, suppliedAt: Date = Date()) throws -> AppUsageTimeline {
        guard data.count <= maximumFileBytes else { throw AppUsageError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw AppUsageError.invalidJSON }
        do {
            var validator = BoundedJSONValidator(bytes: Array(data)); try validator.validate()
            try rejectUnderflowingNumbers(data)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(root.keys) == Set(["schemaVersion", "references"]),
                  let version = root["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                  let entries = root["references"] as? [[String: Any]] else { throw AppUsageError.invalidJSON }
            let references = try entries.map { entry in
                let allowed = Set(["id", "bundleID", "provenance", "coverage", "claimsCompleteForegroundWindows", "foregroundWindows", "aggregateForegroundSeconds", "sourceLabel", "suppliedAt", "deviceScope", "comparisonReportID"])
                guard Set(entry.keys).isSubset(of: allowed), let bundleID = entry["bundleID"] as? String,
                      let source = entry["provenance"] as? String, let provenance = AppUsageProvenance(rawValue: source),
                      let rawCoverage = entry["coverage"] as? [String: Any],
                      let complete = entry["claimsCompleteForegroundWindows"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID(),
                      let rawWindows = entry["foregroundWindows"] as? [[String: Any]] else { throw AppUsageError.invalidJSON }
                let id: UUID
                if let value = entry["id"] {
                    guard let text = value as? String, let parsed = UUID(uuidString: text) else { throw AppUsageError.invalidJSON }
                    id = parsed
                } else {
                    let canonical = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
                    id = ContentDigest.stableID("FirePrivacy/UsageReference/v1|" + ContentDigest.sha256(canonical))
                }
                var total: Double?
                if let value = entry["aggregateForegroundSeconds"] {
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw AppUsageError.invalidJSON }
                    total = number.doubleValue
                }
                var date = suppliedAt
                if let value = entry["suppliedAt"] {
                    guard let text = value as? String, let parsed = try TimestampParser().read(["timeStamp": text], key: "timeStamp").date else { throw AppUsageError.invalidJSON }
                    date = parsed
                }
                var label: String?
                if let value = entry["sourceLabel"] { guard let text = value as? String else { throw AppUsageError.invalidJSON }; label = text }
                var scope = AppUsageDeviceScope.unspecified
                if let value = entry["deviceScope"] {
                    guard let text = value as? String, let decoded = AppUsageDeviceScope(rawValue: text) else { throw AppUsageError.invalidJSON }
                    scope = decoded
                }
                var reportID: UUID?
                if let value = entry["comparisonReportID"] {
                    guard let text = value as? String, let decoded = UUID(uuidString: text) else { throw AppUsageError.invalidJSON }
                    reportID = decoded
                }
                return try AppUsageReference(id: id, bundleID: bundleID, provenance: provenance, coverage: range(rawCoverage),
                    claimsCompleteForegroundWindows: complete.boolValue, foregroundWindows: rawWindows.map(range),
                    aggregateForegroundSeconds: total, sourceLabel: label, suppliedAt: date, deviceScope: scope, comparisonReportID: reportID)
            }
            return try AppUsageTimeline(references: references)
        } catch let error as AppUsageError { throw error }
        catch { throw AppUsageError.invalidJSON }
    }
    /// JSONSerialization can turn 1e-400 into zero. Reject that lossy numeric
    /// conversion before a positive or negative total becomes a zero-use claim.
    private static func rejectUnderflowingNumbers(_ data: Data) throws {
        let bytes = Array(data)
        var index = 0, inString = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 { inString.toggle(); index += 1; continue }
            if inString {
                index += byte == 92 ? 2 : 1
                continue
            }
            if byte == 45 || (48...57).contains(byte) {
                let beginning = index
                while index < bytes.count, [43, 45, 46, 69, 101].contains(bytes[index]) || (index < bytes.count && (48...57).contains(bytes[index])) { index += 1 }
                let token = String(decoding: bytes[beginning..<index], as: UTF8.self)
                let mantissa = token.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
                if Double(token) == 0, mantissa.contains(where: { $0 >= "1" && $0 <= "9" }) { throw AppUsageError.invalidJSON }
            } else { index += 1 }
        }
    }
    private static func range(_ object: [String: Any]) throws -> UsageTimeRange {
        guard Set(object.keys) == Set(["start", "end"]), let start = object["start"] as? String,
              let end = object["end"] as? String else { throw AppUsageError.invalidJSON }
        return try UsageTimeRange(startTimestampText: start, endTimestampText: end)
    }
}
