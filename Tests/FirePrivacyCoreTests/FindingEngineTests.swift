import Foundation
import XCTest
@testable import FirePrivacyCore

final class FindingEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func network(_ app: String = "example.app", _ domain: String = "example.net", count: Int = 1,
                         domainType: ReportedValue? = nil, classification: ReportedValue? = nil) -> Observation {
        Observation(id: ContentDigest.stableID("finding-test/\(app)/\(domain)"), bundleID: app, domain: domain,
                    category: .network, accessType: "networkActivity", count: count,
                    domainType: domainType, domainClassification: classification)
    }
    private func sensor(_ app: String = "example.app", category: String = "location") -> Observation {
        Observation(id: ContentDigest.stableID("finding-test/sensor/\(app)/\(category)"), bundleID: app,
                    category: .sensor, accessType: category, count: 1, timestamp: now)
    }
    private func report(_ records: [Observation], importedAt: Date? = nil) -> PrivacyReport {
        .init(id: ContentDigest.stableID("finding-test/report"), importedAt: importedAt ?? now, observations: records)
    }
    private func knowledge(_ domain: String = "example.net", categories: [ReviewedDomainCategory] = [.analytics],
                           verified: Bool = true, sources: [String] = ["https://vendor.example/privacy"],
                           expiry: Date? = nil, thirdPartyApps: [String] = []) -> ReviewedDomainContext {
        .init(domain: domain, organization: "Reviewed operator", categories: categories, sourceURLs: sources,
              knowledgeBaseVersion: "1.0.0", isVerified: verified, expiresAt: expiry, thirdPartyBundleIDs: thirdPartyApps)
    }
    private func analyze(_ records: [Observation], context: FindingContext? = nil) -> FindingAnalysis {
        VersionedFindingEngine.evaluate(report: report(records), context: context ?? FindingContext(now: now))
    }

    func testUndocumentedNumericClassificationNeverClaimsTracking() throws {
        let analysis = analyze([network(domainType: .integer(2), classification: .integer(1))])
        let finding = try XCTUnwrap(analysis.findings.first { $0.ruleID == "AGG-APPLE-001" })
        XCTAssertEqual(finding.severity, .info)
        XCTAssertTrue(finding.inferences.isEmpty)
        XCTAssertEqual(Set(finding.observedFacts.map(\.value)), ["1", "2"])
        XCTAssertTrue(finding.uncertainty.contains { $0.contains("not interpreted as tracking") })
        XCTAssertNil(analysis.scores.thirdPartyReach)
    }

    func testSharedAppsAreNotAssumedToBeUnrelatedPublishers() throws {
        let records = (1...3).map { network("example.app\($0)") }
        let finding = try XCTUnwrap(analyze(records).findings.first { $0.ruleID == "AGG-CROSSAPP-002" })
        XCTAssertTrue(finding.inferences[0].statement.contains("may share a publisher"))
        XCTAssertFalse(finding.observedFacts.contains { $0.key == "verified_publishers" })
        let context = FindingContext(now: now, appPublisherIDs: ["example.app1": "publisher1", "example.app2": "publisher2", "example.app3": "publisher3"])
        let verified = try XCTUnwrap(analyze(records, context: context).findings.first { $0.ruleID == "AGG-CROSSAPP-002" })
        XCTAssertTrue(verified.observedFacts.contains { $0.key == "verified_publishers" && $0.value == "3" })
        XCTAssertTrue(verified.uncertainty.contains(FindingUncertainty.payload))
    }

    func testInfrastructureDoesNotCreateAggregationFinding() {
        let records = (1...4).map { network("example.app\($0)") }
        let context = FindingContext(now: now, reviewedDomains: [knowledge(categories: [.contentDelivery, .authentication])])
        XCTAssertFalse(analyze(records, context: context).findings.contains { $0.ruleID == "AGG-CROSSAPP-002" })
    }

    func testUnknownFanoutMeansUnknownRatherThanDangerous() throws {
        let records = (1...10).map { network("example.app", "domain\($0).example") }
        let analysis = analyze(records)
        let finding = try XCTUnwrap(analysis.findings.first { $0.ruleID == "UNKNOWN-HIGHFANOUT-005" })
        XCTAssertEqual(finding.severity, .low)
        XCTAssertTrue(finding.uncertainty.contains(FindingUncertainty.unknown))
        XCTAssertTrue(finding.uncertainty.contains { $0.contains("not assumed to be third parties") })
        XCTAssertNil(analysis.scores.thirdPartyReach)
        XCTAssertNil(analysis.scores.privacyPosture)
    }

    func testManualUnexpectedRuleNeedsExplicitUserExpectation() throws {
        let observation = sensor()
        XCTAssertFalse(analyze([observation]).findings.contains { $0.ruleID == "SENSOR-UNEXPECTED-004" })
        let audit = ManualPermissionAudit(entries: [.init(bundleID: "example.app", category: "location", state: .denied, isExpected: false, updatedAt: now)])
        let finding = try XCTUnwrap(analyze([observation], context: .init(now: now, permissionAudit: audit)).findings.first)
        XCTAssertEqual(finding.ruleID, "SENSOR-UNEXPECTED-004")
        XCTAssertEqual(finding.evidenceIDs, [observation.id])
        XCTAssertTrue(finding.uncertainty.contains { $0.contains("not a device permission reading") })
        let expected = ManualPermissionAudit(entries: [.init(bundleID: "example.app", category: "location", state: .always, isExpected: true, updatedAt: now)])
        XCTAssertFalse(analyze([observation], context: .init(now: now, permissionAudit: expected)).findings.contains { $0.ruleID == "SENSOR-UNEXPECTED-004" })
    }

    func testHighImpactRuleRequiresVerifiedHTTPSReviewedSources() {
        let observation = network()
        for item in [knowledge(categories: [.dataBroker], verified: false),
                     knowledge(categories: [.dataBroker], sources: []),
                     knowledge(categories: [.dataBroker], sources: ["http://vendor.example/privacy"]),
                     knowledge(categories: [.dataBroker], sources: ["https:"]),
                     knowledge(categories: [.dataBroker], sources: ["https://user:password@vendor.example/privacy"])] {
            XCTAssertFalse(analyze([observation], context: .init(now: now, reviewedDomains: [item])).findings.contains { $0.ruleID == "VENDOR-KNOWN-006" })
        }
        XCTAssertTrue(analyze([observation], context: .init(now: now, reviewedDomains: [knowledge(categories: [.dataBroker])])).findings.contains { $0.ruleID == "VENDOR-KNOWN-006" })
    }

    func testConflictingClassificationFailsClosed() {
        let context = FindingContext(now: now, reviewedDomains: [knowledge(categories: [.dataBroker]), knowledge(categories: [.authentication])])
        XCTAssertNil(context.reviewedDomain("example.net"))
        XCTAssertFalse(analyze([network()], context: context).findings.contains { $0.ruleID == "VENDOR-KNOWN-006" })
    }

    func testExpiredKnowledgeIsVisibleAndReducesConfidence() throws {
        let current = try XCTUnwrap(analyze([network()], context: .init(now: now, reviewedDomains: [knowledge(categories: [.dataBroker])])).findings.first)
        let expired = try XCTUnwrap(analyze([network()], context: .init(now: now, reviewedDomains: [knowledge(categories: [.dataBroker], expiry: now.addingTimeInterval(-1))])).findings.first)
        XCTAssertFalse(current.isStale)
        XCTAssertTrue(expired.isStale)
        XCTAssertLessThan(expired.confidence, current.confidence)
        XCTAssertFalse(expired.knowledgeSources.isEmpty)
    }

    func testProtectionSuggestionRequiresActualAvailableCapability() throws {
        let record = network()
        let knowledge = knowledge(categories: [.advertising])
        XCTAssertFalse(analyze([record], context: .init(now: now, reviewedDomains: [knowledge])).findings.contains { $0.ruleID == "COVERAGE-GAP-007" })
        let available = FindingContext(now: now, reviewedDomains: [knowledge], protection: .init(urlFilterAvailable: true))
        let gap = try XCTUnwrap(analyze([record], context: available).findings.first { $0.ruleID == "COVERAGE-GAP-007" })
        XCTAssertTrue(gap.actionIDs.contains(ActionCatalog.enableURLFilter.id))
        XCTAssertFalse(gap.actionIDs.contains(ActionCatalog.enableSafari.id))
        XCTAssertTrue(gap.uncertainty.contains { $0.contains("does not prove") })
        let active = FindingContext(now: now, reviewedDomains: [knowledge], protection: .init(urlFilterAvailable: true, urlFilterActive: true))
        XCTAssertFalse(analyze([record], context: active).findings.contains { $0.ruleID == "COVERAGE-GAP-007" })
    }

    func testLocationServiceCooccurrenceNeverClaimsLocationWasSent() throws {
        let records = [sensor(), network()]
        let context = FindingContext(now: now, reviewedDomains: [knowledge(categories: [.locationIntelligence])])
        let finding = try XCTUnwrap(analyze(records, context: context).findings.first { $0.ruleID == "LOC-NET-003" })
        XCTAssertEqual(Set(finding.evidenceIDs), Set(records.map(\.id)))
        XCTAssertTrue(finding.uncertainty.contains { $0.contains("does not establish timing, causation, or transmission") })
        XCTAssertTrue(finding.actionIDs.contains(ActionCatalog.reviewLocation.id))
    }

    func testProfileChangesRelevanceRatherThanEvidenceOrConfidence() throws {
        let context = FindingContext(now: now, reviewedDomains: [knowledge(categories: [.locationIntelligence])])
        let strict = FindingContext(now: now, profile: .minimizeTracking, reviewedDomains: [knowledge(categories: [.locationIntelligence])])
        let normal = try XCTUnwrap(analyze([network()], context: context).findings.first)
        let weighted = try XCTUnwrap(analyze([network()], context: strict).findings.first)
        XCTAssertEqual(normal.id, weighted.id)
        XCTAssertEqual(normal.evidenceIDs, weighted.evidenceIDs)
        XCTAssertEqual(normal.observedFacts, weighted.observedFacts)
        XCTAssertEqual(normal.confidence, weighted.confidence)
        XCTAssertNotEqual(normal.profileRelevance, weighted.profileRelevance)
    }

    func testAnalysisIsDeterministicAcrossInputOrderAndHasOnlyCatalogActions() throws {
        let records = (1...12).map { network("example.app\($0 % 3)", "domain\($0 % 10).example") }
        let a = analyze(records)
        let b = analyze(records.reversed())
        XCTAssertEqual(a, b)
        let evidence = Set(records.map(\.id))
        for finding in a.findings {
            XCTAssertTrue(Set(finding.evidenceIDs).isSubset(of: evidence))
            XCTAssertTrue(finding.actionIDs.allSatisfy(ActionCatalog.contains))
            XCTAssertTrue(finding.actionIDs.contains(ActionCatalog.keepAsIs.id))
        }
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(FindingAnalysis.self, from: data), a)
    }

    func testNoObservationsNeverBecomePerfectSafetyGrade() {
        let analysis = analyze([], context: .init(now: now, includeOverallScore: true))
        XCTAssertNil(analysis.scores.privacyPosture)
        XCTAssertNil(analysis.scores.thirdPartyReach)
        XCTAssertNil(analysis.scores.evidenceConfidence)
    }

    func testScoreRequiresVerifiedAppRelationshipAndExplicitOverallOptIn() {
        let record = network(count: 50)
        let classified = FindingContext(now: now, reviewedDomains: [knowledge()], includeOverallScore: true)
        let unknownRelationship = analyze([record], context: classified).scores
        XCTAssertNil(unknownRelationship.thirdPartyReach)
        XCTAssertNil(unknownRelationship.privacyPosture)
        let related = knowledge(thirdPartyApps: ["example.app"])
        let defaultScores = analyze([record], context: .init(now: now, reviewedDomains: [related])).scores
        XCTAssertNotNil(defaultScores.thirdPartyReach)
        XCTAssertNil(defaultScores.privacyPosture)
        let optedIn = analyze([record], context: .init(now: now, reviewedDomains: [related], includeOverallScore: true)).scores
        XCTAssertNotNil(optedIn.privacyPosture)
        XCTAssertTrue(optedIn.explanation["privacyPosture"]!.contains("not a safety grade"))
        let unknown = knowledge(categories: [.unknown], thirdPartyApps: ["example.app"])
        let unknownPurpose = analyze([record], context: .init(now: now, reviewedDomains: [unknown], includeOverallScore: true)).scores
        XCTAssertNil(unknownPurpose.thirdPartyReach)
        XCTAssertNil(unknownPurpose.privacyPosture)
    }

    func testContactOverflowSaturatesAndNeverTurnsNegative() {
        let records = [network("app.one", "a.example", count: Int.max), network("app.two", "a.example", count: Int.max)]
        let analysis = analyze(records)
        XCTAssertEqual(sumContacts(records), Int.max)
        XCTAssertEqual(analysis.scores.repetition, 100)
        XCTAssertTrue(analysis.scores.sensorExposure.isFinite)
    }

    func testStaleImportWithoutActivityTimeDoesNotInventActivityWindow() throws {
        let old = report([network()], importedAt: now.addingTimeInterval(-20 * 86_400))
        let finding = try XCTUnwrap(VersionedFindingEngine.evaluate(report: old, context: .init(now: now)).findings.first { $0.ruleID == "FRESHNESS-008" })
        XCTAssertEqual(finding.title, "This import is 20 days old")
        XCTAssertTrue(finding.uncertainty.contains { $0.contains("actual activity window is unknown") })
    }

    func testBeginEndRecordsDoNotDoubleSensorExposure() {
        let first = sensor()
        let end = Observation(id: UUID(), bundleID: first.bundleID, category: .sensor, accessType: "location", count: 1, timestamp: now.addingTimeInterval(1), eventKind: "end")
        XCTAssertEqual(analyze([first]).scores.sensorExposure, analyze([first, end]).scores.sensorExposure)
    }

    func testLocalOverrideChangesPriorityWithoutChangingEvidenceOrInstallingBlock() throws {
        let records = (1...3).map { network("example.app\($0)") }
        let ordinary = try XCTUnwrap(analyze(records).findings.first)
        let override = DomainOverride(host: try XCTUnwrap(DomainIdentity("example.net")), disposition: .localBlockRequest)
        let changed = try XCTUnwrap(analyze(records, context: .init(now: now, domainOverrides: .init(overrides: [override]))).findings.first)
        XCTAssertEqual(changed.id, ordinary.id)
        XCTAssertEqual(changed.observedFacts, ordinary.observedFacts)
        XCTAssertEqual(changed.confidence, ordinary.confidence)
        XCTAssertEqual(changed.severity, .medium)
        XCTAssertTrue(changed.uncertainty.contains { $0.contains("does not establish harm or install an OS block") })
    }

    func testLifecycleAbsenceNeverClaimsResolved() throws {
        let records = (1...3).map { network("example.app\($0)") }
        let previous = analyze(records)
        let current = analyze([])
        let lifecycle = FindingLifecycle.compare(previous: previous, current: current)
        XCTAssertTrue(lifecycle.current.isEmpty)
        XCTAssertEqual(lifecycle.previousOnly.count, previous.findings.count)
        XCTAssertTrue(lifecycle.previousOnly.allSatisfy { $0.status == .notObservedInLatestReport })
        XCTAssertEqual(lifecycle.previousOnly.first?.observedFacts, previous.findings.first?.observedFacts)
    }

    func testLifecycleUserAcceptanceAndRecurrencePreserveFacts() throws {
        let records = (1...3).map { network("example.app\($0)") }
        let previous = analyze(records)
        let current = analyze(records)
        let recurring = FindingLifecycle.compare(previous: previous, current: current)
        XCTAssertTrue(recurring.current.allSatisfy { $0.status == .recurring })
        let first = try XCTUnwrap(previous.findings.first)
        let accepted = FindingLifecycle.compare(previous: previous, current: current, acceptedKeys: [first.lifecycleKey])
        XCTAssertEqual(accepted.current.first?.status, .accepted)
        XCTAssertEqual(accepted.current.first?.observedFacts, first.observedFacts)
        XCTAssertEqual(accepted.current.first?.confidence, first.confidence)
    }

    func testSignedBundledKnowledgeAdapterUsesCitationsAndDoesNotInferAppRelationships() throws {
        let manifestURL = try XCTUnwrap(KnowledgeBaseResources.resource("manifest", extension: "json"))
        let manifest = try JSONDecoder().decode(KnowledgeBaseManifest.self, from: Data(contentsOf: manifestURL))
        let time = Date(timeIntervalSince1970: Double(manifest.generatedAt) + 1)
        let snapshot = try KnowledgeBaseResources.loadBundled(now: time)
        let report = report([network("unrelated.example", "api.segment.io")])
        let contexts = DomainMatcher(snapshot: snapshot).findingContexts(for: report, now: time)
        let match = try XCTUnwrap(contexts.first)
        XCTAssertEqual(match.domain, "api.segment.io")
        XCTAssertTrue(match.categories.contains(.analytics))
        XCTAssertFalse(match.sourceURLs.isEmpty)
        XCTAssertTrue(match.hasReviewedSources)
        XCTAssertTrue(match.firstPartyBundleIDs.isEmpty)
        XCTAssertTrue(match.thirdPartyBundleIDs.isEmpty)
        XCTAssertEqual(match.knowledgeBaseVersion, snapshot.version)
    }
}
