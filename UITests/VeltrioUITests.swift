import XCTest

/// Smoke tests of the running app: it launches, its sections open from the
/// menu shortcuts, search takes input, and Settings opens and closes.
///
/// They run against the user's real data folder, so they only navigate and
/// type: nothing is saved, installed or deleted.
final class VeltrioUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // English UI, whatever the Mac's language, so labels are stable.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testLaunchesIntoAWindow() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    /// Through the menu bar rather than ⌘1…⌘4: synthesized digit keys
    /// depend on the keyboard layout (on AZERTY the 2 key types "é").
    func testSectionsOpenFromTheGoMenu() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        open("Collection")
        // With saved titles the page carries a count; without, it's the
        // empty state.
        XCTAssertTrue(text(containing: "in your library").waitForExistence(timeout: 5)
                      || text(containing: "Nothing saved").exists)
        open("Sources")
        XCTAssertTrue(text(containing: "Every catalogue, server and stream resolver").waitForExistence(timeout: 5))
        open("Live")
        XCTAssertTrue(text(containing: "channels").waitForExistence(timeout: 10)
                      || text(containing: "Add an M3U playlist URL").exists)
    }

    private func open(_ section: String) {
        app.menuBars.menuBarItems["Go"].click()
        app.menuBars.menuItems[section].click()
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", fragment, fragment)).firstMatch
    }

    func testSearchTakesInput() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("dune")
        XCTAssertEqual(field.value as? String, "dune")
    }

    func testSettingsOpenAndClose() {
        let settings = app.buttons["nav.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }
}
