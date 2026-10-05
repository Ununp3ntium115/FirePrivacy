import Foundation
import Darwin
import FirePrivacyCore

/// Only OS-feature names survive a partial removal. No report, endpoint,
/// credential, receipt, source hash or encryption key is stored here.
actor ProtectionCleanupPlan {
    private let injectedDirectory: URL?
    init(directory: URL? = nil) { injectedDirectory = directory }

    private func location() throws -> URL {
        if let injectedDirectory { return injectedDirectory.appendingPathComponent("removal.json") }
        guard let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ReportStoreError.storageUnavailable
        }
        return support.appendingPathComponent("FirePrivacyProtectionCleanup", isDirectory: true)
            .appendingPathComponent("removal.json")
    }

    func load() throws -> Set<ConsentFeature> {
        let url = try location()
        guard FileManager().fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([ConsentFeature].self,
            from: ReportFileIO.readBoundedData(from: url, maximumBytes: 1_024))
        let allowed: Set<ConsentFeature> = [.safariProtection, .encryptedDNS, .urlProtection, .managedProtection]
        guard values.count <= 4, Set(values).isSubset(of: allowed) else { throw ReportStoreError.invalidReport }
        return Set(values)
    }

    func save(_ features: Set<ConsentFeature>) throws {
        let allowed: Set<ConsentFeature> = [.safariProtection, .encryptedDNS, .urlProtection, .managedProtection]
        guard features.isSubset(of: allowed) else { throw ReportStoreError.invalidReport }
        let url = try location()
        if features.isEmpty {
            if FileManager().fileExists(atPath: url.deletingLastPathComponent().path) {
                try FileManager().removeItem(at: url.deletingLastPathComponent())
            }
            return
        }
        let folder = url.deletingLastPathComponent()
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try FileManager().setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
        var protectedFolder = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedFolder.setResourceValues(values)
        let data = try JSONEncoder().encode(features.sorted { $0.rawValue < $1.rawValue })
        let staged = folder.appendingPathComponent(".removal-\(UUID().uuidString).json")
        defer { try? FileManager().removeItem(at: staged) }
        try ReportFileIO.writeProtectedData(data, to: staged)
        // Atomic rename preserves the previous retry plan if the new write fails.
        let result = staged.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return Int32(-1) }
                return Darwin.rename(source, destination)
            }
        }
        guard result == 0 else { throw ReportStoreError.persistenceFailed }
    }
}
