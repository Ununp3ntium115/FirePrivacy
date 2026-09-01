import XCTest
@testable import ObservationStore
import ObservationCore
import FindingEngine
import KnowledgeBaseKit
import TestSupport

/// Records whether the key was destroyed, so "delete all" can be checked
/// end to end.
private final class SpyKeyProvider: DataKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var destroyed = false

    var wasDestroyed: Bool {
        lock.lock(); defer { lock.unlock() }
        return destroyed
    }

    func rootKey() throws -> [UInt8] { Array(repeating: 0x11, count: 32) }

    func destroyKey() throws {
        lock.lock(); defer { lock.unlock() }
        destroyed = true
    }
}

final class CryptoBoxTests: XCTestCase {
    func testEnvelopeRoundTripsThroughSerialization() throws {
        let envelope = CryptoEnvelope(
            keyVersion: 1,
            nonce: Array(repeating: 7, count: 12),
            ciphertext: Array(repeating: 3, count: 20),
            tag: Array(repeating: 9, count: 16)
        )
        let parsed = try CryptoEnvelope.parse(envelope.serialized())
        XCTAssertEqual(parsed, envelope)
    }

    func testRejectsTruncatedEnvelope() {
        XCTAssertThrowsError(try CryptoEnvelope.parse([1, 1, 12]))
        XCTAssertThrowsError(try CryptoEnvelope.parse([]))
    }

    func testRejectsUnknownEnvelopeVersion() {
        var bytes = CryptoEnvelope(keyVersion: 1, nonce: Array(repeating: 0, count: 12), ciphertext: [1], tag: Array(repeating: 0, count: 16)).serialized()
        bytes[0] = 99
        XCTAssertThrowsError(try CryptoEnvelope.parse(bytes)) { error in
            XCTAssertEqual(error as? CryptoBoxError, .unsupportedEnvelopeVersion(99))
        }
    }

    #if canImport(CryptoKit)
    func testSealAndOpen() throws {
        let box = CryptoBox(keyProvider: InMemoryDataKeyProvider())
        let plaintext = Array("a domain the user would not want leaked".utf8)
        let sealed = try box.seal(plaintext)
        XCTAssertNotEqual(sealed, plaintext)
        XCTAssertEqual(try box.open(sealed), plaintext)
    }

    func testTamperedCiphertextFailsAuthentication() throws {
        let box = CryptoBox(keyProvider: InMemoryDataKeyProvider())
        var sealed = try box.seal(Array("secret".utf8))
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try box.open(sealed)) { error in
            XCTAssertEqual(error as? CryptoBoxError, .decryptionFailed)
        }
    }

    func testADifferentKeyCannotRead() throws {
        let sealed = try CryptoBox(keyProvider: InMemoryDataKeyProvider(key: Array(repeating: 1, count: 32)))
            .seal(Array("secret".utf8))
        let other = CryptoBox(keyProvider: InMemoryDataKeyProvider(key: Array(repeating: 2, count: 32)))
        XCTAssertThrowsError(try other.open(sealed))
    }
    #endif
}

#if canImport(CryptoKit)
final class EncryptedObservationStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSession(label: String) -> StoredSession {
        let session = Fixtures.session(id: DeterministicUUID.make(namespace: .importSession, name: label))
        let snapshot = Fixtures.snapshot(
            network: [Fixtures.network(session: session, bundle: "com.example.app", host: "collect.tracker.example")],
            session: session
        )
        return StoredSession(
            snapshot: snapshot,
            findings: [],
            evidence: [:],
            scores: .empty,
            ruleSetVersion: "ruleset-test",
            knowledgeBaseVersion: Fixtures.knowledgeBaseVersion,
            evaluatedAt: Fixtures.referenceDate
        )
    }

    func testSavesAndLoads() async throws {
        let store = try EncryptedObservationStore(directory: directory, keyProvider: InMemoryDataKeyProvider())
        let session = makeSession(label: "one")
        try await store.save(session)

        let loaded = try await store.load(sessionID: session.snapshot.session.id)
        XCTAssertEqual(loaded.snapshot.networkObservations.count, 1)
        XCTAssertEqual(loaded.snapshot.session.id, session.snapshot.session.id)
    }

    /// The file on disk must not contain the domain in the clear.
    func testStoredFileIsNotReadableAsPlainText() async throws {
        let store = try EncryptedObservationStore(directory: directory, keyProvider: InMemoryDataKeyProvider())
        try await store.save(makeSession(label: "one"))

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let bytes = try Data(contentsOf: file)
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains("tracker.example"))
            XCTAssertFalse(text.contains("com.example.app"))
        }
    }

    func testDeletingOneSessionKeepsTheOthers() async throws {
        let store = try EncryptedObservationStore(directory: directory, keyProvider: InMemoryDataKeyProvider())
        let first = makeSession(label: "one")
        let second = makeSession(label: "two")
        try await store.save(first)
        try await store.save(second)

        let receipt = try await store.delete(scope: .session(first.snapshot.session.id))
        XCTAssertEqual(receipt.deletedSessionIDs, [first.snapshot.session.id])
        XCTAssertFalse(receipt.destroyedEncryptionKey)

        let remaining = await store.allSessionIDs()
        XCTAssertEqual(remaining, [second.snapshot.session.id])
    }

    func testDeleteEverythingRemovesFilesAndDestroysTheKey() async throws {
        let keyProvider = SpyKeyProvider()
        let store = try EncryptedObservationStore(directory: directory, keyProvider: keyProvider)
        try await store.save(makeSession(label: "one"))
        try await store.save(makeSession(label: "two"))

        let receipt = try await store.delete(scope: .everything)
        XCTAssertTrue(receipt.destroyedEncryptionKey)
        XCTAssertTrue(keyProvider.wasDestroyed)
        XCTAssertEqual(receipt.removedFileCount, 2)

        let remaining = await store.allSessionIDs()
        XCTAssertTrue(remaining.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }

    func testDeletionPreviewNamesWhatSurvives() async throws {
        let store = try EncryptedObservationStore(directory: directory, keyProvider: InMemoryDataKeyProvider())
        try await store.save(makeSession(label: "one"))

        let preview = try await store.previewDeletion(scope: .everything)
        XCTAssertEqual(preview.sessionCount, 1)
        XCTAssertEqual(preview.observationCount, 1)
        XCTAssertTrue(preview.notIncluded.contains { $0.contains("Protection") })
    }

    func testWorkIsRefusedWhileProtectedDataIsUnavailable() async throws {
        let store = try EncryptedObservationStore(directory: directory, keyProvider: InMemoryDataKeyProvider())
        await store.setProtectedDataAvailable(false)
        do {
            try await store.save(makeSession(label: "one"))
            XCTFail("expected the save to be refused")
        } catch {
            XCTAssertEqual(error as? ObservationStoreError, .protectedDataUnavailable)
        }
    }

    func testKnownSourceHashesSupportDuplicateDetection() async throws {
        let store = try EncryptedObservationStore(directory: directory, keyProvider: InMemoryDataKeyProvider())
        let session = makeSession(label: "one")
        try await store.save(session)
        let hashes = await store.knownSourceHashes()
        XCTAssertTrue(hashes.contains(session.snapshot.session.sourceHash))
    }
}
#endif
