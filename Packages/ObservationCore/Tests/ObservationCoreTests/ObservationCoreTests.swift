import XCTest
@testable import ObservationCore

final class DigestTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(
            FireHasher.hash("").hexString,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            FireHasher.hash("abc").hexString,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            FireHasher.hash(String(repeating: "a", count: 1_000_000)).hexString,
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testPortableMatchesPlatformImplementation() {
        for input in ["", "a", "the quick brown fox", String(repeating: "x", count: 130)] {
            var portable = PortableSHA256()
            portable.update(Array(input.utf8))
            XCTAssertEqual(portable.finalize(), FireHasher.hash(input), "mismatch for \(input.count) bytes")
        }
    }

    func testHexRoundTrip() {
        let digest = FireHasher.hash("round trip")
        XCTAssertEqual(FireDigest(hexString: digest.hexString), digest)
        XCTAssertNil(FireDigest(hexString: "not-hex"))
        XCTAssertNil(FireDigest(hexString: String(repeating: "a", count: 63)))
    }
}

final class PunycodeTests: XCTestCase {
    func testEncodesKnownLabels() {
        // The RFC 3492 sample label.
        XCTAssertEqual(Punycode.encode(label: "münchen"), "mnchen-3ya")
        XCTAssertEqual(Punycode.decode(labelBody: "mnchen-3ya"), "münchen")
    }

    func testRoundTrip() {
        for label in ["münchen", "例え", "bücher", "café"] {
            guard let encoded = Punycode.encode(label: label) else { return XCTFail("encode failed for \(label)") }
            XCTAssertEqual(Punycode.decode(labelBody: encoded), label)
        }
    }

    func testAsciiOnlyLabelEncodesToItself() {
        XCTAssertEqual(Punycode.encode(label: "example"), "example-")
    }
}

final class DomainNormalizerTests: XCTestCase {
    private let normalizer = DomainNormalizer()

    func testLowercasesAndStripsTrailingDot() {
        let result = normalizer.normalize("API.Example.COM.")
        XCTAssertEqual(result.host?.value, "api.example.com")
        XCTAssertTrue(result.warnings.contains(.caseFolded))
        XCTAssertTrue(result.warnings.contains(.trailingDot))
    }

    func testStripsSchemePortAndPath() {
        let result = normalizer.normalize("https://user@api.example.com:8443/path?query=1")
        XCTAssertEqual(result.host?.value, "api.example.com")
        XCTAssertTrue(result.warnings.contains(.schemeRemoved))
        XCTAssertTrue(result.warnings.contains(.userInfoRemoved))
        XCTAssertTrue(result.warnings.contains(.portRemoved))
        XCTAssertTrue(result.warnings.contains(.pathRemoved))
    }

    func testRegistrableDomain() {
        XCTAssertEqual(normalizer.normalize("a.b.example.co.uk").registrableDomain?.value, "example.co.uk")
        XCTAssertEqual(normalizer.normalize("deep.sub.example.com").registrableDomain?.value, "example.com")
        XCTAssertNil(normalizer.normalize("com").registrableDomain)
    }

    /// The mistake that libels an unrelated business.
    func testSuffixBoundaryIsLabelAware() {
        XCTAssertEqual(normalizer.normalize("badexample.com").registrableDomain?.value, "badexample.com")
        XCTAssertNotEqual(normalizer.normalize("badexample.com").registrableDomain?.value, "example.com")
    }

    func testWildcardAndExceptionRules() {
        XCTAssertEqual(normalizer.normalize("site.foo.ck").registrableDomain?.value, "site.foo.ck")
        XCTAssertEqual(normalizer.normalize("www.ck").registrableDomain?.value, "www.ck")
    }

    func testInternationalizedHostsAreCanonicalized() {
        let result = normalizer.normalize("münchen.example")
        XCTAssertEqual(result.host?.value, "xn--mnchen-3ya.example")
        XCTAssertEqual(result.host?.displayValue, "münchen.example")
        XCTAssertTrue(result.warnings.contains(.internationalized))
    }

    func testPunycodeAndUnicodeSpellingsAgree() {
        XCTAssertEqual(
            normalizer.normalize("münchen.example").host?.value,
            normalizer.normalize("xn--mnchen-3ya.example").host?.value
        )
    }

    func testAddressLiterals() {
        XCTAssertEqual(normalizer.normalize("192.168.0.1").host?.kind, .ipv4)
        XCTAssertEqual(normalizer.normalize("[2001:db8::1]:443").host?.kind, .ipv6)
        XCTAssertNil(normalizer.normalize("192.168.0.1").registrableDomain)
    }

    func testRejectsMalformedHosts() {
        XCTAssertNil(normalizer.normalize("").host)
        XCTAssertNil(normalizer.normalize("a..b.example").host)
        XCTAssertNil(normalizer.normalize("exa mple.com").host)
        XCTAssertNil(normalizer.normalize(String(repeating: "a", count: 70) + ".example").host)
    }

