import Foundation
import ObservationCore
import KnowledgeBaseKit
import PrivacyProfileKit

/// Shared severity inputs (§13.4).
///
/// `impact` is capped for routine categories so that ordinary analytics or
/// advertising can never be labeled critical no matter how many apps or how many
/// contacts are involved — a scale that shouts at everything tells the user
/// nothing.
enum SeverityInputs {
    static func impact(for categories: [DomainCategory], isUnclassified: Bool) -> Double {
        guard !isUnclassified else { return 2.5 }
        var impact = 1.5
        for category in categories {
            let value: Double = switch category {
            case .dataBroker: 4.5
            case .locationIntelligence: 4.2
            case .personalization: 2.8
            case .social: 2.8
            case .advertising: 3.0
            case .attribution: 3.0
            case .analytics: 2.5
            case .telemetry: 2.0
            case .crashReporting: 1.5
            case .content: 1.5
            case .messaging: 2.0
            case .contentDelivery, .authentication, .payments, .fraudPrevention, .pushNotifications: 1.2
            case .unknown: 2.5
            }
            impact = max(impact, value)
        }
        return impact
    }

    static func breadth(unrelatedPublishers: Int) -> Double {
        1 + min(4, Double(unrelatedPublishers) * 0.9)
    }

    /// Repetition within the report window. Logarithmic and capped, because a
    /// hit count is a contact frequency, not a data volume (DET-008).
    static func persistence(hits: Int) -> Double {
        guard hits > 0 else { return 1 }
        return 1 + min(4, log10(Double(1 + hits)) / 1.2)
    }
}

/// Wording used in every finding that rests on a domain contact (DASH-009).
enum StandardUncertainty {
    static let payload = "The report records that a contact happened, not what was sent. Fire Privacy cannot see the contents of these requests."
    static let permissionState = "This is what the report observed during its window. It is not the app's current permission setting, which only Settings can show."
    static let purpose = "A contact with this domain does not by itself establish what the company did with any data."
    static let coverage = "Apps that use their own networking or their own encrypted DNS may be represented differently in the report."
}

// MARK: - AGG-APPLE-001

/// Apple's own export marked the domain as a possible cross-app or cross-site
/// collector (DET-005).
public struct AppleCrossAppClassificationRule: DetectionRule {
    public let id = "AGG-APPLE-001"
    public let version = "1.0.0"

    public init() {}

    public func evaluate(_ context: FindingEvaluationContext) -> RuleOutput {
        var output = RuleOutput()

        for group in context.index.domainGroups where group.appleFlaggedCrossApp {
            let flagged = group.observations
                .filter(\.domainType.indicatesCrossAppCollection)
                .sorted { $0.sourceLineNumber < $1.sourceLineNumber }
            guard let representative = flagged.first else { continue }

            var evidence = [EvidenceFactory.appleClassification(representative)]
            evidence.append(contentsOf: flagged.prefix(5).map(EvidenceFactory.network))
            evidence.append(contentsOf: group.matches.prefix(2).map { EvidenceFactory.knowledgeBase($0, host: group.key) })

            let severity = Severity.from(
                impact: SeverityInputs.impact(for: group.categories, isUnclassified: !group.isClassified),
                breadth: SeverityInputs.breadth(unrelatedPublishers: group.unrelatedPublisherCount),
                persistence: SeverityInputs.persistence(hits: group.totalHits)
            )
            let apps = group.bundleIDs.sorted().map(\.rawValue)

            let facts = [
                ObservedFact(
                    key: "apple_domain_classification",
                    value: representative.domainType.rawLabel?.value ?? "domainType=\(representative.domainType.rawValue.map(String.init) ?? "unset")",
                    evidenceIDs: [evidence[0].id]
                ),
                ObservedFact(key: "apps", value: apps.joined(separator: ", "), evidenceIDs: flagged.prefix(5).map(\.evidenceID)),
                ObservedFact(key: "contacts", value: String(group.totalHits), evidenceIDs: flagged.prefix(5).map(\.evidenceID)),
            ]

            let finding = makeFinding(
                ruleID: id,
                ruleVersion: version,
                titleKey: "finding.apple_cross_app.title",
                title: "Apple's report identifies \(group.key.displayValue) as a possible cross-app or cross-site collector.",
                subject: .domain(group.key),
                severity: severity,
                // Fixed at the value the specification assigns to this evidence
                // rather than combined upward: the supporting network records
                // are the same observation seen again, not corroboration.
                confidenceOverride: 0.95,
                evidence: evidence,
                facts: facts,
                inferences: [
                    Inference(
                        statement: "Contacts with this domain may contribute to a profile that spans more than one app or website.",
                        basis: [evidence[0].id],
                        confidence: 0.95
                    )
                ],
                uncertainty: [StandardUncertainty.payload, StandardUncertainty.purpose],
                recommendationIDs: recommendations(for: context),
                categoryKeys: group.categories.map(\.rawValue),
                context: context
            )
            output.findings.append(finding)
            output.evidence.append(contentsOf: evidence)
        }
        return output
    }

