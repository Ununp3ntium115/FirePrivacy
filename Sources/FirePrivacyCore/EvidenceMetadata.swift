import Foundation

/// Internal chronology retains all nine supported fractional digits even when Date rounds them.
struct ExactExportTimestamp: Comparable {
    let seconds: Int64
    let nanoseconds: Int
    var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds == rhs.seconds ? lhs.nanoseconds < rhs.nanoseconds : lhs.seconds < rhs.seconds
    }
    init(seconds: Int64, nanoseconds: Int) { self.seconds = seconds; self.nanoseconds = nanoseconds }
    init?(date: Date) {
        let epoch = date.timeIntervalSince1970
        guard epoch.isFinite, epoch >= Double(Int64.min), epoch < Double(Int64.max) else { return nil }
        var seconds = Int64(floor(epoch))
        var nanoseconds = Int(((epoch - floor(epoch)) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 { seconds += 1; nanoseconds = 0 }
        self.init(seconds: seconds, nanoseconds: nanoseconds)
    }
    func adding(_ interval: TimeInterval) -> Self {
        let whole = Int64(floor(interval))
        let fractional = Int(((interval - floor(interval)) * 1_000_000_000).rounded())
        let nanos = nanoseconds + fractional
        let changed = seconds.addingReportingOverflow(whole + Int64(nanos / 1_000_000_000))
        // Real parsed years are 1...9999. Defend manually constructed extreme Dates too.
        if changed.overflow { return Self(seconds: interval >= 0 ? Int64.max : Int64.min, nanoseconds: interval >= 0 ? 999_999_999 : 0) }
        return Self(seconds: changed.partialValue, nanoseconds: nanos % 1_000_000_000)
    }
    func timeIntervalSince(_ other: Self) -> TimeInterval {
        Double(seconds) - Double(other.seconds) + Double(nanoseconds - other.nanoseconds) / 1_000_000_000
    }
}

/// An exported scalar, retained without assigning undocumented numeric meanings.
public enum ReportedValue: Codable, Equatable, Sendable {
    case integer(Int)
    case text(String)
    case number(String)
    case boolean(Bool)
    case null

    public var intValue: Int? { if case .integer(let value) = self { value } else { nil } }
    public var stringValue: String? { if case .text(let value) = self { value } else { nil } }
    public var displayValue: String {
        switch self {
        case .integer(let value): String(value)
        case .text(let value), .number(let value): value
        case .boolean(let value): value ? "true" : "false"
        case .null: "null"
        }
    }
}

public struct ObservationProvenance: Codable, Equatable, Sendable {
    public let sourceLine: Int
    /// SHA-256 of the original physical line bytes (without the newline).
    public let sourceSHA256: String
    public let normalizationWarnings: [String]
    public init(sourceLine: Int, sourceSHA256: String, normalizationWarnings: [String] = []) {
        self.sourceLine = sourceLine
        self.sourceSHA256 = sourceSHA256
        self.normalizationWarnings = normalizationWarnings
    }
}

public struct ReportMetadata: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case complete, partial, legacy }
    public let sourceSHA256: String?
    public let sourceFilename: String?
    public let parserVersion: String
    public let normalizationVersion: String
    /// Inferred bounds of recorded timestamps; these are not a guaranteed export coverage period.
    public let reportStart: Date?
    public let reportEnd: Date?
    public let status: Status
    public let recognizedRecords: Int
    public let skippedRecords: Int
    public let isSyntheticDemo: Bool
    public init(sourceSHA256: String? = nil, sourceFilename: String? = nil,
                parserVersion: String = "2.0.0", normalizationVersion: String = "2.0.0",
                reportStart: Date? = nil, reportEnd: Date? = nil, status: Status = .complete,
                recognizedRecords: Int, skippedRecords: Int = 0, isSyntheticDemo: Bool = false) {
        self.sourceSHA256 = sourceSHA256
        self.sourceFilename = sourceFilename.map { ImportedText.sanitize($0, maximumCharacters: 255) }
        self.parserVersion = parserVersion
        self.normalizationVersion = normalizationVersion
        self.reportStart = reportStart
        self.reportEnd = reportEnd
        self.status = status
        self.recognizedRecords = recognizedRecords
        self.skippedRecords = skippedRecords
        self.isSyntheticDemo = isSyntheticDemo
    }
}

