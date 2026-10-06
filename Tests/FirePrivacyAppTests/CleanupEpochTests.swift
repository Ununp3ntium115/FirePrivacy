import Foundation
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp

final class CleanupEpochTests: XCTestCase {
    func testOldCredentialCleanupCannotClearNewSameIntent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let marker = CredentialCleanupMarker(directory: directory)
        try await marker.setRequired(true)
        let oldLease = await marker.currentGeneration()
        try await marker.setRequired(true, expectedGeneration: oldLease)
        let newLease = await marker.currentGeneration()
        let path = directory.appendingPathComponent("required")
        let bytes = try Data(contentsOf: path)

        do {
            try await marker.setRequired(false, expectedGeneration: oldLease)
            XCTFail("An earlier cleanup must not clear a repeated deletion request.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        let stillRequired = try await marker.isRequired()
        let leaseAfterRejection = await marker.currentGeneration()
        XCTAssertTrue(stillRequired)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertEqual(leaseAfterRejection, newLease)

        try await marker.setRequired(false, expectedGeneration: newLease)
        let requiredAfterClear = try await marker.isRequired()
        XCTAssertFalse(requiredAfterClear)
        XCTAssertFalse(FileManager().fileExists(atPath: directory.path))
    }

    func testFailedCredentialMarkerWriteInvalidatesOldCleanupLease() async throws {
        let root = temporaryDirectory()
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager().removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocked-parent")
        try Data([1]).write(to: blocker)
        let marker = CredentialCleanupMarker(directory: blocker.appendingPathComponent("marker"))
        let oldLease = await marker.currentGeneration()
        do {
            try await marker.setRequired(true, expectedGeneration: oldLease)
            XCTFail("A file cannot be used as the marker's parent directory.")
        } catch { }
        let newLease = await marker.currentGeneration()
        XCTAssertNotEqual(oldLease, newLease)
        do {
            try await marker.setRequired(false, expectedGeneration: oldLease)
            XCTFail("A failed mutation must invalidate an older cleanup completion.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }

        try FileManager().removeItem(at: blocker)
        try await marker.setRequired(true, expectedGeneration: newLease)
        let required = try await marker.isRequired()
        XCTAssertTrue(required)
    }

    func testMalformedCredentialMarkerReadPreservesIntentAndLease() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let marker = CredentialCleanupMarker(directory: directory)
        try await marker.setRequired(true)
        let lease = await marker.currentGeneration()
        let path = directory.appendingPathComponent("required")
        for bytes in [Data([48]), Data([49, 49])] {
            try bytes.write(to: path)
            do {
                _ = try await marker.isRequired()
                XCTFail("An invalid pending marker must not become a successful false result.")
            } catch { }
            let currentLease = await marker.currentGeneration()
            XCTAssertEqual(currentLease, lease)
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
        try await marker.setRequired(true, expectedGeneration: lease)
        let required = try await marker.isRequired()
        XCTAssertTrue(required)
    }

    func testOldProtectionCleanupCannotClearRepeatedOrExpandedIntent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let plan = ProtectionCleanupPlan(directory: directory)
        try await plan.save([.safariProtection])
        let oldLease = await plan.currentGeneration()
        try await plan.save([.safariProtection], expectedGeneration: oldLease)
        do {
            try await plan.save([], expectedGeneration: oldLease)
            XCTFail("A repeated same-feature removal is still a new intent.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        let repeatedLease = await plan.currentGeneration()
        try await plan.save([.safariProtection, .encryptedDNS], expectedGeneration: repeatedLease)
        let expandedLease = await plan.currentGeneration()
        let path = directory.appendingPathComponent("removal.json")
        let bytes = try Data(contentsOf: path)
        do {
            try await plan.save([.safariProtection], expectedGeneration: repeatedLease)
            XCTFail("An older completion must not drop a newly requested DNS removal.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        let pending = try await plan.load()
        let leaseAfterRejection = await plan.currentGeneration()
        XCTAssertEqual(pending, [.safariProtection, .encryptedDNS])
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertEqual(leaseAfterRejection, expandedLease)
        try await plan.save([.encryptedDNS], expectedGeneration: expandedLease)
        let remaining = try await plan.load()
        XCTAssertEqual(remaining, [.encryptedDNS])
    }

    func testFailedProtectionPlanWriteInvalidatesOldCleanupLease() async throws {
        let root = temporaryDirectory()
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager().removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocked-parent")
        try Data([1]).write(to: blocker)
        let plan = ProtectionCleanupPlan(directory: blocker.appendingPathComponent("plan"))
        let oldLease = await plan.currentGeneration()
        do {
            try await plan.save([.safariProtection], expectedGeneration: oldLease)
            XCTFail("A file cannot be used as the plan's parent directory.")
        } catch { }
        let newLease = await plan.currentGeneration()
        XCTAssertNotEqual(oldLease, newLease)
        do {
            try await plan.save([], expectedGeneration: oldLease)
            XCTFail("A failed write must invalidate older cleanup completions.")
        } catch { XCTAssertEqual(error as? ReportStoreError, .staleGeneration) }
        try FileManager().removeItem(at: blocker)
        try await plan.save([.safariProtection], expectedGeneration: newLease)
        let pending = try await plan.load()
        XCTAssertEqual(pending, [.safariProtection])
    }

    func testMalformedProtectionPlanReadPreservesIntentAndLease() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let plan = ProtectionCleanupPlan(directory: directory)
        try await plan.save([.encryptedDNS])
        let lease = await plan.currentGeneration()
        let path = directory.appendingPathComponent("removal.json")
        for bytes in [Data("[\"localImport\"]".utf8), Data(repeating: 65, count: 1_025)] {
            try bytes.write(to: path)
            do { _ = try await plan.load(); XCTFail("Malformed intent must remain a visible failure.") }
            catch { }
            let currentLease = await plan.currentGeneration()
            XCTAssertEqual(currentLease, lease)
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
        try await plan.save([.encryptedDNS], expectedGeneration: lease)
        let pending = try await plan.load()
        XCTAssertEqual(pending, [.encryptedDNS])
    }

    private func temporaryDirectory() -> URL {
        FileManager().temporaryDirectory.appendingPathComponent("FirePrivacyCleanupEpoch-" + UUID().uuidString)
    }
}