    private func recommendations(for context: FindingEvaluationContext) -> [String] {
        var ids = [
            RecommendationCatalog.reviewDomainDetail.id,
            RecommendationCatalog.learnAboutCrossApp.id,
        ]
        if context.protection.supportsURLFilter, !context.protection.urlFilterIsActive {
            ids.append(RecommendationCatalog.enableStandardFilter.id)
        }
        ids.append(RecommendationCatalog.keepAsIs.id)
        return ids
    }
}

// MARK: - AGG-CROSSAPP-002

/// The same third-party domain appears under several unrelated apps in one
/// report (DET-004).
public struct CrossAppRecurrenceRule: DetectionRule {
    public let id = "AGG-CROSSAPP-002"
    public let version = "1.0.0"

    public static let publisherThreshold = 3

    public init() {}

    public func evaluate(_ context: FindingEvaluationContext) -> RuleOutput {
        var output = RuleOutput()

        for group in context.index.domainGroups {
            guard group.unrelatedPublisherCount >= Self.publisherThreshold else { continue }
            // Infrastructure every app uses is not an aggregation signal.
            guard !group.isCommonInfrastructureOnly else { continue }
            guard group.hasAggregationCategory || !group.isClassified else { continue }
            // Already stated more strongly by AGG-APPLE-001.
            guard !group.appleFlaggedCrossApp else { continue }

            var evidence = [EvidenceFactory.crossApp(group)]
            evidence.append(contentsOf: group.observations.prefix(5).map(EvidenceFactory.network))
            evidence.append(contentsOf: group.matches.prefix(2).map { EvidenceFactory.knowledgeBase($0, host: group.key) })

            // Confidence falls between 0.70 and 0.88 depending on how well the
            // vendor is identified, and drops when the contacts came from
            // embedded web content rather than the apps themselves.
            var confidence = group.isClassified ? 0.88 : 0.70
            if group.matches.contains(where: { $0.classification.isHeuristicOnly }) { confidence -= 0.08 }
            let webRatio = group.observations.isEmpty ? 0 : Double(group.webContextCount) / Double(group.observations.count)
            confidence -= 0.15 * webRatio
            confidence = max(0.5, confidence)

            let severity = Severity.from(
                impact: SeverityInputs.impact(for: group.categories, isUnclassified: !group.isClassified),
                breadth: SeverityInputs.breadth(unrelatedPublishers: group.unrelatedPublisherCount),
                persistence: SeverityInputs.persistence(hits: group.totalHits)
            )

            let apps = group.bundleIDs.sorted().map(\.rawValue)
            let organization = group.organization
            let title = organization.map {
                "\($0) received activity from \(apps.count) unrelated apps on this device."
            } ?? "\(group.key.displayValue) was contacted by \(apps.count) unrelated apps."

            var uncertainty = [StandardUncertainty.payload, StandardUncertainty.purpose]
            if !group.isClassified {
                uncertainty.append("Fire Privacy has no reviewed record of who operates this domain, so its purpose is unknown.")
            }
            if webRatio > 0 {
                uncertainty.append("Some of these contacts happened inside web content shown in the app, which can explain a shared domain.")
            }

            let finding = makeFinding(
                ruleID: id,
                ruleVersion: version,
                titleKey: "finding.cross_app_recurrence.title",
                title: title,
                subject: .domain(group.key),
                severity: severity,
                confidenceOverride: confidence,
                evidence: evidence,
                facts: [
                    ObservedFact(key: "apps", value: apps.joined(separator: ", "), evidenceIDs: [evidence[0].id]),
                    ObservedFact(key: "unrelated_publishers", value: String(group.unrelatedPublisherCount), evidenceIDs: [evidence[0].id]),
                    ObservedFact(key: "contacts", value: String(group.totalHits), evidenceIDs: [evidence[0].id]),
                ],
                inferences: [
                    Inference(
                        statement: "One operator receiving activity from unrelated apps is consistent with combining that activity across apps.",
                        basis: [evidence[0].id],
                        confidence: confidence
                    )
                ],
                uncertainty: uncertainty,
                recommendationIDs: {
                    var ids = [RecommendationCatalog.reviewDomainDetail.id, RecommendationCatalog.learnAboutCrossApp.id]
                    if context.protection.supportsURLFilter, !context.protection.urlFilterIsActive {
                        ids.append(RecommendationCatalog.enableStandardFilter.id)
                    }
                    ids.append(RecommendationCatalog.markDomainTrusted.id)
                    ids.append(RecommendationCatalog.keepAsIs.id)
                    return ids
                }(),
                categoryKeys: group.categories.map(\.rawValue),
                context: context
            )
            output.findings.append(finding)
            output.evidence.append(contentsOf: evidence)
        }
        return output
    }
}