/// Imported labels are data. Remove invisible directional/control characters and bound display length.
public enum ImportedText {
    public static func sanitize(_ text: String, maximumCharacters: Int = 512) -> String {
        let safe = text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return !CharacterSet.controlCharacters.contains(scalar) &&
                !(0x200B...0x200F).contains(value) && !(0x202A...0x202E).contains(value) &&
                !(0x2060...0x206F).contains(value) && value != 0xFEFF
        }
        return String(String.UnicodeScalarView(safe)).prefix(max(0, maximumCharacters)).description
    }
}

extension Observation {
    /// Known label aliases only. Unknown categories remain visible verbatim.
    public var sensorCategory: String {
        guard category == .sensor else { return accessType }
        switch accessType.lowercased() {
        case "camera": return "camera"
        case "microphone", "audio": return "microphone"
        case "location", "locationservices": return "location"
        case "contacts", "addressbook": return "contacts"
        case "photos", "photolibrary": return "photos"
        default: return accessType
        }
    }
    public var isSensorBeginRecord: Bool { category == .sensor && eventKind?.lowercased() == "intervalbegin" }
    public var isSensorEndRecord: Bool { category == .sensor && eventKind?.lowercased() == "intervalend" }
}

public struct SensorActivitySummary: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundleID + "|" + category }
    public let bundleID: String
    public let category: String
    public let eventRecords: Int
    public let beginRecords: Int
    public let endRecords: Int
    /// Matched begin/end pairs, not a proven count of distinct accesses.
    public let completedIntervals: Int
    public let unknownKindRecords: Int
}

public struct SensorInterval: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let bundleID: String
    public let category: String
    public let sensorIdentifier: String
    public let start: Date
    public let end: Date
    public let evidenceIDs: [UUID]
    public let startTimestampText: String?
    public let endTimestampText: String?
}

