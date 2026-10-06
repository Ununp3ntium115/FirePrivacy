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
    func testUsageComparisonOpensWithExplicitSampleAndSourceBoundaries() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["demo-report-badge"].firstMatch.waitForExistence(timeout: 15))
        navigationItem(in: app, identifier: "evidence-tab", label: "Evidence").tap()
        let timeline = app.staticTexts["Activity versus app use"].firstMatch
        for _ in 0..<3 {
            if timeline.exists && timeline.isHittable { break }
            app.descendants(matching: .any)["evidence-screen"].firstMatch.swipeUp()
        }
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        timeline.tap()
        XCTAssertTrue(app.descendants(matching: .any)["usage-timeline-screen"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["demo-report-badge"].firstMatch.exists)
        let imported = app.buttons["usage-import-button"].firstMatch
        for _ in 0..<5 {
            if imported.exists && imported.isHittable { break }
            app.descendants(matching: .any)["usage-timeline-screen"].firstMatch.swipeUp()
        }
        XCTAssertTrue(imported.exists)
        XCTAssertFalse(imported.isEnabled, "Synthetic reports must not accept private usage context as fictional evidence.")
    }

    @MainActor
    func testDeletingDemoClearsPreviouslyOpenedEvidence() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["demo-report-badge"].firstMatch.waitForExistence(timeout: 15))
        navigationItem(in: app, identifier: "evidence-tab", label: "Evidence").tap()

        let weather = app.staticTexts["example.weather"].firstMatch
        for _ in 0..<4 {
            if weather.exists && weather.isHittable { break }
            app.descendants(matching: .any)["evidence-screen"].firstMatch.swipeUp()
        }
        XCTAssertTrue(weather.waitForExistence(timeout: 5))
        weather.tap()
        XCTAssertTrue(app.navigationBars["App evidence"].waitForExistence(timeout: 5))

        navigationItem(in: app, identifier: "settings-tab", label: "Settings").tap()
        let delete = app.buttons["delete-all-button"].firstMatch
        for _ in 0..<6 {
            if delete.exists && delete.isHittable { break }
            app.descendants(matching: .any)["settings-screen"].firstMatch.swipeUp()
        }
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["Delete all app data"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Confirmation starts asynchronous deletion; an existing sidebar row
        // stays disabled behind the working overlay until that operation ends.
        XCTAssertTrue(app.staticTexts["No report saved"].waitForExistence(timeout: 15), "Deletion must reach the empty saved-report state before navigating.")
        XCTAssertFalse(app.alerts["Deletion needs attention"].exists)
        let evidence = navigationItem(in: app, identifier: "evidence-tab", label: "Evidence")
        XCTAssertTrue(evidence.waitForExistence(timeout: 10))
        evidence.tap()
        XCTAssertTrue(app.staticTexts["Your evidence starts with an import"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["App evidence"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["demo-report-badge"].firstMatch.exists)
    }

    @MainActor
    private func navigationItem(in app: XCUIApplication, identifier: String, label: String) -> XCUIElement {
        // A SwiftUI Label can propagate an identifier to its decorative image.
        // Tap the tab button or an actionable sidebar element instead.
        let tab = app.tabBars.buttons[label].firstMatch
        if tab.waitForExistence(timeout: 2) {
            XCTAssertTrue(waitUntilActionable(tab), "The \(label) tab must be enabled and hittable.")
            return tab
        }
        let candidates = app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
        // Keep a live query for the sidebar button even while an async operation
        // temporarily disables it; existence alone does not make a row tappable.
        if candidates.contains(where: { $0.elementType == .button }) {
            let button = app.buttons[identifier].firstMatch
            XCTAssertTrue(waitUntilActionable(button), "The \(label) sidebar button must be enabled and hittable.")
            return button
        }
        if let accessibleRow = candidates.first(where: { $0.elementType != .image && $0.isHittable }) {
            XCTAssertTrue(waitUntilActionable(accessibleRow), "The \(label) navigation row must be enabled and hittable.")
            return accessibleRow
        }
        let cell = app.cells.containing(.staticText, identifier: label).firstMatch
        if cell.exists {
            XCTAssertTrue(waitUntilActionable(cell), "The \(label) sidebar cell must be enabled and hittable.")
            return cell
        }
        let text = app.staticTexts[label].firstMatch
        XCTAssertTrue(waitUntilActionable(text), "The \(label) navigation label must be enabled and hittable.")
        return text
    }

    @MainActor
    private func waitUntilActionable(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