// MARK: - LOC-NET-003

/// Location access and location-intelligence infrastructure were both observed
/// for the same app in the same window (DET-007).
public struct LocationAndLocationVendorRule: DetectionRule {
    public let id = "LOC-NET-003"
    public let version = "1.0.0"

    public init() {}

    public func evaluate(_ context: FindingEvaluationContext) -> RuleOutput {
        var output = RuleOutput()

        for profile in context.index.applicationProfiles {
            let locationAccesses = profile.sensorObservations.filter(\.sensorType.isLocation)
            guard !locationAccesses.isEmpty else { continue }

            let locationVendorContacts = profile.networkObservations.filter { observation in
                guard let group = context.index.group(for: observation.ownerKey) else { return false }
                return group.categories.contains(.locationIntelligence)
            }
            guard !locationVendorContacts.isEmpty else { continue }

            var evidence = locationAccesses.prefix(3).map(EvidenceFactory.sensor)
            evidence.append(contentsOf: locationVendorContacts.prefix(3).map(EvidenceFactory.network))
            for observation in locationVendorContacts.prefix(2) {
                if let group = context.index.group(for: observation.ownerKey) {
                    evidence.append(contentsOf: group.matches.prefix(1).map { EvidenceFactory.knowledgeBase($0, host: group.key) })
                }
            }

            let hits = locationVendorContacts.reduce(0) { $0 + ($1.hits ?? 0) }
            let severity = Severity.from(
                impact: 4.2,
                breadth: 2,
                persistence: SeverityInputs.persistence(hits: hits)
            )

            let finding = makeFinding(
                ruleID: id,
                ruleVersion: version,
                titleKey: "finding.location_and_vendor.title",
                title: "\(profile.bundleID.rawValue) used location and contacted location-data infrastructure in the same period.",
                subject: .application(profile.bundleID),
                severity: severity,
                evidence: evidence,
                facts: [
                    ObservedFact(
                        key: "location_access",
                        value: locationAccesses.map(\.sensorType.identifier).joined(separator: ", "),
                        evidenceIDs: locationAccesses.prefix(3).map(\.evidenceID)
                    ),
                    ObservedFact(
                        key: "location_vendor_domains",
                        value: Set(locationVendorContacts.map(\.ownerKey.value)).sorted().joined(separator: ", "),
                        evidenceIDs: locationVendorContacts.prefix(3).map(\.evidenceID)
                    ),
                ],
                inferences: [
                    Inference(
                        statement: "The two observations happened in the same report window for the same app. That is a temporal relationship only.",
                        basis: evidence.map(\.id),
                        confidence: 0.75
                    )
                ],
                uncertainty: [
                    "The report does not show whether any location was sent to this domain, or what was sent.",
                    StandardUncertainty.permissionState,
                ],
                recommendationIDs: [
                    RecommendationCatalog.reviewLocationPermission.id,
                    RecommendationCatalog.reviewDomainDetail.id,
                    RecommendationCatalog.reviewAppNecessity.id,
                    RecommendationCatalog.keepAsIs.id,
                ],
                categoryKeys: [DomainCategory.locationIntelligence.rawValue, "location"],
                context: context
            )
            output.findings.append(finding)
            output.evidence.append(contentsOf: evidence)
        }
        return output
    }
}

