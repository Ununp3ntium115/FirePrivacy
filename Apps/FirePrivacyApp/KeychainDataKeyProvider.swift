import Foundation
import Security
import ObservationStore

/// Stores the root data key in the Keychain (§16.6).
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with no synchronization: the
/// key never leaves this device and never reaches a backup that could be
/// restored elsewhere.
public struct KeychainDataKeyProvider: DataKeyProviding {
    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case generationFailed
    }

    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func rootKey() throws -> [UInt8] {
        if let existing = try read() { return existing }
        return try generateAndStore()
    }

    public func destroyKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func read() throws -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return [UInt8](data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func generateAndStore() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainError.generationFailed
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(bytes),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return bytes
    }
}
