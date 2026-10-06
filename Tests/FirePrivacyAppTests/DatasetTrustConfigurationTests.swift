import Foundation
import CryptoKit
import FirePrivacyCore
import XCTest
@testable import FirePrivacyApp

final class DatasetTrustConfigurationTests: XCTestCase {
    private func key() -> Curve25519.Signing.PrivateKey { Curve25519.Signing.PrivateKey() }
    private func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func fixtureBundle(_ info: [String: Any]) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DatasetTrustTests-\(UUID().uuidString)", isDirectory: true)
        let location = root.appendingPathComponent("Configuration.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = "com.example.DatasetTrustTests.\(UUID().uuidString)"
        plist["CFBundlePackageType"] = "BNDL"
        plist["CFBundleName"] = "Configuration"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: location.appendingPathComponent("Info.plist"))
        return (try XCTUnwrap(Bundle(url: location)), root)
    }

    func testUnsetConfigurationPreservesBootstrapDatasetAcceptanceAndAnchorWindows() throws {
        let config = try DatasetTrustConfiguration()
        for original in KnowledgeBaseResources.trustAnchors {
            let merged = try XCTUnwrap(config.verifierAnchors.first { $0.keyID == original.keyID })
            XCTAssertEqual(merged.publicKey, original.publicKey)
            XCTAssertEqual(merged.validFrom, original.validFrom)
            XCTAssertEqual(merged.expiresAt, original.expiresAt)
        }
        let bundled = try KnowledgeBaseResources.loadBundled()
        XCTAssertNoThrow(try KnowledgeBaseVerifier(trustAnchors: config.verifierAnchors).verify(
            manifestData: bundled.manifestData, payloadData: bundled.payloadData, appVersion: "1.0.0"))
        let starter = try BundledProtectionDataset.safariStarter()
        XCTAssertNoThrow(try FilterDatasetVerifier.verify(starter.signedDataset, trustedKeys: config.publicFilterKeys))
        XCTAssertEqual(try DatasetPublicKeyConfiguration.parseMap(nil), [:])
        XCTAssertEqual(try DatasetPublicKeyConfiguration.parseMap(""), [:])
        XCTAssertEqual(try DatasetPublicKeyConfiguration.parseMap(" {} \n"), [:])
    }

    func testOperatorKnowledgeAnchorAcceptsRealNewSignatureWhileDefaultTrustRejectsIt() throws {
        let operatorKey = key(), id = "operator-knowledge-test"
        let configured = try DatasetTrustConfiguration(knowledgeBasePublicKeysJSON: json([id: hex(operatorKey.publicKey.rawRepresentation)]))
        let now = Int64(Date().timeIntervalSince1970)
        let payload = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "datasetVersion": "2.0.0", "sources": [], "classifications": []])
        var fields: [String: Any] = ["schemaVersion": 1, "datasetVersion": "2.0.0", "sequence": 2,
            "generatedAt": now, "expiresAt": now + 3600, "minimumAppVersion": "1.0.0", "recordCount": 0,
            "payloadSHA256": ContentDigest.sha256(payload), "signingKeyID": id, "signatureBase64": ""]
        let unsigned = try JSONDecoder().decode(KnowledgeBaseManifest.self,
            from: JSONSerialization.data(withJSONObject: fields))
        fields["signatureBase64"] = try operatorKey.signature(for: unsigned.signingRepresentation).base64EncodedString()
        let manifest = try JSONSerialization.data(withJSONObject: fields)
        XCTAssertNoThrow(try KnowledgeBaseVerifier(trustAnchors: configured.verifierAnchors).verify(
            manifestData: manifest, payloadData: payload, appVersion: "1.0.0"))
        XCTAssertThrowsError(try KnowledgeBaseVerifier(trustAnchors: KnowledgeBaseResources.trustAnchors).verify(
            manifestData: manifest, payloadData: payload, appVersion: "1.0.0"))
    }

    func testOperatorFilterAnchorWorksForDatasetAndProviderReauthentication() throws {
        let operatorKey = key(), id = "operator-filter-test"
        let configured = try DatasetTrustConfiguration(filterPublicKeysJSON: json([id: hex(operatorKey.publicKey.rawRepresentation)]))
        let issued = Int64(Date().timeIntervalSince1970)
        let payload = try JSONEncoder().encode(["fixture.github.com"])
        let manifest = FilterDatasetManifest(version: 2, kind: .safariDomainsV1, tag: "temporary-test",
            issuedAtSeconds: issued, expiresAtSeconds: issued + 3600,
            payloadSHA256: ContentDigest.sha256(payload), payloadByteCount: payload.count, keyID: id)
        let signed = SignedFilterDataset(manifest: manifest, payload: payload,
            signature: try operatorKey.signature(for: manifest.signedRepresentation()))
        let verified = try FilterDatasetVerifier.verify(signed, trustedKeys: configured.publicFilterKeys)
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(signed, trustedKeys: BundledProtectionDataset.trustedKeys()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DatasetTrustProviderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProtectionArtifactStore(directory: root, trustedKeys: configured.publicFilterKeys)
        try store.write(ProtectionArtifactStore.SafariEnvelope(configuration: verified.safariConfiguration(),
            signedDataset: signed, allowedUntil: Date().addingTimeInterval(1800)), named: "safari-rules.json")
        XCTAssertEqual(try store.validatedSafari().0.blockedDomains, ["fixture.github.com"])
        let unconfiguredProvider = ProtectionArtifactStore(directory: root, trustedKeys: try BundledProtectionDataset.trustedKeys())
        XCTAssertThrowsError(try unconfiguredProvider.validatedSafari())
    }

    func testAppAndProviderBundleParsingProduceExactSamePublicFilterKeys() throws {
        let kb = key(), filter = key()
        let (bundle, root) = try fixtureBundle([
            DatasetPublicKeyConfiguration.knowledgeInfoKey: json(["operator-kb": hex(kb.publicKey.rawRepresentation)]),
            DatasetPublicKeyConfiguration.filterInfoKey: json(["operator-filter": hex(filter.publicKey.rawRepresentation)])])
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try DatasetTrustConfiguration.load(bundle: bundle)
        let provider = try DatasetPublicKeyConfiguration.loadFilterKeys(bundle: bundle)
        XCTAssertEqual(app.publicFilterKeys, provider)
        XCTAssertEqual(app.verifierAnchors.first { $0.keyID == "operator-kb" }?.publicKey, kb.publicKey.rawRepresentation)
        XCTAssertEqual(provider["operator-filter"], filter.publicKey.rawRepresentation)
    }

    func testDuplicateRawAndEscapedJSONKeyNamesAreRejectedBeforeSelectingAuthority() throws {
        let value = hex(key().publicKey.rawRepresentation)
        for input in [#"{"operator":"\#(value)","operator":"\#(value)"}"#,
                      #"{"operator":"\#(value)","\u006fperator":"\#(value)"}"#] {
            XCTAssertThrowsError(try DatasetPublicKeyConfiguration.parseMap(input)) {
                XCTAssertEqual($0 as? DatasetTrustConfigurationError, .duplicateKeyID)
            }
        }
    }

    func testMalformedUnknownSchemaAndUnexpandedBuildValuesFailClosed() {
        for input in [" ", "[]", "null", "false", "$(FIREPRIVACY_KB_PUBLIC_KEYS_JSON)", "{} trailing",
                      #"{"operator":null}"#, #"{"operator":123}"#, #"{"operator":{}}"#,
                      #"{"operator":"abc",}"#, #"{"operator":"\uD800"}"#] {
            XCTAssertThrowsError(try DatasetPublicKeyConfiguration.parseMap(input))
        }
    }

    func testInvalidKeyBytesAndIdentifiersAreRejectedWithoutDroppingEntries() throws {
        let valid = hex(key().publicKey.rawRepresentation)
        for id in ["", "operator/key", "operator\nkey", "opérator", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try DatasetPublicKeyConfiguration.parseMap(json([id: valid])))
        }
        for value in [String(repeating: "0", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(try DatasetPublicKeyConfiguration.parseMap(json(["operator": value])))
        }
        XCTAssertThrowsError(try DatasetPublicKeyConfiguration.parseMap(json(["valid": valid, "invalid": "short"])))
    }

    func testConfiguredMapByteAndEntryBoundsAndSeparatePinnedCount() throws {
        XCTAssertThrowsError(try DatasetPublicKeyConfiguration.parseMap(String(repeating: " ", count: 16_385))) {
            XCTAssertEqual($0 as? DatasetTrustConfigurationError, .oversized)
        }
        let value = hex(key().publicKey.rawRepresentation)
        let keys = Dictionary(uniqueKeysWithValues: (0..<32).map { ("operator-\($0)", value) })
        XCTAssertEqual(try DatasetPublicKeyConfiguration.parseMap(json(keys)).count, 32)
        let pin = key().publicKey.rawRepresentation
        let maps = try DatasetPublicKeyConfiguration(knowledgeBaseJSON: json(keys), pinnedKnowledgeKeys: ["pin": pin], pinnedFilterKeys: [:])
        XCTAssertEqual(maps.knowledgeBaseKeys.count, 33)
        var excessive = keys; excessive["operator-32"] = value
        XCTAssertThrowsError(try DatasetPublicKeyConfiguration.parseMap(json(excessive)))
    }

    func testIdenticalPinnedKeyMergePreservesOriginalWindowsAndConflictsReject() throws {
        let pinnedKey = key().publicKey.rawRepresentation
        let anchor = KnowledgeBaseTrustAnchor(keyID: "pin", publicKey: pinnedKey, validFrom: 100, expiresAt: 1000)
        let config = try DatasetTrustConfiguration(knowledgeBasePublicKeysJSON: json(["pin": hex(pinnedKey)]),
            pinnedKnowledgeAnchors: [anchor], pinnedFilterKeys: [:])
        XCTAssertEqual(config.verifierAnchors.count, 1)
        XCTAssertEqual(config.verifierAnchors[0].validFrom, 100)
        XCTAssertEqual(config.verifierAnchors[0].expiresAt, 1000)
        XCTAssertThrowsError(try DatasetTrustConfiguration(knowledgeBasePublicKeysJSON: json(["pin": hex(key().publicKey.rawRepresentation)]),
            pinnedKnowledgeAnchors: [anchor], pinnedFilterKeys: [:])) {
            XCTAssertEqual($0 as? DatasetTrustConfigurationError, .pinnedKeyConflict)
        }
        XCTAssertThrowsError(try DatasetTrustConfiguration(pinnedKnowledgeAnchors: [anchor, anchor], pinnedFilterKeys: [:])) {
            XCTAssertEqual($0 as? DatasetTrustConfigurationError, .duplicateKeyID)
        }
    }

    func testCrossFamilyCollisionsRejectEvenSameBytesAndIncludeBootstrapIDs() throws {
        let value = hex(key().publicKey.rawRepresentation), mapping = try json(["same-id": value])
        XCTAssertThrowsError(try DatasetTrustConfiguration(knowledgeBasePublicKeysJSON: mapping,
            filterPublicKeysJSON: mapping, pinnedKnowledgeAnchors: [], pinnedFilterKeys: [:])) {
            XCTAssertEqual($0 as? DatasetTrustConfigurationError, .crossFamilyCollision)
        }
        let pin = try XCTUnwrap(KnowledgeBaseResources.trustAnchors.first)
        XCTAssertThrowsError(try DatasetTrustConfiguration(filterPublicKeysJSON: json([pin.keyID: hex(pin.publicKey)]))) {
            XCTAssertEqual($0 as? DatasetTrustConfigurationError, .crossFamilyCollision)
        }
    }

    func testWrongInfoTypesAndLegacyExtraAnchorsCannotCreateAnAlternateTrustPath() throws {
        for info: [String: Any] in [
            [DatasetPublicKeyConfiguration.filterInfoKey: ["operator": "not-a-string-map"]],
            [DatasetPublicKeyConfiguration.knowledgeInfoKey: 42],
            [DatasetPublicKeyConfiguration.legacyFilterInfoKey: ["unexpected-key": key().publicKey.rawRepresentation.base64EncodedString()]]
        ] {
            let (bundle, root) = try fixtureBundle(info)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try DatasetTrustConfiguration.load(bundle: bundle))
        }
        let pins = try BundledProtectionDataset.trustedKeys().mapValues { $0.base64EncodedString() }
        let (bundle, root) = try fixtureBundle([DatasetPublicKeyConfiguration.legacyFilterInfoKey: pins])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try DatasetPublicKeyConfiguration.loadFilterKeys(bundle: bundle), try BundledProtectionDataset.trustedKeys())
    }
}