// MARK: - SENSOR-UNEXPECTED-004

/// The user marked a sensitive access as unexpected.
public struct UnexpectedSensorAccessRule: DetectionRule {
    public let id = "SENSOR-UNEXPECTED-004"
    public let version = "1.0.0"

    public init() {}

    public func evaluate(_ context: FindingEvaluationContext) -> RuleOutput {
        var output = RuleOutput()

        for observation in context.snapshot.sensorObservations {
            guard let bundleID = observation.bundleID,
                  let entry = context.permissions.entry(bundleID: bundleID, sensorType: observation.sensorType),
                  entry.isExpected == false
            else { continue }

            let evidence = [EvidenceFactory.sensor(observation), EvidenceFactory.userPermission(entry)]
            let baseSeverity = Severity.from(
                impact: Self.sensorImpact(observation.sensorType),
                breadth: 2,
                persistence: SeverityInputs.persistence(hits: observation.count ?? 1)
            )
            let severity = Self.raised(baseSeverity)

            let finding = makeFinding(
                ruleID: id,
                ruleVersion: version,
                titleKey: "finding.unexpected_sensor.title",
                title: "You marked \(bundleID.rawValue)'s use of \(observation.sensorType.identifier) as unexpected.",
                subject: .application(bundleID),
                severity: severity,
                evidence: evidence,
                facts: [
                    ObservedFact(key: "sensor", value: observation.sensorType.identifier, evidenceIDs: [observation.evidenceID]),
                    ObservedFact(key: "user_marked", value: "unexpected", evidenceIDs: [evidence[1].id]),
                    ObservedFact(key: "recorded_permission_state", value: entry.state.rawValue, evidenceIDs: [evidence[1].id]),
                ],
                inferences: [
                    Inference(
                        statement: "An access the user did not expect is worth verifying before anything else on this app.",
                        basis: evidence.map(\.id),
                        confidence: 0.9
                    )
                ],
                uncertainty: [
                    StandardUncertainty.permissionState,
                    "Fire Privacy cannot verify the current setting; the state shown is what you recorded.",
                ],
                recommendationIDs: [
                    RecommendationCatalog.reviewSensorPermission.id,
                    RecommendationCatalog.reviewAppNecessity.id,
                    RecommendationCatalog.keepAsIs.id,
                ],
                categoryKeys: [observation.sensorType.identifier],
                context: context
            )
            output.findings.append(finding)
            output.evidence.append(contentsOf: evidence)
        }
        return output
    }

    static func sensorImpact(_ sensorType: SensorType) -> Double {
        switch sensorType {
        case .preciseLocation, .location: 4.0
        case .microphone: 4.2
        case .camera: 4.0
        case .contacts: 3.8
        case .photosFullLibrary: 3.6
        case .healthKit: 4.2
        case .approximateLocation, .photos, .photosSelected: 2.8
        case .screenRecording: 4.0
        default: 2.5
        }
    }

    static func raised(_ severity: Severity) -> Severity {
        switch severity {
        case .info: .low
        case .low: .medium
        case .medium: .high
        case .high, .critical: .critical
        }
    }
}

// MARK: - UNKNOWN-HIGHFANOUT-005

/// One app contacts many services whose purpose is not classified (DET-009).
public struct UnclassifiedFanOutRule: DetectionRule {
    public let id = "UNKNOWN-HIGHFANOUT-005"
    public let version = "1.0.0"

    public static let domainThreshold = 10
    public static let classifiedCoverageThreshold = 0.4

    public init() {}

