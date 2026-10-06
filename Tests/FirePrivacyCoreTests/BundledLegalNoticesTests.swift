import XCTest
@testable import FirePrivacyCore

final class BundledLegalNoticesTests: XCTestCase {
    func testDistributionIncludesReadableCompleteUpstreamNotices() throws {
        let notices = try BundledLegalNotices.load()
        XCTAssertEqual(Set(notices.map(\.id)), ["public-suffix-list", "apple-url-filter-sample"])
        let psl = try XCTUnwrap(notices.first { $0.id == "public-suffix-list" })
        XCTAssertTrue(psl.text.hasPrefix("Mozilla Public License Version 2.0"))
        XCTAssertTrue(psl.text.contains("Exhibit B - \"Incompatible With Secondary Licenses\" Notice"))
        let apple = try XCTUnwrap(notices.first { $0.id == "apple-url-filter-sample" })
        XCTAssertTrue(apple.text.contains("Copyright © 2026 Apple Inc."))
        XCTAssertTrue(apple.text.contains("The above copyright notice and this permission notice shall be included"))
        XCTAssertTrue(apple.text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        XCTAssertTrue(notices.allSatisfy { !$0.text.isEmpty && $0.text.utf8.count <= BundledLegalNotices.maximumNoticeBytes })
    }
}
