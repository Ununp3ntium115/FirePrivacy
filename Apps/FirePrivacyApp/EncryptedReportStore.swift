import CryptoKit
import Darwin
import Foundation
import FirePrivacyCore
import Security

enum ReportStoreError: LocalizedError, Equatable {
    case storageUnavailable
    case keyUnavailable
    case missingKey
    case invalidKey
    case invalidReport
    case unsupportedFormat
    case persistenceFailed
    case deletionFailed

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Protected local storage is unavailable. Unlock your device and try again."
        case .keyUnavailable:
            "The local encryption key is unavailable. Unlock your device and try again."
        case .missingKey, .invalidKey:
            "The saved report cannot be unlocked. Delete local data before saving a new report."
        case .invalidReport:
            "The saved report could not be verified. Delete local data before saving a new report."
        case .unsupportedFormat:
            "The saved report uses an unsupported format."
        case .persistenceFailed:
            "The report could not be saved securely. Your previous saved report has been preserved."
        case .deletionFailed:
            "Local data could not be completely deleted. Unlock your device and try again."
        }
    }
}

/// Providers must be safe to call from the store actor. `storeKey` must never
/// replace an existing key, since that would make an existing report unreadable.
protocol ReportKeyProvider: Sendable {
    func readKey() throws -> Data?
    func storeKey(_ key: Data) throws
    func deleteKey() throws
}

struct KeychainReportKeyProvider: ReportKeyProvider {
    private let service: String
    private let account = "encrypted-report-key-v1"

    init(service: String? = nil) {
        self.service = service ?? "\(Bundle.main.bundleIdentifier ?? "org.fireprivacy.app").local-report"
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func readKey() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ReportStoreError.keyUnavailable
        }
        return data
    }

    func storeKey(_ key: Data) throws {
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = key
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ReportStoreError.keyUnavailable
        }
    }

    func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReportStoreError.deletionFailed
        }
    }
}

/// One normalized report, authenticated and encrypted with a device-only key.
/// Raw imported bytes never enter this store.
actor EncryptedReportStore {
    private struct Envelope: Codable {
        let version: Int
        let sealedReport: Data
    }

    private static let formatVersion = 1
    private static let authenticatedContext = Data("FirePrivacy/PrivacyReport/v1".utf8)
    private static let maximumStoredBytes = 48 * 1_024 * 1_024
    private let injectedDirectoryURL: URL?
    private let keyProvider: any ReportKeyProvider
    private let fileManager = FileManager()

    init(directoryURL: URL? = nil, keyProvider: any ReportKeyProvider = KeychainReportKeyProvider()) {
        injectedDirectoryURL = directoryURL
        self.keyProvider = keyProvider
    }

    func load() throws -> PrivacyReport? {
        let directory = try directoryURL()
        let reportURL = directory.appendingPathComponent("report.encrypted", isDirectory: false)
        guard fileManager.fileExists(atPath: reportURL.path) else { return nil }
        guard let keyData = try keyProvider.readKey() else { throw ReportStoreError.missingKey }
        guard keyData.count == 32 else { throw ReportStoreError.invalidKey }

        let encoded: Data
        do {
            encoded = try ReportFileIO.readBoundedData(from: reportURL, maximumBytes: Self.maximumStoredBytes)
        } catch {
            throw ReportStoreError.storageUnavailable
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: encoded)
        } catch {
            throw ReportStoreError.invalidReport
        }
        guard envelope.version == Self.formatVersion else { throw ReportStoreError.unsupportedFormat }

        do {
            let sealed = try AES.GCM.SealedBox(combined: envelope.sealedReport)
            let cleartext = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: keyData),
                authenticating: Self.authenticatedContext
            )
            return try JSONDecoder().decode(PrivacyReport.self, from: cleartext)
        } catch {
            throw ReportStoreError.invalidReport
        }
    }

    func save(_ report: PrivacyReport) throws {
        let directory = try directoryURL()
        let reportURL = directory.appendingPathComponent("report.encrypted", isDirectory: false)
        // Fail closed if a previous report cannot be read. Do not silently
        // replace inaccessible or damaged data with a newly created key.
        if fileManager.fileExists(atPath: reportURL.path) { _ = try load() }
        try prepareDirectory(directory)

        let keyData: Data
        if let existing = try keyProvider.readKey() {
            guard existing.count == 32 else { throw ReportStoreError.invalidKey }
            keyData = existing
        } else {
            var random = Data(count: 32)
            let status = random.withUnsafeMutableBytes { bytes in
                guard let address = bytes.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
            }
            guard status == errSecSuccess else { throw ReportStoreError.keyUnavailable }
            // Persist the key before committing ciphertext. A failed write may
            // leave an unused key; keeping it permits a safe retry or deletion.
            try keyProvider.storeKey(random)
            keyData = random
        }

        let encrypted: Data
        do {
            let cleartext = try JSONEncoder().encode(report)
            let box = try AES.GCM.seal(
                cleartext,
                using: SymmetricKey(data: keyData),
                authenticating: Self.authenticatedContext
            )
            guard let combined = box.combined else { throw ReportStoreError.persistenceFailed }
            encrypted = try JSONEncoder().encode(Envelope(version: Self.formatVersion, sealedReport: combined))
            guard encrypted.count <= Self.maximumStoredBytes else { throw ReportStoreError.persistenceFailed }
        } catch {
            throw ReportStoreError.persistenceFailed
        }

        let stagedURL = directory.appendingPathComponent(".report-\(UUID().uuidString).encrypted")
        defer { try? fileManager.removeItem(at: stagedURL) }
        do {
            // The staged file receives protection and backup exclusion before
            // the atomic rename, so metadata failures cannot replace old data.
            try ReportFileIO.writeProtectedData(encrypted, to: stagedURL)
            let result = stagedURL.withUnsafeFileSystemRepresentation { source in
                reportURL.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination else { return Int32(-1) }
                    return Darwin.rename(source, destination)
                }
            }
            guard result == 0 else { throw ReportStoreError.persistenceFailed }
        } catch {
            throw ReportStoreError.persistenceFailed
        }
    }

    func deleteAll() throws {
        let directory = try directoryURL()
        // Remove the whole dedicated directory, including encrypted staging
        // files left by an interrupted write. If removal fails, preserve the
        // key so the report remains recoverable and propagate the failure.
        do {
            try ReportFileIO.removeAllExportFiles()
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        } catch {
            throw ReportStoreError.deletionFailed
        }
        // A failed key deletion is surfaced even after ciphertext was removed.
        // Retrying Delete All removes the remaining key without needing a file.
        do {
            try keyProvider.deleteKey()
        } catch {
            throw ReportStoreError.deletionFailed
        }
    }

    private func directoryURL() throws -> URL {
        if let injectedDirectoryURL { return injectedDirectoryURL }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ReportStoreError.storageUnavailable
        }
        return support.appendingPathComponent("FirePrivacy", isDirectory: true)
    }

    private func prepareDirectory(_ directory: URL) throws {
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
        } catch {
            throw ReportStoreError.storageUnavailable
        }
    }
}
