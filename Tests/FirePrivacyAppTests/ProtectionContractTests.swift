import XCTest
import CryptoKit
@testable import FirePrivacyApp
@testable import FirePrivacyCore

private struct RejectedProtectionAuthorization: ConsentAuthorizationChecking {
    func validateAuthorization(_ authorization: ConsentAuthorization) async -> Bool { false }
}

final class ProtectionContractTests: XCTestCase {
    func testSharedSafariArtifactAuthenticatesAndRejectsExpiredAuthorization() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let payload = try JSONEncoder().encode(["tracker.example.org"])
        let manifest = FilterDatasetManifest(version: 1, kind: .safariDomainsV1, tag: "native-fixture",
            issuedAtSeconds: Int64(now.timeIntervalSince1970) - 60, expiresAtSeconds: Int64(now.timeIntervalSince1970) + 3600,
            payloadSHA256: ContentDigest.sha256(payload), payloadByteCount: payload.count, keyID: "test-only")
        let dataset = SignedFilterDataset(manifest: manifest, payload: payload,
                                         signature: try key.signature(for: manifest.signedRepresentation()))
        let store = ProtectionArtifactStore(directory: directory, trustedKeys: ["test-only": key.publicKey.rawRepresentation])
        let config = try FilterDatasetVerifier.verify(dataset, trustedKeys: store.trustedKeys).safariConfiguration()
        try store.write(ProtectionArtifactStore.SafariEnvelope(configuration: config, signedDataset: dataset,
                                                                allowedUntil: now.addingTimeInterval(60)), named: "safari-rules.json")
        XCTAssertEqual(try store.validatedSafari(now: now).0, config)
        XCTAssertThrowsError(try store.validatedSafari(now: now.addingTimeInterval(61))) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .consentRevoked)
        }
        let changed = SafariRuleConfiguration(blockedDomains: ["different.example.org"], datasetVersion: 1)
        try store.write(ProtectionArtifactStore.SafariEnvelope(configuration: changed, signedDataset: dataset,
                                                                allowedUntil: now.addingTimeInterval(60)), named: "safari-rules.json")
        XCTAssertThrowsError(try store.validatedSafari(now: now)) {
            XCTAssertEqual($0 as? FilterDatasetError, .payloadMismatch)
        }
        try store.write(ProtectionArtifactStore.SafariEnvelope(configuration: config, signedDataset: dataset,
                                                                allowedUntil: now.addingTimeInterval(60)), named: "safari-rules.json")
        let document = FilterRevocationDocument(targetKind: .safariDomainsV1, revocations: .init(versions: [1]))
        let revocationPayload = try JSONEncoder().encode(document)
        let revocationManifest = FilterDatasetManifest(version: 1, kind: .revocationsV1, tag: "native-revocations",
            issuedAtSeconds: manifest.issuedAtSeconds, expiresAtSeconds: manifest.expiresAtSeconds,
            payloadSHA256: ContentDigest.sha256(revocationPayload), payloadByteCount: revocationPayload.count, keyID: "test-only")
        let raw = SignedFilterDataset(manifest: revocationManifest, payload: revocationPayload,
                                     signature: try key.signature(for: revocationManifest.signedRepresentation()))
        try store.installRevocations(FilterDatasetVerifier.verifyRevocationList(raw, trustedKeys: store.trustedKeys))
        XCTAssertThrowsError(try store.validatedSafari(now: now)) {
            XCTAssertEqual($0 as? FilterDatasetError, .revoked)
        }
    }

    @MainActor
    func testRevokedConsentRefusesDNSBeforeRequestingSystemConfiguration() async throws {
        let configuration = DNSResolverConfiguration(transport: .https, servers: ["1.1.1.1"],
            serverURL: URL(string: "https://resolver.example.org/dns-query")!, operatorName: "Fixture operator",
            privacyPolicyURL: URL(string: "https://resolver.example.org/privacy")!, loggingDisclosure: "Fixture policy",
            retentionDisclosure: "Fixture retention", jurisdictionDisclosure: "Fixture region", filteringDisclosure: "Encryption only")
        var state = ConsentState()
        let receipt = try state.grant(.encryptedDNS, disclosureVersion: ConsentDisclosure.currentVersion,
                                      scopeIdentity: configuration.scopeIdentity, at: Date(), appVersion: "test", osVersion: "test")
        let proof = ConsentAuthorization(receipt: receipt, generation: state.generation)
        do {
            _ = try await ProtectionService().enableDNS(configuration: configuration,
                    authorization: proof, checker: RejectedProtectionAuthorization())
            XCTFail("Revoked authority must never configure system DNS")
        } catch {
            XCTAssertEqual(error as? ProtectionConfigurationError, .consentRequired)
        }
    }
}
