import Foundation
import XCTest
@testable import FirePrivacyCore

final class AppUsageTimelineTests: XCTestCase {
    func testCompleteSameDeviceClaimComparesRealNetworkAndSensorTimestamps() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z"), sensor(time: "2026-10-01T09:00:00Z")])
        let comparison = try analyze(report, windows: [range("10:00:00", "11:00:00")])
        let app = try XCTUnwrap(comparison.apps.first)
        XCTAssertEqual(app.outsideClaimedWindowActivities, 2)
        XCTAssertTrue(app.activities.allSatisfy { $0.reviewSuggested && $0.alignment == .outsideClaimedWindows })
        XCTAssertEqual(Set(app.activities.flatMap(\.evidenceIDs)), Set(report.observations.map(\.id)))
        XCTAssertEqual(app.networkContactCount, 17)
        XCTAssertEqual(app.sensorEventRecords, 1)
        XCTAssertTrue(app.activities.allSatisfy { !$0.sourceAssessments[0].independentlyVerified })
    }
    func testBoundariesAreClosedAndNanosecondAfterWindowIsOutside() throws {
        let window = try range("10:00:00.000000001", "11:00:00.000000001")
        let report = try parse([network(time: "2026-10-01T10:00:00.000000001Z"),
                                network(domain: "end.example", time: "2026-10-01T11:00:00.000000001Z"),
                                network(domain: "after.example", time: "2026-10-01T11:00:00.000000002Z")])
        let app = try XCTUnwrap(analyze(report, windows: [window]).apps.first)
        XCTAssertEqual(app.outsideClaimedWindowActivities, 1)
        XCTAssertEqual(app.activities.first(where: { $0.domain == "after.example" })?.alignment, .outsideClaimedWindows)
        XCTAssertEqual(app.activities.filter { $0.alignment == .overlapsSuppliedWindows }.count, 2)
    }
    func testNetworkBoundsPreserveHitsWithoutDistributingThemAcrossTime() throws {
        let report = try parse([network(first: "2026-10-01T09:00:00Z", last: "2026-10-01T10:30:00Z", hits: 900)])
        let row = try XCTUnwrap(analyze(report, windows: [range("10:00:00", "11:00:00")]).apps.first?.activities.first)
        XCTAssertEqual(row.precision, .networkBounds)
        XCTAssertEqual(row.alignment, .mixedReportedTimestamps)
        XCTAssertEqual(row.reportedContactCount, 900)
        XCTAssertEqual(row.timestampEvidence.count, 2)
        XCTAssertEqual(row.evidenceIDs, [report.observations[0].id])
        XCTAssertTrue(row.limitations.contains { $0.contains("intermediate hits are not located") })
    }
    func testEndpointsInsideDoNotInventContactsInAnUncoveredMiddleGap() throws {
        let report = try parse([network(first: "2026-10-01T10:05:00Z", last: "2026-10-01T11:55:00Z")])
        let row = try XCTUnwrap(analyze(report, windows: [range("10:00:00", "10:10:00"), range("11:50:00", "12:00:00")]).apps.first?.activities.first)
        XCTAssertEqual(row.alignment, .overlapsSuppliedWindows)
        XCTAssertFalse(row.reviewSuggested)
        XCTAssertEqual(row.reportedContactCount, 17)
    }
    func testMissingAndIncompleteTimestampsRemainDistinct() throws {
        let report = try parse([network(domain: "untimed.example"), network(domain: "first.example", first: "2026-10-01T09:00:00Z")])
        let rows = try analyze(report, windows: [range("10:00:00", "11:00:00")]).apps[0].activities
        XCTAssertEqual(rows.first { $0.domain == "untimed.example" }?.alignment, .unknown)
        XCTAssertNil(rows.first { $0.domain == "untimed.example" }?.start)
        let first = try XCTUnwrap(rows.first { $0.domain == "first.example" })
        XCTAssertEqual(first.precision, .incompleteTimestamp)
        XCTAssertEqual(first.timestampEvidence[0].role, .firstContact)
        XCTAssertEqual(first.reportedTimestampAlignment, .outsideClaimedWindows)
        XCTAssertNil(first.end)
    }
    func testSensorPairUsesBothRealEventsAndDoesNotDoubleCountSessions() throws {
        let report = try parse([sensor(time: "2026-10-01T09:00:00Z", kind: "intervalBegin"), sensor(time: "2026-10-01T10:30:00Z", kind: "intervalEnd")])
        let row = try XCTUnwrap(analyze(report, windows: [range("10:00:00", "11:00:00")]).apps[0].activities.first)
        XCTAssertEqual(row.precision, .sensorMatchedInterval)
        XCTAssertEqual(row.evidenceIDs.count, 2)
        XCTAssertEqual(row.sensorEventRecordCount, 2)
        XCTAssertNil(row.reportedContactCount)
        XCTAssertEqual(row.alignment, .mixedReportedTimestamps)
    }
    func testUnpairedAndAmbiguousSensorRecordsDoNotInventEnds() throws {
        let report = try parse([sensor(time: "2026-10-01T09:00:00Z", kind: "intervalBegin"),
                                sensor(time: "2026-10-01T09:01:00Z", kind: "intervalBegin"),
                                sensor(time: "2026-10-01T09:02:00Z", kind: "intervalEnd")])
        let rows = try analyze(report, windows: [range("10:00:00", "11:00:00")]).apps[0].activities
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.precision == .incompleteSensorInterval && $0.alignment == .unknown && $0.end == nil })
        XCTAssertTrue(rows.allSatisfy { $0.reportedTimestampAlignment == .outsideClaimedWindows && $0.reviewSuggested })
    }
    func testIncompleteClaimsAndOutsideCoverageCannotProveUnusedTimes() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z"), network(domain: "outside-coverage.example", time: "2026-10-02T09:00:00Z")])
        let partial = try analyze(report, windows: [range("10:00:00", "11:00:00")], complete: false)
        XCTAssertTrue(partial.apps[0].activities.allSatisfy { $0.alignment == .unknown && !$0.reviewSuggested })
        let complete = try analyze(report, windows: [range("10:00:00", "11:00:00")])
        XCTAssertEqual(complete.apps[0].activities.first { $0.domain == "outside-coverage.example" }?.alignment, .unknown)
    }
    func testPositiveAggregateDoesNotCreateWindowsEvenWhenDurationEqualsCoverage() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z")])
        for total in [Double(60), 86_399] {
            let row = try XCTUnwrap(analyze(report, total: total).apps[0].activities.first)
            XCTAssertEqual(row.alignment, .unknown)
            XCTAssertFalse(row.reviewSuggested)
            XCTAssertEqual(row.sourceAssessments[0].aggregateForegroundSeconds, total)
        }
    }
    func testZeroAggregateSuggestsReviewOnlyForRealTimestampWithinCoverage() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z"), sensor(time: "2026-10-01T09:01:00Z"),
                                network(domain: "untimed.example"), network(domain: "outside.example", time: "2026-10-02T09:00:00Z"),
                                network(domain: "zero-hits.example", time: "2026-10-01T09:00:00Z", hits: 0)])
        let app = try analyze(report, total: 0).apps[0]
        XCTAssertEqual(app.zeroReportedUsageActivities, 2)
        XCTAssertEqual(app.outsideClaimedWindowActivities, 0)
        XCTAssertEqual(app.activities.filter(\.reviewSuggested).count, 2)
        XCTAssertTrue(app.activities.filter(\.reviewSuggested).allSatisfy { $0.alignment == .activityDuringZeroReportedForegroundUsage })
        XCTAssertEqual(app.activities.first { $0.domain == "zero-hits.example" }?.alignment, .unknown)
    }
    func testOtherOrUnspecifiedDeviceScopesYieldNoReviewSignals() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z")])
        for scope in [AppUsageDeviceScope.unspecified, .otherDeviceOrCombined] {
            for total in [Double?.none, Double?.some(0)] {
                let reference = try makeReference(windows: [], complete: total == nil, total: total, scope: scope)
                let result = AppUsageTimelineAnalyzer.analyze(report: report, timeline: try AppUsageTimeline(references: [reference]).bindingClaims(to: report.id))
                XCTAssertFalse(result.apps[0].activities[0].reviewSuggested)
                XCTAssertEqual(result.apps[0].activities[0].alignment, .unknown)
            }
        }
    }
    func testEquivalentOffsetTimeZonesAndOverlappingWindowsCompareSameInstant() throws {
        let report = try parse([network(time: "2026-10-01T09:30:00Z")])
        let first = try UsageTimeRange(startTimestampText: "2026-10-01T11:00:00+02:00", endTimestampText: "2026-10-01T12:00:00+02:00")
        let second = try range("09:20:00", "09:40:00")
        let row = try analyze(report, windows: [first, second]).apps[0].activities[0]
        XCTAssertEqual(row.alignment, .overlapsSuppliedWindows)
        XCTAssertFalse(row.reviewSuggested)
    }
    func testConflictingSourcesDisagreeAtSameTimestampAndRetainBothProvenances() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z")])
        let first = try makeReference(windows: [range("10:00:00", "11:00:00")])
        let second = try makeReference(windows: [range("08:30:00", "09:30:00")], provenance: .userTranscribedSystemUsage)
        let timeline = try AppUsageTimeline(references: [first, second]).bindingClaims(to: report.id)
        let row = AppUsageTimelineAnalyzer.analyze(report: report, timeline: timeline).apps[0].activities[0]
        XCTAssertEqual(row.alignment, .conflictingReferences)
        XCTAssertEqual(Set(row.sourceAssessments.map(\.provenance)), Set([.userRecollection, .userTranscribedSystemUsage]))
    }
    func testDifferentCoverageAtDifferentEndpointsIsNotAFalseConflict() throws {
        let report = try parse([network(first: "2026-10-01T09:00:00Z", last: "2026-10-01T10:30:00Z")])
        let first = try makeReference(windows: [range("10:00:00", "11:00:00")])
        let second = try AppUsageReference(bundleID: "example.app", provenance: .importedUsageLog,
            coverage: range("10:00:00", "11:00:00"), claimsCompleteForegroundWindows: true,
            foregroundWindows: [range("10:00:00", "11:00:00")], deviceScope: .sameDeviceAsReport)
        let result = AppUsageTimelineAnalyzer.analyze(report: report, timeline: try AppUsageTimeline(references: [first, second]).bindingClaims(to: report.id))
        XCTAssertEqual(result.apps[0].activities[0].alignment, .mixedReportedTimestamps)
    }
    func testRawAPRContextNeverBecomesVerifiedForegroundOrBackgroundClassification() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z", context: "foreground")])
        let row = try analyze(report, windows: []).apps[0].activities[0]
        XCTAssertEqual(row.rawAPRContexts, ["foreground"])
        XCTAssertEqual(row.alignment, .outsideClaimedWindows)
        XCTAssertTrue(row.sourceAssessments[0].limitations.contains { $0.contains("unverified") })
    }
    func testBundleIDsDoNotBorrowUsageFromAnotherApp() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z")])
        let reference = try AppUsageReference(bundleID: "different.app", provenance: .userRecollection, coverage: range("00:00:00", "23:59:59"),
            claimsCompleteForegroundWindows: true, deviceScope: .sameDeviceAsReport)
        let comparison = AppUsageTimelineAnalyzer.analyze(report: report, timeline: try AppUsageTimeline(references: [reference]).bindingClaims(to: report.id))
        XCTAssertTrue(comparison.apps[0].activities[0].sourceAssessments.isEmpty)
        XCTAssertEqual(comparison.apps[0].activities[0].alignment, .unknown)
    }
    func testLimitsAreExplicitAndComparisonDeterministicWhenInputOrderChanges() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z"), network(domain: "second.example", time: "2026-10-01T09:00:00Z")])
        let a = try makeReference(windows: []), b = try makeReference(windows: [], provenance: .importedUsageLog)
        let first = AppUsageTimelineAnalyzer.analyze(report: report, timeline: try AppUsageTimeline(references: [a, b]).bindingClaims(to: report.id), maximumActivities: 1)
        let reverse = PrivacyReport(id: report.id, importedAt: report.importedAt, observations: report.observations.reversed(), metadata: report.metadata)
        let second = AppUsageTimelineAnalyzer.analyze(report: reverse, timeline: try AppUsageTimeline(references: [b, a]).bindingClaims(to: report.id), maximumActivities: 1)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.reachedLimit)
        XCTAssertEqual(first.omittedActivityCount, 1)
    }
    func testCodableValidationRejectsImpossibleOrMixedReferences() throws {
        XCTAssertThrowsError(try UsageTimeRange(startTimestampText: "2026-10-01T09:00:00", endTimestampText: "2026-10-01T10:00:00Z"))
        XCTAssertThrowsError(try range("11:00:00", "10:00:00"))
        XCTAssertThrowsError(try makeReference(windows: [range("10:00:00", "11:00:00")], total: 0))
        XCTAssertThrowsError(try makeReference(windows: [], total: .infinity))
        XCTAssertThrowsError(try makeReference(windows: [], total: 90_000))
        let reference = try makeReference(windows: [])
        XCTAssertThrowsError(try AppUsageTimeline(references: [reference, reference]))
        let valid = try AppUsageTimeline(references: [reference])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(AppUsageTimeline.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(try JSONDecoder().decode(AppUsageTimeline.self, from: JSONEncoder().encode(valid)), valid)
    }
    func testJSONImporterIsStrictBoundedAndDeterministic() throws {
        let data = Data(jsonReference().utf8)
        let first = try AppUsageTimelineImporter.parse(data, suppliedAt: Date(timeIntervalSince1970: 1))
        let second = try AppUsageTimelineImporter.parse(data, suppliedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(first.references[0].id, second.references[0].id)
        XCTAssertEqual(try first.merging(second).references.count, 1)
        XCTAssertEqual(first.references[0].provenance, .importedUsageLog)
        XCTAssertEqual(first.references[0].deviceScope, .sameDeviceAsReport)
        for invalid in [jsonReference().replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
                        jsonReference().replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                        jsonReference().replacingOccurrences(of: "\"claimsCompleteForegroundWindows\":true", with: "\"claimsCompleteForegroundWindows\":1"),
                        jsonReference().replacingOccurrences(of: "\"importedUsageLog\"", with: "\"verifiedAppleTelemetry\""),
                        jsonReference().replacingOccurrences(of: "\"coverage\":", with: "\"unexpected\":1,\"coverage\":"),
                        jsonReference().replacingOccurrences(of: "10:00:00Z", with: "10:00:00"),
                        jsonReference().replacingOccurrences(of: "2026-10-01T10:00:00Z", with: "2026-02-30T10:00:00Z")] {
            XCTAssertThrowsError(try AppUsageTimelineImporter.parse(Data(invalid.utf8)))
        }
        XCTAssertThrowsError(try AppUsageTimelineImporter.parse(Data(repeating: 32, count: AppUsageTimelineImporter.maximumFileBytes + 1)))
    }
    func testTimelineMergeDoesNotSilentlyReplaceDifferentClaimsWithSameID() throws {
        let first = try makeReference(windows: [])
        let changed = try AppUsageReference(id: first.id, bundleID: first.bundleID, provenance: first.provenance, coverage: first.coverage,
            foregroundWindows: [range("10:00:00", "11:00:00")], deviceScope: .sameDeviceAsReport)
        XCTAssertThrowsError(try AppUsageTimeline(references: [first]).merging(AppUsageTimeline(references: [changed])))
    }
    func testSameDeviceClaimCannotSilentlyTransferToDifferentReport() throws {
        let a = try parse([network(time: "2026-10-01T09:00:00Z")])
        let b = try parse([network(time: "2026-10-01T09:01:00Z")])
        let unbound = try AppUsageTimeline(references: [makeReference(windows: [])])
        XCTAssertFalse(AppUsageTimelineAnalyzer.analyze(report: a, timeline: unbound).apps[0].activities[0].reviewSuggested)
        let bound = try unbound.bindingClaims(to: a.id)
        XCTAssertTrue(AppUsageTimelineAnalyzer.analyze(report: a, timeline: bound).apps[0].activities[0].reviewSuggested)
        let differentReport = AppUsageTimelineAnalyzer.analyze(report: b, timeline: bound)
        XCTAssertEqual(differentReport.apps[0].activities[0].alignment, .unknown)
        XCTAssertFalse(differentReport.apps[0].activities[0].reviewSuggested)
        XCTAssertEqual(try bound.bindingClaims(to: b.id).references[0].comparisonReportID, a.id)
    }

    func testDistinctRawTimeStampIsNotLostWhenModelPrefersLastTimeStamp() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z", first: "2026-10-01T10:00:00Z", last: "2026-10-01T10:30:00Z")])
        let row = try analyze(report, windows: [range("10:00:00", "11:00:00")]).apps[0].activities[0]
        XCTAssertEqual(row.timestampEvidence.count, 3)
        XCTAssertEqual(row.timestampEvidence.first { $0.role == .event }?.timestampText, "2026-10-01T09:00:00Z")
        XCTAssertEqual(row.alignment, .mixedReportedTimestamps)
        XCTAssertTrue(row.reviewSuggested)
    }

    func testPositiveOrNegativeJSONUnderflowCannotBecomeZeroUsageClaim() throws {
        let template = #"{"schemaVersion":1,"references":[{"bundleID":"example.app","provenance":"userTranscribedSystemUsage","coverage":{"start":"2026-10-01T00:00:00Z","end":"2026-10-01T23:59:59Z"},"claimsCompleteForegroundWindows":false,"foregroundWindows":[],"aggregateForegroundSeconds":VALUE}]}"#
        for value in ["1e-400", "-1e-400", "0.00001e-999"] {
            XCTAssertThrowsError(try AppUsageTimelineImporter.parse(Data(template.replacingOccurrences(of: "VALUE", with: value).utf8)))
        }
        let zero = try AppUsageTimelineImporter.parse(Data(template.replacingOccurrences(of: "VALUE", with: "0e-400").utf8))
        XCTAssertEqual(zero.references[0].aggregateForegroundSeconds, 0)
    }

    func testSingleNetworkTimestampDoesNotLocateAllReportedHits() throws {
        let report = try parse([network(time: "2026-10-01T09:00:00Z", hits: 999)])
        let row = try analyze(report, windows: []).apps[0].activities[0]
        XCTAssertEqual(row.reportedContactCount, 999)
        XCTAssertEqual(row.timestampEvidence.count, 1)
        XCTAssertTrue(row.limitations.contains { $0.contains("do not locate every reported hit") })
    }

    private func range(_ start: String, _ end: String) throws -> UsageTimeRange {
        try UsageTimeRange(startTimestampText: "2026-10-01T\(start)Z", endTimestampText: "2026-10-01T\(end)Z")
    }
    private func makeReference(windows: [UsageTimeRange], complete: Bool = true, total: Double? = nil,
                               scope: AppUsageDeviceScope = .sameDeviceAsReport, provenance: AppUsageProvenance = .userRecollection) throws -> AppUsageReference {
        try AppUsageReference(bundleID: "example.app", provenance: provenance, coverage: range("00:00:00", "23:59:59"),
            claimsCompleteForegroundWindows: total == nil ? complete : false, foregroundWindows: windows,
            aggregateForegroundSeconds: total, suppliedAt: Date(timeIntervalSince1970: 1), deviceScope: scope)
    }
    private func analyze(_ report: PrivacyReport, windows: [UsageTimeRange] = [], complete: Bool = true, total: Double? = nil) throws -> AppUsageTimelineComparison {
        AppUsageTimelineAnalyzer.analyze(report: report, timeline: try AppUsageTimeline(references: [makeReference(windows: windows, complete: complete, total: total)]).bindingClaims(to: report.id))
    }
    private func parse(_ lines: [[String: Any]]) throws -> PrivacyReport {
        let bytes = try lines.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        var data = Data(); for line in bytes { data.append(line); data.append(10) }
        return try ReportImporter.parse(data)
    }
    private func network(domain: String = "contact.example", time: String? = nil, first: String? = nil, last: String? = nil, hits: Int = 17, context: String? = nil) -> [String: Any] {
        var record: [String: Any] = ["type": "networkActivity", "bundleID": "example.app", "domain": domain, "hits": hits]
        record["timeStamp"] = time; record["firstTimeStamp"] = first; record["lastTimeStamp"] = last; record["context"] = context
        return record
    }
    private func sensor(time: String, kind: String = "instant", identifier: String = "session1") -> [String: Any] {
        ["type": "access", "accessor": ["identifier": "example.app"], "category": "camera", "identifier": identifier, "kind": kind, "timeStamp": time]
    }
    private func jsonReference() -> String {
        #"{"schemaVersion":1,"references":[{"bundleID":"example.app","provenance":"importedUsageLog","deviceScope":"sameDeviceAsReport","coverage":{"start":"2026-10-01T00:00:00Z","end":"2026-10-01T23:59:59Z"},"claimsCompleteForegroundWindows":true,"foregroundWindows":[{"start":"2026-10-01T10:00:00Z","end":"2026-10-01T11:00:00Z"}]}]}"#
    }
}