    func testSingleLabelIsFlagged() {
        let result = normalizer.normalize("localhost")
        XCTAssertTrue(result.warnings.contains(.singleLabel))
    }

    func testMixedScriptsAreFlagged() {
        let result = normalizer.normalize("pаypal.example") // Cyrillic а
        XCTAssertTrue(result.warnings.contains(.mixedScripts))
    }
}

final class TimestampParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testISO8601Variants() {
        let expected = Date(timeIntervalSince1970: 1_756_684_800) // 2025-09-01T00:00:00Z
        XCTAssertEqual(TimestampParser.parse("2025-09-01T00:00:00Z", now: now), expected)
        XCTAssertEqual(TimestampParser.parse("2025-09-01T00:00:00.000Z", now: now), expected)
        XCTAssertEqual(TimestampParser.parse("2025-09-01 00:00:00Z", now: now), expected)
        XCTAssertEqual(TimestampParser.parse("2025-08-31T17:00:00-07:00", now: now), expected)
    }

    func testEpochSecondsAndMilliseconds() {
        XCTAssertEqual(TimestampParser.parse("1756684800", now: now)?.timeIntervalSince1970, 1_756_684_800)
        XCTAssertEqual(TimestampParser.parse("1756684800000", now: now)?.timeIntervalSince1970, 1_756_684_800)
    }

    func testRejectsImplausibleAndMalformedValues() {
        XCTAssertNil(TimestampParser.parse("1900-01-01T00:00:00Z", now: now))
        XCTAssertNil(TimestampParser.parse("2099-01-01T00:00:00Z", now: now))
        XCTAssertNil(TimestampParser.parse("2025-13-01T00:00:00Z", now: now))
        XCTAssertNil(TimestampParser.parse("2025-02-30T00:00:00Z", now: now))
        XCTAssertNil(TimestampParser.parse("not a date", now: now))
        XCTAssertNil(TimestampParser.parse("", now: now))
    }

    func testLeapDay() {
        XCTAssertNotNil(TimestampParser.parse("2024-02-29T12:00:00Z", now: now))
        XCTAssertNil(TimestampParser.parse("2023-02-29T12:00:00Z", now: now))
    }
}

final class UntrustedTextTests: XCTestCase {
    func testStripsControlAndBidiCharacters() {
        let text = UntrustedText("safe\u{202E}evil\u{0000}value")
        XCTAssertEqual(text.value, "safeevilvalue")
        XCTAssertTrue(text.wasModified)
    }

    func testCollapsesNewlinesToSpaces() {
        XCTAssertEqual(UntrustedText("line one\nline two").value, "line one line two")
    }

    func testTruncatesToLimit() {
        let text = UntrustedText(String(repeating: "a", count: 100), limit: 10)
        XCTAssertEqual(text.value.count, 10)
        XCTAssertTrue(text.wasTruncated)
    }

    func testOptionalInitializerRejectsEmptyValues() {
        XCTAssertNil(UntrustedText(optional: nil))
        XCTAssertNil(UntrustedText(optional: ""))
        XCTAssertNil(UntrustedText(optional: "\u{0000}"))
    }
}

final class BundleIdentifierTests: XCTestCase {
    func testAcceptsRealShapes() {
        XCTAssertNotNil(BundleIdentifier("com.example.app"))
        XCTAssertNotNil(BundleIdentifier("com.example.app-extension"))
    }

    func testRejectsHostileValues() {
        XCTAssertNil(BundleIdentifier(""))
        XCTAssertNil(BundleIdentifier(".com.example"))
        XCTAssertNil(BundleIdentifier("com..example"))
        XCTAssertNil(BundleIdentifier("com.example/../etc"))
        XCTAssertNil(BundleIdentifier("com.example.app'; DROP TABLE apps;--"))
        XCTAssertNil(BundleIdentifier(String(repeating: "a", count: 300)))
    }

    func testPublisherPrefixGroupsSiblingApps() {
        XCTAssertEqual(BundleIdentifier("com.example.one")?.publisherPrefix, "com.example")
        XCTAssertEqual(BundleIdentifier("com.example.two")?.publisherPrefix, "com.example")
        XCTAssertNotEqual(BundleIdentifier("com.other.one")?.publisherPrefix, "com.example")
    }
}

final class DeterministicUUIDTests: XCTestCase {
    func testStableAcrossCalls() {
        let first = DeterministicUUID.make(namespace: .finding, name: "same")
        let second = DeterministicUUID.make(namespace: .finding, name: "same")
        XCTAssertEqual(first, second)
    }

    func testNamespaceSeparatesIdentifiers() {
        XCTAssertNotEqual(
            DeterministicUUID.make(namespace: .finding, name: "x"),
            DeterministicUUID.make(namespace: .evidence, name: "x")
        )
    }

    func testWellFormedVersionAndVariantBits() {
        let uuid = DeterministicUUID.make(namespace: .application, name: "bits")
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        XCTAssertEqual(bytes[6] & 0xF0, 0x80)
        XCTAssertEqual(bytes[8] & 0xC0, 0x80)
    }
}
