import XCTest
@testable import FindingEngine
import ObservationCore
import KnowledgeBaseKit
import PrivacyProfileKit
import TestSupport

private func makeContext(
    network: [NetworkObservation],
    sensors: [SensorObservation] = [],
    permissions: SelfReportedPermissionSet = SelfReportedPermissionSet(),
    overrides: DomainOverrideSet = DomainOverrideSet(),
    protection: ProtectionCoverage = ProtectionCoverage(osMajorVersion: 26),
    profile: PrivacyProfile = .balanced,
    knowledgeBaseIsStale: Bool = false,
    now: Date = Fixtures.referenceDate
) -> FindingEvaluationContext {
    let snapshot = Fixtures.snapshot(network: network, sensors: sensors)
    return FindingEvaluationContext(
        index: AnalysisIndex(snapshot: snapshot, matcher: Fixtures.matcher),
        knowledgeBaseVersion: Fixtures.knowledgeBaseVersion,
        knowledgeBaseIsStale: knowledgeBaseIsStale,
        profile: profile,
        overrides: overrides,
        permissions: permissions,
        protection: protection,
        now: now
    )
}

final class RuleTests: XCTestCase {
    private let session = Fixtures.session()

    // MARK: AGG-APPLE-001

    func testAppleClassificationProducesAFinding() {
        let context = makeContext(network: [
            Fixtures.network(session: session, bundle: "com.example.one", host: "collect.tracker.example", domainType: 2)
        ])
        let findings = AppleCrossAppClassificationRule().evaluate(context).findings
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.confidence ?? 0, 0.95, accuracy: 0.05)
        XCTAssertFalse(findings.first?.uncertainty.isEmpty ?? true)
    }

    func testNoAppleClassificationMeansNoFinding() {
        let context = makeContext(network: [
            Fixtures.network(session: session, bundle: "com.example.one", host: "collect.tracker.example", domainType: 1)
        ])
        XCTAssertTrue(AppleCrossAppClassificationRule().evaluate(context).findings.isEmpty)
    }

    // MARK: AGG-CROSSAPP-002

    func testCrossAppRecurrenceNeedsThreeUnrelatedPublishers() {
        let two = makeContext(network: [
            Fixtures.network(session: session, bundle: "com.alpha.app", host: "collect.tracker.example", line: 1),
            Fixtures.network(session: session, bundle: "com.beta.app", host: "collect.tracker.example", line: 2),
        ])
        XCTAssertTrue(CrossAppRecurrenceRule().evaluate(two).findings.isEmpty)

        let three = makeContext(network: [
            Fixtures.network(session: session, bundle: "com.alpha.app", host: "collect.tracker.example", line: 1),
            Fixtures.network(session: session, bundle: "com.beta.app", host: "collect.tracker.example", line: 2),
            Fixtures.network(session: session, bundle: "com.gamma.app", host: "collect.tracker.example", line: 3),
        ])
        XCTAssertEqual(CrossAppRecurrenceRule().evaluate(three).findings.count, 1)
    }

    func testAppsFromOnePublisherAreOneRelationship() {
        let context = makeContext(network: [
            Fixtures.network(session: session, bundle: "com.alpha.one", host: "collect.tracker.example", line: 1),
            Fixtures.network(session: session, bundle: "com.alpha.two", host: "collect.tracker.example", line: 2),
            Fixtures.network(session: session, bundle: "com.alpha.three", host: "collect.tracker.example", line: 3),
        ])
        XCTAssertTrue(CrossAppRecurrenceRule().evaluate(context).findings.isEmpty)
    }

    func testSharedInfrastructureIsNotAnAggregationSignal() {
        for host in ["edge.cdn.example", "sso.login.example"] {
            let context = makeContext(network: [
                Fixtures.network(session: session, bundle: "com.alpha.app", host: host, line: 1),
                Fixtures.network(session: session, bundle: "com.beta.app", host: host, line: 2),
                Fixtures.network(session: session, bundle: "com.gamma.app", host: host, line: 3),
                Fixtures.network(session: session, bundle: "com.delta.app", host: host, line: 4),
            ])
            XCTAssertTrue(
                CrossAppRecurrenceRule().evaluate(context).findings.isEmpty,
                "\(host) is infrastructure every app uses and must not raise an aggregation signal"
            )
        }
    }

    func testWebContentContextLowersConfidence() {
        func confidence(context: String?) -> Double {
            let network = (1...3).map { index in
                Fixtures.network(
                    session: session,
                    bundle: "com.publisher\(index).app",
                    host: "collect.tracker.example",
                    context: context,
                    line: index
                )
            }
            return CrossAppRecurrenceRule().evaluate(makeContext(network: network)).findings.first?.confidence ?? 0
        }
        XCTAssertLessThan(confidence(context: "news.example"), confidence(context: nil))
    }

    // MARK: LOC-NET-003

    func testLocationRuleNeedsBothSignals() {
        let sensorOnly = makeContext(
            network: [Fixtures.network(session: session, bundle: "com.example.app", host: "api.example.com")],
            sensors: [Fixtures.sensor(session: session, bundle: "com.example.app", sensor: "location")]
        )
        XCTAssertTrue(LocationAndLocationVendorRule().evaluate(sensorOnly).findings.isEmpty)

        let both = makeContext(
            network: [Fixtures.network(session: session, bundle: "com.example.app", host: "geo.places.example")],
            sensors: [Fixtures.sensor(session: session, bundle: "com.example.app", sensor: "location")]
        )
        let findings = LocationAndLocationVendorRule().evaluate(both).findings
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(
            findings[0].uncertainty.contains { $0.contains("does not show whether any location was sent") },
            "a temporal correlation must never be reported as transmission (DET-007)"
        )
    }

    // MARK: SENSOR-UNEXPECTED-004

    func testUnexpectedAccessRaisesSeverity() {
        let sensor = Fixtures.sensor(session: session, bundle: "com.example.app", sensor: "microphone")
        var permissions = SelfReportedPermissionSet()
        permissions.record(SelfReportedPermission(
            bundleID: Fixtures.bundleID("com.example.app"),
            sensorType: .microphone,
            state: .whileUsing,
            isExpected: false,
            recordedAt: Fixtures.referenceDate
        ))
        let context = makeContext(network: [], sensors: [sensor], permissions: permissions)
        let findings = UnexpectedSensorAccessRule().evaluate(context).findings
        XCTAssertEqual(findings.count, 1)
        XCTAssertGreaterThanOrEqual(findings[0].severity, .high)
    }

    func testExpectedAccessProducesNoFinding() {
        let sensor = Fixtures.sensor(session: session, bundle: "com.example.app", sensor: "microphone")
        var permissions = SelfReportedPermissionSet()
        permissions.record(SelfReportedPermission(
            bundleID: Fixtures.bundleID("com.example.app"),
            sensorType: .microphone,
            state: .whileUsing,
            isExpected: true,
            recordedAt: Fixtures.referenceDate
        ))
        let context = makeContext(network: [], sensors: [sensor], permissions: permissions)
        XCTAssertTrue(UnexpectedSensorAccessRule().evaluate(context).findings.isEmpty)
    }

    // MARK: UNKNOWN-HIGHFANOUT-005

    func testUnclassifiedFanOut() {
        let network = (1...12).map { index in
            Fixtures.network(session: session, bundle: "com.example.app", host: "node\(index).unknown\(index).test", line: index)
        }
        let findings = UnclassifiedFanOutRule().evaluate(makeContext(network: network)).findings
        XCTAssertEqual(findings.count, 1)
        XCTAssertLessThan(findings[0].confidence, 0.75, "an unknown owner is unknown, not dangerous (DET-009)")
        XCTAssertLessThanOrEqual(findings[0].severity, .medium)
    }

    // MARK: VENDOR-KNOWN-006

    func testReviewedDataBrokerIsSurfaced() {
        let context = makeContext(network: [
            Fixtures.network(session: session, bundle: "com.example.app", host: "ingest.broker.example", hits: 500)
        ])
        let findings = ReviewedHighImpactVendorRule().evaluate(context).findings
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(
            findings[0].uncertainty.contains { $0.contains("not a statement that anything unlawful happened") },
            "vendor findings must not read as accusations (DASH-009)"
        )
    }

    // MARK: COVERAGE-GAP-007

    func testCoverageGapOnlyWhenProtectionIsAvailableAndOff() {
        let network = ["collect.tracker.example", "ingest.broker.example", "sdk.ads.example"].enumerated().map {
            Fixtures.network(session: session, bundle: "com.example.app\($0.offset)", host: $0.element, line: $0.offset)
        }
        let unsupported = makeContext(network: network, protection: ProtectionCoverage(osMajorVersion: 18))
        XCTAssertTrue(ProtectionCoverageGapRule().evaluate(unsupported).findings.isEmpty)

        let onAlready = makeContext(network: network, protection: ProtectionCoverage(urlFilterIsActive: true, osMajorVersion: 26))
        XCTAssertTrue(ProtectionCoverageGapRule().evaluate(onAlready).findings.isEmpty)

        let gap = makeContext(network: network, protection: ProtectionCoverage(osMajorVersion: 26))
        XCTAssertEqual(ProtectionCoverageGapRule().evaluate(gap).findings.count, 1)
    }

    func testRecommendationsNeverSuggestUnavailableActions() {
        let network = ["collect.tracker.example", "ingest.broker.example"].enumerated().map {
            Fixtures.network(session: session, bundle: "com.example.app\($0.offset)", host: $0.element, domainType: 2, line: $0.offset)
        }
        let context = makeContext(network: network, protection: ProtectionCoverage(osMajorVersion: 18))
        let findings = DeterministicFindingEngine().evaluate(context).findings
        let available = Set(RecommendationCatalog.available(osMajorVersion: 18).map(\.id))
        for finding in findings {
            for id in finding.recommendationIDs {
                XCTAssertTrue(available.contains(id), "\(finding.ruleID) suggested \(id), which iOS 18 cannot do")
            }
        }
    }

    // MARK: FRESHNESS-008

    func testStaleReportIsReported() {
        let context = makeContext(network: [], now: Fixtures.referenceDate.addingTimeInterval(40 * 86_400))
        let findings = ReportFreshnessRule().evaluate(context).findings
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].severity, .info)
    }
}

