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
    var pendingCleanup: [CiphertextCleanupTask]

    init() {
        version = 2
        selectedReportID = nil
        sessions = []
        retention = WorkspaceRetentionPolicy()
        pendingCleanup = []
    }

    func validate() throws {
        try retention.validate()
        guard version == 2, sessions.count <= retention.maximumReports,
              pendingCleanup.count <= 256, Set(pendingCleanup.map(\.id)).count == pendingCleanup.count,
              Set(sessions.map(\.id)).count == sessions.count,
              sessions.allSatisfy({ $0.encryptedBytes > 0 && $0.encryptedSourceBytes >= 0 && $0.observationCount >= 0 && $0.contactCount >= 0 }),
              selectedReportID == nil || sessions.contains(where: { $0.id == selectedReportID }) else {
            throw ReportStoreError.invalidReport
        }
        for task in pendingCleanup {
            try task.validate()
            if task.kind == .historyReport, sessions.contains(where: { $0.id == task.identifier }) { throw ReportStoreError.invalidReport }
            if task.kind == .rawSource, sessions.contains(where: { $0.id == task.identifier && $0.retainsEncryptedSource }) { throw ReportStoreError.invalidReport }
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
    private enum CodingKeys: String, CodingKey { case version, selectedReportID, sessions, retention, pendingCleanup }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        selectedReportID = try c.decodeIfPresent(UUID.self, forKey: .selectedReportID)
        sessions = try c.decode([ReportSessionDescriptor].self, forKey: .sessions)
        retention = try c.decode(WorkspaceRetentionPolicy.self, forKey: .retention)
        pendingCleanup = try c.decodeIfPresent([CiphertextCleanupTask].self, forKey: .pendingCleanup) ?? []
    }
}

struct CiphertextCleanupTask: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case historyReport, rawSource, legacyReport, stagedRoot, stagedHistory, stagedFeature, legacyStaged }
    let kind: Kind
    let identifier: UUID?
    let encryptedBytes: Int
    var id: String { relativePath }
    var relativePath: String {
        if kind == .legacyReport { return "report.encrypted" }
        guard let identifier else { return "" }
        switch kind {
        case .historyReport: return "history/\(identifier.uuidString).encrypted"
        case .rawSource: return "history/\(identifier.uuidString).source.encrypted"
        case .stagedRoot: return ".staged-\(identifier.uuidString).encrypted"
        case .stagedHistory: return "history/.staged-\(identifier.uuidString).encrypted"
        case .stagedFeature: return "features/.staged-\(identifier.uuidString).encrypted"
        case .legacyStaged: return ".report-\(identifier.uuidString).encrypted"
        case .legacyReport: return "report.encrypted"
        }
    }
    func validate() throws {
        guard encryptedBytes >= 0, !relativePath.isEmpty,
              kind == .legacyReport ? identifier == nil : identifier != nil else { throw ReportStoreError.invalidReport }
    }
}

struct EncryptedWorkspaceSnapshot: Sendable {
    let selectedReport: PrivacyReport?
    let sessions: [ReportSessionDescriptor]
    let retention: WorkspaceRetentionPolicy
    let migratedLegacyReport: Bool
    var pendingCleanupCount: Int = 0
}

enum FeatureStatePrecondition: Equatable, Sendable {
    case absent
    case checksum(String)
}

struct FeatureStateSnapshot<Value: Codable & Sendable>: Sendable {
    let value: Value?
    let precondition: FeatureStatePrecondition
}
