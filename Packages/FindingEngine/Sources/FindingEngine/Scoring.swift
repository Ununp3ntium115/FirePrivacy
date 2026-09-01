import Foundation
import ObservationCore
import KnowledgeBaseKit
import PrivacyProfileKit

/// The dashboard's separate dimensions (DASH-001).
///
/// Fire Privacy shows dimensions rather than a single opaque number, and every
/// dimension names the inputs that produced it. The optional overall posture
/// score is presented as a summary of these, never as a safety grade.
public struct PostureScores: Codable, Sendable, Hashable {
    /// Higher means more sensitive access observed.
    public let sensorExposure: Double
    /// Higher means more reach by third parties.
    public let thirdPartyReach: Double
    /// Higher means more evidence consistent with cross-app aggregation.
    public let aggregationSignals: Double
    /// Higher means more repetition within the report window.
    public let repetition: Double
    /// Higher means more gaps between what was observed and what is controlled.
    public let controlGap: Double
    /// Higher means the analysis rests on stronger evidence.
    public let evidenceConfidence: Double
    /// 0–100 where higher is better.
    public let privacyPosture: Int
    /// The inputs behind each number, for the "How is this calculated?" screen.
    public let explanation: [String: String]

    public init(
        sensorExposure: Double,
        thirdPartyReach: Double,
        aggregationSignals: Double,
        repetition: Double,
        controlGap: Double,
        evidenceConfidence: Double,
        privacyPosture: Int,
        explanation: [String: String]
    ) {
        self.sensorExposure = sensorExposure
        self.thirdPartyReach = thirdPartyReach
        self.aggregationSignals = aggregationSignals
        self.repetition = repetition
        self.controlGap = controlGap
        self.evidenceConfidence = evidenceConfidence
        self.privacyPosture = privacyPosture
        self.explanation = explanation
    }

    public static let empty = PostureScores(
        sensorExposure: 0, thirdPartyReach: 0, aggregationSignals: 0,
        repetition: 0, controlGap: 0, evidenceConfidence: 0,
        privacyPosture: 100,
        explanation: ["state": "No report has been imported yet."]
    )
}

/// Computes the dimension scores (§13.2).
public enum PostureCalculator {
    // MARK: Weights

    /// Base weight per sensor category (§13.2).
    static func sensorWeight(_ sensorType: SensorType) -> Double {
        switch sensorType {
        case .preciseLocation: 25
        case .location: 22
        case .approximateLocation: 14
        case .microphone: 22
        case .camera: 18
        case .contacts: 18
        case .photosFullLibrary: 15
        case .photos: 12
        case .photosSelected: 6
        case .healthKit: 22
        case .screenRecording: 20
        case .bluetooth: 8
        case .motionAndFitness: 10
        case .localNetwork: 8
        case .calendars: 12
        case .reminders: 10
        case .speechRecognition: 14
        case .mediaLibrary: 8
        case .other: 10
        }
    }

    /// Category weight for third-party reach. Infrastructure categories weigh
    /// far less than advertising and data-broker categories.
    static func categoryWeight(_ categories: [DomainCategory]) -> Double {
        guard !categories.isEmpty else { return 0.45 }
        var weight = 0.0
        for category in categories {
            let value: Double = switch category {
            case .advertising, .dataBroker: 1.0
            case .locationIntelligence: 0.95
            case .attribution: 0.9
            case .personalization: 0.8
            case .social: 0.7
            case .analytics: 0.65
            case .telemetry: 0.5
            case .messaging: 0.45
            case .crashReporting: 0.3
            case .content: 0.3
            case .pushNotifications: 0.2
            case .payments, .authentication, .fraudPrevention: 0.15
            case .contentDelivery: 0.1
            case .unknown: 0.5
            }
            weight = max(weight, value)
        }
        return weight
    }

    /// Saturation constant for sensor exposure. Chosen so that a handful of
    /// routine accesses lands mid-scale rather than pinning the meter.
    static let sensorSaturation = 120.0

    // MARK: Dimensions