final class AppUsageEventLogTests: XCTestCase {
    func testPairedUserLogCreatesOnlyObservedWindowAndSupportsAPRComparison() throws {
        let data = log([event("opened", "09:00:00"), event("closed", "09:20:00")])
        let result = try AppUsageEventLogImporter.parse(data, suppliedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(result.pairedWindows, 1)
        XCTAssertEqual(result.importedEventRecords, 2)
        XCTAssertEqual(result.sourceSHA256, ContentDigest.sha256(data))
        XCTAssertTrue(result.warnings.isEmpty)
        let reference = try XCTUnwrap(result.timeline.references.first)
        XCTAssertEqual(reference.provenance, .importedUsageLog)
        XCTAssertTrue(reference.claimsCompleteForegroundWindows)
        XCTAssertFalse(reference.independentlyVerified)
        XCTAssertNil(reference.comparisonReportID)
        let apr = try ReportImporter.parse(Data(#"{"type":"networkActivity","bundleID":"example.app","domain":"contact.example","hits":13,"timeStamp":"2026-10-01T10:00:00Z"}"#.utf8))
        let comparison = AppUsageTimelineAnalyzer.analyze(report: apr, timeline: try result.timeline.bindingClaims(to: apr.id))
        XCTAssertTrue(comparison.apps[0].activities[0].reviewSuggested)
        XCTAssertEqual(comparison.apps[0].activities[0].reportedContactCount, 13)
        XCTAssertEqual(result.timeline.references[0].id, try AppUsageEventLogImporter.parse(data).timeline.references[0].id)
    }
    func testUnmatchedOpenedAndClosedNeverInventBoundaryOrCompleteness() throws {
        for events in [[event("opened", "09:00:00")], [event("closed", "09:20:00")]] {
            let result = try AppUsageEventLogImporter.parse(log(events))
            XCTAssertEqual(result.pairedWindows, 0)
            XCTAssertFalse(result.timeline.references[0].claimsCompleteForegroundWindows)
            XCTAssertTrue(result.timeline.references[0].foregroundWindows.isEmpty)
            XCTAssertTrue(result.warnings.contains { $0.code == .unmatchedOpened || $0.code == .unmatchedClosed })
        }
    }
    func testDuplicateOpenedClearsAmbiguousPairAndAllowsLaterUnambiguousPair() throws {
        let result = try AppUsageEventLogImporter.parse(log([event("opened", "09:00:00"), event("opened", "09:01:00"), event("closed", "09:20:00"), event("opened", "10:00:00"), event("closed", "10:20:00")]))
        XCTAssertEqual(result.pairedWindows, 1)
        XCTAssertEqual(result.timeline.references[0].foregroundWindows[0].startTimestampText, "2026-10-01T10:00:00Z")
        XCTAssertFalse(result.timeline.references[0].claimsCompleteForegroundWindows)
        XCTAssertTrue(result.warnings.contains { $0.code == .duplicateOpened })
        XCTAssertTrue(result.warnings.contains { $0.code == .unmatchedClosed })
    }
    func testOutOfOrderNanosecondEventInvalidatesPairWithoutDateRoundingError() throws {
        let result = try AppUsageEventLogImporter.parse(log([event("opened", "09:00:00.000000002"), event("closed", "09:00:00.000000001")]))
        XCTAssertEqual(result.pairedWindows, 0)
        XCTAssertFalse(result.timeline.references[0].claimsCompleteForegroundWindows)
        XCTAssertTrue(result.warnings.contains { $0.code == .outOfOrder })
    }
    func testUnattributableMalformedRecordInvalidatesAllClaimsAndPendingPairs() throws {
        let first = event("opened", "09:00:00"), second = event("closed", "09:20:00")
        let other = event("opened", "10:00:00", app: "second.app"), otherEnd = event("closed", "10:20:00", app: "second.app")
        let result = try AppUsageEventLogImporter.parse(log([first, "{broken sensitive input}", second, other, otherEnd]))
        XCTAssertEqual(result.pairedWindows, 1)
        XCTAssertTrue(result.timeline.references.allSatisfy { !$0.claimsCompleteForegroundWindows })
        XCTAssertTrue(result.warnings.contains { $0.code == .invalidRecord && $0.bundleID == nil })
        XCTAssertFalse(String(describing: result.warnings).contains("sensitive input"))
    }
    func testAttributedMalformedRecordDowngradesOnlyItsApp() throws {
        let invalid = #"{"bundleID":"example.app","event":"opened","timestamp":"not-a-time"}"#
        let result = try AppUsageEventLogImporter.parse(log([invalid, event("opened", "09:00:00", app: "second.app"), event("closed", "09:20:00", app: "second.app")]))
        XCTAssertFalse(try XCTUnwrap(result.timeline.references.first { $0.bundleID == "example.app" }).claimsCompleteForegroundWindows)
        XCTAssertTrue(try XCTUnwrap(result.timeline.references.first { $0.bundleID == "second.app" }).claimsCompleteForegroundWindows)
    }
    func testOutsideCoverageEventsAreNotClippedIntoInventedSessions() throws {
        let outside = #"{"bundleID":"example.app","event":"opened","timestamp":"2026-09-30T23:59:00Z"}"#
        let result = try AppUsageEventLogImporter.parse(log([outside, event("closed", "09:20:00")]))
        XCTAssertEqual(result.pairedWindows, 0)
        XCTAssertFalse(result.timeline.references[0].claimsCompleteForegroundWindows)
        XCTAssertTrue(result.warnings.contains { $0.code == .outsideCoverage })
    }
    func testDifferentAppsMayInterleaveWithoutFalseOutOfOrderWarning() throws {
        let result = try AppUsageEventLogImporter.parse(log([event("opened", "09:00:00"), event("opened", "08:00:00", app: "second.app"),
            event("closed", "08:20:00", app: "second.app"), event("closed", "09:20:00")]))
        XCTAssertEqual(result.pairedWindows, 2)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(result.timeline.references.allSatisfy(\.claimsCompleteForegroundWindows))
    }
    func testOffsetTimestampPairPreservesOriginalTextAndSameInstant() throws {
        let begin = #"{"bundleID":"example.app","event":"opened","timestamp":"2026-10-01T11:00:00+02:00"}"#
        let result = try AppUsageEventLogImporter.parse(log([begin, event("closed", "09:20:00")]))
        let window = try XCTUnwrap(result.timeline.references.first?.foregroundWindows.first)
        XCTAssertEqual(window.startTimestampText, "2026-10-01T11:00:00+02:00")
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 1_200)
    }
    func testDeclaredNoEventAppRemainsExplicitUnverifiedClaimWithWarning() throws {
        let header = metadata().replacingOccurrences(of: "\"sourceLabel\":", with: "\"bundleIDs\":[\"example.app\"],\"sourceLabel\":")
        let result = try AppUsageEventLogImporter.parse(Data((header + "\n").utf8))
        XCTAssertEqual(result.timeline.references[0].foregroundWindows.count, 0)
        XCTAssertTrue(result.timeline.references[0].claimsCompleteForegroundWindows)
        XCTAssertEqual(result.warnings[0].code, .noEvents)
        XCTAssertNil(result.timeline.references[0].comparisonReportID)
    }
    func testStrictHeaderDuplicateUnknownAndMissingZoneAreRejected() throws {
        for invalid in [metadata().replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
                        metadata().replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                        metadata().replacingOccurrences(of: "\"sourceLabel\":", with: "\"unexpected\":1,\"sourceLabel\":"),
                        metadata().replacingOccurrences(of: "00:00:00Z", with: "00:00:00"),
                        metadata().replacingOccurrences(of: "sameDeviceAsReport", with: "verifiedSystemTelemetry")] {
            XCTAssertThrowsError(try AppUsageEventLogImporter.parse(Data(invalid.utf8)))
        }
        XCTAssertThrowsError(try AppUsageEventLogImporter.parse(Data(event("opened", "09:00:00").utf8)))
    }
    func testEventAndWindowLimitsFailClosedAndWarningsAreBounded() throws {
        XCTAssertThrowsError(try AppUsageEventLogImporter.parse(Data(repeating: 32, count: AppUsageEventLogImporter.maximumFileBytes + 1)))
        let repeated = Array(repeating: event("closed", "09:00:00"), count: 400)
        let bounded = try AppUsageEventLogImporter.parse(log(repeated))
        XCTAssertEqual(bounded.warnings.count, 256)
        XCTAssertTrue(bounded.warningsTruncated)
        XCTAssertFalse(bounded.timeline.references[0].claimsCompleteForegroundWindows)
        XCTAssertThrowsError(try AppUsageEventLogImporter.parse(log(Array(repeating: event("closed", "09:00:00"), count: AppUsageEventLogImporter.maximumEvents + 1))))
        let pairs = (0..<129).flatMap { index in
            let minute = String(format: "%02d", index / 60), second = String(format: "%02d", index % 60)
            return [event("opened", "09:\(minute):\(second)"), event("closed", "09:\(minute):\(second)")]
        }
        XCTAssertThrowsError(try AppUsageEventLogImporter.parse(log(pairs)))
    }
    func testBundledJSONAndNDJSONExamplesAreImportableAndRemainUnverified() throws {
        let referenceURL = try XCTUnwrap(Bundle.module.url(forResource: "example", withExtension: "json"))
        let eventURL = try XCTUnwrap(Bundle.module.url(forResource: "usage-events-example", withExtension: "ndjson"))
        let timeline = try AppUsageTimelineImporter.parse(Data(contentsOf: referenceURL))
        let events = try AppUsageEventLogImporter.parse(Data(contentsOf: eventURL))
        XCTAssertEqual(timeline.references.count, 1)
        XCTAssertFalse(timeline.references[0].claimsCompleteForegroundWindows)
        XCTAssertNil(timeline.references[0].comparisonReportID)
        XCTAssertEqual(events.pairedWindows, 1)
        XCTAssertFalse(events.timeline.references[0].claimsCompleteForegroundWindows)
        XCTAssertFalse(events.timeline.references[0].independentlyVerified)
    }

    private func log(_ records: [String]) -> Data { Data(([metadata()] + records).joined(separator: "\n").utf8) }
    private func event(_ kind: String, _ time: String, app: String = "example.app") -> String {
        "{\"bundleID\":\"\(app)\",\"event\":\"\(kind)\",\"timestamp\":\"2026-10-01T\(time)Z\"}"
    }
    private func metadata() -> String {
        #"{"type":"coverage","schemaVersion":1,"start":"2026-10-01T00:00:00Z","end":"2026-10-01T23:59:59Z","claimsCompleteForegroundWindows":true,"deviceScope":"sameDeviceAsReport","sourceLabel":"User-configured local opened/closed log"}"#
    }
}