    public func evaluate(_ context: FindingEvaluationContext) -> RuleOutput {
        var output = RuleOutput()

        for profile in context.index.applicationProfiles {
            let groups = Set(profile.networkObservations.map(\.ownerKey.value))
                .sorted()
                .compactMap { context.index.group(for: NormalizedHost(value: $0, kind: .domain)) }
            let thirdParty = groups.filter { !$0.isLikelyFirstParty(for: profile.bundleID) }
            guard thirdParty.count >= Self.domainThreshold else { continue }

            let classified = thirdParty.filter(\.isClassified).count
            let coverage = Double(classified) / Double(thirdParty.count)
            guard coverage < Self.classifiedCoverageThreshold else { continue }

            let unclassified = thirdParty.filter { !$0.isClassified }
            var evidence: [Evidence] = []
            for group in unclassified.prefix(6) {
                evidence.append(contentsOf: group.observations.prefix(1).map(EvidenceFactory.network))
            }
            guard !evidence.isEmpty else { continue }

            let finding = makeFinding(
                ruleID: id,
                ruleVersion: version,
                titleKey: "finding.unclassified_fan_out.title",
                title: "\(profile.bundleID.rawValue) contacts \(thirdParty.count) services whose purpose Fire Privacy has not classified.",
                subject: .application(profile.bundleID),
                severity: Severity.from(impact: 2.5, breadth: min(5, 1 + Double(thirdParty.count) / 6), persistence: SeverityInputs.persistence(hits: profile.totalHits)),
                confidenceOverride: 0.6,
                evidence: evidence,
                facts: [
                    ObservedFact(key: "third_party_domains", value: String(thirdParty.count), evidenceIDs: evidence.map(\.id)),
                    ObservedFact(key: "classified_domains", value: String(classified), evidenceIDs: evidence.map(\.id)),
                    ObservedFact(
                        key: "unclassified_examples",
                        value: unclassified.prefix(6).map(\.key.value).joined(separator: ", "),
                        evidenceIDs: evidence.map(\.id)
                    ),
                ],
                inferences: [
                    Inference(
                        statement: "A wide spread of unclassified destinations is worth reviewing. It is not by itself evidence of tracking.",
                        basis: evidence.map(\.id),
                        confidence: 0.6
                    )
                ],
                uncertainty: [
                    "An unknown owner means unknown, not dangerous. These domains may be ordinary infrastructure Fire Privacy has not reviewed.",
                    StandardUncertainty.payload,
                ],
                recommendationIDs: [
                    RecommendationCatalog.reviewDomainDetail.id,
                    RecommendationCatalog.learnAboutReportLimits.id,
                    RecommendationCatalog.keepAsIs.id,
                ],
                categoryKeys: [DomainCategory.unknown.rawValue],
                context: context
            )
            output.findings.append(finding)
            output.evidence.append(contentsOf: evidence)
        }
        return output
    }
}

// MARK: - VENDOR-KNOWN-006

/// A reviewed data-broker or location-intelligence endpoint was contacted
/// (DET-006).
public struct ReviewedHighImpactVendorRule: DetectionRule {
    public let id = "VENDOR-KNOWN-006"
    public let version = "1.0.0"

    public init() {}

