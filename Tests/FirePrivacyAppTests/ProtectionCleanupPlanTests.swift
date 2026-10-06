import Foundation
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp

final class ProtectionCleanupPlanTests: XCTestCase {
    func testOnlyFeatureNamesSurvivePrivateDataRemovalAndCanBeRetried() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager().removeItem(at: directory) }
        let first = ProtectionCleanupPlan(directory: directory)
        try await first.save([.encryptedDNS, .safariProtection])
        let path = directory.appendingPathComponent("removal.json")
        let bytes = try Data(contentsOf: path)
        let decoded = try JSONDecoder().decode([String].self, from: bytes)
        XCTAssertEqual(Set(decoded), ["encryptedDNS", "safariProtection"])
        XCTAssertEqual(try path.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let restored = ProtectionCleanupPlan(directory: directory)
        let pending = try await restored.load()
        XCTAssertEqual(pending, [.encryptedDNS, .safariProtection])
        try await restored.save([.encryptedDNS])
        let remaining = try await first.load()
        XCTAssertEqual(remaining, [.encryptedDNS])
        try await restored.save([])
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
    }

    func testInvalidFeatureCannotOverwriteDurableRemovalPlan() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager().removeItem(at: directory) }
        let plan = ProtectionCleanupPlan(directory: directory)
        try await plan.save([.encryptedDNS])
        let path = directory.appendingPathComponent("removal.json")
        let previous = try Data(contentsOf: path)
        do {
            try await plan.save([.selfHostedAdvisor])
            XCTFail("Only OS feature identifiers may enter the independent cleanup plan.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .invalidReport) }
        XCTAssertEqual(try Data(contentsOf: path), previous)
    }

    func testMalformedAndOversizedPlanNeverSilentlyClearsPendingRemoval() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager().removeItem(at: directory) }
        let plan = ProtectionCleanupPlan(directory: directory)
        try await plan.save([.encryptedDNS])
        let path = directory.appendingPathComponent("removal.json")
        for bytes in [Data("[\"localImport\"]".utf8), Data(repeating: 65, count: 1_025)] {
            try bytes.write(to: path)
            do { _ = try await plan.load(); XCTFail("An invalid plan cannot become an empty successful result.") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }
}
