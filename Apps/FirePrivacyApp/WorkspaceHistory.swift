import Foundation
import FirePrivacyCore

struct WorkspaceRetentionPolicy: Codable, Equatable, Sendable {
    var maximumReports: Int = 10
    var maximumStoredBytes: Int = 64 * 1_024 * 1_024

    func validate() throws {
        guard (1...20).contains(maximumReports),
              (1_024 * 1_024...64 * 1_024 * 1_024).contains(maximumStoredBytes) else {
            throw ReportStoreError.invalidReport
        }
    }
}

struct ReportSessionDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let importedAt: Date
    let observationCount: Int
    let contactCount: Int
    let encryptedBytes: Int
    let encryptedSourceBytes: Int
    let sourceSHA256: String?

    var retainsEncryptedSource: Bool { encryptedSourceBytes > 0 }
}

struct EncryptedWorkspaceIndex: Codable, Sendable {
    let version: Int
    var selectedReportID: UUID?
    var sessions: [ReportSessionDescriptor]
    var retention: WorkspaceRetentionPolicy

    init() {
        version = 2
        selectedReportID = nil
        sessions = []
        retention = WorkspaceRetentionPolicy()
    }

    func validate() throws {
        try retention.validate()
        guard version == 2, sessions.count <= retention.maximumReports,
              Set(sessions.map(\.id)).count == sessions.count,
              sessions.allSatisfy({ $0.encryptedBytes > 0 && $0.encryptedSourceBytes >= 0 && $0.observationCount >= 0 && $0.contactCount >= 0 }),
              selectedReportID == nil || sessions.contains(where: { $0.id == selectedReportID }) else {
            throw ReportStoreError.invalidReport
        }
        var total = 0
        for item in sessions {
            for amount in [item.encryptedBytes, item.encryptedSourceBytes] {
                let (sum, overflow) = total.addingReportingOverflow(amount)
                guard !overflow, sum <= retention.maximumStoredBytes else { throw ReportStoreError.invalidReport }
                total = sum
            }
        }
    }
}

struct EncryptedWorkspaceSnapshot: Sendable {
    let selectedReport: PrivacyReport?
    let sessions: [ReportSessionDescriptor]
    let retention: WorkspaceRetentionPolicy
    let migratedLegacyReport: Bool
}
