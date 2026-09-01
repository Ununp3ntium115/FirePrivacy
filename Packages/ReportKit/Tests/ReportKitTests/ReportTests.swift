import XCTest
@testable import ReportKit
import ObservationCore
import FindingEngine
import KnowledgeBaseKit
import ObservationStore
import TestSupport

private func storedSession(
    label: String,
    hosts: [String],
    findings: [Finding] = [],
    posture: Int = 80
) -> StoredSession {
    let session = Fixtures.session(id: DeterministicUUID.make(namespace: .importSession, name: label))
    let network = hosts.enumerated().map { index, host in
        Fixtures.network(session: session, bundle: "com.example.app", host: host, line: index + 1)
    }
    return StoredSession(
        snapshot: Fixtures.snapshot(network: network, session: session),
        findings: findings,
        evidence: [:],
        scores: PostureScores(
            sensorExposure: 0, thirdPartyReach: 0, aggregationSignals: 0,
            repetition: 0, controlGap: 0, evidenceConfidence: 0,
            privacyPosture: posture, explanation: [:]
        ),
        ruleSetVersion: "ruleset-test",
        knowledgeBaseVersion: Fixtures.knowledgeBaseVersion,
        evaluatedAt: Fixtures.referenceDate
    )
}

final class ExportTests: XCTestCase {
    private let builder = ExportBuilder(appVersion: "1.0.0", osVersion: "26.0")

    func testJSONCarriesEveryVersionStamp() throws {
        let data = try builder.makeJSON(
            sessions: [storedSession(label: "one", hosts: ["a.example"])],
            redaction: .fullPersonalArchive,
            generatedAt: Fixtures.referenceDate
        )
        let text = String(decoding: data, as: UTF8.self)
        for key in ["schemaVersion", "appVersion", "parserVersion", "ruleSetVersion", "knowledgeBaseVersion", "sourceHashes", "generatedAt"] {
            XCTAssertTrue(text.contains(key), "export is missing \(key) (EXP-004)")
        }
    }

    func testAnonymousPresetRemovesIdentifiers() throws {
        let session = storedSession(label: "one", hosts: ["collect.tracker.example"])
        let data = try builder.makeJSON(sessions: [session], redaction: .anonymousBugReport, generatedAt: Fixtures.referenceDate)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("collect.tracker.example"))
        XCTAssertFalse(text.contains("com.example.app"))
    }

    func testFullArchiveKeepsIdentifiers() throws {
        let session = storedSession(label: "one", hosts: ["collect.tracker.example"])
        let data = try builder.makeJSON(sessions: [session], redaction: .fullPersonalArchive, generatedAt: Fixtures.referenceDate)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("collect.tracker.example"))
    }

    func testPreviewReportsWhatWillBeIncluded() {
        let session = storedSession(label: "one", hosts: ["collect.tracker.example"])
        let preview = builder.preview(sessions: [session], redaction: .securityPractitioner)
        XCTAssertEqual(preview.sessionCount, 1)
        XCTAssertEqual(preview.domains, ["collect.tracker.example"])
        XCTAssertFalse(preview.includesUserNotes)
        XCTAssertGreaterThan(preview.estimatedByteCount, 0)
    }

    func testCSVQuotesAndNeutralizesFormulas() {
        XCTAssertEqual(ExportBuilder.csvEscape("plain"), "\"plain\"")
        XCTAssertEqual(ExportBuilder.csvEscape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ExportBuilder.csvEscape("=1+1"), "\"'=1+1\"")
        XCTAssertEqual(ExportBuilder.csvEscape("@SUM(A1)"), "\"'@SUM(A1)\"")
    }

    func testCSVHasOneRowPerObservationPlusHeader() {
        let session = storedSession(label: "one", hosts: ["a.example", "b.example", "c.example"])
        let rows = builder.makeNetworkCSV(sessions: [session], redaction: .fullPersonalArchive)
            .split(separator: "\n")
        XCTAssertEqual(rows.count, 4)
    }

    func testMarkdownStatesTheAccuracyBoundary() {
        let markdown = builder.makeMarkdown(
            sessions: [storedSession(label: "one", hosts: ["a.example"])],
            redaction: .fullPersonalArchive,
            generatedAt: Fixtures.referenceDate
        )
        XCTAssertTrue(markdown.contains("does not show what was sent"))
    }
}

final class ComparisonTests: XCTestCase {
    func testDetectsNewAndDisappearedDomains() {
        let earlier = storedSession(label: "one", hosts: ["a.example", "b.example"])
        let later = storedSession(label: "two", hosts: ["b.example", "c.example"])
        let comparison = ReportComparison(earlier: earlier, later: later)

        XCTAssertEqual(comparison.newDomains.map(\.host.value), ["c.example"])
        XCTAssertEqual(comparison.disappearedDomains.map(\.host.value), ["a.example"])
    }

    func testReportsPostureDelta() {
        let comparison = ReportComparison(
            earlier: storedSession(label: "one", hosts: ["a.example"], posture: 70),
            later: storedSession(label: "two", hosts: ["a.example"], posture: 85)
        )
        XCTAssertEqual(comparison.postureDelta, 15)
    }

    func testAttributesDifferencesToADatasetChangeWhenOneHappened() {
        var earlier = storedSession(label: "one", hosts: ["a.example"])
        earlier = StoredSession(
            snapshot: earlier.snapshot,
            findings: earlier.findings,
            evidence: [:],
            scores: earlier.scores,
            ruleSetVersion: earlier.ruleSetVersion,
            knowledgeBaseVersion: KnowledgeBaseVersion(
                datasetVersion: "kb-old", generatedAt: nil, expiresAt: nil, origin: .bundled, recordCount: 1
            ),
            evaluatedAt: earlier.evaluatedAt
        )
        let comparison = ReportComparison(earlier: earlier, later: storedSession(label: "two", hosts: ["a.example"]))
        XCTAssertTrue(comparison.knowledgeBaseChanged)
        XCTAssertNotNil(comparison.attributionNote)
    }

    func testNoAttributionNoteWhenNothingChangedInFirePrivacy() {
        let comparison = ReportComparison(
            earlier: storedSession(label: "one", hosts: ["a.example"]),
            later: storedSession(label: "two", hosts: ["a.example"])
        )
        XCTAssertNil(comparison.attributionNote)
    }
}

final class WeeklyReportTests: XCTestCase {
    func testAbsenceOfDataIsNeverReportedAsNoChange() {
        let report = WeeklyReport(
            generatedAt: Fixtures.referenceDate,
            hasNewSourceReport: false,
            comparison: nil,
            protectionIsActive: false,
            knowledgeBaseIsStale: false,
            latestSession: nil
        )
        XCTAssertTrue(report.summaryLines.contains { $0.contains("No new source report") })
        XCTAssertTrue(report.summaryLines.contains { $0.contains("not a statement that nothing changed") })
    }

    /// A notification must not name an app or a domain on the lock screen.
    func testNotificationTextIsGenericByDefault() {
        let body = WeeklyReport.genericNotificationBody
        XCTAssertEqual(body, "Your Fire Privacy checkup is ready.")
        XCTAssertFalse(body.contains(".example"))
        XCTAssertFalse(body.contains("com."))
    }
}
