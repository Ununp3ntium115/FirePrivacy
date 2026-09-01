import Foundation
import ObservationCore
import FindingEngine
import KnowledgeBaseKit
import ObservationStore

/// The difference between two imports (DASH-008).
///
/// A comparison separates changes in *behavior* from changes in Fire Privacy's
/// own data: if a domain is newly flagged only because the knowledge base
/// learned about it, the comparison says so rather than implying the app started
/// doing something new.
public struct ReportComparison: Sendable {
    public struct DomainChange: Sendable, Hashable {
        public let host: NormalizedHost
        public let apps: [String]
        public let categories: [String]
    }

    public struct SensorChange: Sendable, Hashable {
        public let bundleID: BundleIdentifier
        public let sensorType: SensorType
        public let previousCount: Int?
        public let currentCount: Int?
    }

    public let earlier: StoredSession
    public let later: StoredSession

    public let newApplications: [BundleIdentifier]
    public let removedApplications: [BundleIdentifier]
    public let newDomains: [DomainChange]
    public let disappearedDomains: [DomainChange]
    public let sensorChanges: [SensorChange]
    public let newFindings: [Finding]
    public let resolvedFindings: [Finding]
    /// Findings whose only reason for appearing is a knowledge-base update.
    public let knowledgeBaseAttributedFindings: [Finding]
    public let postureDelta: Int
    public let knowledgeBaseChanged: Bool
    public let ruleSetChanged: Bool

