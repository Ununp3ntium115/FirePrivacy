import Foundation
import ObservationCore
import KnowledgeBaseKit

/// Everything the rules need about one registrable domain in one report.
public struct DomainGroup: Sendable {
    public let key: NormalizedHost
    public private(set) var hosts: Set<String> = []
    public private(set) var bundleIDs: Set<BundleIdentifier> = []
    public private(set) var publisherPrefixes: Set<String> = []
    public private(set) var totalHits: Int = 0
    public private(set) var hitsByApp: [BundleIdentifier: Int] = [:]
    public private(set) var observations: [NetworkObservation] = []
    public private(set) var appleFlaggedCrossApp = false
    /// Contacts that happened inside embedded web content, which weakens a
    /// cross-app inference (DET-004).
    public private(set) var webContextCount = 0
    public let matches: [DomainMatch]

    init(key: NormalizedHost, matches: [DomainMatch]) {
        self.key = key
        self.matches = matches
    }

    mutating func absorb(_ observation: NetworkObservation) {
        hosts.insert(observation.host.value)
        observations.append(observation)
        if let bundleID = observation.bundleID {
            bundleIDs.insert(bundleID)
            publisherPrefixes.insert(bundleID.publisherPrefix)
            hitsByApp[bundleID, default: 0] += observation.hits ?? 0
        }
        totalHits += observation.hits ?? 0
        if observation.domainType.indicatesCrossAppCollection { appleFlaggedCrossApp = true }
        if observation.context != nil { webContextCount += 1 }
    }

    public var categories: [DomainCategory] { matches.categories }
    public var organization: String? { matches.organization }
    public var isClassified: Bool { !matches.isEmpty }

    /// True when every category that applies is infrastructure every app uses.
    public var isCommonInfrastructureOnly: Bool { matches.isCommonInfrastructureOnly }

    /// Categories that make a cross-app appearance meaningful rather than
    /// expected.
    public var hasAggregationCategory: Bool {
        categories.contains { category in
            switch category {
            case .advertising, .attribution, .dataBroker, .locationIntelligence, .personalization, .analytics: true
            default: false
            }
        }
    }

    /// Number of *unrelated* publishers contacting this domain. Apps from the
    /// same publisher are one relationship, not several (DET-004).
    public var unrelatedPublisherCount: Int { publisherPrefixes.count }

    /// A weak, clearly-labeled heuristic that a domain belongs to the app
    /// itself: the second-level label of the registrable domain matches the
    /// app's publisher segment or its product segment
    /// (`com.example.weathernow` → `weathernow.example`).
    ///
    /// Only the second-level label is compared. Comparing every label would let
    /// the public suffix itself produce a match, which would quietly reclassify
    /// third-party domains as first-party and understate third-party reach.
    public func isLikelyFirstParty(for bundleID: BundleIdentifier) -> Bool {
        guard let secondLevel = key.labels.first, secondLevel.count >= 4 else { return false }
        let publisherToken = bundleID.publisherPrefix.split(separator: ".").last.map(String.init) ?? ""
        if publisherToken.count >= 4, secondLevel == publisherToken { return true }
        let productToken = bundleID.lastComponent
        return productToken.count >= 4 && secondLevel == productToken
    }
}

/// Per-app view of one report.
public struct ApplicationProfile: Sendable {
    public let bundleID: BundleIdentifier
    public let application: ObservedApplication?
    public private(set) var networkObservations: [NetworkObservation] = []
    public private(set) var sensorObservations: [SensorObservation] = []
    public private(set) var domainKeys: Set<String> = []

    init(bundleID: BundleIdentifier, application: ObservedApplication?) {
        self.bundleID = bundleID
        self.application = application
    }

    mutating func absorb(network: NetworkObservation) {
        networkObservations.append(network)
        domainKeys.insert(network.ownerKey.value)
    }

    mutating func absorb(sensor: SensorObservation) {
        sensorObservations.append(sensor)
    }

    public var totalHits: Int { networkObservations.reduce(0) { $0 + ($1.hits ?? 0) } }
    public var distinctDomainCount: Int { domainKeys.count }
    public var sensorTypes: [SensorType] {
        Array(Set(sensorObservations.map(\.sensorType))).sorted { $0.identifier < $1.identifier }
    }
}

/// Precomputed views over one import, built once per evaluation so rules are
/// cheap and see exactly the same data.
public struct AnalysisIndex: Sendable {
    public let snapshot: ObservationSnapshot
    public let domainGroups: [DomainGroup]
    public let applicationProfiles: [ApplicationProfile]
    private let groupsByKey: [String: Int]
    private let profilesByBundle: [String: Int]

    public init(snapshot: ObservationSnapshot, matcher: DomainMatcher) {
        let sorted = snapshot.sorted()
        var groups: [String: DomainGroup] = [:]
        var profiles: [String: ApplicationProfile] = [:]

        for observation in sorted.networkObservations {
            let key = observation.ownerKey
            var group = groups[key.value] ?? DomainGroup(key: key, matches: matcher.matches(for: observation.host))
            group.absorb(observation)
            groups[key.value] = group

            if let bundleID = observation.bundleID {
                var profile = profiles[bundleID.rawValue]
                    ?? ApplicationProfile(bundleID: bundleID, application: sorted.application(bundleID: bundleID))
                profile.absorb(network: observation)
                profiles[bundleID.rawValue] = profile
            }
        }

        for observation in sorted.sensorObservations {
            guard let bundleID = observation.bundleID else { continue }
            var profile = profiles[bundleID.rawValue]
                ?? ApplicationProfile(bundleID: bundleID, application: sorted.application(bundleID: bundleID))
            profile.absorb(sensor: observation)
            profiles[bundleID.rawValue] = profile
        }

        let orderedGroups = groups.values.sorted { $0.key.value < $1.key.value }
        let orderedProfiles = profiles.values.sorted { $0.bundleID < $1.bundleID }

        self.snapshot = sorted
        self.domainGroups = orderedGroups
        self.applicationProfiles = orderedProfiles
        self.groupsByKey = Dictionary(
            orderedGroups.enumerated().map { ($0.element.key.value, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        self.profilesByBundle = Dictionary(
            orderedProfiles.enumerated().map { ($0.element.bundleID.rawValue, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func group(for host: NormalizedHost) -> DomainGroup? {
        groupsByKey[host.value].map { domainGroups[$0] }
    }

    public func profile(for bundleID: BundleIdentifier) -> ApplicationProfile? {
        profilesByBundle[bundleID.rawValue].map { applicationProfiles[$0] }
    }

    /// Domains contacted by three or more unrelated publishers, which is the
    /// threshold rule AGG-CROSSAPP-002 uses.
    public var crossAppDomains: [DomainGroup] {
        domainGroups.filter { $0.unrelatedPublisherCount >= 3 }
    }
}
