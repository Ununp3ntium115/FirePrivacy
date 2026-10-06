import Foundation
import FirePrivacyCore

enum ReportFileError: LocalizedError, Equatable {
    case unsupportedFile
    case unreadableFile
    case tooLarge
    case exportFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            "Choose a report file from Files."
        case .unreadableFile:
            "The report file could not be read. Try downloading it in Files first."
        case .tooLarge:
            "The report is larger than the 16 MB import limit. Choose a smaller report."
        case .exportFailed:
            "A protected export could not be created. Please try again."
        case .cleanupFailed:
            "The temporary export could not be removed. Try Delete All again."
        }
    }
}

enum ReportFileIO {
    static let maximumImportBytes = 16 * 1_024 * 1_024

    private struct ExportEnvelope: Encodable {
        let schemaVersion = 1
        let exportNotice = "This normalized report contains sensitive domains and app identifiers. Sharing may send it outside your device through the destination you choose. Share only with people you trust. Recorded contacts do not prove that personal data was transmitted."
        let isSyntheticDemo: Bool
        let report: PrivacyReport
    }

    /// Reads a Files-provider URL in bounded chunks; it never persists the raw
    /// import. Call from a detached task to keep file access off the main actor.
    static func readImportedData(from url: URL, maximumBytes: Int = maximumImportBytes) throws -> Data {
        guard url.isFileURL else { throw ReportFileError.unsupportedFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try readBoundedData(from: url, maximumBytes: maximumBytes)
    }

    static func readBoundedData(from url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, url.isFileURL else { throw ReportFileError.unsupportedFile }
        let handle: FileHandle
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ReportFileError.unsupportedFile }
            if let size = values.fileSize, size > maximumBytes { throw ReportFileError.tooLarge }
            handle = try FileHandle(forReadingFrom: url)
        } catch let error as ReportFileError {
            throw error
        } catch {
            throw ReportFileError.unreadableFile
        }
        defer { try? handle.close() }

        var data = Data()
        do {
            while true {
                // Reading one extra byte detects files that grew after the
                // initial size check without allocating an unbounded buffer.
                let remaining = maximumBytes - data.count
                let readSize = remaining >= 64 * 1_024 ? 64 * 1_024 : remaining + 1
                let chunk = try handle.read(upToCount: readSize) ?? Data()
                if chunk.isEmpty { break }
                guard chunk.count <= remaining else { throw ReportFileError.tooLarge }
                data.append(chunk)
            }
        } catch let error as ReportFileError {
            throw error
        } catch {
            throw ReportFileError.unreadableFile
        }
        return data
    }

    /// This is an explicit user-directed plaintext export. The share UI must
    /// warn about its contents and delete the URL when sharing finishes.
    static func makeExportFile(for report: PrivacyReport, isSyntheticDemo: Bool = false) throws -> URL {
        let fileManager = FileManager()
        let directory = fileManager.temporaryDirectory.appendingPathComponent("FirePrivacyExports", isDirectory: true)
        let url = directory.appendingPathComponent("FirePrivacy-\(UUID().uuidString).json")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(ExportEnvelope(isSyntheticDemo: isSyntheticDemo, report: report))
            try writeProtectedData(data, to: url)
            return url
        } catch {
            try? fileManager.removeItem(at: url)
            throw ReportFileError.exportFailed
        }
    }

    static func makeExportFile(data: Data, fileExtension: String) throws -> URL {
        guard ["json", "csv", "md"].contains(fileExtension), data.count <= 48 * 1_024 * 1_024 else {
            throw ReportFileError.exportFailed
        }
        let directory = FileManager().temporaryDirectory.appendingPathComponent("FirePrivacyExports", isDirectory: true)
        let url = directory.appendingPathComponent("FirePrivacy-\(UUID().uuidString).\(fileExtension)")
        do {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            try FileManager().setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            var folder = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            try writeProtectedData(data, to: url)
            return url
        } catch {
            try? FileManager().removeItem(at: url)
            throw ReportFileError.exportFailed
        }
    }

    static func removeExportFile(at url: URL) throws {
        do {
            if FileManager().fileExists(atPath: url.path) { try FileManager().removeItem(at: url) }
        } catch {
            throw ReportFileError.cleanupFailed
        }
    }

    /// Used at launch and by Delete All to clear exports left by termination.
    static func removeAllExportFiles() throws {
        let fileManager = FileManager()
        let directory = fileManager.temporaryDirectory.appendingPathComponent("FirePrivacyExports", isDirectory: true)
        do {
            if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        } catch {
            throw ReportFileError.cleanupFailed
        }
    }

    static func writeProtectedData(_ data: Data, to url: URL) throws {
        let fileManager = FileManager()
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else { throw ReportStoreError.persistenceFailed }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var protectedFile = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedFile.setResourceValues(values)
    }
}
