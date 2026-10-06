import Foundation
import XCTest
@testable import FirePrivacyCore

final class AnalysisHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let reportID = ContentDigest.stableID("history/report")
    private let observationID = ContentDigest.stableID("history/observation")

    private func observation(id: UUID? = nil, count: Int = 4, timestampText: String? = nil,
                             classification: ReportedValue? = nil) -> Observation {
        .init(id: id ?? observationID, bundleID: "example.app", domain: "service.example",
            category: .network, accessType: "networkActivity", count: count, timestamp: now,
            timestampText: timestampText, domainClassification: classification)
    }
    private func report(id: UUID? = nil, records: [Observation]? = nil, source: String? = "source-one",
                        parser: String = "2.0.0", normalization: String = "2.0.0") -> PrivacyReport {
        let records = records ?? [observation()]
        return .init(id: id ?? reportID, importedAt: now, observations: records,
            metadata: .init(sourceSHA256: source.map { ContentDigest.sha256(Data($0.utf8)) },
                parserVersion: parser, normalizationVersion: normalization, recognizedRecords: records.count))
    }
    private func finding(id: String = "history.finding", evidenceID: UUID? = nil,
                         title: String = "Recorded service contact", category: String = "analytics",
                         isStale: Bool = false) -> RuleFinding {
        let evidence = evidenceID ?? observationID
        return .init(id: id, ruleID: "HISTORY-TEST", ruleVersion: "1.0.0", title: title,
            detail: "The export records a destination; payload contents are unknown.", subject: .domain("service.example"),
            severity: .info, confidence: 0.7,
            observedFacts: [.init(key: "contacts", value: "4", evidenceIDs: [evidence])],
            uncertainty: ["This contact does not establish harm."], evidenceIDs: [evidence],
            actionIDs: [ActionCatalog.keepAsIs.id], categoryKeys: [category], isStale: isStale)
    }
    private func analysis(for report: PrivacyReport, findings: [RuleFinding]? = nil,
                          ruleset: String = "ruleset-test-1", scoring: String = "scores-test-1") -> FindingAnalysis {
        .init(reportID: report.id, rulesetVersion: ruleset, findings: findings ?? [finding()],
            scores: .init(version: scoring, sensorExposure: 0, thirdPartyReach: nil, aggregationSignals: 0,
                repetition: 10, controlGap: 0, evidenceConfidence: 70, classificationCoverage: 0,
                privacyPosture: nil, explanation: ["unknown": "Ownership and payload are unknown."]))
    }
    private func knowledge(version: String = "1.0.0", expiry: Date? = nil,
                           category: ReviewedDomainCategory = .analytics) -> ReviewedDomainContext {
        .init(domain: "service.example", organization: "Reviewed service operator", categories: [category],
            sourceURLs: ["https://operator.example/privacy"], knowledgeBaseVersion: version,
            isVerified: true, expiresAt: expiry)
    }
    private func mutateJSON(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testRestartAndWallClockRebuildPreserveFirstSeenLifecycle() throws {
        var history = AnalysisHistory()
        let report = report(), analysis = analysis(for: report)
        let first = try history.record(report: report, analysis: analysis, context: .init(now: now))
        XCTAssertEqual(first.lifecycle.current.first?.status, .new)
        var restored = try AnalysisHistory.decode(history.encoded())
        let reopened = try restored.record(report: report, analysis: analysis,
            context: .init(now: now.addingTimeInterval(60)))
        XCTAssertEqual(reopened, first)
        XCTAssertEqual(restored.records.count, 1)
        XCTAssertEqual(reopened.evaluatedAt, now)
    }

    func testSwitchingReportsUsesTheirOwnBaseline() throws {
        var history = AnalysisHistory()
        let firstReport = report()
        let first = try history.record(report: firstReport, analysis: analysis(for: firstReport), context: .init(now: now))
        let secondReport = report(id: ContentDigest.stableID("history/second-report"))
        let second = try history.record(report: secondReport, analysis: analysis(for: secondReport), context: .init(now: now))
        XCTAssertNil(second.comparison)
        XCTAssertEqual(second.lifecycle.current.first?.status, .new)
        let selectedAgain = try history.record(report: firstReport, analysis: analysis(for: firstReport),
            context: .init(now: now.addingTimeInterval(10)))
        XCTAssertEqual(selectedAgain, first)
        XCTAssertEqual(history.records.count, 2)
    }

    func testExplicitCrossReportBaselineDoesNotManufactureActivityOnDuplicateImport() throws {
        var history = AnalysisHistory()
        let firstReport = report()
        _ = try history.record(report: firstReport, analysis: analysis(for: firstReport), context: .init(now: now))
        let secondID = ContentDigest.stableID("history/reimport")
        let secondObservation = observation(id: ContentDigest.stableID("history/reimport-observation"))
        let secondReport = report(id: secondID, records: [secondObservation])
        let revision = try history.record(report: secondReport,
            analysis: analysis(for: secondReport, findings: [finding(id: "second.finding", evidenceID: secondObservation.id)]),
            context: .init(now: now), baselineReportID: firstReport.id)
        let change = try XCTUnwrap(revision.comparison)
        XCTAssertFalse(change.normalizedEvidenceChanged)
        XCTAssertEqual(change.sourceBytesChanged, false)
        XCTAssertTrue(change.dimensions.contains(.reportIdentity))
        XCTAssertTrue(change.dimensions.contains(.evidenceReferences))
        XCTAssertEqual(revision.lifecycle.current.first?.status, .recurring)
        XCTAssertEqual(revision.lifecycle.previousOnly.first?.status, .superseded)
    }

    func testProfileContentChangeIsRecordedEvenWhenProfileIDStaysSame() throws {
        var history = AnalysisHistory()
        let report = report(), analysis = analysis(for: report)
        let profileID = ContentDigest.stableID("history/profile")
        let original = PrivacyProfile(id: profileID, name: "Personal", analyticsTolerance: 55, updatedAt: now)
        let changed = PrivacyProfile(id: profileID, name: "Personal", analyticsTolerance: 10, updatedAt: now)
        let first = try history.record(report: report, analysis: analysis, context: .init(now: now, profile: original))
        let next = try history.record(report: report, analysis: analysis, context: .init(now: now, profile: changed))
        XCTAssertEqual(next.comparison?.dimensions, [.profile])
        XCTAssertTrue(try XCTUnwrap(next.comparison).isSameEvidenceReanalysis)
        XCTAssertEqual(first.analysis.findings[0].observedFacts, next.analysis.findings[0].observedFacts)
        XCTAssertEqual(next.lifecycle.current.first?.status, .new)
    }

    func testKnowledgeContentChangeIsDetectedWithoutVersionChange() throws {
        var history = AnalysisHistory()
        let report = report(), analysis = analysis(for: report)
        _ = try history.record(report: report, analysis: analysis,
            context: .init(now: now, reviewedDomains: [knowledge()]), knowledgeBaseVersion: "1.0.0")
        let next = try history.record(report: report, analysis: analysis,
            context: .init(now: now, reviewedDomains: [knowledge(category: .contentDelivery)]), knowledgeBaseVersion: "1.0.0")
        XCTAssertEqual(next.comparison?.dimensions, [.reviewedKnowledge])
        XCTAssertFalse(try XCTUnwrap(next.comparison).normalizedEvidenceChanged)
        XCTAssertTrue(try XCTUnwrap(next.comparison).interpretationInputsChanged)
    }

    func testRuleKnowledgeAndProfileChangesAreConcurrentMetadataNotCausalFacts() throws {
        var history = AnalysisHistory()
        let report = report()
        let first = try history.record(report: report, analysis: analysis(for: report),
            context: .init(now: now), knowledgeBaseVersion: "1.0.0")
        let next = try history.record(report: report, analysis: analysis(for: report, ruleset: "ruleset-test-2"),
            context: .init(now: now, profile: .minimizeTracking), knowledgeBaseVersion: "1.1.0")
        let comparison = try XCTUnwrap(next.comparison)
        XCTAssertTrue(comparison.dimensions.contains(.rulesetVersion))
        XCTAssertTrue(comparison.dimensions.contains(.knowledgeVersion))
        XCTAssertTrue(comparison.dimensions.contains(.profile))
        XCTAssertFalse(comparison.normalizedEvidenceChanged)
        XCTAssertEqual(comparison.findings.evidenceUnchanged, true)
        XCTAssertEqual(first.analysis.findings, next.analysis.findings)
        XCTAssertTrue(comparison.limitations.contains { $0.contains("do not establish which update caused") })
        XCTAssertTrue(comparison.findings.analysisVersionsChanged)
    }

    func testUnknownSourceProvenanceIsNeverReportedAsEqualBytes() throws {
        var history = AnalysisHistory()
        let firstReport = report(source: nil)
        _ = try history.record(report: firstReport, analysis: analysis(for: firstReport), context: .init(now: now))
        let nextReport = report(source: "known-source")
        let next = try history.record(report: nextReport, analysis: analysis(for: nextReport), context: .init(now: now))
        XCTAssertNil(next.comparison?.sourceBytesChanged)
        XCTAssertFalse(try XCTUnwrap(next.comparison).normalizedEvidenceChanged)
        XCTAssertTrue(try XCTUnwrap(next.comparison).dimensions.contains(.sourceIdentity))
    }

    func testRawSourceAndParserRevisionsCanChangeWithoutNewNormalizedEvidence() throws {
        var history = AnalysisHistory()
        let firstReport = report()
        _ = try history.record(report: firstReport, analysis: analysis(for: firstReport), context: .init(now: now))
        let nextReport = report(source: "different-json-whitespace", parser: "2.1.0", normalization: "2.1.0")
        let next = try history.record(report: nextReport, analysis: analysis(for: nextReport), context: .init(now: now))
        XCTAssertEqual(next.comparison?.sourceBytesChanged, true)
        XCTAssertFalse(try XCTUnwrap(next.comparison).normalizedEvidenceChanged)
        XCTAssertTrue(try XCTUnwrap(next.comparison).dimensions.contains(.parserVersion))
        XCTAssertTrue(try XCTUnwrap(next.comparison).dimensions.contains(.normalizationVersion))
        XCTAssertEqual(next.lifecycle.current.first?.status, .new)
    }

    func testNormalizedFingerprintIgnoresLineOrderButPreservesMultiplicityAndPreciseText() throws {
        let a = observation(timestampText: "2027-01-15T08:00:00.123456789Z")
        let b = observation(id: ContentDigest.stableID("history/second-observation"), count: 9)
        let original = report(records: [a, b])
        let swapped = report(records: [b, a])
        let duplicated = report(records: [a, b, a])
        let changedPrecision = report(records: [observation(timestampText: "2027-01-15T08:00:00.123456788Z"), b])
        let first = try AnalysisInputRevision(report: original, analysis: analysis(for: original), context: .init(now: now))
        let order = try AnalysisInputRevision(report: swapped, analysis: analysis(for: swapped), context: .init(now: now))
        let duplicate = try AnalysisInputRevision(report: duplicated, analysis: analysis(for: duplicated), context: .init(now: now))
        let precision = try AnalysisInputRevision(report: changedPrecision, analysis: analysis(for: changedPrecision), context: .init(now: now))
        XCTAssertEqual(first.normalizedEvidenceSHA256, order.normalizedEvidenceSHA256)
        XCTAssertNotEqual(first.normalizedEvidenceSHA256, duplicate.normalizedEvidenceSHA256)
        XCTAssertNotEqual(first.normalizedEvidenceSHA256, precision.normalizedEvidenceSHA256)
        XCTAssertEqual(ReportComparator.compare(earlier: original, later: swapped).normalizedEvidenceChanged, false)
        XCTAssertEqual(ReportComparator.compare(earlier: original, later: duplicated).normalizedEvidenceChanged, true)
    }

    func testReportedClassificationChangeChangesEvidenceFingerprintWithoutInterpretation() throws {
        let original = report(records: [observation(classification: .integer(1))])
        let changed = report(records: [observation(classification: .integer(2))])
        let first = try AnalysisInputRevision(report: original, analysis: analysis(for: original), context: .init(now: now))
        let second = try AnalysisInputRevision(report: changed, analysis: analysis(for: changed), context: .init(now: now))
        XCTAssertNotEqual(first.normalizedEvidenceSHA256, second.normalizedEvidenceSHA256)
    }

    func testKnowledgeExpiryRecordsTimeAndOutputChangeWithoutNewExportedActivity() throws {
        var history = AnalysisHistory()
        let report = report()
        let reviewed = knowledge(expiry: now.addingTimeInterval(30), category: .dataBroker)
        let before = FindingContext(now: now, reviewedDomains: [reviewed])
        let after = FindingContext(now: now.addingTimeInterval(60), reviewedDomains: [reviewed])
        _ = try history.record(report: report, analysis: VersionedFindingEngine.evaluate(report: report, context: before), context: before)
        let next = try history.record(report: report, analysis: VersionedFindingEngine.evaluate(report: report, context: after), context: after)
        let comparison = try XCTUnwrap(next.comparison)
        XCTAssertFalse(comparison.normalizedEvidenceChanged)
        XCTAssertFalse(comparison.dimensions.contains(.reviewedKnowledge))
        XCTAssertTrue(comparison.dimensions.contains(.evaluationTime))
        XCTAssertTrue(comparison.dimensions.contains(.analysisOutput))
        XCTAssertEqual(next.lifecycle.current.first { $0.ruleID == "VENDOR-KNOWN-006" }?.status, .stale)
    }

    func testDecisionsSurviveRestartAndRemainSeparateFromRuleFacts() throws {
        var history = AnalysisHistory()
        let report = report(), analysis = analysis(for: report)
        let key = analysis.findings[0].lifecycleKey
        _ = try history.record(report: report, analysis: analysis, context: .init(now: now))
        let accepted = try history.record(report: report, analysis: analysis, context: .init(now: now), acceptedKeys: [key])
        XCTAssertEqual(accepted.lifecycle.current.first?.status, .accepted)
        XCTAssertEqual(accepted.analysis.findings.first?.status, .new)
        XCTAssertEqual(accepted.comparison?.dimensions, [.findingDecisions])
        var restored = try AnalysisHistory.decode(history.encoded())
        let reopened = try restored.record(report: report, analysis: analysis,
            context: .init(now: now.addingTimeInterval(10)), acceptedKeys: [key])
        XCTAssertEqual(reopened, accepted)
        let ignored = try restored.record(report: report, analysis: analysis, context: .init(now: now), ignoredKeys: [key])
        XCTAssertEqual(ignored.lifecycle.current.first?.status, .ignored)
    }

    func testMissingFindingDoesNotClaimActivityWasResolved() throws {
        var history = AnalysisHistory()
        let report = report()
        _ = try history.record(report: report, analysis: analysis(for: report), context: .init(now: now))
        let next = try history.record(report: report, analysis: analysis(for: report, findings: [], ruleset: "ruleset-test-2"), context: .init(now: now))
        XCTAssertEqual(next.lifecycle.previousOnly.first?.status, .notObservedInLatestReport)
        XCTAssertTrue(try XCTUnwrap(next.comparison).limitations.contains { $0.contains("does not establish that the underlying activity stopped") })
    }

    func testRecordRejectsForeignEvidenceAndReportMismatchWithoutMutatingHistory() throws {
        var history = AnalysisHistory()
        let report = report()
        let foreign = analysis(for: report, findings: [finding(evidenceID: UUID())])
        XCTAssertThrowsError(try history.record(report: report, analysis: foreign, context: .init(now: now))) {
            XCTAssertEqual($0 as? AnalysisHistoryError, .invalidEvidenceReference)
        }
        let another = self.report(id: UUID())
        XCTAssertThrowsError(try history.record(report: report, analysis: analysis(for: another), context: .init(now: now))) {
            XCTAssertEqual($0 as? AnalysisHistoryError, .reportMismatch)
        }
        XCTAssertTrue(history.records.isEmpty)
    }

    func testRollingRetentionKeepsLatestRevisionAndBoundedCount() throws {
        var history = AnalysisHistory()
        let report = report()
        for index in 0..<(AnalysisHistory.maximumRecords + 3) {
            _ = try history.record(report: report, analysis: analysis(for: report, ruleset: "ruleset-\(index)"), context: .init(now: now))
        }
        XCTAssertEqual(history.records.count, AnalysisHistory.maximumRecords)
        XCTAssertEqual(history.records.first?.analysis.rulesetVersion, "ruleset-3")
        XCTAssertEqual(history.latest(for: reportID)?.analysis.rulesetVersion, "ruleset-26")
        XCTAssertEqual(try AnalysisHistory.decode(history.encoded()), history)
    }

    func testDeletionPurgesCrossReportBaselineFactsAndRemapsSurvivingChain() throws {
        var history = AnalysisHistory()
        let deletedReport = report(id: ContentDigest.stableID("history/delete-me"))
        let deletedFinding = RuleFinding(id: "secret-old-finding", ruleID: "SECRET-OLD-RULE", ruleVersion: "1",
            title: "Secret old report fact", detail: "Secret old context", subject: .app("secret.deleted.app"),
            severity: .info, confidence: 1, observedFacts: [], uncertainty: [], evidenceIDs: [], actionIDs: [])
        _ = try history.record(report: deletedReport, analysis: analysis(for: deletedReport, findings: [deletedFinding]), context: .init(now: now))
        let retainedReport = report()
        let first = try history.record(report: retainedReport, analysis: analysis(for: retainedReport), context: .init(now: now), baselineReportID: deletedReport.id)
        XCTAssertEqual(first.lifecycle.previousOnly.first?.id, deletedFinding.id)
        _ = try history.record(report: retainedReport, analysis: analysis(for: retainedReport, ruleset: "ruleset-test-2"), context: .init(now: now))
        history.retain(reportIDs: [retainedReport.id])
        XCTAssertEqual(history.records.count, 2)
        XCTAssertNil(history.records[0].comparison)
        XCTAssertTrue(history.records[0].lifecycle.previousOnly.isEmpty)
        XCTAssertEqual(history.records[1].priorRecordID, history.records[0].id)
        let serialized = String(decoding: try history.encoded(), as: UTF8.self)
        XCTAssertFalse(serialized.contains("secret.deleted.app"))
        XCTAssertFalse(serialized.contains("SECRET-OLD-RULE"))
        XCTAssertFalse(serialized.contains(deletedReport.id.uuidString))
        XCTAssertEqual(try AnalysisHistory.decode(history.encoded()), history)
        history.remove(reportID: retainedReport.id)
        XCTAssertTrue(history.records.isEmpty)
    }

    func testDeletedCrossReportBaselineCannotLeaveInheritedRecurringStatus() throws {
        var history = AnalysisHistory()
        let deleted = report(id: ContentDigest.stableID("history/deleted-recurring-baseline"))
        _ = try history.record(report: deleted, analysis: analysis(for: deleted), context: .init(now: now))
        let retained = report()
        let first = try history.record(report: retained, analysis: analysis(for: retained),
            context: .init(now: now), baselineReportID: deleted.id)
        XCTAssertEqual(first.lifecycle.current.first?.status, .recurring)
        _ = try history.record(report: retained, analysis: analysis(for: retained, ruleset: "ruleset-test-2"), context: .init(now: now))
        let changedEvidence = report(records: [observation(count: 9)])
        _ = try history.record(report: changedEvidence, analysis: analysis(for: changedEvidence, ruleset: "ruleset-test-3"), context: .init(now: now))
        history.remove(reportID: deleted.id)
        XCTAssertEqual(history.records[0].lifecycle.current.first?.status, .new)
        XCTAssertEqual(history.records[1].lifecycle.current.first?.status, .new,
            "An interpretation of unchanged evidence must not inherit a deleted baseline's recurrence.")
        XCTAssertEqual(history.records[2].lifecycle.current.first?.status, .recurring,
            "Changed evidence still has a surviving same-report baseline.")
        XCTAssertEqual(try AnalysisHistory.decode(history.encoded()), history)
    }

    func testBaselinePruningPreservesExplicitDecisionsAndStaleStatus() throws {
        var history = AnalysisHistory()
        let deleted = report(id: ContentDigest.stableID("history/deleted-decision-baseline"))
        _ = try history.record(report: deleted, analysis: analysis(for: deleted), context: .init(now: now))
        let retained = report()
        let key = finding().lifecycleKey
        _ = try history.record(report: retained, analysis: analysis(for: retained), context: .init(now: now),
            acceptedKeys: [key], baselineReportID: deleted.id)
        let ignored = report(id: ContentDigest.stableID("history/ignored-retained"))
        _ = try history.record(report: ignored, analysis: analysis(for: ignored), context: .init(now: now),
            ignoredKeys: [key], baselineReportID: deleted.id)
        let stale = report(id: ContentDigest.stableID("history/stale-retained"))
        _ = try history.record(report: stale, analysis: analysis(for: stale, findings: [finding(isStale: true)]),
            context: .init(now: now), baselineReportID: deleted.id)
        history.remove(reportID: deleted.id)
        XCTAssertEqual(history.latest(for: retained.id)?.lifecycle.current.first?.status, .accepted)
        XCTAssertEqual(history.latest(for: ignored.id)?.lifecycle.current.first?.status, .ignored)
        XCTAssertEqual(history.latest(for: stale.id)?.lifecycle.current.first?.status, .stale)
        XCTAssertEqual(try AnalysisHistory.decode(history.encoded()), history)
    }

    func testOversizedRecordFailsAtomicallyAndOversizedDecodeIsRejectedBeforeParsing() throws {
        var history = AnalysisHistory()
        let report = report()
        let first = try history.record(report: report, analysis: analysis(for: report), context: .init(now: now))
        let huge = analysis(for: report, findings: [finding(title: String(repeating: "x", count: AnalysisHistory.maximumRecordBytes))])
        XCTAssertThrowsError(try history.record(report: report, analysis: huge, context: .init(now: now))) {
            XCTAssertEqual($0 as? AnalysisHistoryError, .oversizedRecord)
        }
        XCTAssertEqual(history.records, [first])
        XCTAssertThrowsError(try AnalysisHistory.decode(Data(repeating: 0, count: AnalysisHistory.maximumEncodedBytes + 1))) {
            XCTAssertEqual($0 as? AnalysisHistoryError, .oversizedHistory)
        }
    }

    func testDecodeRejectsUnsupportedSchemaDuplicateRecordsAndModifiedFacts() throws {
        var history = AnalysisHistory()
        let report = report()
        _ = try history.record(report: report, analysis: analysis(for: report), context: .init(now: now))
        let bytes = try history.encoded()
        let schema = try mutateJSON(bytes) { $0["version"] = 99 }
        XCTAssertThrowsError(try AnalysisHistory.decode(schema)) { XCTAssertEqual($0 as? AnalysisHistoryError, .unsupportedSchema) }
        let duplicate = try mutateJSON(bytes) { object in
            let records = object["records"] as! [[String: Any]]
            object["records"] = records + records
        }
        XCTAssertThrowsError(try AnalysisHistory.decode(duplicate)) { XCTAssertEqual($0 as? AnalysisHistoryError, .invalidRecord) }
        let tampered = try mutateJSON(bytes) { object in
            var records = object["records"] as! [[String: Any]]
            var analysis = records[0]["analysis"] as! [String: Any]
            var findings = analysis["findings"] as! [[String: Any]]
            findings[0]["detail"] = "Unverified new fact"
            analysis["findings"] = findings
            records[0]["analysis"] = analysis
            object["records"] = records
        }
        XCTAssertThrowsError(try AnalysisHistory.decode(tampered)) { XCTAssertEqual($0 as? AnalysisHistoryError, .invalidRecord) }
    }

    func testDecodeRejectsUndeclaredAcceptedStatus() throws {
        var history = AnalysisHistory()
        let report = report()
        _ = try history.record(report: report, analysis: analysis(for: report), context: .init(now: now))
        let bytes = try mutateJSON(history.encoded()) { object in
            var records = object["records"] as! [[String: Any]]
            var lifecycle = records[0]["lifecycle"] as! [String: Any]
            var current = lifecycle["current"] as! [[String: Any]]
            current[0]["status"] = "accepted"
            lifecycle["current"] = current
            records[0]["lifecycle"] = lifecycle
            object["records"] = records
        }
        XCTAssertThrowsError(try AnalysisHistory.decode(bytes)) { XCTAssertEqual($0 as? AnalysisHistoryError, .invalidRecord) }
    }

    func testRecordIdentityCommitsPreviousOnlyFactsComparisonAndEvaluationTime() throws {
        var history = AnalysisHistory()
        let report = report()
        _ = try history.record(report: report, analysis: analysis(for: report), context: .init(now: now))
        _ = try history.record(report: report, analysis: analysis(for: report, findings: [], ruleset: "ruleset-test-2"), context: .init(now: now))
        let bytes = try history.encoded()
        let changedPreviousFact = try mutateJSON(bytes) { object in
            var records = object["records"] as! [[String: Any]]
            var lifecycle = records[1]["lifecycle"] as! [String: Any]
            var previousOnly = lifecycle["previousOnly"] as! [[String: Any]]
            previousOnly[0]["detail"] = "An invented previous report claim"
            lifecycle["previousOnly"] = previousOnly
            records[1]["lifecycle"] = lifecycle
            object["records"] = records
        }
        XCTAssertThrowsError(try AnalysisHistory.decode(changedPreviousFact)) { XCTAssertEqual($0 as? AnalysisHistoryError, .invalidRecord) }
        let changedAttribution = try mutateJSON(bytes) { object in
            var records = object["records"] as! [[String: Any]]
            var comparison = records[1]["comparison"] as! [String: Any]
            comparison["sourceBytesChanged"] = true
            records[1]["comparison"] = comparison
            object["records"] = records
        }
        XCTAssertThrowsError(try AnalysisHistory.decode(changedAttribution)) { XCTAssertEqual($0 as? AnalysisHistoryError, .invalidRecord) }
        let changedTime = try mutateJSON(bytes) { object in
            var records = object["records"] as! [[String: Any]]
            records[1]["evaluatedAt"] = 10
            object["records"] = records
        }
        XCTAssertThrowsError(try AnalysisHistory.decode(changedTime)) { XCTAssertEqual($0 as? AnalysisHistoryError, .invalidRecord) }
    }
}
