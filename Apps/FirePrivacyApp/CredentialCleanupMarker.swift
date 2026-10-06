import Foundation
import Darwin

/// A single pending-removal flag survives private-data deletion. It contains
/// no endpoint, account identity, token, consent receipt or encryption key.
actor CredentialCleanupMarker {
    private let directory: URL?
    private var generation = UUID()
    init(directory: URL? = nil) { self.directory = directory }

    func currentGeneration() -> UUID { generation }

    private func folder() throws -> URL {
        if let directory { return directory }
        guard let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ReportStoreError.storageUnavailable
        }
        return support.appendingPathComponent("FirePrivacyCredentialCleanup", isDirectory: true)
    }

    func isRequired() throws -> Bool {
        let url = try folder().appendingPathComponent("required")
        guard FileManager().fileExists(atPath: url.path) else { return false }
        guard try ReportFileIO.readBoundedData(from: url, maximumBytes: 1) == Data([49]) else {
            throw ReportStoreError.invalidReport
        }
        return true
    }

    func setRequired(_ required: Bool, expectedGeneration: UUID? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { throw ReportStoreError.staleGeneration }
        // Rotate before filesystem work so a failed update cannot leave an old
        // cleanup completion authorized to clear a newer removal attempt.
        generation = UUID()
        let root = try folder()
        let manager = FileManager()
        if !required {
            if manager.fileExists(atPath: root.path) {
                try manager.removeItem(at: root)
                try RotationDurability.synchronizeDirectory(at: root.deletingLastPathComponent())
            }
            return
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        var protectedRoot = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        let staged = root.appendingPathComponent(".required-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        try ReportFileIO.writeProtectedData(Data([49]), to: staged)
        try RotationDurability.synchronizeFile(at: staged)
        let url = root.appendingPathComponent("required")
        let result = staged.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return Darwin.rename(source, target)
            }
        }
        guard result == 0 else { throw ReportStoreError.persistenceFailed }
        try RotationDurability.synchronizeDirectory(at: root)
    }
}
