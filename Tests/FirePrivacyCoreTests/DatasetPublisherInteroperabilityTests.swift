import Foundation
import XCTest
@testable import FirePrivacyCore

// Process-based operator tooling is tested on the portable Linux/macOS hosts,
// never embedded into the iOS app. All private keys are unique temporary keys.
#if os(Linux) || os(macOS)
final class DatasetPublisherInteroperabilityTests: XCTestCase {
    private struct KnowledgeDownload: Decodable {
        let manifest: Data?
        let payload: Data?
        let revocations: SignedKnowledgeBaseRevocations?
        let rules: SignedRuleConfiguration?
    }
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // Do not include arguments, paths, key data or backend diagnostics.
            throw NSError(domain: "DatasetPublisherTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Publisher test command failed; credential details suppressed."])
        }
        return output
    }

    func testRealOperatorEnvelopesAndCanonicalBytesAreAcceptedBySwiftVerifiers() throws {
        let lookup = "import importlib.util,sys; s=importlib.util.spec_from_file_location('publisher',sys.argv[1]); p=importlib.util.module_from_spec(s); s.loader.exec_module(p); print(p.openssl_path() or '')"
        let selected = try command("/usr/bin/env", ["python3", "-c", lookup,
            repository.appendingPathComponent("scripts/publish-signed-datasets.py").path])
        let openssl = String(data: selected, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if openssl.isEmpty { throw XCTSkip("OpenSSL is genuinely unavailable on this host.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dataset-publisher-interop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("test-only-private.pem")
        _ = try command(openssl, ["genpkey", "-algorithm", "ED25519", "-out", key.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let der = try command(openssl, ["pkey", "-in", key.path, "-pubout", "-outform", "DER"])
        XCTAssertEqual(der.count, 44)
        let publicKey = Data(der.suffix(32)), keyID = "temporary-interop-key"
        let issued = Int64(Date().timeIntervalSince1970), expires = issued + 3600
        let now = Date(timeIntervalSince1970: Double(issued))
        let stamp = ISO8601DateFormatter().string(from: now)
        let citation = "https://github.com/Ununp3ntium115/FirePrivacy"
        let review: [String: Any] = ["schemaVersion": 1, "reviewer": "Synthetic test reviewer",
            "reviewedAtSeconds": issued, "changeSummary": "Temporary interoperability test only.",
            "sources": [["url": citation, "retrievedAtSeconds": issued,
                         "purpose": "Synthetic evidence fixture.", "license": "Synthetic data; no vendor claim."]]]
        let reviewPath = directory.appendingPathComponent("source-review.json")
        try JSONSerialization.data(withJSONObject: review, options: [.sortedKeys]).write(to: reviewPath)

        func publish(_ target: String, payload: Data, extra: [String]) throws -> URL {
            let input = directory.appendingPathComponent("input-\(UUID().uuidString)")
            try payload.write(to: input)
            let output = directory.appendingPathComponent("output-\(UUID().uuidString)", isDirectory: true)
            let arguments = [repository.appendingPathComponent("scripts/publish-signed-datasets.py").path,
                target, "--payload", input.path, "--private-key", key.path, "--key-id", keyID,
                "--review-record", reviewPath.path, "--endpoint", "https://github.com/Ununp3ntium115/FirePrivacy/raw/main/synthetic-only.json",
                "--output", output.path, "--issued-at", String(issued), "--expires-at", String(expires)] + extra
            _ = try command("/usr/bin/env", ["python3"] + arguments)
            let privatePEM = try Data(contentsOf: key)
            let artifacts = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            for artifact in artifacts {
                XCTAssertNil(try Data(contentsOf: artifact).range(of: privatePEM), "Private key was included in an artifact.")
            }
            return output
        }
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
        func bytes(_ directory: URL, _ filename: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(filename)) }

        let kbPayload: [String: Any] = ["schemaVersion": 1, "datasetVersion": "1.0.1",
            "sources": [["id": "synthetic", "title": "Synthetic café evidence", "url": citation,
                         "type": "internalReview", "retrievedAt": stamp, "excerpt": "Temporary test data only."]],
            "classifications": [["id": "synthetic", "pattern": "fixture.github.com", "patternKind": "exactHost",
                "categories": ["analytics"], "purposes": ["Test verifier interoperability."], "confidence": 0.5,
                "sourceIDs": ["synthetic"], "lastReviewed": stamp, "reviewStatus": "provisional",
                "notes": "This fixture is not a vendor classification."]]]
        let kbDirectory = try publish("kb", payload: json(kbPayload), extra: ["--sequence", "5", "--minimum-app-version", "1.0.0"])
        let download = try JSONDecoder().decode(KnowledgeDownload.self, from: bytes(kbDirectory, "download.json"))
        let manifest = try XCTUnwrap(download.manifest), payload = try XCTUnwrap(download.payload)
        let anchors = [KnowledgeBaseTrustAnchor(keyID: keyID, publicKey: publicKey)]
        let verifier = KnowledgeBaseVerifier(trustAnchors: anchors)
        let verified = try verifier.verify(manifestData: manifest, payloadData: payload, appVersion: "1.0.0", now: now)
        XCTAssertEqual(verified.payload.classifications.count, 1)
        XCTAssertEqual(verified.manifest.signingRepresentation, try bytes(kbDirectory, "signing-message.bin"))
        XCTAssertThrowsError(try verifier.verify(manifestData: manifest, payloadData: payload + Data([32]), appVersion: "1.0.0", now: now))
        var alteredManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        var badSignature = try XCTUnwrap(Data(base64Encoded: verified.manifest.signatureBase64))
        badSignature[0] ^= 1; alteredManifest["signatureBase64"] = badSignature.base64EncodedString()
        XCTAssertThrowsError(try verifier.verify(manifestData: json(alteredManifest), payloadData: payload, appVersion: "1.0.0", now: now))

        let revocationPayload: [String: Any] = ["schemaVersion": 1, "sequence": 3,
            "revokedVersions": ["0.9.0", "0.8.0"], "revokedKeyIDs": ["retired"],
            "revokedPayloadDigests": [String(repeating: "a", count: 64)]]
        let kbRevDirectory = try publish("kb-revocations", payload: json(revocationPayload), extra: ["--sequence", "3"])
        let revDownload = try JSONDecoder().decode(KnowledgeDownload.self, from: bytes(kbRevDirectory, "download.json"))
        let revocations = try XCTUnwrap(revDownload.revocations)
        let verifiedRevocations = try KnowledgeBaseRevocationVerifier(trustAnchors: anchors).verify(revocations, now: now)
        XCTAssertEqual(verifiedRevocations.manifest.signingRepresentation, try bytes(kbRevDirectory, "signing-message.bin"))
        XCTAssertEqual(verifiedRevocations.revocations.revokedVersions, ["0.8.0", "0.9.0"])
        XCTAssertThrowsError(try KnowledgeBaseRevocationVerifier(trustAnchors: anchors).verify(
            .init(manifestData: revocations.manifestData, payloadData: revocations.payloadData + Data([32])), now: now))

        let safariDirectory = try publish("filter", payload: json(["fixture.github.com"]),
            extra: ["--kind", "safariDomainsV1", "--version", "9007199254740993", "--tag", "synthetic"])
        let safari = try JSONDecoder().decode(SignedFilterDataset.self, from: bytes(safariDirectory, "download.json"))
        let keys = [keyID: publicKey]
        let validated = try FilterDatasetVerifier.verify(safari, trustedKeys: keys, now: now)
        XCTAssertEqual(validated.manifest.version, 9_007_199_254_740_993)
        XCTAssertEqual(try safari.manifest.signedRepresentation(), try bytes(safariDirectory, "signing-message.bin"))
        XCTAssertFalse(String(decoding: try safari.manifest.signedRepresentation(), as: UTF8.self).contains("null"))
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(.init(manifest: safari.manifest, payload: safari.payload + Data([32]), signature: safari.signature), trustedKeys: keys, now: now))
        var alteredSignature = safari.signature; alteredSignature[0] ^= 1
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(.init(manifest: safari.manifest, payload: safari.payload, signature: alteredSignature), trustedKeys: keys, now: now))

        let policy: [String: Any] = ["version": 7, "deploymentMode": "mdmPerApp", "expiresAtSeconds": issued + 1800,
            "rules": [["domain": "fixture.github.com", "includeSubdomains": true, "action": "drop", "appIdentifier": "com.example.test"],
                      ["domain": "needed.github.com", "includeSubdomains": false, "action": "allow"]]]
        let managedDirectory = try publish("filter", payload: json(policy), extra: ["--kind", "managedRulesV1", "--version", "7", "--tag", "synthetic-managed"])
        let managed = try JSONDecoder().decode(SignedFilterDataset.self, from: bytes(managedDirectory, "download.json"))
        XCTAssertEqual(try managed.manifest.signedRepresentation(), try bytes(managedDirectory, "signing-message.bin"))
        XCTAssertNoThrow(try FilterDatasetVerifier.verify(managed, trustedKeys: keys, now: now))

        let bloom = try AppleURLBloomFilter(items: ["fixture.github.com"], murmurSeed: 77)
        let bloomDirectory = try publish("filter", payload: bloom.data, extra: ["--kind", "appleURLBloomV1", "--version", "8", "--tag", "synthetic-bloom",
            "--bit-count", String(bloom.bitCount), "--hash-count", String(bloom.hashCount), "--murmur-seed", "77",
            "--pir-server-url", "https://github.com/operator/synthetic-pir", "--privacy-pass-issuer-url", "https://github.com/operator/synthetic-issuer",
            "--apple-configuration-identity", "synthetic-not-an-approval"])
        let signedBloom = try JSONDecoder().decode(SignedFilterDataset.self, from: bytes(bloomDirectory, "download.json"))
        XCTAssertEqual(try signedBloom.manifest.signedRepresentation(), try bytes(bloomDirectory, "signing-message.bin"))
        XCTAssertNoThrow(try FilterDatasetVerifier.verify(signedBloom, trustedKeys: keys, now: now))

        let filterRevPayload: [String: Any] = ["targetKind": "safariDomainsV1", "revocations": ["keyIDs": ["retired"], "versions": [1, 2], "payloadDigests": [String(repeating: "b", count: 64)]]]
        let filterRevDirectory = try publish("filter-revocations", payload: json(filterRevPayload), extra: ["--version", "9", "--tag", "synthetic-revocation"])
        let filterRev = try JSONDecoder().decode(SignedFilterDataset.self, from: bytes(filterRevDirectory, "download.json"))
        XCTAssertEqual(try filterRev.manifest.signedRepresentation(), try bytes(filterRevDirectory, "signing-message.bin"))
        let filterRevVerified = try FilterDatasetVerifier.verifyRevocationList(filterRev, trustedKeys: keys, now: now)
        XCTAssertEqual(filterRevVerified.document.revocations.versions, [1, 2])
        XCTAssertThrowsError(try FilterDatasetVerifier.verifyRevocationList(filterRev, trustedKeys: [:], now: now))

        let config = try DeclarativeRuleConfiguration(version: "1.0.1", rules: VersionedRuleSet.defaultConfiguration.rules)
        let ruleDirectory = try publish("rules", payload: config.encoded(), extra: ["--sequence", "6", "--minimum-app-version", "1.0.0"])
        let ruleDownload = try JSONDecoder().decode(KnowledgeDownload.self, from: bytes(ruleDirectory, "download.json"))
        let signedRules = try XCTUnwrap(ruleDownload.rules)
        let rulesVerifier = RuleConfigurationVerifier(trustAnchors: anchors)
        let checkedRules = try rulesVerifier.verify(signedRules, appVersion: "1.0.0", now: now)
        XCTAssertEqual(checkedRules.configuration, config)
        XCTAssertEqual(signedRules.manifest.signingRepresentation, try bytes(ruleDirectory, "signing-message.bin"))
        XCTAssertEqual(try signedRules.manifest.encoded(), try bytes(ruleDirectory, "manifest.json"))
        XCTAssertEqual(checkedRules.manifestSHA256, ContentDigest.sha256(try bytes(ruleDirectory, "manifest.json")))
        XCTAssertThrowsError(try rulesVerifier.verify(.init(manifest: signedRules.manifest,
            payloadData: signedRules.payloadData + Data([32])), appVersion: "1.0.0", now: now))
        XCTAssertThrowsError(try rulesVerifier.verify(signedRules, appVersion: "1.0.0", now: now,
            highWaterMark: checkedRules.highWaterMark))
        XCTAssertNoThrow(try rulesVerifier.verify(signedRules, appVersion: "1.0.0", now: now,
            highWaterMark: checkedRules.highWaterMark, restoringCurrent: true))

        let original = signedRules.manifest
        let changedUnsigned = RuleConfigurationManifest(configurationVersion: original.configurationVersion,
            sequence: original.sequence, generatedAt: original.generatedAt, expiresAt: original.expiresAt + 60,
            minimumAppVersion: original.minimumAppVersion, payloadSHA256: original.payloadSHA256,
            signingKeyID: original.signingKeyID, signatureBase64: "")
        let messagePath = directory.appendingPathComponent("changed-rule-manifest.bin")
        try changedUnsigned.signingRepresentation.write(to: messagePath)
        let changedSignature = try command(openssl, ["pkeyutl", "-sign", "-rawin", "-inkey", key.path, "-in", messagePath.path])
        let changedManifest = RuleConfigurationManifest(configurationVersion: original.configurationVersion,
            sequence: original.sequence, generatedAt: original.generatedAt, expiresAt: original.expiresAt + 60,
            minimumAppVersion: original.minimumAppVersion, payloadSHA256: original.payloadSHA256,
            signingKeyID: original.signingKeyID, signatureBase64: changedSignature.base64EncodedString())
        XCTAssertThrowsError(try rulesVerifier.verify(.init(manifest: changedManifest, payloadData: signedRules.payloadData),
            appVersion: "1.0.0", now: now, highWaterMark: checkedRules.highWaterMark, restoringCurrent: true)) {
            XCTAssertEqual($0 as? RuleConfigurationVerifier.Failure, .equivocationRejected)
        }
    }
}
#endif
