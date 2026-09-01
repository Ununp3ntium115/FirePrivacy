import Foundation
import ObservationCore

/// Folds decoded lines into the normalized observations the rest of the app
/// works with.
///
/// Apple emits one line per contact window, so a single app/domain pair appears
/// many times in one report. Aggregation happens here, once, with a documented
/// merge rule per field — not in each view, where two screens would eventually
/// disagree about the same number.
public struct AppActivityNormalizer: Sendable {
    public init() {}

    public struct Aggregate: Sendable {
        public let applications: [ObservedApplication]
        public let networkObservations: [NetworkObservation]
        public let sensorObservations: [SensorObservation]
        public let reportStart: Date?
        public let reportEnd: Date?
    }

    public func aggregate(records: [DecodedRecord], sessionID: UUID) -> Aggregate {
        var networkGroups: [NetworkKey: NetworkAccumulator] = [:]
        var sensorGroups: [SensorKey: SensorAccumulator] = [:]
        var applicationFirst: [BundleIdentifier: Date] = [:]
        var applicationLast: [BundleIdentifier: Date] = [:]
        var bundleIDs = Set<BundleIdentifier>()
        var reportStart: Date?
        var reportEnd: Date?

        for record in records {
            if let bundleID = record.bundleID { bundleIDs.insert(bundleID) }
            for stamp in [record.firstTimestamp, record.lastTimestamp].compactMap({ $0 }) {
                reportStart = reportStart.map { min($0, stamp) } ?? stamp
                reportEnd = reportEnd.map { max($0, stamp) } ?? stamp
                if let bundleID = record.bundleID {
                    applicationFirst[bundleID] = applicationFirst[bundleID].map { min($0, stamp) } ?? stamp
                    applicationLast[bundleID] = applicationLast[bundleID].map { max($0, stamp) } ?? stamp
                }
            }

            switch record.kind {
            case .networkActivity:
                guard let host = record.host else { continue }
                let key = NetworkKey(
                    bundleID: record.bundleID?.rawValue,
                    host: host.value,
                    context: record.context?.value
                )
                networkGroups[key, default: NetworkAccumulator(host: host)].absorb(record)
            case .access:
                guard let sensorType = record.sensorType else { continue }
                let key = SensorKey(bundleID: record.bundleID?.rawValue, sensor: sensorType.identifier)
                sensorGroups[key, default: SensorAccumulator(sensorType: sensorType)].absorb(record)
            }
        }

        let applications = bundleIDs.sorted().map { bundleID in
            ObservedApplication(
                id: DeterministicUUID.make(namespace: .application, name: "\(sessionID.uuidString)|\(bundleID.rawValue)"),
                bundleID: bundleID,
                firstObserved: applicationFirst[bundleID],
                lastObserved: applicationLast[bundleID]
            )
        }
        var applicationIDs: [BundleIdentifier: UUID] = [:]
        for application in applications { applicationIDs[application.bundleID] = application.id }

        let networkObservations = networkGroups
            .sorted { $0.key < $1.key }
            .map { key, accumulator in
                accumulator.build(key: key, sessionID: sessionID, applicationIDs: applicationIDs)
            }

        let sensorObservations = sensorGroups
            .sorted { $0.key < $1.key }
            .map { key, accumulator in
                accumulator.build(key: key, sessionID: sessionID, applicationIDs: applicationIDs)
            }

        return Aggregate(
            applications: applications,
            networkObservations: networkObservations,
            sensorObservations: sensorObservations,
            reportStart: reportStart,
            reportEnd: reportEnd
        )
    }

    struct NetworkKey: Hashable, Comparable, Sendable {
        let bundleID: String?
        let host: String
        let context: String?

        static func < (lhs: NetworkKey, rhs: NetworkKey) -> Bool {
            if lhs.bundleID != rhs.bundleID { return (lhs.bundleID ?? "") < (rhs.bundleID ?? "") }
            if lhs.host != rhs.host { return lhs.host < rhs.host }
            return (lhs.context ?? "") < (rhs.context ?? "")
        }
    }

    struct SensorKey: Hashable, Comparable, Sendable {
        let bundleID: String?
        let sensor: String

        static func < (lhs: SensorKey, rhs: SensorKey) -> Bool {
            if lhs.bundleID != rhs.bundleID { return (lhs.bundleID ?? "") < (rhs.bundleID ?? "") }
            return lhs.sensor < rhs.sensor
        }
    }