extension PrivacyReport {
    /// Candidate intervals: exactly one begin/end with the same exact reported app/category/identifier.
    /// The identifier's export semantics and the number of distinct accesses remain unknown.
    public var sensorIntervals: [SensorInterval] {
        let timestamps = TimestampParser()
        let groups = Dictionary(grouping: observations.filter {
            $0.category == .sensor && $0.sensorIdentifier != nil
        }, by: { [$0.bundleID, $0.sensorCategory, $0.sensorIdentifier ?? ""].joined(separator: "\u{1F}") })
        return groups.values.compactMap { records -> SensorInterval? in
            guard records.count == 2,
                  let begin = records.first(where: \.isSensorBeginRecord),
                  let end = records.first(where: \.isSensorEndRecord),
                  let startDate = begin.timestamp, let endDate = end.timestamp,
                  let startInstant = exactInstant(date: startDate, text: begin.timestampText, parser: timestamps),
                  let endInstant = exactInstant(date: endDate, text: end.timestampText, parser: timestamps),
                  startInstant <= endInstant, let identifier = begin.sensorIdentifier else { return nil }
            let ids = [begin.id, end.id]
            return SensorInterval(id: "interval:" + ContentDigest.sha256(Data(ids.map(\.uuidString).joined(separator: "|").utf8)),
                                  bundleID: begin.bundleID, category: begin.sensorCategory,
                                  sensorIdentifier: identifier, start: startDate, end: endDate, evidenceIDs: ids,
                                  startTimestampText: begin.timestampText, endTimestampText: end.timestampText)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    public var sensorActivity: [SensorActivitySummary] {
        let intervals: [String: [SensorInterval]] = Dictionary(grouping: sensorIntervals, by: { $0.bundleID + "|" + $0.category })
        let groups: [String: [Observation]] = Dictionary(grouping: observations.filter { $0.category == .sensor }, by: {
            $0.bundleID + "|" + $0.sensorCategory
        })
        var result: [SensorActivitySummary] = []
        for (key, records) in groups {
            let begins = records.filter(\.isSensorBeginRecord).count
            let ends = records.filter(\.isSensorEndRecord).count
            result.append(SensorActivitySummary(bundleID: records[0].bundleID, category: records[0].sensorCategory,
                eventRecords: records.count, beginRecords: begins, endRecords: ends,
                completedIntervals: intervals[key]?.count ?? 0, unknownKindRecords: records.count - begins - ends))
        }
        return result.sorted { $0.id < $1.id }
    }
}

public struct TemporalAssociation: Identifiable, Codable, Equatable, Sendable {
    public enum Precision: String, Codable, Sendable { case timestampPoint, aggregatedWindow }
    public let id: String
    public let bundleID: String
    public let sensorEvidenceIDs: [UUID]
    public let networkObservationID: UUID
    public let precision: Precision
    public let observedStart: Date
    public let observedEnd: Date
    public let separationSeconds: TimeInterval
    public let explanation: String
}

public struct TemporalAssociationResult: Codable, Equatable, Sendable {
    public let associations: [TemporalAssociation]
    public let reachedLimit: Bool
    public let comparisons: Int
    public let untimedRecords: Int
}

public enum TemporalAssociations {
    public static func find(in report: PrivacyReport, tolerance: TimeInterval = 300,
                            maximumResults: Int = 2_000) -> [TemporalAssociation] {
        analyze(in: report, tolerance: tolerance, maximumResults: maximumResults).associations
    }

    /// A bounded sweep over same-app intervals. Overlap is a temporal association, never causation.
    public static func analyze(in report: PrivacyReport, tolerance: TimeInterval = 300,
                               maximumResults: Int = 2_000) -> TemporalAssociationResult {
        let tolerance = tolerance.isFinite ? min(3_600, max(0, tolerance)) : 0
        let resultLimit = min(10_000, max(0, maximumResults))
        struct Window {
            let id: String; let bundleID: String; let start: Date; let end: Date
            let startInstant: ExactExportTimestamp; let endInstant: ExactExportTimestamp
            let evidenceIDs: [UUID]; let isSensor: Bool; let aggregated: Bool
        }
        var windows: [Window] = []
        let timestamps = TimestampParser()
        let intervals = report.sensorIntervals
        let paired = Set(intervals.flatMap(\.evidenceIDs))
        for interval in intervals {
            guard let start = exactInstant(date: interval.start, text: interval.startTimestampText, parser: timestamps),
                  let end = exactInstant(date: interval.end, text: interval.endTimestampText, parser: timestamps) else { continue }
            windows.append(Window(id: interval.id, bundleID: interval.bundleID, start: interval.start,
                                  end: interval.end, startInstant: start, endInstant: end,
                                  evidenceIDs: interval.evidenceIDs, isSensor: true, aggregated: true))
        }
        var untimed = 0
        for observation in report.observations where !paired.contains(observation.id) {
            if observation.category == .sensor {
                guard let date = observation.timestamp,
                      let instant = exactInstant(date: date, text: observation.timestampText, parser: timestamps) else { untimed += 1; continue }
                windows.append(Window(id: observation.id.uuidString, bundleID: observation.bundleID,
                                      start: date, end: date, startInstant: instant, endInstant: instant,
                                      evidenceIDs: [observation.id], isSensor: true, aggregated: false))
            } else if let first = observation.firstTimestamp,
                      let last = observation.lastTimestamp ?? (observation.timestampText != nil ? observation.timestamp : nil),
                      let start = exactInstant(date: first, text: observation.firstTimestampText, parser: timestamps),
                      let end = exactInstant(date: last, text: observation.lastTimestampText ?? observation.timestampText, parser: timestamps),
                      start <= end {
                windows.append(Window(id: observation.id.uuidString, bundleID: observation.bundleID,
                                      start: first, end: last, startInstant: start, endInstant: end,
                                      evidenceIDs: [observation.id], isSensor: false, aggregated: true))
            } else if observation.firstTimestamp == nil, observation.timestampText != nil, let date = observation.timestamp,
                      let instant = exactInstant(date: date, text: observation.timestampText, parser: timestamps) {
                windows.append(Window(id: observation.id.uuidString, bundleID: observation.bundleID,
                                      start: date, end: date, startInstant: instant, endInstant: instant,
                                      evidenceIDs: [observation.id], isSensor: false, aggregated: false))
            } else { untimed += 1 }
        }
        struct Endpoint { let time: ExactExportTimestamp; let beginning: Bool; let index: Int }
        var output: [TemporalAssociation] = []
        var comparisons = 0
        var limited = false
        let grouped = Dictionary(grouping: windows, by: \.bundleID)
        outer: for bundleID in grouped.keys.sorted() {
            let local = grouped[bundleID] ?? []
            var endpoints: [Endpoint] = []
            for index in local.indices {
                let window = local[index]
                endpoints.append(Endpoint(time: window.startInstant.adding(window.isSensor ? -tolerance : 0), beginning: true, index: index))
                endpoints.append(Endpoint(time: window.endInstant.adding(window.isSensor ? tolerance : 0), beginning: false, index: index))
            }
            endpoints.sort { lhs, rhs in
                if lhs.time != rhs.time { return lhs.time < rhs.time }
                if lhs.beginning != rhs.beginning { return lhs.beginning }
                return local[lhs.index].id < local[rhs.index].id
            }
            var sensors = Set<Int>(), networks = Set<Int>()
            for endpoint in endpoints {
                let window = local[endpoint.index]
                if !endpoint.beginning {
                    if window.isSensor { sensors.remove(endpoint.index) } else { networks.remove(endpoint.index) }
                    continue
                }
                let candidates = (window.isSensor ? networks : sensors).sorted { local[$0].id < local[$1].id }
                for otherIndex in candidates {
                    comparisons += 1
                    if comparisons > 250_000 || output.count >= resultLimit { limited = true; break outer }
                    let other = local[otherIndex]
                    let sensor = window.isSensor ? window : other
                    let network = window.isSensor ? other : window
                    let gap = max(0, max(network.startInstant.timeIntervalSince(sensor.endInstant), sensor.startInstant.timeIntervalSince(network.endInstant)))
                    let precision: TemporalAssociation.Precision = sensor.aggregated || network.aggregated ? .aggregatedWindow : .timestampPoint
                    let identity = sensor.evidenceIDs.map(\.uuidString).joined(separator: "|") + "|" + network.id
                    output.append(TemporalAssociation(id: "temporal:" + ContentDigest.sha256(Data(identity.utf8)), bundleID: bundleID,
                        sensorEvidenceIDs: sensor.evidenceIDs, networkObservationID: network.evidenceIDs[0], precision: precision,
                        observedStart: min(sensor.start, network.start), observedEnd: max(sensor.end, network.end), separationSeconds: gap,
                        explanation: precision == .aggregatedWindow ? "Reported time windows overlap or are nearby. Aggregated contacts cannot be placed at an individual instant; this does not establish transmission of sensor data." : "Reported timestamps are nearby in the same app. Timing alone does not establish a relationship or transmission of sensor data."))
                }
                if window.isSensor { sensors.insert(endpoint.index) } else { networks.insert(endpoint.index) }
            }
        }
        return TemporalAssociationResult(associations: output.sorted { $0.id < $1.id }, reachedLimit: limited,
                                         comparisons: min(comparisons, 250_000), untimedRecords: untimed)
    }
}

private func exactInstant(date: Date, text: String?, parser: TimestampParser) -> ExactExportTimestamp? {
    if let text { return (try? parser.read(["timeStamp": text], key: "timeStamp"))?.instant }
    return ExactExportTimestamp(date: date)
}
