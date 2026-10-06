import Foundation
import XCTest
@testable import FirePrivacyCore

final class UpdateEnvelopeValidatorTests: XCTestCase {
    func testShallowCombinedEnvelopeLeavesSignedBase64PayloadOpaque() throws {
        // Decoding these bytes as configuration JSON would fail. Shape checking
        // must not inspect the still-unauthenticated base64 payload's contents.
        let opaque = Data("{\"id\":1,\"id\":2}".utf8).base64EncodedString()
        let body = Data("{\"rules\":{\"manifest\":{\"sequence\":1},\"payloadData\":\"\(opaque)\"},\"manifest\":null,\"payload\":null}".utf8)
        XCTAssertNoThrow(try UpdateEnvelopeValidator.validate(body))
    }

    func testDuplicateAndEscapedDuplicateKeysAreRejectedAtEveryContainerLevel() {
        for text in [
            "{\"rules\":null,\"rules\":null}",
            "{\"rules\":{\"manifest\":{\"sequence\":1,\"sequence\":2}}}",
            "{\"rules\":{\"manifest\":{\"sequence\":1,\"sequen\\u0063e\":1}}}",
            "{\"payload\":\"a\",\"paylo\\u0061d\":\"a\"}",
            "{\"items\":[{\"x\":1,\"x\":2}]}"
        ] {
            XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data(text.utf8))) {
                XCTAssertEqual($0 as? UpdateEnvelopeValidator.Failure, .malformedShape)
            }
        }
    }

    func testDifferentObjectsMayReuseKeysAndQuotedBracesDoNotChangeShape() throws {
        let body = Data(#"{"first":{"sequence":1},"second":{"sequence":2},"quoted":"{\"sequence\":1}","slash":"\\"}"#.utf8)
        XCTAssertNoThrow(try UpdateEnvelopeValidator.validate(body))
    }

    func testDepthObjectKeyAndKeyByteBoundsRejectBeforeTypedDecoding() {
        let nested = "{\"x\":" + String(repeating: "[", count: 8) + "0" + String(repeating: "]", count: 8) + "}"
        XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data(nested.utf8)))
        let objects = "{\"x\":[" + Array(repeating: "{}", count: 128).joined(separator: ",") + "]}"
        XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data(objects.utf8)))
        let keys = "{" + (0...80).map { "\"field\($0)\":0" }.joined(separator: ",") + "}"
        XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data(keys.utf8)))
        let longKey = "{\"" + String(repeating: "x", count: 257) + "\":0}"
        XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data(longKey.utf8)))
    }

    func testByteLimitsAndInvalidUTF8FailWithSpecificErrors() {
        XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data("{}".utf8), maximumBytes: 1)) {
            XCTAssertEqual($0 as? UpdateEnvelopeValidator.Failure, .oversized)
        }
        XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data("{}".utf8), maximumBytes: Int.max))
        XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data(repeating: 32, count: UpdateEnvelopeValidator.maximumDocumentBytes + 1)))
        let invalidUTF8 = Data([123, 34, 120, 34, 58, 34, 0xFF, 34, 125])
        XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(invalidUTF8)) {
            XCTAssertEqual($0 as? UpdateEnvelopeValidator.Failure, .invalidUTF8)
        }
    }

    func testPrimitiveRootAndUnbalancedContainersFailShapeCheck() {
        for text in ["[]", "true", "{\"x\":[}", "{\"x\":{", "{\"x\":\"unterminated}"] {
            XCTAssertThrowsError(try UpdateEnvelopeValidator.validate(Data(text.utf8)))
        }
    }
}
