import Foundation

public enum ObservationCategory: String, Codable, Equatable, Sendable {
    case sensor
    case network
}

/// An exported record, not a conclusion about data leaving a device.
public struct Observation: Identifiable, Codable, Equatable, Sendable {
    public typealias Category = ObservationCategory
    public let id: UUID
    public let bundleID: String
    public let domain: String?
    public let category: ObservationCategory
    public let accessType: String
    /// Network: the original `hits`. Sensor: one imported event record.
    public let count: Int
    public let timestamp: Date?
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    /// Original timestamp text is retained so fractional precision is not lost.
    public let timestampText: String?
    public let firstTimestampText: String?
    public let lastTimestampText: String?
    public let eventKind: String?
    public let provenance: ObservationProvenance?
    public let context: String?
    public let domainOwner: String?
    public let domainType: ReportedValue?
    public let initiatedType: ReportedValue?
    public let domainClassification: ReportedValue?
    /// Exact bounded exported resource/access identifier; its semantics are not inferred.
    public let sensorIdentifier: String?
    public let originalDomain: String?

    public init(
        id: UUID = UUID(), bundleID: String, domain: String? = nil,
        category: ObservationCategory, accessType: String, count: Int,
        timestamp: Date? = nil, firstTimestamp: Date? = nil, lastTimestamp: Date? = nil,
        timestampText: String? = nil, firstTimestampText: String? = nil,
        lastTimestampText: String? = nil, eventKind: String? = nil,
        provenance: ObservationProvenance? = nil, context: String? = nil,
        domainOwner: String? = nil, domainType: ReportedValue? = nil,
        initiatedType: ReportedValue? = nil, domainClassification: ReportedValue? = nil,
        sensorIdentifier: String? = nil, originalDomain: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.domain = domain
        self.category = category
        self.accessType = accessType
        self.count = count
        self.timestamp = timestamp
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.timestampText = timestampText
        self.firstTimestampText = firstTimestampText
        self.lastTimestampText = lastTimestampText
        self.eventKind = eventKind
        self.provenance = provenance
        self.context = context
        self.domainOwner = domainOwner
        self.domainType = domainType
        self.initiatedType = initiatedType
        self.domainClassification = domainClassification
        self.sensorIdentifier = sensorIdentifier
        self.originalDomain = originalDomain
    }
}

public struct ImportIssue: Codable, Equatable, Sendable {
    public let message: String
    public let line: Int

    public init(message: String, line: Int) {
        self.message = message
        self.line = line
    }
}

public struct AppSummary: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let contacts: Int
    public let domains: [String]
    /// Counts event records, including interval begin/end records when present.
    public let sensorAccesses: Int

    public init(bundleID: String, contacts: Int, domains: [String], sensorAccesses: Int) {
        self.bundleID = bundleID
        self.contacts = contacts
        self.domains = domains
        self.sensorAccesses = sensorAccesses
    }
}

public struct DomainSummary: Identifiable, Codable, Equatable, Sendable {
    public var id: String { domain }
    public let domain: String
    public let contacts: Int
    public let apps: [String]

    public init(domain: String, contacts: Int, apps: [String]) {
        self.domain = domain
        self.contacts = contacts
        self.apps = apps
    }
}

public struct Finding: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let recommendedSteps: [String]
    public let evidenceIDs: [UUID]

    public init(id: String, title: String, detail: String, recommendedSteps: [String], evidenceIDs: [UUID]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.recommendedSteps = recommendedSteps
        self.evidenceIDs = evidenceIDs
    }
}

public struct PrivacyReport: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let importedAt: Date
    public let observations: [Observation]
    public let issues: [ImportIssue]
    public let metadata: ReportMetadata?

    public init(id: UUID = UUID(), importedAt: Date = Date(), observations: [Observation], issues: [ImportIssue] = [], metadata: ReportMetadata? = nil) {
        self.id = id
        self.importedAt = importedAt
        self.observations = observations
        self.issues = issues
        self.metadata = metadata
    }

    public var totalContacts: Int {
        observations.filter { $0.category == .network }.reduce(0) { boundedSum($0, $1.count) }
    }

    public var apps: [AppSummary] {
        Dictionary(grouping: observations, by: \.bundleID).map { bundleID, records in
            AppSummary(
                bundleID: bundleID,
                contacts: records.filter { $0.category == .network }.reduce(0) { boundedSum($0, $1.count) },
                domains: Array(Set(records.compactMap(\.domain))).sorted(),
                sensorAccesses: records.filter { $0.category == .sensor }.count
            )
        }.sorted { lhs, rhs in
            lhs.contacts == rhs.contacts ? lhs.bundleID < rhs.bundleID : lhs.contacts > rhs.contacts
        }
    }

    public var domains: [DomainSummary] {
        let network = observations.filter { $0.category == .network && $0.domain != nil }
        let grouped: [String: [Observation]] = Dictionary(grouping: network, by: { $0.domain ?? "" })
        let summaries: [DomainSummary] = grouped.map { domain, records in
            DomainSummary(
                domain: domain,
                contacts: records.reduce(0) { boundedSum($0, $1.count) },
                apps: Array(Set(records.map(\.bundleID))).sorted()
            )
        }
        return summaries.sorted { lhs, rhs in
            lhs.contacts == rhs.contacts ? lhs.domain < rhs.domain : lhs.contacts > rhs.contacts
        }
    }

    /// Descriptive findings only: no vendor classification, risk score, or causal inference.
    public var findings: [Finding] {
        let domainFindings = domains.prefix(3).map { summary in
            Finding(
                id: "domain:\(summary.domain)",
                title: "\(summary.domain)",
                detail: "The export records \(summary.contacts) contacts across \(summary.apps.count) app(s). Contact counts do not show what data was sent or whether a contact was harmful.",
                recommendedSteps: [
                    "Review the contributing apps and compare this domain with their privacy policies.",
                    "Open Settings > Privacy & Security > App Privacy Report for Apple's original view."
                ],
                evidenceIDs: observations.filter { $0.category == .network && $0.domain == summary.domain }.map(\.id)
            )
        }
        let sensorGroups = Dictionary(grouping: observations.filter { $0.category == .sensor }, by: \.bundleID)
        let sensorFindings = sensorGroups.keys.sorted().prefix(3).compactMap { bundleID -> Finding? in
            guard let records = sensorGroups[bundleID] else { return nil }
            let sensors = Array(Set(records.map(\.accessType))).sorted().joined(separator: ", ")
            return Finding(
                id: "sensors:\(bundleID)",
                title: "Review recorded sensor events",
                detail: "\(bundleID) has \(records.count) exported event record(s) for \(sensors). Begin/end records may describe the same access. This history does not establish the app's current permission state or any data transmission.",
                recommendedSteps: [
                    "Open Settings > Privacy & Security and review the relevant permission category.",
                    "Consider whether the app feature needs that permission before changing it."
                ],
                evidenceIDs: records.map(\.id)
            )
        }
        return domainFindings + sensorFindings
    }
}

// Imported reports reject overflowing totals. Keep manually constructed models safe too.
private func boundedSum(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}