final class EngineTests: XCTestCase {
    private let session = Fixtures.session()

    private var busyContext: FindingEvaluationContext {
        makeContext(
            network: [
                Fixtures.network(session: session, bundle: "com.alpha.app", host: "collect.tracker.example", domainType: 2, line: 1),
                Fixtures.network(session: session, bundle: "com.beta.app", host: "collect.tracker.example", domainType: 2, line: 2),
                Fixtures.network(session: session, bundle: "com.gamma.app", host: "collect.tracker.example", domainType: 2, line: 3),
                Fixtures.network(session: session, bundle: "com.alpha.app", host: "ingest.broker.example", line: 4),
                Fixtures.network(session: session, bundle: "com.alpha.app", host: "geo.places.example", line: 5),
                Fixtures.network(session: session, bundle: "com.alpha.app", host: "edge.cdn.example", line: 6),
            ],
            sensors: [Fixtures.sensor(session: session, bundle: "com.alpha.app", sensor: "location")]
        )
    }

    func testResultsAreReproducible() {
        let engine = DeterministicFindingEngine()
        let first = engine.evaluate(busyContext)
        let second = engine.evaluate(busyContext)

        XCTAssertEqual(first.findings.map(\.id), second.findings.map(\.id))
        XCTAssertEqual(first.findings.map(\.severity), second.findings.map(\.severity))
        XCTAssertEqual(first.scores, second.scores)
    }

