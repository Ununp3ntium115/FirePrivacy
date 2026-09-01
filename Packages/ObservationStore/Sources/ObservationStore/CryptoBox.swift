import Foundation
import ObservationCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Supplies the symmetric key that protects local data (§16.6).
///
/// The app implements this over the Keychain with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and no iCloud
/// synchronization. Tests use an in-memory implementation.
public protocol DataKeyProviding: Sendable {
    /// 32 raw bytes.
    func rootKey() throws -> [UInt8]
    /// Deletes the key. "Delete all" removes the key as well as the ciphertext,
    /// so anything missed is unreadable (TRU-002).
    func destroyKey() throws
}

public enum CryptoBoxError: Error, Sendable, Equatable {
    case unavailableOnThisPlatform
    case invalidKeyLength
    case decryptionFailed
    case malformedEnvelope
    case unsupportedEnvelopeVersion(Int)
}

/// AES-GCM envelope with a version byte, so keys can be rotated and old records
/// migrated transactionally (§16.6).
public struct CryptoEnvelope: Sendable, Hashable {
    public static let currentVersion = 1

    public let version: Int
    public let keyVersion: Int
    public let nonce: [UInt8]
    public let ciphertext: [UInt8]
    public let tag: [UInt8]

    public init(version: Int = CryptoEnvelope.currentVersion, keyVersion: Int, nonce: [UInt8], ciphertext: [UInt8], tag: [UInt8]) {
        self.version = version
        self.keyVersion = keyVersion
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    /// `version(1) | keyVersion(1) | nonceLength(1) | nonce | tag(16) | ciphertext`
    public func serialized() -> [UInt8] {
        var bytes: [UInt8] = [UInt8(version), UInt8(keyVersion), UInt8(nonce.count)]
        bytes.append(contentsOf: nonce)
        bytes.append(contentsOf: tag)
        bytes.append(contentsOf: ciphertext)
        return bytes
    }

    public static func parse(_ bytes: [UInt8]) throws -> CryptoEnvelope {
        guard bytes.count > 3 else { throw CryptoBoxError.malformedEnvelope }
        let version = Int(bytes[0])
        guard version == currentVersion else { throw CryptoBoxError.unsupportedEnvelopeVersion(version) }
        let keyVersion = Int(bytes[1])
        let nonceLength = Int(bytes[2])
        let tagLength = 16
        guard bytes.count >= 3 + nonceLength + tagLength else { throw CryptoBoxError.malformedEnvelope }
        let nonce = Array(bytes[3..<(3 + nonceLength)])
        let tag = Array(bytes[(3 + nonceLength)..<(3 + nonceLength + tagLength)])
        let ciphertext = Array(bytes[(3 + nonceLength + tagLength)...])
        return CryptoEnvelope(version: version, keyVersion: keyVersion, nonce: nonce, ciphertext: ciphertext, tag: tag)
    }
}

/// Encrypts and decrypts local records.
public struct CryptoBox: Sendable {
    private let keyProvider: any DataKeyProviding
    private let keyVersion: Int

    public init(keyProvider: any DataKeyProviding, keyVersion: Int = 1) {
        self.keyProvider = keyProvider
        self.keyVersion = keyVersion
    }

    public func seal(_ plaintext: [UInt8]) throws -> [UInt8] {
        #if canImport(CryptoKit)
        let key = try symmetricKey()
        let sealed = try AES.GCM.seal(Data(plaintext), using: key)
        let envelope = CryptoEnvelope(
            keyVersion: keyVersion,
            nonce: Array(sealed.nonce),
            ciphertext: Array(sealed.ciphertext),
            tag: Array(sealed.tag)
        )
        return envelope.serialized()
        #else
        throw CryptoBoxError.unavailableOnThisPlatform
        #endif
    }

    public func open(_ bytes: [UInt8]) throws -> [UInt8] {
        #if canImport(CryptoKit)
        let envelope = try CryptoEnvelope.parse(bytes)
        let key = try symmetricKey()
        guard let nonce = try? AES.GCM.Nonce(data: Data(envelope.nonce)) else {
            throw CryptoBoxError.malformedEnvelope
        }
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(envelope.ciphertext), tag: Data(envelope.tag))
        guard let plaintext = try? AES.GCM.open(sealed, using: key) else {
            throw CryptoBoxError.decryptionFailed
        }
        return Array(plaintext)
        #else
        throw CryptoBoxError.unavailableOnThisPlatform
        #endif
    }

    #if canImport(CryptoKit)
    private func symmetricKey() throws -> SymmetricKey {
        let bytes = try keyProvider.rootKey()
        guard bytes.count == 32 else { throw CryptoBoxError.invalidKeyLength }
        return SymmetricKey(data: Data(bytes))
    }
    #endif
}

/// An in-memory key, used by tests and by previews. Never used in the app.
public struct InMemoryDataKeyProvider: DataKeyProviding {
    private let key: [UInt8]

    public init(key: [UInt8] = Array(repeating: 0x2A, count: 32)) {
        self.key = key
    }

    public func rootKey() throws -> [UInt8] { key }
    public func destroyKey() throws {}
}
