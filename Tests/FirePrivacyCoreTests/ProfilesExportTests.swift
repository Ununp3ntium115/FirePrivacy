import Foundation
import XCTest
@testable import FirePrivacyCore

final class ProfilesExportTests: XCTestCase {
    private func privateReport() throws -> PrivacyReport {
        let network = #"{"type":"networkActivity","bundleID":"private.owner.app","domain":"secret.example","hits":12,"timeStamp":"2026-10-01T12:00:00.123456789Z","context":"=HYPERLINK(\"https://secret.example\")","domainOwner":"<private-owner>|[link](https://secret.example)","domainType":2,"domainClassification":"private-classification"}"#
        let sensor = #"{"type":"access","accessor":{"identifier":"private.owner.app"},"category":"camera","identifier":"private-sensor-session","kind":"intervalBegin","timeStamp":"2026-10-01T12:00:00Z"}"#
        return try ReportImporter.parse(Data((network + "\n" + sensor).utf8), importedAt: Date(timeIntervalSince1970: 123), sourceFilename: "private-filename.ndjson")
    }

    func testProfilesClampInvalidPreferenceValuesOnCreationAndDecode() throws {
        let profile = PrivacyProfile(name: "Private\u{202E}Profile", trackingTolerance: -1, locationSensitivity: 101)
        XCTAssertEqual(profile.name, "PrivateProfile")
        XCTAssertEqual(profile.trackingTolerance, 0)
        XCTAssertEqual(profile.locationSensitivity, 100)
        let data = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["advertisingTolerance"] = 1000
        let decoded = try JSONDecoder().decode(PrivacyProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.advertisingTolerance, 100)
    }

    func testPresetIDsAndWeightsAreStableAndPreferencesDoNotChangeEvidence() throws {
        XCTAssertEqual(Set(PrivacyProfile.presets.map(\.id)).count, 3)
        XCTAssertEqual(PrivacyProfile.balanced, PrivacyProfile.presets[0])
        let keys: Set<String> = ["advertising", "dataBroker", "locationIntelligence"]
        let strict = PrivacyProfile.minimizeTracking.relevanceMultiplier(forCategoryKeys: keys)
        XCTAssertGreaterThan(strict, PrivacyProfile.balanced.relevanceMultiplier(forCategoryKeys: keys))
        XCTAssertLessThanOrEqual(strict, 1.8)
        XCTAssertEqual(PrivacyProfile.balanced.relevanceMultiplier(forCategoryKeys: []), 1)
        let report = try privateReport()
        let saved = report
        _ = PrivacyProfile.maximumLocalProcessing.relevanceMultiplier(forCategoryKeys: keys)
        XCTAssertEqual(report, saved)
    }

    func testPermissionAuditKeepsExplicitUnknownAndDatedUserStatements() throws {
        let old = SelfReportedPermission(bundleID: "example.app", category: "camera", state: .denied, updatedAt: Date(timeIntervalSince1970: 1))
        let newer = SelfReportedPermission(bundleID: "example.app", category: "camera", state: .unknown, isExpected: false, note: "I will review this", updatedAt: Date(timeIntervalSince1970: 2))
        var audit = ManualPermissionAudit(entries: [newer, old])
        XCTAssertEqual(audit.entries.count, 1)
        XCTAssertEqual(audit.entry(bundleID: "example.app", category: "camera")?.state, .unknown)
        XCTAssertEqual(audit.entry(bundleID: "example.app", category: "camera")?.updatedAt, newer.updatedAt)
        audit.record(SelfReportedPermission(bundleID: "example.app", category: "camera", state: .limited))
        XCTAssertEqual(audit.entries.count, 1)
        XCTAssertEqual(audit.entries[0].state, .limited)
        audit.remove(bundleID: "example.app", category: "camera")
        XCTAssertTrue(audit.entries.isEmpty)
        XCTAssertNil(audit.entry(bundleID: "example.app", category: "location"))
    }

    func testAuditRoundTripDeduplicatesAndDoesNotInferPermission() throws {
        let report = try privateReport()
        let audit = ManualPermissionAudit()
        XCTAssertNil(audit.entry(bundleID: report.observations[0].bundleID, category: "camera"))
        let roundTrip = try JSONDecoder().decode(ManualPermissionAudit.self, from: JSONEncoder().encode(audit))
        XCTAssertEqual(audit, roundTrip)
    }

