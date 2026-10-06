import Foundation
import FirePrivacyCore
#if canImport(Security)
import Security
#endif
import XCTest
@testable import FirePrivacyApp

final class AdvisorCredentialStoreTests: XCTestCase {
    @MainActor
    func testReadDoesNotRetainAndConfigurationsHaveSeparateCredentials() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let first = try configuration()
        let second = try configuration(model: "other-reviewed-model")
        let epoch = await store.currentGeneration()
        let absent = try await store.token(for: first, expectedGeneration: epoch)
        XCTAssertNil(absent)
        let readOnlyCounts = await provider.counts()
        XCTAssertEqual(readOnlyCounts[.store], nil)

        try await store.retain("fixture.first-token", for: first, expectedGeneration: epoch)
        try await store.retain("fixture.second-token", for: second, expectedGeneration: epoch)
        let firstRead = try await store.token(for: first, expectedGeneration: epoch)
        let secondRead = try await store.token(for: second, expectedGeneration: epoch)
        XCTAssertTrue(firstRead == "fixture.first-token")
        XCTAssertTrue(secondRead == "fixture.second-token")
        let identities = await provider.identities()
        XCTAssertEqual(identities, Set([first.identity, second.identity]))

        try await store.retain("fixture.replacement-token", for: first, expectedGeneration: epoch)
        let replacement = try await store.token(for: first, expectedGeneration: epoch)
        let unchanged = try await store.token(for: second, expectedGeneration: epoch)
        XCTAssertTrue(replacement == "fixture.replacement-token")
        XCTAssertTrue(unchanged == "fixture.second-token")
    }

    @MainActor
    func testEveryConfigurationFieldScopesCredentialIdentity() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let original = try configuration()
        let epoch = await store.currentGeneration()
        try await store.retain("fixture.scoped-token", for: original, expectedGeneration: epoch)
        let variants = [
            try configuration(endpoint: "https://advisor.example.invalid/other"),
            try configuration(model: "different-model"),
            try configuration(retention: "Different retention disclosure."),
            try configuration(pin: String(repeating: "a", count: 64))
        ]
        for variant in variants {
            XCTAssertNotEqual(variant.identity, original.identity)
            let token = try await store.token(for: variant, expectedGeneration: epoch)
            XCTAssertNil(token)
        }
    }

    @MainActor
    func testRejectsInvalidTokensBeforeProviderMutationAndAcceptsBoundary() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let config = try configuration()
        let epoch = await store.currentGeneration()
        let invalid = ["", "has space", "tab\tvalue", "newline\nvalue", "nul\u{0}value",
                       "delete\u{7f}value", "nonascii-é", String(repeating: "a", count: 8_193)]
        for token in invalid {
            do {
                try await store.retain(token, for: config, expectedGeneration: epoch)
                XCTFail("Invalid token must not be retained.")
            } catch { XCTAssertEqual(error as? AdvisorCredentialError, .invalidToken) }
        }
        let rejectedCounts = await provider.counts()
        XCTAssertEqual(rejectedCounts[.store], nil)
        let boundary = String(repeating: "a", count: 8_192)
        try await store.retain(boundary, for: config, expectedGeneration: epoch)
        let returned = try await store.token(for: config, expectedGeneration: epoch)
        XCTAssertTrue(returned == boundary)
    }

    @MainActor
    func testMalformedStoredCredentialIsRejectedWithoutPrintingIt() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let config = try configuration()
        let epoch = await store.currentGeneration()
        for bytes in [Data([0xff]), Data("fixture\nvalue".utf8), Data(repeating: 65, count: 8_193)] {
            await provider.inject(bytes, identity: config.identity)
            do {
                _ = try await store.token(for: config, expectedGeneration: epoch)
                XCTFail("Malformed stored credential must not reach request preparation.")
            } catch { XCTAssertEqual(error as? AdvisorCredentialError, .invalidToken) }
        }
    }

    @MainActor
    func testProviderErrorsHaveSanitizedVisibleFailures() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let config = try configuration()
        let epoch = await store.currentGeneration()
        await provider.setFailure(.store, enabled: true)
        do {
            try await store.retain("fixture.token", for: config, expectedGeneration: epoch)
            XCTFail("Failed persistence must be visible.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .storageFailed) }
        await provider.setFailure(.read, enabled: true)
        do {
            _ = try await store.token(for: config, expectedGeneration: epoch)
            XCTFail("Failed credential read must be visible.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .readFailed) }
    }

    @MainActor
    func testIndividualEraseFailureBlocksThatIdentityAndRetryInvalidatesOldEpoch() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let config = try configuration()
        let other = try configuration(model: "other-reviewed-model")
        let epoch = await store.currentGeneration()
        try await store.retain("fixture.first", for: config, expectedGeneration: epoch)
        try await store.retain("fixture.other", for: other, expectedGeneration: epoch)
        await provider.setFailure(.delete, enabled: true)
        do {
            try await store.erase(for: config, expectedGeneration: epoch)
            XCTFail("Failed individual deletion must be visible.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .deletionFailed) }
        let afterFailure = await store.currentGeneration()
        XCTAssertNotEqual(epoch, afterFailure)
        do {
            _ = try await store.token(for: config, expectedGeneration: afterFailure)
            XCTFail("A credential awaiting cleanup must not be read.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .cleanupPending) }
        do {
            try await store.retain("fixture.new", for: config, expectedGeneration: afterFailure)
            XCTFail("A credential awaiting cleanup must not be replaced.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .cleanupPending) }
        let unaffected = try await store.token(for: other, expectedGeneration: afterFailure)
        XCTAssertTrue(unaffected == "fixture.other")
        await provider.setFailure(.delete, enabled: false)
        try await store.erase(for: config, expectedGeneration: afterFailure)
        let afterRetry = await store.currentGeneration()
        let deleted = try await store.token(for: config, expectedGeneration: afterRetry)
        XCTAssertNil(deleted)
        do {
            try await store.retain("fixture.late", for: config, expectedGeneration: epoch)
            XCTFail("Old user actions must not recreate an erased credential.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .staleOperation) }
    }

    @MainActor
    func testDeleteAllFailureRemainsDisabledUntilSuccessfulRetryAndExplicitResume() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let config = try configuration()
        let epoch = await store.currentGeneration()
        try await store.retain("fixture.token", for: config, expectedGeneration: epoch)
        await provider.setFailure(.deleteAll, enabled: true)
        do {
            try await store.disableAndEraseAll()
            XCTFail("Failed delete-all must be visible.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .deletionFailed) }
        let failedEpoch = await store.currentGeneration()
        do {
            try await store.resumeAfterDeletion(expectedGeneration: failedEpoch)
            XCTFail("Failed delete-all must not permit resume.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .cleanupPending) }
        do {
            _ = try await store.token(for: config, expectedGeneration: failedEpoch)
            XCTFail("Failed cleanup must block saved credential use.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .cleanupPending) }
        await provider.setFailure(.deleteAll, enabled: false)
        try await store.disableAndEraseAll()
        let clearedEpoch = await store.currentGeneration()
        do {
            try await store.retain("fixture.new", for: config, expectedGeneration: clearedEpoch)
            XCTFail("Successful cleanup must still require explicit resume.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .cleanupPending) }
        let remainingIdentities = await provider.identities()
        XCTAssertTrue(remainingIdentities.isEmpty)
        try await store.resumeAfterDeletion(expectedGeneration: clearedEpoch)
        let absent = try await store.token(for: config, expectedGeneration: clearedEpoch)
        XCTAssertNil(absent)
        try await store.retain("fixture.new", for: config, expectedGeneration: clearedEpoch)
    }

    @MainActor
    func testDeleteAllSerializesAfterSuspendedWriteAndPreventsResurrection() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let config = try configuration()
        let epoch = await store.currentGeneration()
        await provider.suspendNext(.store)
        let saving = Task { try await store.retain("fixture.late", for: config, expectedGeneration: epoch) }
        await provider.waitUntilSuspended()
        defer { Task { await provider.resumeSuspended() } }
        let deletion = Task { try await store.disableAndEraseAll() }
        let disabledEpoch = try await changedGeneration(store, from: epoch)
        do {
            _ = try await store.token(for: config, expectedGeneration: disabledEpoch)
            XCTFail("Delete-all disables reads before waiting for a suspended provider.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .cleanupPending) }
        await provider.resumeSuspended()
        do {
            try await saving.value
            XCTFail("A save crossing deletion must expire.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .staleOperation) }
        try await deletion.value
        let remainingIdentities = await provider.identities()
        let operationOrder = await provider.operationOrder()
        XCTAssertTrue(remainingIdentities.isEmpty)
        XCTAssertEqual(operationOrder, [.store, .deleteAll])
        try await store.resumeAfterDeletion(expectedGeneration: disabledEpoch)
        let absent = try await store.token(for: config, expectedGeneration: disabledEpoch)
        XCTAssertNil(absent)
    }

    @MainActor
    func testIndividualEraseInvalidatesSuspendedReadBeforeReturningToken() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let config = try configuration()
        let epoch = await store.currentGeneration()
        try await store.retain("fixture.token", for: config, expectedGeneration: epoch)
        await provider.suspendNext(.read)
        let reading = Task { try await store.token(for: config, expectedGeneration: epoch) }
        await provider.waitUntilSuspended()
        defer { Task { await provider.resumeSuspended() } }
        let deletion = Task { try await store.erase(for: config, expectedGeneration: epoch) }
        _ = try await changedGeneration(store, from: epoch)
        await provider.resumeSuspended()
        do {
            _ = try await reading.value
            XCTFail("An in-flight read must not return a credential after erase starts.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .staleOperation) }
        try await deletion.value
        let remainingIdentities = await provider.identities()
        XCTAssertTrue(remainingIdentities.isEmpty)
    }

    @MainActor
    func testOverlappingDeleteAllCannotResumeWhileLatestDeletionIsPending() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let originalEpoch = await store.currentGeneration()
        await provider.suspendNext(.deleteAll)
        let first = Task { try await store.disableAndEraseAll() }
        await provider.waitUntilSuspended()
        defer { Task { await provider.resumeSuspended() } }
        let firstEpoch = try await changedGeneration(store, from: originalEpoch)
        let second = Task { try await store.disableAndEraseAll() }
        let secondEpoch = try await changedGeneration(store, from: firstEpoch)
        await provider.suspendNext(.deleteAll)
        await provider.resumeSuspended()
        do {
            try await first.value
            XCTFail("An earlier cleanup cannot acknowledge a later deletion epoch.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .staleOperation) }
        await provider.waitUntilSuspended()
        do {
            try await store.resumeAfterDeletion(expectedGeneration: secondEpoch)
            XCTFail("A later suspended cleanup must still block resume.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .cleanupPending) }
        await provider.resumeSuspended()
        try await second.value
        try await store.resumeAfterDeletion(expectedGeneration: secondEpoch)
    }

    @MainActor
    func testCancelledQueuedRetentionDoesNotWriteAfterProviderBecomesAvailable() async throws {
        let provider = MemoryAdvisorCredentials()
        let store = AdvisorCredentialStore(provider: provider)
        let config = try configuration()
        let epoch = await store.currentGeneration()
        await provider.suspendNext(.read)
        let reading = Task { try await store.token(for: config, expectedGeneration: epoch) }
        await provider.waitUntilSuspended()
        defer { Task { await provider.resumeSuspended() } }
        let saving = Task { try await store.retain("fixture.cancelled", for: config, expectedGeneration: epoch) }
        saving.cancel()
        await provider.resumeSuspended()
        _ = try await reading.value
        do {
            try await saving.value
            XCTFail("A cancelled queued save must not write a credential.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let counts = await provider.counts()
        XCTAssertNil(counts[.store])
    }

    #if canImport(Security)
    @MainActor
    func testRealKeychainUsesDeviceOnlyUnlockedNonSyncExactAccountsAndScopedDeletion() async throws {
        let service = "FirePrivacyAdvisorCredentialTests.\(UUID().uuidString)"
        let provider = KeychainAdvisorCredentialProvider(service: service)
        let otherService = service + ".unrelated"
        let unrelated = KeychainAdvisorCredentialProvider(service: otherService)
        // Synchronous best-effort final cleanup uses exact isolated test services.
        // No raw values or attributes are included in assertion diagnostics.
        defer {
            for ownedService in [service, otherService] {
                let cleanup: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: ownedService, kSecAttrSynchronizable as String: false]
                _ = SecItemDelete(cleanup as CFDictionary)
            }
        }
        let first = try configuration().identity
        let second = try configuration(model: "other-reviewed-model").identity
        let bytes = Data("synthetic.keychain-test-token".utf8)
        try await provider.store(bytes, identity: first)
        try await provider.store(bytes, identity: second)
        try await unrelated.store(bytes, identity: first)
        let result = try await provider.read(identity: first)
        XCTAssertTrue(result == bytes)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: first,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var attributesResult: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &attributesResult), errSecSuccess)
        guard let attributes = attributesResult as? [String: Any] else {
            XCTFail("Keychain must expose test item metadata."); return
        }
        XCTAssertTrue((attributes[kSecAttrAccessible as String] as? String) ==
                      (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
        XCTAssertTrue((attributes[kSecAttrAccount as String] as? String) == first)
        var synchronized = query
        synchronized[kSecAttrSynchronizable as String] = true
        XCTAssertEqual(SecItemCopyMatching(synchronized as CFDictionary, nil), errSecItemNotFound)
        let exactItem: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: first,
            kSecAttrSynchronizable as String: false]
        let weakerAccess: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        XCTAssertEqual(SecItemUpdate(exactItem as CFDictionary, weakerAccess as CFDictionary), errSecSuccess)
        do {
            _ = try await provider.read(identity: first)
            XCTFail("Read must reject an item with weaker unlock accessibility.")
        } catch { XCTAssertEqual(error as? AdvisorCredentialError, .readFailed) }
        try await provider.store(Data("synthetic.replacement-token".utf8), identity: first)
        let updated = try await provider.read(identity: first)
        XCTAssertTrue(updated == Data("synthetic.replacement-token".utf8))
        try await provider.delete(identity: first)
        let absent = try await provider.read(identity: first)
        let remaining = try await provider.read(identity: second)
        XCTAssertNil(absent)
        XCTAssertTrue(remaining == bytes)
        try await provider.deleteAll()
        let erased = try await provider.read(identity: second)
        let isolated = try await unrelated.read(identity: first)
        XCTAssertNil(erased)
        XCTAssertTrue(isolated == bytes)
    }
    #endif

    private func configuration(endpoint: String = "https://advisor.example.invalid/v1/chat",
                               model: String = "reviewed-model", retention: String = "Operator retains no requests.",
                               pin: String? = nil) throws -> SelfHostedAdvisorConfiguration {
        try SelfHostedAdvisorConfiguration(endpoint: URL(string: endpoint)!, modelName: model,
            retentionDisclosure: retention, certificateSHA256: pin)
    }

    @MainActor
    private func changedGeneration(_ store: AdvisorCredentialStore, from previous: UUID) async throws -> UUID {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let current = await store.currentGeneration()
            if current != previous { return current }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Credential deletion did not invalidate its epoch before awaiting the provider.")
        throw CredentialTestFailure.progressTimedOut
    }

}

private enum CredentialTestFailure: Error { case progressTimedOut }

/// Test-only provider. Recorded operations never include a credential value.
private actor MemoryAdvisorCredentials: AdvisorCredentialProvider {
    enum Operation: Hashable, Sendable { case read, store, delete, deleteAll }
    private var values: [String: Data] = [:]
    private var failures: Set<Operation> = []
    private var operations: [Operation] = []
    private var nextSuspension: Operation?
    private var suspended: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func read(identity: String) async throws -> Data? {
        try await begin(.read)
        return values[identity]
    }

    func store(_ token: Data, identity: String) async throws {
        try await begin(.store)
        values[identity] = token
    }

    func delete(identity: String) async throws {
        try await begin(.delete)
        values.removeValue(forKey: identity)
    }

    func deleteAll() async throws {
        try await begin(.deleteAll)
        values.removeAll()
    }

    func setFailure(_ operation: Operation, enabled: Bool) {
        if enabled { failures.insert(operation) } else { failures.remove(operation) }
    }

    func inject(_ bytes: Data, identity: String) { values[identity] = bytes }
    func identities() -> Set<String> { Set(values.keys) }
    func operationOrder() -> [Operation] { operations }
    func counts() -> [Operation: Int] { Dictionary(operations.map { ($0, 1) }, uniquingKeysWith: +) }
    func suspendNext(_ operation: Operation) { nextSuspension = operation }

    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resumeSuspended() {
        let continuation = suspended
        suspended = nil
        continuation?.resume()
    }

    private func begin(_ operation: Operation) async throws {
        operations.append(operation)
        if nextSuspension == operation {
            nextSuspension = nil
            await withCheckedContinuation { continuation in
                suspended = continuation
                for waiter in suspensionWaiters { waiter.resume() }
                suspensionWaiters.removeAll()
            }
        }
        if failures.contains(operation) {
            // An arbitrary provider error must not leak userInfo through the store.
            throw NSError(domain: "InjectedCredentialProvider", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "synthetic sensitive provider detail"])
        }
    }
}