    func testEveryFindingCitesResolvableEvidence() {
        let result = DeterministicFindingEngine().evaluate(busyContext)
        XCTAssertFalse(result.findings.isEmpty)
        for finding in result.findings {
            XCTAssertFalse(finding.evidenceIDs.isEmpty, "\(finding.ruleID) has no evidence")
            for id in finding.evidenceIDs {
                XCTAssertNotNil(result.evidenceByID[id], "\(finding.ruleID) cites missing evidence \(id)")
            }
            XCTAssertNotNil(result.evidenceGraph(for: finding.id))
            XCTAssertFalse(finding.recommendationIDs.isEmpty)
            XCTAssertTrue(
                finding.recommendationIDs.contains(RecommendationCatalog.keepAsIs.id),
                "\(finding.ruleID) must offer the option to change nothing"
            )
        }
    }

    func testPriorityIsCappedAtFive() {
        XCTAssertLessThanOrEqual(DeterministicFindingEngine().evaluate(busyContext).priorityFindings.count, 5)
    }

    func testRoutineAdvertisingIsNeverCritical() {
        let network = (1...6).map { index in
            Fixtures.network(session: session, bundle: "com.publisher\(index).app", host: "ads.tracker.example", hits: 100_000, line: index)
        }
        let result = DeterministicFindingEngine().evaluate(makeContext(network: network))
        for finding in result.findings {
            XCTAssertLessThan(finding.severity, .critical, "\(finding.ruleID) escalated routine advertising to critical")
        }
    }

    func testProfileChangesRankingNotContent() {
        let engine = DeterministicFindingEngine()
        let balanced = engine.evaluate(busyContext)
        let strict = engine.evaluate(makeContext(
            network: busyContext.snapshot.networkObservations,
            sensors: busyContext.snapshot.sensorObservations,
            profile: .minimizeTracking
        ))
        XCTAssertEqual(Set(balanced.findings.map(\.id)), Set(strict.findings.map(\.id)))
    }

    func testStaleKnowledgeBaseMarksFindings() {
        let result = DeterministicFindingEngine().evaluate(makeContext(
            network: busyContext.snapshot.networkObservations,
            knowledgeBaseIsStale: true
        ))
        XCTAssertTrue(result.findings.allSatisfy(\.isStale))
        XCTAssertTrue(result.findings.allSatisfy { $0.status == .stale })
    }

