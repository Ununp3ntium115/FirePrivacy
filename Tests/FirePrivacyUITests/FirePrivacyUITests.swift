import XCTest

/// These launch and navigate the actual SwiftUI app on both simulator families.
final class FirePrivacyUITests: XCTestCase {
    @MainActor
    func testDemoExplainsEvidenceAndLocalPrivacy() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["overview-screen"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["demo-report-badge"].firstMatch.waitForExistence(timeout: 15))
        capture(app, named: "01-overview-demo")

        let evidence = navigationItem(in: app, identifier: "evidence-tab", label: "Evidence")
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        evidence.tap()
        XCTAssertTrue(app.descendants(matching: .any)["evidence-screen"].firstMatch.waitForExistence(timeout: 5))
        capture(app, named: "02-evidence")

        let trust = navigationItem(in: app, identifier: "trust-tab", label: "Trust")
        XCTAssertTrue(trust.waitForExistence(timeout: 5))
        trust.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trust-screen"].firstMatch.waitForExistence(timeout: 5))
        capture(app, named: "03-trust")
    }

    @MainActor
    private func navigationItem(in app: XCUIApplication, identifier: String, label: String) -> XCUIElement {
        let identified = app.descendants(matching: .any)[identifier].firstMatch
        if identified.waitForExistence(timeout: 3) { return identified }
        return app.tabBars.buttons[label].firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