    public init(earlier: StoredSession, later: StoredSession) {
        self.earlier = earlier
        self.later = later

        let earlierApps = Set(earlier.snapshot.applications.map(\.bundleID))
        let laterApps = Set(later.snapshot.applications.map(\.bundleID))
        self.newApplications = laterApps.subtracting(earlierApps).sorted()
        self.removedApplications = earlierApps.subtracting(laterApps).sorted()

        let earlierHosts = Dictionary(
            grouping: earlier.snapshot.networkObservations,
            by: { $0.host.value }
        )
        let laterHosts = Dictionary(
            grouping: later.snapshot.networkObservations,
            by: { $0.host.value }
        )

        func change(_ key: String, _ observations: [NetworkObservation]) -> DomainChange? {
            guard let first = observations.first else { return nil }
            return DomainChange(
                host: first.host,
                apps: Array(Set(observations.compactMap { $0.bundleID?.rawValue })).sorted(),
                categories: []
            )
        }

        self.newDomains = laterHosts.keys.sorted()
            .filter { earlierHosts[$0] == nil }
            .compactMap { change($0, laterHosts[$0] ?? []) }
        self.disappearedDomains = earlierHosts.keys.sorted()
            .filter { laterHosts[$0] == nil }
            .compactMap { change($0, earlierHosts[$0] ?? []) }

        var sensorChanges: [SensorChange] = []
        let earlierSensors = Dictionary(
            earlier.snapshot.sensorObservations.compactMap { observation -> (String, SensorObservation)? in
                guard let bundleID = observation.bundleID else { return nil }
                return ("\(bundleID.rawValue)|\(observation.sensorType.identifier)", observation)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let laterSensors = Dictionary(
            later.snapshot.sensorObservations.compactMap { observation -> (String, SensorObservation)? in
                guard let bundleID = observation.bundleID else { return nil }
                return ("\(bundleID.rawValue)|\(observation.sensorType.identifier)", observation)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for key in Set(earlierSensors.keys).union(laterSensors.keys).sorted() {
            let previous = earlierSensors[key]
            let current = laterSensors[key]
            guard previous?.count != current?.count || previous == nil || current == nil else { continue }
            guard let bundleID = (current ?? previous)?.bundleID, let sensorType = (current ?? previous)?.sensorType else { continue }
            sensorChanges.append(SensorChange(
                bundleID: bundleID,
                sensorType: sensorType,
                previousCount: previous?.count,
                currentCount: current?.count
            ))
        }
        self.sensorChanges = sensorChanges

        let earlierFindingIDs = Set(earlier.findings.map(\.id))
        let laterFindingIDs = Set(later.findings.map(\.id))
        let appeared = later.findings.filter { !earlierFindingIDs.contains($0.id) }
        self.newFindings = appeared
        self.resolvedFindings = earlier.findings.filter { !laterFindingIDs.contains($0.id) }

        let knowledgeBaseChanged = earlier.knowledgeBaseVersion.datasetVersion != later.knowledgeBaseVersion.datasetVersion
        self.knowledgeBaseChanged = knowledgeBaseChanged
        self.ruleSetChanged = earlier.ruleSetVersion != later.ruleSetVersion

        // A finding about a domain that was already present, appearing only now,
        // is explained by the dataset rather than by new behavior.
        let earlierHostSet = Set(earlier.snapshot.networkObservations.map(\.host.value))
        self.knowledgeBaseAttributedFindings = knowledgeBaseChanged
            ? appeared.filter { finding in
                if case .domain(let host) = finding.subject { return earlierHostSet.contains(host.value) }
                return false
            }
            : []

        self.postureDelta = later.scores.privacyPosture - earlier.scores.privacyPosture
    }

    /// One-line summary used on the Overview "What changed" card.
    public var headline: String {
        if newFindings.isEmpty, resolvedFindings.isEmpty, newDomains.isEmpty {
            return "Nothing meaningful changed between these two reports."
        }
        var parts: [String] = []
        if !newDomains.isEmpty { parts.append("\(newDomains.count) new domain\(newDomains.count == 1 ? "" : "s")") }
        if !newFindings.isEmpty { parts.append("\(newFindings.count) new finding\(newFindings.count == 1 ? "" : "s")") }
        if !resolvedFindings.isEmpty { parts.append("\(resolvedFindings.count) resolved") }
        return parts.joined(separator: ", ") + "."
    }

    /// Stated whenever a change might be Fire Privacy's doing rather than an
    /// app's (DASH-008).
    public var attributionNote: String? {
        guard knowledgeBaseChanged || ruleSetChanged else { return nil }
        var reasons: [String] = []
        if knowledgeBaseChanged { reasons.append("the knowledge base was updated") }
        if ruleSetChanged { reasons.append("the rules changed") }
        var note = "Some differences may exist because \(reasons.joined(separator: " and ")), not because an app behaved differently."
        if !knowledgeBaseAttributedFindings.isEmpty {
            note += " \(knowledgeBaseAttributedFindings.count) finding\(knowledgeBaseAttributedFindings.count == 1 ? " is" : "s are") about domains that were already present in the earlier report."
        }
        return note
    }
}

/// The weekly summary (RPT-001).
public struct WeeklyReport: Sendable {
    public let generatedAt: Date
    public let hasNewSourceReport: Bool
    public let comparison: ReportComparison?
    public let protectionIsActive: Bool
    public let knowledgeBaseIsStale: Bool
    public let latestSession: StoredSession?

    public init(
        generatedAt: Date,
        hasNewSourceReport: Bool,
        comparison: ReportComparison?,
        protectionIsActive: Bool,
        knowledgeBaseIsStale: Bool,
        latestSession: StoredSession?
    ) {
        self.generatedAt = generatedAt
        self.hasNewSourceReport = hasNewSourceReport
        self.comparison = comparison
        self.protectionIsActive = protectionIsActive
        self.knowledgeBaseIsStale = knowledgeBaseIsStale
        self.latestSession = latestSession
    }

    /// Generic by default, so a notification never names an app or a domain on
    /// the lock screen (RPT-003).
    public static let genericNotificationBody = "Your Fire Privacy checkup is ready."

    public var summaryLines: [String] {
        var lines: [String] = []
        guard hasNewSourceReport else {
            // Never infer that nothing happened from the absence of data (RPT-004).
            lines.append("No new source report. Fire Privacy has nothing newer to compare against — this is not a statement that nothing changed.")
            lines.append(protectionIsActive ? "Protection is on." : "Protection is off.")
            return lines
        }
        if let comparison {
            lines.append(comparison.headline)
            if let note = comparison.attributionNote { lines.append(note) }
            if comparison.postureDelta != 0 {
                let direction = comparison.postureDelta > 0 ? "improved" : "declined"
                lines.append("Your posture score \(direction) by \(abs(comparison.postureDelta)) points.")
            }
        }
        lines.append(protectionIsActive ? "Protection is on." : "Protection is off.")
        if knowledgeBaseIsStale {
            lines.append("The knowledge base has expired, so vendor classifications may be out of date.")
        }
        return lines
    }
}