    public func evaluate(_ context: FindingEvaluationContext) -> RuleOutput {
        var output = RuleOutput()

        for group in context.index.domainGroups {
            let highImpact = group.categories.filter { $0 == .dataBroker || $0 == .locationIntelligence }
            guard !highImpact.isEmpty else { continue }
            let reviewed = group.matches.filter { $0.classification.reviewStatus == .reviewed && !$0.classification.isHeuristicOnly }
            guard !reviewed.isEmpty else { continue }

            var evidence = reviewed.prefix(2).map { EvidenceFactory.knowledgeBase($0, host: group.key) }
            evidence.append(contentsOf: group.observations.prefix(4).map(EvidenceFactory.network))

            let apps = group.bundleIDs.sorted().map(\.rawValue)
            let organization = group.organization ?? group.key.displayValue
            let severity = Severity.from(
                impact: SeverityInputs.impact(for: group.categories, isUnclassified: false),
                breadth: SeverityInputs.breadth(unrelatedPublishers: group.unrelatedPublisherCount),
                persistence: SeverityInputs.persistence(hits: group.totalHits)
            )

            let finding = makeFinding(
                ruleID: id,
                ruleVersion: version,
                titleKey: "finding.reviewed_high_impact_vendor.title",
                title: "\(apps.count == 1 ? apps[0] : "\(apps.count) apps") contacted \(organization), recorded as \(highImpact.map(\.displayName).joined(separator: " and ")) infrastructure.",
                subject: .domain(group.key),
                severity: severity,
                evidence: evidence,
                facts: [
                    ObservedFact(key: "organization", value: organization, evidenceIDs: [evidence[0].id]),
                    ObservedFact(key: "categories", value: group.categories.map(\.displayName).joined(separator: ", "), evidenceIDs: [evidence[0].id]),
                    ObservedFact(key: "apps", value: apps.joined(separator: ", "), evidenceIDs: group.observations.prefix(4).map(\.evidenceID)),
                ],
                inferences: [
                    Inference(
                        statement: "This category of company builds and licenses information about people or places, so a contact is worth understanding.",
                        basis: [evidence[0].id],
                        confidence: 0.85
                    )
                ],
                uncertainty: [
                    StandardUncertainty.payload,
                    "This describes what the company's documented business is. It is not a statement that anything unlawful happened.",
                ],
                recommendationIDs: {
                    var ids = [RecommendationCatalog.reviewDomainDetail.id, RecommendationCatalog.reviewAppNecessity.id]
                    if context.protection.supportsURLFilter, !context.protection.urlFilterIsActive {
                        ids.append(RecommendationCatalog.enableStandardFilter.id)
                    }
                    ids.append(RecommendationCatalog.keepAsIs.id)
                    return ids
                }(),
                categoryKeys: group.categories.map(\.rawValue),
                context: context
            )
            output.findings.append(finding)
            output.evidence.append(contentsOf: evidence)
        }
        return output
    }
}

// MARK: - COVERAGE-GAP-007

/// Known tracking destinations are present and protection is available but off.
public struct ProtectionCoverageGapRule: DetectionRule {
    public let id = "COVERAGE-GAP-007"
    public let version = "1.0.0"

    public init() {}

    public func evaluate(_ context: FindingEvaluationContext) -> RuleOutput {
        guard context.protection.supportsURLFilter, !context.protection.urlFilterIsActive else { return RuleOutput() }

        let blockable = context.index.domainGroups.filter { group in
            group.categories.contains { $0 == .advertising || $0 == .attribution || $0 == .dataBroker }
                || group.appleFlaggedCrossApp
        }
        guard blockable.count >= 3 else { return RuleOutput() }

        var evidence = [EvidenceFactory.protectionState(context.protection)]
        evidence.append(contentsOf: blockable.prefix(4).compactMap { $0.observations.first.map(EvidenceFactory.network) })

        let finding = makeFinding(
            ruleID: id,
            ruleVersion: version,
            titleKey: "finding.protection_gap.title",
            title: "\(blockable.count) destinations in this report are the kind Fire Privacy's filter can deny, and the filter is off.",
            subject: .device,
            severity: .medium,
            confidenceOverride: 0.9,
            evidence: evidence,
            facts: [
                ObservedFact(key: "candidate_domains", value: String(blockable.count), evidenceIDs: evidence.map(\.id)),
                ObservedFact(key: "url_filter_active", value: "false", evidenceIDs: [evidence[0].id]),
            ],
            inferences: [
                Inference(
                    statement: "Turning the filter on would let iOS deny requests to destinations on Fire Privacy's list, without Fire Privacy seeing the addresses.",
                    basis: [evidence[0].id],
                    confidence: 0.9
                )
            ],
            uncertainty: [
                "Coverage depends on the networking each app uses. Apps with their own network stack are only covered if they opt in.",
                "Turning on a filter can break an app that depends on a blocked destination. Protection can be paused or removed at any time.",
            ],
            recommendationIDs: [
                RecommendationCatalog.enableStandardFilter.id,
                RecommendationCatalog.enableSafariContentBlocker.id,
                RecommendationCatalog.keepAsIs.id,
            ],
            categoryKeys: ["protection"],
            context: context
        )
        return RuleOutput(findings: [finding], evidence: evidence)
    }
}

// MARK: - FRESHNESS-008

/// The imported report is old enough that the dashboard would be describing the
/// past rather than the present (DASH-002, RPT-004).
public struct ReportFreshnessRule: DetectionRule {
    public let id = "FRESHNESS-008"
    public let version = "1.0.0"

    public static let staleAfter: TimeInterval = 60 * 60 * 24 * 14

    public init() {}

