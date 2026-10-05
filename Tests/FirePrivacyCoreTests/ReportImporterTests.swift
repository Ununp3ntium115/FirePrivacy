import Foundation
import XCTest
@testable import FirePrivacyCore

final class ReportImporterTests: XCTestCase {
    private let sensor = #"{"type":"access","accessor":{"identifier":"example.camera","identifierType":"bundleID"},"category":"camera","kind":"intervalBegin","timeStamp":"2026-10-01T12:34:56Z"}"#

    private func network(hits: String = "7", extra: String = "", domain: String = "API.Example.") -> String {
        #"{"type":"networkActivity","accessor":{"identifier":"example.weather","identifierType":"bundleID"},"domain":""# + domain + #"","hits":"# + hits + extra + "}"
    }

    private func report(_ lines: [String]) throws -> PrivacyReport {
        try ReportImporter.parse(Data(lines.joined(separator: "\n").utf8), importedAt: Date(timeIntervalSince1970: 123))
    }

    func testNetworkPreservesCountAndTimestampPrecision() throws {
        let first = "2026-10-01T12:34:56.123456789Z"
        let last = "2026-10-01T12:35:56.987654321+00:00"
        let result = try report([network(hits: "42", extra: #", "firstTimeStamp":""# + first + #"","lastTimeStamp":""# + last + #"""#)])
        let observation = try XCTUnwrap(result.observations.first)
        XCTAssertEqual(observation.count, 42)
        XCTAssertEqual(result.totalContacts, 42)
        XCTAssertEqual(observation.firstTimestampText, first)
        XCTAssertEqual(observation.lastTimestampText, last)
        XCTAssertEqual(observation.timestamp, observation.lastTimestamp)
        XCTAssertNotNil(observation.firstTimestamp)
        XCTAssertEqual(result.importedAt, Date(timeIntervalSince1970: 123))
    }

    func testSensorIntervalsRemainSeparateEventRecords() throws {
        let result = try report([sensor, sensor.replacingOccurrences(of: "intervalBegin", with: "intervalEnd")])
        XCTAssertEqual(result.observations.map(\.eventKind), ["intervalBegin", "intervalEnd"])
        XCTAssertEqual(result.apps.first?.sensorAccesses, 2)
        XCTAssertEqual(result.totalContacts, 0)
        XCTAssertTrue(result.findings.first?.detail.contains("same access") == true)
    }

    func testCanonicalNetworkTopLevelBundleIDAndTimeStamp() throws {
        let text = #"{"type":"networkActivity","bundleID":"example.weather","domain":"api.example","hits":19,"firstTimeStamp":"2026-10-01T08:00:00Z","timeStamp":"2026-10-01T09:00:00.123+00:00"}"#
        let result = try report([text])
        XCTAssertEqual(result.observations.first?.bundleID, "example.weather")
        XCTAssertEqual(result.observations.first?.timestampText, "2026-10-01T09:00:00.123+00:00")
        XCTAssertEqual(result.observations.first?.count, 19)
        XCTAssertNotNil(result.observations.first?.firstTimestamp)
    }

    func testMatchingBundleIDAlternativesAreAccepted() throws {
        let result = try report([network(extra: #", "bundleID":"example.weather""#)])
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.observations.first?.bundleID, "example.weather")
    }

    func testConflictingBundleIDAlternativesAreQuarantined() throws {
        let result = try report([network(extra: #", "bundleID":"example.other""#), sensor])
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues.first?.message.contains("Conflicting") == true)
    }

    func testInvalidTopLevelBundleIDIsQuarantined() throws {
        let result = try report([network(extra: #", "bundleID":true"#), sensor])
        XCTAssertEqual(result.issues.count, 1)
    }

    func testMissingNetworkCountIsQuarantinedInsteadOfInvented() throws {
        let explicit = #"{"type":"networkActivity","accessor":{"identifier":"example.app"},"domain":"api.example"}"#
        let result = try report([explicit, sensor])
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.totalContacts, 0)
        XCTAssertEqual(result.issues.map(\.line), [1])
    }

    func testInvalidCountsAreQuarantined() throws {
        let result = try report(["true", "-1", "1.5", "null", "\"7\"", "9223372036854775808"].map { network(hits: $0) } + [sensor])
        XCTAssertEqual(result.issues.count, 6)
        XCTAssertEqual(result.observations.count, 1)
    }

    func testZeroAndIntegralExponentArePreserved() throws {
        let result = try report([network(hits: "0"), network(hits: "2e3"), network(hits: "200.00e-2")])
        XCTAssertEqual(result.observations.map(\.count), [0, 2_000, 2])
        XCTAssertEqual(result.totalContacts, 2_002)
    }

    func testTinyFractionalRemainderCannotBeRoundedIntoAHit() throws {
        let result = try report([network(hits: "1.00000000000000000000000000000000000000000001"), sensor])
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testIntegerLargerThanDoublePrecisionIsPreserved() throws {
        let result = try report([network(hits: "9007199254740993")])
        XCTAssertEqual(result.observations.first?.count, 9_007_199_254_740_993)
    }

    func testOverflowingTotalQuarantinesOnlyOverflowingRecord() throws {
        let result = try report([network(hits: String(Int.max)), network(hits: "1")])
        XCTAssertEqual(result.totalContacts, Int.max)
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testMixedUnknownAndMalformedRecordsRetainLineNumbers() throws {
        let result = try report([#"{"type":"metadata"}"#, "not JSON", sensor])
        XCTAssertEqual(result.issues.map(\.line), [1, 2])
        XCTAssertEqual(result.observations.count, 1)
    }

    func testIssuesDoNotEchoSensitiveImportedContent() throws {
        let result = try report([#"{"secret-domain.example": invalid}"#, sensor])
        XCTAssertFalse(result.issues.contains { $0.message.contains("secret-domain") })
    }

    func testDuplicateAndEscapedDuplicateKeysAreRejected() throws {
        let duplicate = network(extra: #", "hits":8"#)
        let escaped = network(extra: #", "h\u0069ts":8"#)
        let result = try report([duplicate, escaped, sensor])
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertTrue(result.issues.allSatisfy { $0.message.contains("duplicate") })
    }

    func testNestedDuplicateKeysAreRejected() throws {
        let invalid = network(extra: #", "extra":{"value":1,"value":2}"#)
        XCTAssertEqual(try report([invalid, sensor]).issues.count, 1)
    }

    func testExcessiveNestingIsRejectedBeforeDeserialization() throws {
        let nested = String(repeating: "[", count: 30) + "0" + String(repeating: "]", count: 30)
        let result = try report([network(extra: ",\"extra\":" + nested), sensor])
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertTrue(result.issues.first?.message.contains("nesting") == true)
    }

    func testOversizedLineAndStringAreQuarantined() throws {
        let line = String(repeating: "x", count: ReportImporter.maximumLineBytes + 1)
        let longString = network(extra: ",\"extra\":\"" + String(repeating: "x", count: 4_097) + "\"")
        let result = try report([line, longString, sensor])
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertEqual(result.observations.count, 1)
    }

    func testOversizedFileFailsWithActionableError() {
        XCTAssertThrowsError(try ReportImporter.parse(Data(repeating: 0x20, count: ReportImporter.maximumFileBytes + 1))) {
            XCTAssertEqual($0 as? ReportImporter.ImportError, .fileTooLarge)
        }
    }

    func testNonemptyRecordLimitIsEnforced() {
        let data = Data(String(repeating: "{}\n", count: ReportImporter.maximumRecords + 1).utf8)
        XCTAssertThrowsError(try ReportImporter.parse(data)) {
            XCTAssertEqual($0 as? ReportImporter.ImportError, .tooManyRecords)
        }
    }

    func testInvalidUTF8IsQuarantinedPerLine() throws {
        var data = Data([0xFF, 0x0A])
        data.append(Data(sensor.utf8))
        let result = try ReportImporter.parse(data)
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.issues.first?.line, 1)
        XCTAssertTrue(result.issues.first?.message.contains("UTF-8") == true)
    }

    func testBOMCRLFAndBlankLinesPreserveIssueLineNumbers() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data((sensor + "\r\n \t\r\n{}\r\n").utf8))
        let result = try ReportImporter.parse(data)
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.issues.map(\.line), [3])
    }

    func testArrayRootAndTrailingJSONAreRejected() throws {
        let result = try report(["[" + sensor + "]", sensor + "{}", sensor])
        XCTAssertEqual(result.issues.count, 2)
    }

    func testHostileDisplayedTextIsRejected() throws {
        let bidi = network(domain: #"api.\u202Eexample"#)
        let markup = sensor.replacingOccurrences(of: "example.camera", with: "<script>")
        let newline = sensor.replacingOccurrences(of: "camera\",\"kind", with: "cam\\n era\",\"kind")
        let result = try report([bidi, markup, newline, sensor])
        XCTAssertEqual(result.issues.count, 3)
        XCTAssertEqual(result.observations.count, 1)
    }

    func testInvalidTimestampAndReverseRangeAreQuarantined() throws {
        let bad = network(extra: #", "lastTimeStamp":"not-a-date""#)
        let reversed = network(extra: #", "firstTimeStamp":"2026-10-02T00:00:00Z","lastTimeStamp":"2026-10-01T00:00:00Z""#)
        let nullTimestamp = network(extra: #", "lastTimeStamp":null"#)
        XCTAssertEqual(try report([bad, reversed, nullTimestamp, sensor]).issues.count, 3)
    }

    func testInvalidCalendarDateCannotBeSilentlyNormalized() throws {
        let invalid = network(extra: #", "timeStamp":"2026-02-30T00:00:00Z""#)
        let valid = network(extra: #", "timeStamp":"2024-02-29T00:00:00Z""#)
        let result = try report([invalid, valid])
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.observations.first?.timestampText, "2024-02-29T00:00:00Z")
    }

    func testOversizedArrayAndObjectAreQuarantined() throws {
        let array = Array(repeating: "0", count: 129).joined(separator: ",")
        let fields = (0..<129).map { "\"field\($0)\":0" }.joined(separator: ",")
        let result = try report([network(extra: ",\"extra\":[" + array + "]"), network(extra: ",\"extra\":{" + fields + "}"), sensor])
        XCTAssertEqual(result.issues.count, 2)
    }

    func testAbsentTimestampsRemainUnknown() throws {
        let result = try report([network()])
        XCTAssertNil(result.observations.first?.timestamp)
        XCTAssertNil(result.observations.first?.lastTimestamp)
    }

    func testNonBundleAccessorIsUnsupported() throws {
        let invalid = sensor.replacingOccurrences(of: "bundleID", with: "executablePath")
        XCTAssertEqual(try report([invalid, sensor]).issues.count, 1)
    }

    func testDomainsNormalizeAndAggregateWithoutInventingContacts() throws {
        let otherApp = network(hits: "11").replacingOccurrences(of: "example.weather", with: "example.reader")
        let result = try report([network(hits: "5"), otherApp, sensor])
        XCTAssertEqual(result.domains, [DomainSummary(domain: "api.example", contacts: 16, apps: ["example.reader", "example.weather"])])
        XCTAssertEqual(result.apps.map(\.bundleID), ["example.reader", "example.weather", "example.camera"])
        XCTAssertEqual(result.totalContacts, 16)
    }

    func testUnsupportedOnlyAndEmptyFilesFail() {
        for data in [Data(), Data(" \n\t\r\n".utf8), Data(#"{"type":"unknown"}"#.utf8)] {
            XCTAssertThrowsError(try ReportImporter.parse(data)) { error in
                guard case .noRecognizedRecords = error as? ReportImporter.ImportError else {
                    return XCTFail("Expected an actionable unsupported report error")
                }
            }
        }
    }

    func testReportCodableRoundTripPreservesEvidence() throws {
        let result = try report([network(), sensor, "{}"])
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(PrivacyReport.self, from: data), result)
    }

    func testFindingsLinkExistingEvidenceAndStateLimits() throws {
        let result = try report([network(), sensor])
        let ids = Set(result.observations.map(\.id))
        XCTAssertEqual(Set(result.findings.map(\.id)).count, result.findings.count)
        XCTAssertTrue(result.findings.allSatisfy { !$0.evidenceIDs.isEmpty && Set($0.evidenceIDs).isSubset(of: ids) })
        XCTAssertTrue(result.findings.contains { $0.detail.contains("do not show what data was sent") })
        XCTAssertTrue(result.findings.contains { $0.detail.contains("current permission state") })
    }

    func testSyntheticDemoAndBundledFileAgreeOnSummaries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/DemoReport.ndjson"))
        let imported = try ReportImporter.parse(data)
        XCTAssertTrue(imported.issues.isEmpty)
        XCTAssertEqual(imported.apps, PrivacyReport.demo.apps)
        XCTAssertEqual(imported.domains, PrivacyReport.demo.domains)
        XCTAssertEqual(imported.totalContacts, 49)
        XCTAssertTrue(imported.domains.allSatisfy { $0.domain.hasSuffix(".example") })
    }
}
