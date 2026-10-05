import XCTest
@testable import FirePrivacyCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class ProtectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func signed(_ payload: Data, kind: FilterPayloadKind = .safariDomainsV1,
                        version: UInt64 = 10, expires: Int64 = 1_790_086_400,
                        rollback: UInt64? = nil) throws -> (SignedFilterDataset, [String: Data]) {
        let key = Curve25519.Signing.PrivateKey()
        let m = FilterDatasetManifest(version: version, kind: kind, tag: "test-v\(version)",
            issuedAtSeconds: 1_789_999_000, expiresAtSeconds: expires,
            payloadSHA256: ContentDigest.sha256(payload), payloadByteCount: payload.count, keyID: "fixture",
            rollbackFromVersion: rollback)
        return (.init(manifest: m, payload: payload, signature: try key.signature(for: m.signedRepresentation())),
                ["fixture": key.publicKey.rawRepresentation])
    }
    func testActiveStateRequiresSystemReadBack() {
        let optimistic = ProtectionComponentState(component: .encryptedDNS, phase: .active, detail: "installed")
        XCTAssertFalse(optimistic.isActive)
        XCTAssertEqual(optimistic.phase, .awaitingUserEnablement)
        XCTAssertTrue(ProtectionComponentState(component: .encryptedDNS, phase: .active,
                                               systemConfirmed: true, detail: "read back").isActive)
    }
    func testSafariCompilerEscapesDomainsAndRespectsAllows() throws {
        let config = SafariRuleConfiguration(blockedDomains: ["ads.example.org", "tracker.example.org", "ads.example.org"],
                                            allowedDomains: ["example.org"], datasetVersion: 1)
        XCTAssertEqual(String(data: try SafariRuleCompiler.compile(config), encoding: .utf8), "[]")
        let rules = try JSONSerialization.jsonObject(with: SafariRuleCompiler.compile(.init(blockedDomains: ["tracker.example.org"], datasetVersion: 1))) as! [[String: Any]]
        let trigger = rules[0]["trigger"] as! [String: Any]
        XCTAssertEqual(trigger["load-type"] as? [String], ["third-party"])
        let regex = try NSRegularExpression(pattern: trigger["url-filter"] as! String)
        for (url, matches) in [("https://tracker.example.org/a", true), ("https://sub.tracker.example.org/a", true),
                               ("https://trackerXexampleXorg/a", false), ("https://tracker.example.org.evil/a", false)] {
            XCTAssertEqual(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, matches)
        }
    }
    func testSafariCompilerRejectsURLRegexAndIPAddressInput() {
        for domain in ["https://tracker.example.org", "*.example.org", "127.0.0.1", "a..org", "evil.org/.*", "éxample.org"] {
            XCTAssertThrowsError(try SafariRuleCompiler.compile(.init(blockedDomains: [domain], datasetVersion: 1)))
        }
    }
    func testSafariChildAllowPreservesParentBlocking() throws {
        let data = try SafariRuleCompiler.compile(.init(blockedDomains: ["tracker.example.org"],
            allowedDomains: ["needed.tracker.example.org"], datasetVersion: 1))
        let rules = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual((rules[0]["action"] as! [String: String])["type"], "block")
        XCTAssertEqual((rules[1]["action"] as! [String: String])["type"], "ignore-previous-rules")
        let pattern = (rules[1]["trigger"] as! [String: Any])["url-filter"] as! String
        let regex = try NSRegularExpression(pattern: pattern)
        for (url, allowed) in [("https://needed.tracker.example.org/a", true), ("https://other.tracker.example.org/a", false)] {
            XCTAssertEqual(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, allowed)
        }
    }
    func testDNSConfigurationBindsDestinationAndOperatorDisclosure() throws {
        let a = DNSResolverConfiguration(transport: .https, servers: ["1.1.1.1", "2606:4700:4700::1111"],
            serverURL: URL(string: "https://resolver.example.org/dns-query")!, operatorName: "Test operator",
            privacyPolicyURL: URL(string: "https://resolver.example.org/privacy")!, loggingDisclosure: "Operator policy applies",
            retentionDisclosure: "Review operator retention", jurisdictionDisclosure: "Disclosed region",
            filteringDisclosure: "Encryption only")
        try a.validate()
        XCTAssertTrue(try a.scopeIdentity.hasPrefix("dns/v1:"))
        let b = DNSResolverConfiguration(transport: .https, servers: a.servers,
            serverURL: URL(string: "http://resolver.example.org/dns-query")!, operatorName: a.operatorName,
            privacyPolicyURL: a.privacyPolicyURL, loggingDisclosure: a.loggingDisclosure,
            retentionDisclosure: a.retentionDisclosure, jurisdictionDisclosure: a.jurisdictionDisclosure,
            filteringDisclosure: a.filteringDisclosure)
        XCTAssertThrowsError(try b.validate())
    }
    func testAppleBloomMatchesOfficialSampleByteForByte() throws {
        // Apple FilteringTrafficByURL.zip bloom_filter.plist, supplied under its MIT license.
        let items = ["example.com", "example2.com", "example3.com", "example4.com", "example5.com", "example6.com",
                     "example7.com", "example8.com", "example9.com", "example10.com/resource?query=bugs"]
        let filter = try AppleURLBloomFilter(items: items, murmurSeed: 624_656_550)
        XCTAssertEqual(filter.bitCount, 144); XCTAssertEqual(filter.hashCount, 10)
        XCTAssertEqual(filter.data, Data(base64Encoded: "drTfH9rdTUxh8MMyOMHdj00m"))
        XCTAssertTrue(items.allSatisfy(filter.possiblyContains))
        XCTAssertFalse(filter.possiblyContains("unlisted.invalid/path"))
    }
    func testSignedDatasetValidatesAndTamperingIsRejected() throws {
        let payload = try JSONEncoder().encode(["tracker.example.org"])
        let (dataset, keys) = try signed(payload)
        let validated = try FilterDatasetVerifier.verify(dataset, trustedKeys: keys, now: now)
        XCTAssertEqual(try validated.safariConfiguration().blockedDomains, ["tracker.example.org"])
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(.init(manifest: dataset.manifest,
                        payload: Data("[]".utf8), signature: dataset.signature), trustedKeys: keys, now: now))
        let altered = FilterDatasetManifest(version: dataset.manifest.version, kind: .safariDomainsV1, tag: "altered",
            issuedAtSeconds: dataset.manifest.issuedAtSeconds, expiresAtSeconds: dataset.manifest.expiresAtSeconds,
            payloadSHA256: dataset.manifest.payloadSHA256, payloadByteCount: payload.count, keyID: "fixture")
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(.init(manifest: altered, payload: payload,
                        signature: dataset.signature), trustedKeys: keys, now: now)) { XCTAssertEqual($0 as? FilterDatasetError, .invalidSignature) }
    }
    func testBundledSafariStarterIsIndependentlySignedAndExpires() throws {
        let bundled = try BundledProtectionDataset.safariStarter()
        XCTAssertEqual(try bundled.safariConfiguration().blockedDomains, ["api.segment.io"])
        XCTAssertEqual(bundled.manifest.keyID, "fireprivacy-safari-publisher-2026-10")
        XCTAssertThrowsError(try BundledProtectionDataset.safariStarter(now: bundled.expiresAt.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? FilterDatasetError, .expired)
        }
    }
    func testStaleRevokedAndRollbackDatasetsCannotActivate() throws {
        let payload = try JSONEncoder().encode(["tracker.example.org"])
        let (dataset, keys) = try signed(payload)
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(dataset, trustedKeys: keys, now: now.addingTimeInterval(90_000))) {
            XCTAssertEqual($0 as? FilterDatasetError, .expired)
        }
        for revocations in [FilterRevocations(keyIDs: ["fixture"]), FilterRevocations(versions: [10]),
                            FilterRevocations(payloadDigests: [dataset.manifest.payloadSHA256])] {
            XCTAssertThrowsError(try FilterDatasetVerifier.verify(dataset, trustedKeys: keys, revocations: revocations, now: now)) {
                XCTAssertEqual($0 as? FilterDatasetError, .revoked)
            }
        }
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(dataset, trustedKeys: keys, highestAcceptedVersion: 11, now: now)) {
            XCTAssertEqual($0 as? FilterDatasetError, .rollback)
        }
        let (rollback, rollbackKeys) = try signed(payload, rollback: 11)
        XCTAssertNoThrow(try FilterDatasetVerifier.verify(rollback, trustedKeys: rollbackKeys, highestAcceptedVersion: 11, now: now))
    }
    func testIncompatibleOldSHA256BloomCannotBeUsedByApple() throws {
        let key = Curve25519.Signing.PrivateKey(), payload = Data([1])
        let manifest = FilterDatasetManifest(version: 1, kind: .appleURLBloomV1, tag: "old", issuedAtSeconds: 1_789_999_000,
            expiresAtSeconds: 1_790_086_400, payloadSHA256: ContentDigest.sha256(payload), payloadByteCount: 1, keyID: "fixture",
            bitCount: 8, hashCount: 2, murmurSeed: 0, hashAlgorithm: "sha256-double-hash",
            pirServerURL: URL(string: "https://filter.example.org/pir")!, appleConfigurationIdentity: "unverified-test-only")
        let dataset = SignedFilterDataset(manifest: manifest, payload: payload,
                                          signature: try key.signature(for: manifest.signedRepresentation()))
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(dataset, trustedKeys: ["fixture": key.publicKey.rawRepresentation], now: now)) {
            XCTAssertEqual($0 as? FilterDatasetError, .incompatibleBloomFilter)
        }
    }
    func testHostileManifestLifetimeDoesNotOverflow() throws {
        let m = FilterDatasetManifest(version: 1, kind: .safariDomainsV1, tag: "hostile", issuedAtSeconds: Int64.min,
                                      expiresAtSeconds: Int64.max, payloadSHA256: String(repeating: "0", count: 64), payloadByteCount: 0, keyID: "fixture")
        XCTAssertThrowsError(try FilterDatasetVerifier.verify(.init(manifest: m, payload: Data(), signature: Data()), trustedKeys: [:], now: now)) {
            XCTAssertEqual($0 as? FilterDatasetError, .malformedManifest)
        }
    }
    func testManagedAllowsOverrideDropAndUnknownAttributionCannotMatchScopedRule() throws {
        let policy = ManagedPolicy(version: 1, deploymentMode: .supervisedDevice,
            rules: [.init(domain: "tracker.example.org", action: .drop),
                    .init(appIdentifier: "com.example.Allowed", domain: "tracker.example.org", action: .allow),
                    .init(appIdentifier: "com.example.Blocked", domain: "scoped.example.org", action: .drop)],
            expiresAtSeconds: 1_790_086_400)
        try policy.validate()
        XCTAssertEqual(policy.decision(host: "sub.tracker.example.org", sourceAppIdentifier: nil, now: now), .drop)
        XCTAssertEqual(policy.decision(host: "tracker.example.org", sourceAppIdentifier: "com.example.Allowed", now: now), .allow)
        XCTAssertEqual(policy.decision(host: "scoped.example.org", sourceAppIdentifier: nil, now: now), .allow)
        XCTAssertEqual(policy.decision(host: "scoped.example.org", sourceAppIdentifier: "com.example.Blocked", now: now), .drop)
        XCTAssertEqual(policy.decision(host: "tracker.example.org", sourceAppIdentifier: nil,
                                      now: now.addingTimeInterval(90_000)), .allow)
    }
}
