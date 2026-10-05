import Foundation
import XCTest
@testable import FirePrivacyCore

final class EvidenceHistoryTests: XCTestCase {
    private func network(_ app: String = "example.app", domain: String = "api.example", hits: Int = 7, extra: String = "") -> String {
        "{\"type\":\"networkActivity\",\"bundleID\":\"\(app)\",\"domain\":\"\(domain)\",\"hits\":\(hits)\(extra)}"
    }
    private func sensor(_ kind: String, identifier: String? = "session-1", time: String = "2026-10-01T12:00:00Z", app: String = "example.app") -> String {
        let identifierField = identifier.map { ",\"identifier\":\"\($0)\"" } ?? ""
        return "{\"type\":\"access\",\"accessor\":{\"identifier\":\"\(app)\"},\"category\":\"camera\",\"kind\":\"\(kind)\",\"timeStamp\":\"\(time)\"\(identifierField)}"
    }
    private func parse(_ lines: [String], date: TimeInterval = 100) throws -> PrivacyReport {
        try ReportImporter.parse(Data(lines.joined(separator: "\n").utf8), importedAt: Date(timeIntervalSince1970: date))
    }

    func testReimportHasStableIDsAndPreservesImportDateSeparately() throws {
        let first = try parse([network(), network()], date: 100)
        let second = try parse([network(), network()], date: 200)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.observations.map(\.id), second.observations.map(\.id))
        XCTAssertNotEqual(first.observations[0].id, first.observations[1].id)
        XCTAssertNotEqual(first.importedAt, second.importedAt)
        XCTAssertEqual(first.observations[0].provenance?.sourceSHA256, first.observations[1].provenance?.sourceSHA256)
    }

    func testProvenanceHashesPhysicalBOMCRLFLineAndPreservesLineNumbers() throws {
        let line = "\u{FEFF}" + network() + "\r"
        let data = Data((line + "\n\n" + sensor("intervalBegin")).utf8)
        let report = try ReportImporter.parse(data, sourceFilename: "/private/owner/report.ndjson")
        XCTAssertEqual(report.metadata?.sourceSHA256, ContentDigest.sha256(data))
        XCTAssertEqual(report.metadata?.sourceFilename, "report.ndjson")
        XCTAssertEqual(report.observations[0].provenance?.sourceSHA256, ContentDigest.sha256(Data(line.utf8)))
        XCTAssertEqual(report.observations.map { $0.provenance?.sourceLine }, [1, 3])
    }

    func testRawClassificationsAreIndependentAndLargeNumbersExact() throws {
        let report = try parse([network(extra: #", "domainType":2, "domainClassification":"unverified-label", "initiatedType":9007199254740993, "domainOwner":"Unverified Owner", "context":"embedded-web""#)])
        let observation = try XCTUnwrap(report.observations.first)
        XCTAssertEqual(observation.domainType, .integer(2))
        XCTAssertEqual(observation.domainClassification, .text("unverified-label"))
        XCTAssertEqual(observation.initiatedType, .integer(9_007_199_254_740_993))
        XCTAssertEqual(observation.domainOwner, "Unverified Owner")
        XCTAssertEqual(observation.context, "embedded-web")
        XCTAssertFalse(report.findings.contains { $0.detail.lowercased().contains("tracker") })
    }

    func testRawNonIntegerAndBooleanNullFlagsRemainTyped() throws {
        let report = try parse([network(extra: #", "domainType":2.0000000000000000001, "initiatedType":true, "domainClassification":null"#)])
        XCTAssertEqual(report.observations[0].domainType, .number("2.0000000000000000001"))
        XCTAssertEqual(report.observations[0].initiatedType, .boolean(true))
        XCTAssertEqual(report.observations[0].domainClassification, .null)
    }

    func testMetadataSanitizationDoesNotLeakRawValuesIntoWarnings() throws {
        let report = try parse([network(extra: #", "domainOwner":"Private\u202EOwner\n", "context":{"secret":"value"}"#)])
        XCTAssertEqual(report.observations[0].domainOwner, "PrivateOwner")
        XCTAssertNil(report.observations[0].context)
        let warnings = report.observations[0].provenance?.normalizationWarnings.joined() ?? ""
        XCTAssertFalse(warnings.contains("Private"))
        XCTAssertFalse(warnings.contains("secret"))
        XCTAssertFalse(warnings.isEmpty)
    }

    func testInternationalizedHostCanonicalizationPreservesOriginalSpelling() throws {
        let report = try parse([network(domain: "BÜCHER.example.")])
        XCTAssertEqual(report.observations[0].domain, "xn--bcher-kva.example")
        XCTAssertEqual(report.observations[0].originalDomain, "BÜCHER.example.")
    }

    func testLegacyIPv4DestinationCountRemainsWithoutOwnershipAssertion() throws {
        let report = try parse([network(domain: "192.0.2.12", hits: 19)])
        XCTAssertEqual(report.observations[0].domain, "192.0.2.12")
        XCTAssertEqual(report.totalContacts, 19)
        XCTAssertNil(DomainIdentity(report.observations[0].domain ?? ""))
    }

    func testPartialMetadataAndInferredBounds() throws {
        let report = try parse([network(extra: #", "firstTimeStamp":"2026-10-01T11:00:00Z", "lastTimeStamp":"2026-10-01T13:00:00Z""#), "{}", sensor("intervalBegin")])
        XCTAssertEqual(report.metadata?.status, .partial)
        XCTAssertEqual(report.metadata?.recognizedRecords, 2)
        XCTAssertEqual(report.metadata?.skippedRecords, 1)
        XCTAssertLessThan(try XCTUnwrap(report.metadata?.reportStart), try XCTUnwrap(report.metadata?.reportEnd))
    }

    func testLegacyDecodePreservesUUIDAndUnknownProvenance() throws {
        let id = UUID()
        let legacy = PrivacyReport(id: id, importedAt: Date(timeIntervalSince1970: 123), observations: [Observation(bundleID: "example.app", category: .sensor, accessType: "camera", count: 1)])
        let encoder = JSONEncoder(); let decoder = JSONDecoder()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
        let decoded = try decoder.decode(PrivacyReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.metadata)
        XCTAssertNil(decoded.observations[0].provenance)
        XCTAssertNil(decoded.observations[0].domainClassification)
    }

    func testSensorStartsAreSeparateFromRecordsAndMatchedIntervals() throws {
        let report = try parse([sensor("intervalBegin"), sensor("intervalEnd", time: "2026-10-01T12:01:00Z")])
        XCTAssertEqual(report.apps[0].sensorAccesses, 2)
        XCTAssertEqual(report.sensorActivity[0].eventRecords, 2)
        XCTAssertEqual(report.sensorActivity[0].beginRecords, 1)
        XCTAssertEqual(report.sensorActivity[0].completedIntervals, 1)
        XCTAssertEqual(report.sensorIntervals[0].evidenceIDs.count, 2)
    }

    func testAmbiguousMissingAndReversedSensorIntervalsAreNotPaired() throws {
        let missing = try parse([sensor("intervalBegin", identifier: nil), sensor("intervalEnd", identifier: nil)])
        XCTAssertTrue(missing.sensorIntervals.isEmpty)
        let ambiguous = try parse([sensor("intervalBegin"), sensor("intervalBegin"), sensor("intervalEnd")])
        XCTAssertTrue(ambiguous.sensorIntervals.isEmpty)
        let reversed = try parse([sensor("intervalBegin", time: "2026-10-01T12:01:00Z"), sensor("intervalEnd")])
        XCTAssertTrue(reversed.sensorIntervals.isEmpty)
    }

    func testSanitizedSensorIdentifierCannotBecomeAnExactPairingKey() throws {
        let begin = sensor("intervalBegin", identifier: "session\\u202E1")
        let end = sensor("intervalEnd", identifier: "session1", time: "2026-10-01T12:01:00Z")
        let report = try parse([begin, end])
        XCTAssertNil(report.observations[0].sensorIdentifier)
        XCTAssertFalse(report.observations[0].provenance?.normalizationWarnings.isEmpty ?? true)
        XCTAssertTrue(report.sensorIntervals.isEmpty)
        let prefix = String(repeating: "a", count: 512)
        let long = try parse([sensor("intervalBegin", identifier: prefix + "1"), sensor("intervalEnd", identifier: prefix + "2")])
        XCTAssertTrue(long.sensorIntervals.isEmpty)
    }

    func testReverseNanosecondNetworkBoundsAreQuarantinedExactly() throws {
        let report = try parse([network(extra: #", "firstTimeStamp":"2026-10-01T12:00:00.123456789Z", "timeStamp":"2026-10-01T12:00:00.123456780Z""#), sensor("intervalBegin")])
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertEqual(report.observations.count, 1)
        XCTAssertTrue(report.issues[0].message.contains("later than"))
    }

    func testNanosecondSensorOrderAndTemporalThresholdRemainExact() throws {
        let reversed = try parse([sensor("intervalBegin", time: "2026-10-01T12:00:00.123456789Z"), sensor("intervalEnd", time: "2026-10-01T12:00:00.123456780Z")])
        XCTAssertTrue(reversed.sensorIntervals.isEmpty)
        let point = try parse([sensor("instantaneous", time: "2026-10-01T12:00:00.123456780Z"),
            network(extra: #", "timeStamp":"2026-10-01T12:00:00.123456789Z""#)])
        XCTAssertTrue(TemporalAssociations.find(in: point, tolerance: 0).isEmpty)
        let nearby = TemporalAssociations.find(in: point, tolerance: 0.000001)
        XCTAssertEqual(nearby.count, 1)
        XCTAssertEqual(nearby[0].separationSeconds, 0.000000009, accuracy: 0.000000000001)
    }

    func testTemporalAssociationRequiresSameAppAndExplicitTiming() throws {
        let report = try parse([sensor("intervalBegin"),
            network(extra: #", "timeStamp":"2026-10-01T12:00:10Z""#),
            network("example.other", extra: #", "timeStamp":"2026-10-01T12:00:10Z""#),
            network(extra: #", "firstTimeStamp":"2026-10-01T12:00:10Z""#)])
        let result = TemporalAssociations.analyze(in: report, tolerance: 30)
        XCTAssertEqual(result.associations.count, 1)
        XCTAssertEqual(result.associations[0].precision, .timestampPoint)
        XCTAssertEqual(result.associations[0].separationSeconds, 10)
        XCTAssertEqual(result.untimedRecords, 1)
        XCTAssertTrue(result.associations[0].explanation.contains("does not establish"))
    }

    func testTemporalAggregatedWindowRetainsUncertaintyAndLimit() throws {
        let report = try parse([sensor("intervalBegin"), sensor("intervalEnd", time: "2026-10-01T12:01:00Z"),
            network(extra: #", "firstTimeStamp":"2026-10-01T00:00:00Z", "lastTimeStamp":"2026-10-02T00:00:00Z""#)])
        let result = TemporalAssociations.analyze(in: report, tolerance: 0)
        XCTAssertEqual(result.associations.count, 1)
        XCTAssertEqual(result.associations[0].sensorEvidenceIDs.count, 2)
        XCTAssertEqual(result.associations[0].precision, .aggregatedWindow)
        XCTAssertTrue(result.associations[0].explanation.contains("individual instant"))
        XCTAssertTrue(TemporalAssociations.analyze(in: report, maximumResults: 0).reachedLimit)
    }

    func testCanonicalFirstPlusTimeStampIsAnAggregatedWindow() throws {
        let report = try parse([sensor("intervalBegin"),
            network(extra: #", "firstTimeStamp":"2026-10-01T00:00:00Z", "timeStamp":"2026-10-02T00:00:00Z""#)])
        let associations = TemporalAssociations.find(in: report, tolerance: 0)
        XCTAssertEqual(associations.count, 1)
        XCTAssertEqual(associations.first?.precision, .aggregatedWindow)
    }

    func testComparisonDescribesExportPresenceAndCountsWithCoverageWarnings() throws {
        let before = try parse([network("example.old", domain: "old.example", hits: 3)])
        let after = try parse([network("example.new", domain: "new.example", hits: 7)])
        let comparison = ReportComparator.compare(earlier: before, later: after)
        XCTAssertEqual(comparison.appsPresentOnlyLater, ["example.new"])
        XCTAssertEqual(comparison.domainsPresentOnlyEarlier, ["old.example"])
        XCTAssertEqual(comparison.totalContactChange.delta, 4)
        XCTAssertEqual(comparison.coverage, .unknown)
        XCTAssertEqual(comparison.sourceBytesChanged, true)
        XCTAssertTrue(comparison.normalizedEvidenceChanged)
        XCTAssertTrue(comparison.warnings.contains { $0.contains("not installed") })
    }

    func testComparisonIgnoresSourceOrderAndImportIdentityForSemanticEquality() throws {
        let first = try parse([network(), sensor("intervalBegin")])
        let second = try parse([sensor("intervalBegin"), network()], date: 300)
        let comparison = ReportComparator.compare(earlier: first, later: second,
            earlierRevision: AnalysisRevision(knowledgeVersion: "1"), laterRevision: AnalysisRevision(knowledgeVersion: "2"))
        XCTAssertEqual(comparison.sourceBytesChanged, true)
        XCTAssertFalse(comparison.normalizedEvidenceChanged)
        XCTAssertEqual(comparison.analysisRevisionChanged, true)
        XCTAssertTrue(comparison.warnings.contains { $0.contains("Reanalyze") })
    }

    func testWeeklySummaryUsesLatestSnapshotWithoutDoubleCounting() throws {
        let first = try parse([network(hits: 7)], date: 1_000)
        let second = try parse([network(hits: 9)], date: 2_000)
        let summary = WeeklySummaryBuilder.build(reports: [second, first], now: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(summary.uniqueReportCount, 2)
        XCTAssertEqual(summary.latestRecordedContacts, 9)
        XCTAssertEqual(summary.comparisonToPrevious?.totalContactChange.delta, 2)
        XCTAssertTrue(summary.limitations.contains { $0.contains("not continuously") })
    }
}
