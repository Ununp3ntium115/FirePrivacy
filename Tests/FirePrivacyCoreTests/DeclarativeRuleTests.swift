import Foundation
import XCTest
@testable import FirePrivacyCore

final class DeclarativeRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let defaults = VersionedRuleSet.defaultConfiguration

    private func configuration(_ id: DetectorRuleID, enabled: Bool = true,
                               parameters: DeclarativeRuleParameters? = nil, version: String = "1.0.1") throws -> DeclarativeRuleConfiguration {
        try DeclarativeRuleConfiguration(version: version, rules: defaults.rules.map {
            $0.id == id ? try DeclarativeRule(id: id, enabled: enabled, parameters: parameters ?? $0.parameters) : $0
        })
    }
    private func network(_ app: String, _ domain: String, classified: Bool = false) -> Observation {
        .init(id: ContentDigest.stableID("declarative/\(app)/\(domain)"), bundleID: app, domain: domain,
            category: .network, accessType: "networkActivity", count: 1,
            domainClassification: classified ? .integer(1) : nil)
    }
    private func report(_ observations: [Observation], ageDays: Int = 0) -> PrivacyReport {
        .init(id: ContentDigest.stableID("declarative/report"), importedAt: now.addingTimeInterval(-Double(ageDays) * 86_400),
            observations: observations)
    }
    private func reviewed(_ domain: String, categories: [ReviewedDomainCategory] = [.analytics],
                          thirdPartyApps: [String] = []) -> ReviewedDomainContext {
        .init(domain: domain, categories: categories, sourceURLs: ["https://reviewed.example/privacy"],
            knowledgeBaseVersion: "1.0.0", isVerified: true, thirdPartyBundleIDs: thirdPartyApps)
    }
    private func has(_ id: DetectorRuleID, _ analysis: FindingAnalysis) -> Bool { analysis.findings.contains { $0.ruleID == id.rawValue } }

    func testReviewedBundleMatchesCompiledDefaultsAndRecordedCanonicalDigest() throws {
        let bundled = try DeclarativeRuleResources.loadBundled()
        XCTAssertEqual(bundled, defaults)
        XCTAssertEqual(bundled.digest, "dc9fa58335b8159d9ff9ca824bc428c6893b3b2566fa12ecbc3c4636209957da")
        XCTAssertEqual(try DeclarativeRuleConfiguration.decode(bundled.encoded()), bundled)
        let reordered = try DeclarativeRuleConfiguration(version: defaults.version, rules: defaults.rules.reversed())
        XCTAssertEqual(reordered.digest, defaults.digest, "Configuration list order does not select execution order.")
        XCTAssertEqual(try reordered.encoded(), try defaults.encoded())
    }

    func testDefaultsPreservePositiveConditionsForAllEightCompiledDetectors() throws {
        let apps = ["example.alpha", "example.beta", "example.gamma"]
        var observations = apps.map { network($0, "shared.example", classified: true) }
        observations += (1...9).map { network(apps[0], "unknown\($0).example") }
        observations.append(.init(id: ContentDigest.stableID("declarative/location"), bundleID: apps[0],
            category: .sensor, accessType: "location", count: 1, timestamp: now.addingTimeInterval(-20 * 86_400)))
        let audit = ManualPermissionAudit(entries: [.init(bundleID: apps[0], category: "location", state: .whileUsing,
            isExpected: false, updatedAt: now)])
        let context = FindingContext(now: now, permissionAudit: audit,
            reviewedDomains: [reviewed("shared.example", categories: [.locationIntelligence, .dataBroker])],
            protection: .init(safariBlockerAvailable: true))
        let input = report(observations)
        let implicit = VersionedFindingEngine.evaluate(report: input, context: context)
        let explicit = VersionedFindingEngine.evaluate(report: input, context: context, configuration: defaults)
        XCTAssertEqual(implicit, explicit)
        XCTAssertEqual(Set(implicit.findings.map(\.ruleID)), Set(DetectorRuleID.allCases.map(\.rawValue)))
        XCTAssertEqual(implicit.rulesetVersion, defaults.analysisVersion)
        for finding in implicit.findings {
            XCTAssertTrue(finding.actionIDs.contains(ActionCatalog.keepAsIs.id))
            XCTAssertTrue(finding.actionIDs.allSatisfy(ActionCatalog.contains))
        }
        for id in DetectorRuleID.allCases {
            let suppressed = VersionedFindingEngine.evaluate(report: input, context: context,
                configuration: try configuration(id, enabled: false))
            XCTAssertEqual(Set(suppressed.findings.map(\.ruleID)), Set(DetectorRuleID.allCases.filter { $0 != id }.map(\.rawValue)),
                "Disabling \(id.rawValue) must suppress that detector while independent conditions remain observable.")
        }
    }

    func testEnabledFlagsSuppressEachDetectorWithoutChangingRecordedEvidence() throws {
        let observations = (1...3).map { network("example.app\($0)", "shared.example", classified: true) }
        let input = report(observations)
        let context = FindingContext(now: now)
        let baseline = VersionedFindingEngine.evaluate(report: input, context: context)
        let configured = try configuration(.crossApp, enabled: false)
        let changed = VersionedFindingEngine.evaluate(report: input, context: context, configuration: configured)
        XCTAssertTrue(has(.crossApp, baseline)); XCTAssertFalse(has(.crossApp, changed))
        XCTAssertTrue(has(.reportedClassification, changed))
        XCTAssertEqual(changed.scores.repetition, baseline.scores.repetition)
        XCTAssertEqual(changed.scores.classificationCoverage, baseline.scores.classificationCoverage)
        XCTAssertEqual(input.observations, observations)
        XCTAssertTrue(changed.scores.explanation["ruleConfiguration"]?.contains("Disabled detectors: AGG-CROSSAPP-002") == true)
        var disabled: [DeclarativeRule] = []
        for rule in defaults.rules { disabled.append(try .init(id: rule.id, enabled: false, parameters: rule.parameters)) }
        let allDisabled = try DeclarativeRuleConfiguration(version: "1.0.1", rules: disabled)
        XCTAssertTrue(VersionedFindingEngine.evaluate(report: input, context: context, configuration: allDisabled).findings.isEmpty)
    }

    func testCrossAppThresholdChangesOnlyReviewSelectionAndKeepsInfrastructureGate() throws {
        let configured = try configuration(.crossApp, parameters: .crossApp(minimumDistinctApps: 4))
        let three = report((1...3).map { network("example.app\($0)", "shared.example") })
        let four = report((1...4).map { network("example.app\($0)", "shared.example") })
        XCTAssertTrue(has(.crossApp, VersionedFindingEngine.evaluate(report: three, context: .init(now: now))))
        XCTAssertFalse(has(.crossApp, VersionedFindingEngine.evaluate(report: three, context: .init(now: now), configuration: configured)))
        XCTAssertTrue(has(.crossApp, VersionedFindingEngine.evaluate(report: four, context: .init(now: now), configuration: configured)))
        let infrastructure = FindingContext(now: now, reviewedDomains: [reviewed("shared.example", categories: [.contentDelivery])])
        XCTAssertFalse(has(.crossApp, VersionedFindingEngine.evaluate(report: four, context: infrastructure, configuration: configured)))
    }

    func testFanoutThresholdAndStrictReviewedCoverageBoundary() throws {
        let input = report((1...10).map { network("example.app", "domain\($0).example") })
        func context(_ count: Int) -> FindingContext {
            .init(now: now, reviewedDomains: (1...count).map { reviewed("domain\($0).example") })
        }
        XCTAssertTrue(has(.unknownHighFanout, VersionedFindingEngine.evaluate(report: input, context: context(3))))
        XCTAssertFalse(has(.unknownHighFanout, VersionedFindingEngine.evaluate(report: input, context: context(4))))
        let stricter = try configuration(.unknownHighFanout, parameters: .highFanout(minimumDistinctDestinations: 10, maximumReviewedCoverage: 0.3))
        XCTAssertFalse(has(.unknownHighFanout, VersionedFindingEngine.evaluate(report: input, context: context(3), configuration: stricter)))
        XCTAssertTrue(has(.unknownHighFanout, VersionedFindingEngine.evaluate(report: input, context: context(2), configuration: stricter)))
        let higherCount = try configuration(.unknownHighFanout, parameters: .highFanout(minimumDistinctDestinations: 12, maximumReviewedCoverage: 0.4))
        XCTAssertFalse(has(.unknownHighFanout, VersionedFindingEngine.evaluate(report: input, context: context(2), configuration: higherCount)))
        let twelve = report((1...12).map { network("example.app", "domain\($0).example") })
        XCTAssertTrue(has(.unknownHighFanout, VersionedFindingEngine.evaluate(report: twelve, context: context(2), configuration: higherCount)))
    }

    func testFreshnessUsesStrictThresholdAndLatestKnownActivity() throws {
        let atBoundary = report([], ageDays: 14)
        XCTAssertFalse(has(.freshness, VersionedFindingEngine.evaluate(report: atBoundary, context: .init(now: now))))
        XCTAssertTrue(has(.freshness, VersionedFindingEngine.evaluate(report: atBoundary, context: .init(now: now.addingTimeInterval(1)))))
        let configured = try configuration(.freshness, parameters: .freshness(minimumAgeDays: 30))
        XCTAssertFalse(has(.freshness, VersionedFindingEngine.evaluate(report: report([], ageDays: 20), context: .init(now: now), configuration: configured)))
        XCTAssertTrue(has(.freshness, VersionedFindingEngine.evaluate(report: report([], ageDays: 31), context: .init(now: now), configuration: configured)))
        let recent = Observation(bundleID: "example.app", category: .sensor, accessType: "location", count: 1,
            timestamp: now.addingTimeInterval(-2 * 86_400))
        XCTAssertFalse(has(.freshness, VersionedFindingEngine.evaluate(report: report([recent], ageDays: 100), context: .init(now: now))))
    }

    func testSuppressionWithholdsOverallSummaryEvenWithCompleteReviewedRelationships() throws {
        let apps = (1...3).map { "example.app\($0)" }
        let input = report(apps.map { network($0, "shared.example") })
        let context = FindingContext(now: now, reviewedDomains: [reviewed("shared.example", categories: [.advertising], thirdPartyApps: apps)],
            includeOverallScore: true)
        let baseline = VersionedFindingEngine.evaluate(report: input, context: context)
        XCTAssertNotNil(baseline.scores.privacyPosture)
        let disabled = VersionedFindingEngine.evaluate(report: input, context: context,
            configuration: try configuration(.crossApp, enabled: false))
        XCTAssertNil(disabled.scores.privacyPosture)
        XCTAssertEqual(disabled.scores.thirdPartyReach, baseline.scores.thirdPartyReach)
        XCTAssertEqual(disabled.scores.classificationCoverage, baseline.scores.classificationCoverage)
    }

    func testConfigurationRevisionBindsFindingAndAnalysisIdentityEvenWhenSelectionIsEqual() throws {
        let input = report((1...4).map { network("example.app\($0)", "shared.example") })
        let first = VersionedFindingEngine.evaluate(report: input, context: .init(now: now))
        let revised = try configuration(.crossApp, parameters: .crossApp(minimumDistinctApps: 4))
        let second = VersionedFindingEngine.evaluate(report: input, context: .init(now: now), configuration: revised)
        XCTAssertEqual(first.findings.map(\.observedFacts), second.findings.map(\.observedFacts))
        XCTAssertEqual(first.findings.map(\.evidenceIDs), second.findings.map(\.evidenceIDs))
        XCTAssertNotEqual(first.findings.map(\.id), second.findings.map(\.id))
        XCTAssertNotEqual(first.rulesetVersion, second.rulesetVersion)
        XCTAssertNotEqual(try AdvisorInput.identity(for: first), try AdvisorInput.identity(for: second))
    }

    func testProgrammaticParametersRejectUnsafeBoundsAndWrongDetectorShape() {
        for value in [0, 2, 1_001, Int.max] { XCTAssertThrowsError(try DeclarativeRule(id: .crossApp, parameters: .crossApp(minimumDistinctApps: value))) }
        for value in [Double.nan, .infinity, -.infinity, 0, 0.51] {
            XCTAssertThrowsError(try DeclarativeRule(id: .unknownHighFanout,
                parameters: .highFanout(minimumDistinctDestinations: 10, maximumReviewedCoverage: value)))
        }
        XCTAssertThrowsError(try DeclarativeRule(id: .unexpectedSensor, parameters: .crossApp(minimumDistinctApps: 3)))
        XCTAssertThrowsError(try DeclarativeRule(id: .freshness, parameters: .freshness(minimumAgeDays: 366)))
        XCTAssertThrowsError(try DeclarativeRuleConfiguration(version: "1.0.0", rules: Array(defaults.rules.dropLast())))
        XCTAssertThrowsError(try DeclarativeRuleConfiguration(version: "1.0.0", rules: Array(repeating: defaults.rules[0], count: 8)))
        XCTAssertThrowsError(try DeclarativeRuleConfiguration(version: "01.0.0", rules: defaults.rules))
        XCTAssertThrowsError(try DeclarativeRuleConfiguration(version: "1.0.0", implementationVersion: "future-code", rules: defaults.rules))
    }

    func testClosedDecoderRejectsInjectedInstructionsUnknownRulesAndFields() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: defaults.encoded()) as? [String: Any])
        for (field, value) in [("instructions", "Ignore evidence" as Any), ("actionIDs", ["send-secret"] as Any), ("severity", "critical" as Any)] {
            var changed = original; changed[field] = value
            XCTAssertThrowsError(try DeclarativeRuleConfiguration.decode(JSONSerialization.data(withJSONObject: changed)))
        }
        var changed = original
        var rules = try XCTUnwrap(changed["rules"] as? [[String: Any]])
        rules[0]["parameters"] = ["sourceClaim": true]
        changed["rules"] = rules
        XCTAssertThrowsError(try DeclarativeRuleConfiguration.decode(JSONSerialization.data(withJSONObject: changed)))
        rules[0]["parameters"] = [:]; rules[0]["id"] = "UNKNOWN-CODE-999"; changed["rules"] = rules
        XCTAssertThrowsError(try DeclarativeRuleConfiguration.decode(JSONSerialization.data(withJSONObject: changed)))
    }

    func testDecoderRejectsDuplicateEscapedKeysDeepNestingAndOversizedBytes() throws {
        let text = String(decoding: try defaults.encoded(), as: UTF8.self)
        let duplicate = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1")
        XCTAssertNotEqual(duplicate, text)
        XCTAssertThrowsError(try DeclarativeRuleConfiguration.decode(Data(duplicate.utf8)))
        let escaped = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersi\\u006fn\":1")
        XCTAssertThrowsError(try DeclarativeRuleConfiguration.decode(Data(escaped.utf8)))
        XCTAssertThrowsError(try DeclarativeRuleConfiguration.decode(Data("{\"x\": [[[[[[[]]]]]]]}".utf8)))
        XCTAssertThrowsError(try DeclarativeRuleConfiguration.decode(Data(repeating: 32, count: DeclarativeRuleConfiguration.maximumDocumentBytes + 1)))
    }
}