    public func evaluate(_ context: FindingEvaluationContext) -> RuleOutput {
        let session = context.snapshot.session
        let reference = session.reportEnd ?? session.importedAt
        let age = context.now.timeIntervalSince(reference)
        guard age > Self.staleAfter else { return RuleOutput() }

        let days = Int(age / 86_400)
        let evidence = [Evidence(
            id: "freshness:\(session.id.uuidString)",
            kind: .reportComparison,
            summary: "The most recent activity in this report is \(days) days old.",
            confidence: 0.98,
            detail: [
                "report_end": session.reportEnd.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown",
                "imported_at": ISO8601DateFormatter().string(from: session.importedAt),
                "age_days": String(days),
            ]
        )]

        let finding = makeFinding(
            ruleID: id,
            ruleVersion: version,
            titleKey: "finding.report_stale.title",
            title: "This report is \(days) days old.",
            subject: .device,
            severity: .info,
            confidenceOverride: 0.98,
            evidence: evidence,
            facts: [ObservedFact(key: "age_days", value: String(days), evidenceIDs: [evidence[0].id])],
            inferences: [
                Inference(
                    statement: "Everything shown describes the window this report covers, not what apps are doing now.",
                    basis: [evidence[0].id],
                    confidence: 0.98
                )
            ],
            uncertainty: ["No new report means no new information. It does not mean nothing changed."],
            recommendationIDs: [
                RecommendationCatalog.importFreshReport.id,
                RecommendationCatalog.learnAboutReportLimits.id,
                RecommendationCatalog.keepAsIs.id,
            ],
            categoryKeys: ["freshness"],
            context: context
        )
        return RuleOutput(findings: [finding], evidence: evidence)
    }
}

// MARK: - Shared construction

/// Builds a finding with a deterministic identifier, applying the local override
/// and staleness adjustments every rule shares.
func makeFinding(
    ruleID: String,
    ruleVersion: String,
    titleKey: String,
    title: String,
    subject: FindingSubject,
    severity: Severity,
    confidenceOverride: Double? = nil,
    evidence: [Evidence],
    facts: [ObservedFact],
    inferences: [Inference],
    uncertainty: [String],
    recommendationIDs: [String],
    categoryKeys: [String],
    context: FindingEvaluationContext
) -> Finding {
    let evidenceIDs = evidence.map(\.id).sorted()
    var severity = severity
    var status = FindingStatus.new

    // A user override lowers prominence but never changes the evidence.
    if case .domain(let host) = subject, let override = context.overrides.override(for: host) {
        switch override.disposition {
        case .trusted, .localAllow:
            severity = lowered(severity)
            status = .accepted
        case .alwaysReview, .localBlockRequest:
            severity = max(severity, .medium)
        case .customCategory:
            break
        }
    }
    if context.knowledgeBaseIsStale { status = .stale }

    return Finding(
        id: Finding.makeID(ruleID: ruleID, ruleVersion: ruleVersion, subject: subject, evidenceIDs: evidenceIDs),
        ruleID: ruleID,
        ruleVersion: ruleVersion,
        titleKey: titleKey,
        title: title,
        subject: subject,
        severity: severity,
        confidence: confidenceOverride ?? ConfidenceCalculator.combine(evidence),
        status: status,
        observedFacts: facts,
        inferences: inferences,
        uncertainty: uncertainty,
        evidenceIDs: evidenceIDs,
        recommendationIDs: recommendationIDs,
        categoryKeys: categoryKeys.sorted(),
        createdAt: context.now,
        isStale: context.knowledgeBaseIsStale
    )
}

private func lowered(_ severity: Severity) -> Severity {
    switch severity {
    case .critical: .high
    case .high: .medium
    case .medium: .low
    case .low, .info: .info
    }
}

/// The rules shipped in this release.
public enum RuleSet {
    public static let version = "ruleset-1.0.0"

    public static let all: [any DetectionRule] = [
        AppleCrossAppClassificationRule(),
        CrossAppRecurrenceRule(),
        LocationAndLocationVendorRule(),
        UnexpectedSensorAccessRule(),
        UnclassifiedFanOutRule(),
        ReviewedHighImpactVendorRule(),
        ProtectionCoverageGapRule(),
        ReportFreshnessRule(),
    ]
}