    struct NetworkAccumulator {
        let host: NormalizedHost
        var registrableDomain: NormalizedHost?
        var bundleID: BundleIdentifier?
        var context: UntrustedText?
        var hits: Int?
        var domainType = ReportedDomainType(rawValue: nil, rawLabel: nil)
        var initiatedType: UntrustedText?
        var domainOwner: UntrustedText?
        var warnings: NormalizationWarnings = []
        var first: Date?
        var last: Date?
        var firstLineNumber = Int.max
        var firstLineHash: FireDigest?
        var mergedRecordCount = 0

        init(host: NormalizedHost) { self.host = host }

        mutating func absorb(_ record: DecodedRecord) {
            mergedRecordCount += 1
            registrableDomain = registrableDomain ?? record.registrableDomain
            bundleID = bundleID ?? record.bundleID
            context = context ?? record.context
            initiatedType = initiatedType ?? record.initiatedType
            domainOwner = domainOwner ?? record.domainOwner
            warnings.formUnion(record.normalizationWarnings)

            if let recordHits = record.hits {
                hits = (hits ?? 0) + recordHits
            }
            // Apple's classification is authoritative when any line carries it;
            // a later line without the field must not erase it.
            if !domainType.isKnown || (record.domainType.indicatesCrossAppCollection && !domainType.indicatesCrossAppCollection) {
                if record.domainType.isKnown { domainType = record.domainType }
            }
            if let stamp = record.firstTimestamp { first = first.map { min($0, stamp) } ?? stamp }
            if let stamp = record.lastTimestamp { last = last.map { max($0, stamp) } ?? stamp }
            if record.lineNumber < firstLineNumber {
                firstLineNumber = record.lineNumber
                firstLineHash = record.lineHash
            }
        }

        func build(key: NetworkKey, sessionID: UUID, applicationIDs: [BundleIdentifier: UUID]) -> NetworkObservation {
            let name = "\(sessionID.uuidString)|\(key.bundleID ?? "")|\(key.host)|\(key.context ?? "")"
            return NetworkObservation(
                id: DeterministicUUID.make(namespace: .networkObservation, name: name),
                importSessionID: sessionID,
                applicationID: bundleID.flatMap { applicationIDs[$0] },
                bundleID: bundleID,
                host: host,
                registrableDomain: registrableDomain,
                context: context,
                firstTimestamp: first,
                lastTimestamp: last,
                hits: hits,
                domainType: domainType,
                initiatedType: initiatedType,
                domainOwner: domainOwner,
                sourceLineHash: firstLineHash ?? FireHasher.hash(name),
                sourceLineNumber: firstLineNumber == .max ? 0 : firstLineNumber,
                normalizationWarnings: warnings,
                mergedRecordCount: mergedRecordCount
            )
        }
    }

    struct SensorAccumulator {
        let sensorType: SensorType
        var bundleID: BundleIdentifier?
        var first: Date?
        var last: Date?
        var accessCount = 0
        var sawExplicitKind = false
        var firstLineNumber = Int.max
        var firstLineHash: FireDigest?
        var mergedRecordCount = 0

        init(sensorType: SensorType) { self.sensorType = sensorType }

        mutating func absorb(_ record: DecodedRecord) {
            mergedRecordCount += 1
            bundleID = bundleID ?? record.bundleID
            if let stamp = record.firstTimestamp { first = first.map { min($0, stamp) } ?? stamp }
            if let stamp = record.lastTimestamp { last = last.map { max($0, stamp) } ?? stamp }

            // Apple emits paired intervalBegin/intervalEnd records. Counting both
            // would double every access count, so only the begin edge counts.
            switch record.accessKind {
            case "intervalbegin", "begin", "start":
                sawExplicitKind = true
                accessCount += 1
            case "intervalend", "end", "stop":
                sawExplicitKind = true
            default:
                accessCount += 1
            }

            if record.lineNumber < firstLineNumber {
                firstLineNumber = record.lineNumber
                firstLineHash = record.lineHash
            }
        }

        func build(key: SensorKey, sessionID: UUID, applicationIDs: [BundleIdentifier: UUID]) -> SensorObservation {
            let name = "\(sessionID.uuidString)|\(key.bundleID ?? "")|\(key.sensor)"
            return SensorObservation(
                id: DeterministicUUID.make(namespace: .sensorObservation, name: name),
                importSessionID: sessionID,
                applicationID: bundleID.flatMap { applicationIDs[$0] },
                bundleID: bundleID,
                sensorType: sensorType,
                firstTimestamp: first,
                lastTimestamp: last,
                count: accessCount > 0 ? accessCount : nil,
                sourceLineHash: firstLineHash ?? FireHasher.hash(name),
                sourceLineNumber: firstLineNumber == .max ? 0 : firstLineNumber,
                mergedRecordCount: mergedRecordCount
            )
        }
    }
}
