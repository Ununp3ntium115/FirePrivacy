import Foundation
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Native integration with the actual Apple adapter, using only synthetic imported evidence.
/// Simulator checks exercise availability and actual coordinator fallback. A simulator
/// can report ready while its generation assets are missing; physical guided generation
/// remains a separate check on eligible hardware with downloaded model assets.
final class SystemLanguageModelAdvisorTests: XCTestCase {
    @MainActor
    func testActualAdapterReportsTypedSystemAvailability() async {
        let advisor = SystemLanguageModelAdvisor()
        let availability = await advisor.availability()
        XCTAssertEqual(advisor.mode, .appleOnDevice)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let expected: AdvisorAvailability
            switch SystemLanguageModel.default.availability {
            case .available: expected = .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: expected = .unsupportedDevice
                case .appleIntelligenceNotEnabled: expected = .appleIntelligenceDisabled
                case .modelNotReady: expected = .modelNotReady
                @unknown default: expected = .unavailable
                }
            }
            XCTAssertEqual(availability, expected)
            return
        }
        #endif
        XCTAssertEqual(availability, .unsupportedOS(required: 26))
    }

    @MainActor
    func testUnavailableActualAdapterRejectsBeforeGeneration() async throws {
        let advisor = SystemLanguageModelAdvisor()
        let availability = await advisor.availability()
        guard availability != .available else {
            throw XCTSkip("This environment has a ready model; unavailable-state rejection is exercised only on unsupported OS/device, disabled Apple Intelligence, or unavailable assets.")
        }
        let fixture = try makeFixture()
        do {
            _ = try await advisor.assess(fixture.input)
            XCTFail("An unavailable system model must reject before opening a generation session.")
        } catch let error as AdvisorError {
            XCTAssertEqual(error, .unavailable(availability))
        }
    }

    @MainActor
    func testActualCoordinatorKeepsGroundedResultsAcrossSystemRuntimeStates() async throws {
        let advisor = SystemLanguageModelAdvisor()
        let availability = await advisor.availability()
        let fixture = try makeFixture()
        let baseline = try await OfflineAdvisor().assess(fixture.input)
        let result = try await AdvisorCoordinator.assess(fixture.input, preferred: advisor)
        if availability != .available {
            XCTAssertEqual(result.mode, .offline)
            XCTAssertEqual(result.fallback, .unavailable(availability))
            XCTAssertEqual(result.assessment, baseline)
        } else if result.mode == .appleOnDevice {
            XCTAssertNil(result.fallback)
        } else {
            // This invokes the actual model even when advertised availability is
            // optimistic. Framework errors remain closed, sanitized typed reasons.
            XCTAssertEqual(result.mode, .offline)
            let fallback = try XCTUnwrap(result.fallback)
            switch fallback {
            case .unavailable(let state): XCTAssertNotEqual(state, .available)
            case .failed(let failure):
                if case .unavailable(let state) = failure { XCTAssertNotEqual(state, .available) }
            }
            XCTAssertEqual(result.assessment, baseline)
        }
        assertGrounded(result.assessment, in: fixture.analysis, input: fixture.input)
    }

    @MainActor
    func testRealGuidedGenerationOnEligiblePhysicalDeviceWithReadyAssets() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical guided-generation QA requires eligible Apple Intelligence hardware and ready model assets. Simulator availability can report ready without usable generation assets; its actual coordinator fallback is tested separately.")
        #else
        let advisor = SystemLanguageModelAdvisor()
        let availability = await advisor.availability()
        guard availability == .available else {
            throw XCTSkip("Real guided generation requires iOS/iPadOS 26+, eligible Apple Intelligence hardware, Apple Intelligence enabled, and downloaded ready model assets. Current runtime: " + availability.explanation)
        }
        let fixture = try makeFixture()
        // No network, model download, permission change or arbitrary readiness delay is attempted.
        let assessment = try await advisor.assess(fixture.input)
        assertGrounded(assessment, in: fixture.analysis, input: fixture.input)
        #endif
    }

    @MainActor
    private func makeFixture() throws -> (analysis: FindingAnalysis, input: AdvisorInput) {
        let source = Data("""
        {"type":"networkActivity","bundleID":"example.apple-advisor.first","domain":"shared.example","domainClassification":2,"hits":3,"timeStamp":"2026-10-05T12:00:00Z"}
        {"type":"networkActivity","bundleID":"example.apple-advisor.second","domain":"shared.example","hits":2,"timeStamp":"2026-10-05T12:00:01Z"}
        {"type":"networkActivity","bundleID":"example.apple-advisor.third","domain":"shared.example","hits":1,"timeStamp":"2026-10-05T12:00:02Z"}
        """.utf8)
        let importedAt = Date(timeIntervalSince1970: 1_791_201_610)
        let report = try ReportImporter.parse(source, importedAt: importedAt)
        XCTAssertEqual(report.observations.count, 3)
        XCTAssertTrue(report.issues.isEmpty)
        let analysis = VersionedFindingEngine.evaluate(report: report, context: FindingContext(now: importedAt))
        XCTAssertFalse(analysis.findings.isEmpty)
        let input = try AdvisorInput.make(analysis: analysis)
        try input.validate()
        let payload = try XCTUnwrap(String(data: input.encoded(), encoding: .utf8))
        XCTAssertFalse(payload.contains("shared.example"))
        XCTAssertFalse(payload.contains("example.apple-advisor"))
        return (analysis, input)
    }

    @MainActor
    private func assertGrounded(_ assessment: ValidatedAdvisorAssessment, in analysis: FindingAnalysis,
                                input: AdvisorInput, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try AdvisorValidator.validate(assessment.assessment, for: input), file: file, line: line)
        do {
            let explanations = try AdvisorRenderer.explanations(assessment: assessment, analysis: analysis)
            XCTAssertEqual(explanations.count, input.claims.count, file: file, line: line)
            for explanation in explanations {
                let finding = try XCTUnwrap(analysis.findings.first { $0.id == explanation.findingID }, file: file, line: line)
                XCTAssertEqual(explanation.title, finding.title, file: file, line: line)
                XCTAssertEqual(explanation.detail, finding.detail, file: file, line: line)
                XCTAssertEqual(explanation.facts, finding.observedFacts, file: file, line: line)
                XCTAssertEqual(explanation.inferences, finding.inferences, file: file, line: line)
                XCTAssertTrue(explanation.uncertainty.starts(with: finding.uncertainty), file: file, line: line)
                XCTAssertTrue(explanation.actions.contains { $0.id == ActionCatalog.keepAsIs.id }, file: file, line: line)
            }
        } catch { XCTFail("The actual adapter/fallback must remain bound to deterministic findings: \(error)", file: file, line: line) }
    }
}