    public static func evaluate(
        index: AnalysisIndex,
        permissions: SelfReportedPermissionSet,
        protection: ProtectionCoverage,
        findings: [Finding],
        knowledgeBaseIsStale: Bool,
        reportIsStale: Bool,
        recurrenceAcrossReports: Double = 0
    ) -> PostureScores {
        var explanation: [String: String] = [:]

        // --- Sensor exposure -------------------------------------------------
        var sensorTotal = 0.0
        for observation in index.snapshot.sensorObservations {
            let count = observation.count ?? 1
            let frequency = 1 + min(1.0, log10(Double(1 + count)) / 3)
            var weight = sensorWeight(observation.sensorType) * frequency
            if let bundleID = observation.bundleID,
               let entry = permissions.entry(bundleID: bundleID, sensorType: observation.sensorType),
               entry.isExpected == true {
                // The user said this access makes sense. Their judgement counts.
                weight *= 0.5
            }
            sensorTotal += weight
        }
        let sensorExposure = 100 * (1 - exp(-sensorTotal / sensorSaturation))
        explanation["sensorExposure"] = "\(index.snapshot.sensorObservations.count) sensor access records, weighted by category and how often each was recorded."

        // --- Third-party reach ----------------------------------------------
        var weighted = 0.0
        var maximum = 0.0
        var thirdPartyCount = 0
        for group in index.domainGroups {
            let isFirstPartyEverywhere = group.bundleIDs.allSatisfy { group.isLikelyFirstParty(for: $0) }
            guard !isFirstPartyEverywhere else { continue }
            thirdPartyCount += 1
            let hits = max(1, group.totalHits)
            let magnitude = log(Double(1 + hits))
            let ownerWeight = group.organization != nil ? 1.0 : 0.8
            weighted += categoryWeight(group.categories) * ownerWeight * magnitude
            maximum += magnitude
        }
        let thirdPartyReach = maximum > 0 ? 100 * weighted / maximum : 0
        explanation["thirdPartyReach"] = "\(thirdPartyCount) third-party domains, weighted by what each is documented to do and how often it was contacted."

        // --- Aggregation signals --------------------------------------------
        var contributions: [Double] = []
        if index.domainGroups.contains(where: \.appleFlaggedCrossApp) { contributions.append(0.40) }
        if index.domainGroups.contains(where: { group in
            group.categories.contains { $0 == .dataBroker || $0 == .locationIntelligence }
        }) { contributions.append(0.35) }
        if !index.crossAppDomains.filter({ !$0.isCommonInfrastructureOnly }).isEmpty { contributions.append(0.25) }
        if index.domainGroups.contains(where: { group in
            group.categories.contains { $0 == .advertising || $0 == .attribution }
        }) { contributions.append(0.20) }
        if index.applicationProfiles.contains(where: { $0.distinctDomainCount >= 15 }) { contributions.append(0.10) }
        let aggregationSignals = 100 * (1 - contributions.reduce(1.0) { $0 * (1 - $1) })
        explanation["aggregationSignals"] = "\(contributions.count) independent signals combined with saturation, so repeated evidence of the same kind does not compound."

        // --- Repetition -------------------------------------------------------
        let windowSeconds = index.snapshot.session.coveredInterval?.duration ?? 0
        var spanRatios: [Double] = []
        var totalHits = 0
        for group in index.domainGroups {
            totalHits += group.totalHits
            let stamps = group.observations.compactMap { observation -> (Date, Date)? in
                guard let first = observation.firstTimestamp, let last = observation.lastTimestamp else { return nil }
                return (first, last)
            }
            guard let earliest = stamps.map(\.0).min(), let latest = stamps.map(\.1).max(), windowSeconds > 0 else { continue }
            spanRatios.append(min(1, latest.timeIntervalSince(earliest) / windowSeconds))
        }
        let normalizedSpan = spanRatios.isEmpty ? 0 : spanRatios.reduce(0, +) / Double(spanRatios.count)
        let normalizedHits = min(1, log10(Double(1 + totalHits)) / 4.5)
        let repetition = min(100, max(0, 35 * normalizedSpan + 45 * normalizedHits + 20 * min(1, recurrenceAcrossReports)))
        explanation["repetition"] = "How much of the report window each destination spans, plus total contact frequency. This is repetition in the report, not proof of background activity."

        // --- Control gap ------------------------------------------------------
        var gapPoints = 0.0
        let sensitiveApps = Set(index.snapshot.sensorObservations.compactMap(\.bundleID))
        let auditedApps = sensitiveApps.filter { bundleID in
            index.snapshot.sensorObservations
                .filter { $0.bundleID == bundleID }
                .contains { permissions.entry(bundleID: bundleID, sensorType: $0.sensorType) != nil }
        }
        if !sensitiveApps.isEmpty {
            gapPoints += 35 * (1 - Double(auditedApps.count) / Double(sensitiveApps.count))
        }
        let blockable = index.domainGroups.filter { group in
            group.appleFlaggedCrossApp || group.categories.contains { $0 == .advertising || $0 == .attribution || $0 == .dataBroker }
        }
        if !blockable.isEmpty, !protection.urlFilterIsActive {
            gapPoints += protection.supportsURLFilter ? 35 : 20
        }
        if reportIsStale { gapPoints += 15 }
        if knowledgeBaseIsStale { gapPoints += 15 }
        let controlGap = min(100, gapPoints)
        explanation["controlGap"] = "Sensitive accesses not yet verified in Settings, blockable destinations not covered by protection, and how fresh the report and knowledge base are."

        // --- Evidence confidence ---------------------------------------------
        let confidences = findings.map(\.confidence)
        let evidenceConfidence = confidences.isEmpty ? 100 : 100 * confidences.reduce(0, +) / Double(confidences.count)
        explanation["evidenceConfidence"] = "Average confidence across \(findings.count) findings. Low confidence means the evidence is weak, not that nothing happened."

        let exposure = 0.24 * sensorExposure + 0.24 * thirdPartyReach + 0.24 * aggregationSignals
            + 0.14 * repetition + 0.14 * controlGap
        let posture = Int(max(0, min(100, (100 - exposure).rounded())))
        explanation["privacyPosture"] = "100 − (0.24×Sensor + 0.24×Third-party + 0.24×Aggregation + 0.14×Repetition + 0.14×Control gap). It summarizes the dimensions above; it is not a safety grade."

        return PostureScores(
            sensorExposure: round(sensorExposure * 10) / 10,
            thirdPartyReach: round(thirdPartyReach * 10) / 10,
            aggregationSignals: round(aggregationSignals * 10) / 10,
            repetition: round(repetition * 10) / 10,
            controlGap: round(controlGap * 10) / 10,
            evidenceConfidence: round(evidenceConfidence * 10) / 10,
            privacyPosture: posture,
            explanation: explanation
        )
    }
}