    func testAuditDecodingSanitizesAndTupleIDsCannotCollide() throws {
        let entry = SelfReportedPermission(bundleID: "example.app", category: "camera", note: "safe")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["note"] = "Private\u{202E}Note" + String(repeating: "x", count: 600)
        let decoded = try JSONDecoder().decode(SelfReportedPermission.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.note?.count, 512)
        XCTAssertFalse(decoded.note?.contains("\u{202E}") ?? true)
        let first = SelfReportedPermission(bundleID: "a|b", category: "c")
        let second = SelfReportedPermission(bundleID: "a", category: "b|c")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(ManualPermissionAudit(entries: [first, second]).entries.count, 2)
    }

    func testRedactedExportRejectsInvalidRawNumberAndPrivateVersionOrRecordLabels() throws {
        let observation = Observation(bundleID: "private.app", domain: "secret.example", category: .network, accessType: "private-type", count: 1,
            domainType: .number("private.owner.app"), initiatedType: .number("2e0"))
        let report = PrivacyReport(observations: [observation], metadata: ReportMetadata(parserVersion: "private-name", normalizationVersion: "private-name", recognizedRecords: 1))
        let exported = ReportExporter.document(report: report, options: .redacted)
        XCTAssertNil(exported.report.observations[0].domainType)
        XCTAssertEqual(exported.report.observations[0].initiatedType, .number("2e0"))
        XCTAssertEqual(exported.report.observations[0].accessType, "networkActivity")
        XCTAssertEqual(exported.report.metadata?.parserVersion, "unavailable")
        let text = String(decoding: try ReportExporter.json(report: report, options: .redacted), as: UTF8.self)
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("secret.example"))
    }

    func testNormalizedJSONIncludesSourceAndExactTimestampText() throws {
        let report = try privateReport()
        let data = try ReportExporter.json(report: report)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let exported = try decoder.decode(ReportExportDocument.self, from: data)
        XCTAssertFalse(exported.redacted)
        XCTAssertEqual(exported.report.totalContacts, 12)
        XCTAssertEqual(exported.report.metadata?.sourceSHA256, report.metadata?.sourceSHA256)
        XCTAssertEqual(exported.report.observations[0].timestampText, "2026-10-01T12:00:00.123456789Z")
        XCTAssertEqual(data, try ReportExporter.json(report: report))
    }

    func testRedactedJSONRemovesIdentifiersHashesContextOwnersDatesAndSensorIDs() throws {
        let report = try privateReport()
        let data = try ReportExporter.json(report: report, options: .redacted)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for privateValue in ["private.owner.app", "secret.example", "private-owner", "private-sensor-session", "private-filename", "private-classification", "2026-10-01", report.id.uuidString, report.metadata?.sourceSHA256 ?? "missing"] {
            XCTAssertFalse(text.contains(privateValue), "Leaked \(privateValue)")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let exported = try decoder.decode(ReportExportDocument.self, from: data)
        XCTAssertTrue(exported.redacted)
        XCTAssertEqual(exported.report.totalContacts, 12)
        XCTAssertEqual(exported.report.observations[0].bundleID, exported.report.observations[1].bundleID)
        XCTAssertEqual(exported.report.observations[0].domain, "domain-1.invalid")
        XCTAssertNil(exported.report.observations[0].provenance)
        XCTAssertNil(exported.report.observations[0].timestamp)
        XCTAssertNil(exported.report.observations[0].domainClassification)
        XCTAssertEqual(exported.report.observations[0].domainType, .integer(2))
    }

    func testIdentifierRedactionOverridesConflictingSensitiveOptions() throws {
        let report = try privateReport()
        let options = ReportExportOptions(redactIdentifiers: true, includeContext: true, includeOwners: true, includeProvenance: true)
        let exported = ReportExporter.document(report: report, options: options)
        XCTAssertNil(exported.report.observations[0].context)
        XCTAssertNil(exported.report.observations[0].domainOwner)
        XCTAssertNil(exported.report.observations[0].provenance)
        XCTAssertNil(exported.report.metadata?.sourceSHA256)
    }

    func testCSVQuotesFormulaCellsAndPreservesExactCountsAndFractionalTime() throws {
        let text = String(decoding: ReportExporter.csv(report: try privateReport()), as: UTF8.self)
        XCTAssertTrue(text.contains("\"'=HYPERLINK("))
        XCTAssertTrue(text.contains("\"12\""))
        XCTAssertTrue(text.contains("2026-10-01T12:00:00.123456789Z"))
        XCTAssertTrue(text.contains("\"\"https://secret.example\"\""))
        XCTAssertTrue(text.hasSuffix("\r\n"))
    }

    func testCSVPreventsFormulaExecutionAfterWhitespaceAndControlRemoval() {
        let observation = Observation(bundleID: "example.app", category: .sensor, accessType: "camera", count: 1, context: "\t  @SUM(1,2)")
        let text = String(decoding: ReportExporter.csv(report: PrivacyReport(observations: [observation])), as: UTF8.self)
        XCTAssertTrue(text.contains("\"'  @SUM(1,2)\""))
        XCTAssertFalse(text.contains("\t"))
    }

    func testMarkdownEscapesImportedMarkupAndRedactedExportsOmitPrivateLabels() throws {
        let unsafe = Observation(bundleID: "<script>|[link]", domain: "*private*`domain`", category: .network, accessType: "networkActivity", count: 3)
        let markdown = String(decoding: ReportExporter.markdown(report: PrivacyReport(observations: [unsafe])), as: UTF8.self)
        XCTAssertFalse(markdown.contains("<script>"))
        XCTAssertTrue(markdown.contains("&lt;script&gt;\\|\\[link\\]"))
        XCTAssertTrue(markdown.contains("\\*private\\*\\`domain\\`"))
        let redactedCSV = String(decoding: ReportExporter.csv(report: try privateReport(), options: .redacted), as: UTF8.self)
        let redactedMarkdown = String(decoding: ReportExporter.markdown(report: try privateReport(), options: .redacted), as: UTF8.self)
        XCTAssertFalse(redactedCSV.contains("secret.example"))
        XCTAssertFalse(redactedMarkdown.contains("private.owner.app"))
    }

    func testDiagnosticsAllowOnlyCountsVersionTokensAndErrorEnums() throws {
        let report = try privateReport()
        let diagnostics = DiagnosticsBuilder.build(reports: [report], appVersion: "1.2.3", osVersion: "26.0", eventCodes: [.partialImport, .storageUnavailable])
        let text = String(decoding: try DiagnosticsBuilder.json(diagnostics), as: UTF8.self)
        XCTAssertEqual(diagnostics.observationCount, 2)
        XCTAssertEqual(diagnostics.reportCount, 1)
        XCTAssertTrue(text.contains("storageUnavailable"))
        for privateValue in ["private.owner.app", "secret.example", "private-owner", "private-filename", report.id.uuidString, report.metadata?.sourceSHA256 ?? "missing"] {
            XCTAssertFalse(text.contains(privateValue))
        }
        let rejected = DiagnosticsBuilder.build(reports: [], appVersion: "private.owner.app", osVersion: "https://secret.example")
        XCTAssertEqual(rejected.appVersion, "unavailable")
        XCTAssertEqual(rejected.osVersion, "unavailable")
    }

    func testSyntheticExportLabelIsExplicitMetadataNotDomainGuessing() {
        let observation = Observation(bundleID: "example.app", domain: "api.example", category: .network, accessType: "networkActivity", count: 0)
        let unknown = PrivacyReport(observations: [observation])
        XCTAssertFalse(ReportExporter.document(report: unknown).syntheticDemo)
        let demo = PrivacyReport(observations: [observation], metadata: ReportMetadata(recognizedRecords: 1, isSyntheticDemo: true))
        XCTAssertTrue(ReportExporter.document(report: demo).syntheticDemo)
        XCTAssertTrue(String(decoding: ReportExporter.markdown(report: demo), as: UTF8.self).contains("Synthetic demonstration"))
        let csv = String(decoding: ReportExporter.csv(report: demo, options: .redacted), as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix("\"synthetic_demo\",\"redacted\""))
        XCTAssertTrue(csv.contains("\"true\",\"true\""))
    }
}