    func testTrustedOverrideLowersSeverityWithoutHiding() {
        var overrides = DomainOverrideSet()
        overrides.set(DomainOverride(host: Fixtures.host("tracker.example"), disposition: .trusted, createdAt: Fixtures.referenceDate))
        let network = (1...3).map { index in
            Fixtures.network(session: session, bundle: "com.publisher\(index).app", host: "collect.tracker.example", line: index)
        }
        let plain = DeterministicFindingEngine().evaluate(makeContext(network: network))
        let overridden = DeterministicFindingEngine().evaluate(makeContext(network: network, overrides: overrides))

        XCTAssertEqual(plain.findings.count, overridden.findings.count)
        XCTAssertLessThanOrEqual(
            overridden.findings.map(\.severity).max() ?? .info,
            plain.findings.map(\.severity).max() ?? .info
        )
    }

    func testLifecycleMarksRecurringFindings() {
        let engine = DeterministicFindingEngine()
        let first = engine.evaluate(busyContext)
        let second = engine.evaluate(busyContext).withLifecycle(comparedTo: first)
        XCTAssertTrue(second.findings.allSatisfy { $0.status == .recurring })
    }
}

final class ScoringTests: XCTestCase {
    func testEmptyReportScoresCleanly() {
        let scores = PostureCalculator.evaluate(
            index: AnalysisIndex(snapshot: Fixtures.snapshot(network: []), matcher: Fixtures.matcher),
            permissions: SelfReportedPermissionSet(),
            protection: ProtectionCoverage(),
            findings: [],
            knowledgeBaseIsStale: false,
            reportIsStale: false
        )
        XCTAssertEqual(scores.sensorExposure, 0)
        XCTAssertEqual(scores.thirdPartyReach, 0)
    }

    func testInfrastructureScoresLowerThanAdvertising() {
        let session = Fixtures.session()
        func reach(_ host: String) -> Double {
            let snapshot = Fixtures.snapshot(network: [
                Fixtures.network(session: session, bundle: "com.example.app", host: host, hits: 100)
            ])
            return PostureCalculator.evaluate(
                index: AnalysisIndex(snapshot: snapshot, matcher: Fixtures.matcher),
                permissions: SelfReportedPermissionSet(),
                protection: ProtectionCoverage(),
                findings: [],
                knowledgeBaseIsStale: false,
                reportIsStale: false
            ).thirdPartyReach
        }
        XCTAssertLessThan(reach("edge.cdn.example"), reach("ads.tracker.example"))
    }

    func testEveryDimensionIsExplained() {
        let scores = PostureCalculator.evaluate(
            index: AnalysisIndex(snapshot: Fixtures.snapshot(network: []), matcher: Fixtures.matcher),
            permissions: SelfReportedPermissionSet(),
            protection: ProtectionCoverage(),
            findings: [],
            knowledgeBaseIsStale: false,
            reportIsStale: false
        )
        for key in ["sensorExposure", "thirdPartyReach", "aggregationSignals", "repetition", "controlGap", "evidenceConfidence", "privacyPosture"] {
            XCTAssertNotNil(scores.explanation[key], "\(key) must be explainable (DASH-001)")
        }
    }
}

final class ConfidenceTests: XCTestCase {
    func testCorrelatedEvidenceDoesNotCompound() {
        func evidence(_ id: String) -> Evidence {
            Evidence(id: id, kind: .appleNetworkObservation, summary: "s", confidence: 0.9)
        }
        let single = ConfidenceCalculator.combine([evidence("a")])
        let five = ConfidenceCalculator.combine((1...5).map { evidence("e\($0)") })
        XCTAssertGreaterThan(five, single)
        XCTAssertLessThan(five, 0.99)
    }

    func testIndependentEvidenceCombinesMoreStrongly() {
        let correlated = ConfidenceCalculator.combine([
            Evidence(id: "a", kind: .appleNetworkObservation, summary: "s", confidence: 0.8),
            Evidence(id: "b", kind: .appleNetworkObservation, summary: "s", confidence: 0.8),
        ])
        let independent = ConfidenceCalculator.combine([
            Evidence(id: "a", kind: .appleNetworkObservation, summary: "s", confidence: 0.8),
            Evidence(id: "b", kind: .knowledgeBaseMatch, summary: "s", confidence: 0.8),
        ])
        XCTAssertGreaterThan(independent, correlated)
    }

    func testSeverityIsIndependentOfConfidence() {
        XCTAssertEqual(
            Severity.from(impact: 5, breadth: 5, persistence: 5),
            Severity.from(impact: 5, breadth: 5, persistence: 5)
        )
        XCTAssertEqual(Severity.from(impact: 1, breadth: 1, persistence: 1), .info)
        XCTAssertEqual(Severity.from(impact: 5, breadth: 5, persistence: 5), .critical)
    }
}
