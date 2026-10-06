import XCTest

/// Runs against a real MeshHome server with the simulated radio. Skipped unless the test runner
/// gets MESHHOME_TEST_SERVER (e.g. TEST_RUNNER_MESHHOME_TEST_SERVER=localhost:8080 xcodebuild test),
/// plus MESHHOME_TEST_USER / MESHHOME_TEST_PASSWORD. MESHHOME_TEST_SHOTS: folder for screenshots.
final class MessagingUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    func testSignInReadAndSend() throws {
        let server = try XCTUnwrap(env["MESHHOME_TEST_SERVER"], "no test server")
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()

        let address = app.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(server)
        app.buttons["Connect"].tap()

        let user = app.textFields["Username"]
        XCTAssertTrue(user.waitForExistence(timeout: 15), "server check failed")
        shot(app, "1-connect")
        user.tap()
        user.typeText(env["MESHHOME_TEST_USER"] ?? "owner")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(env["MESHHOME_TEST_PASSWORD"] ?? "")
        app.buttons["Sign in"].tap()

        let publicRow = app.staticTexts["Public"]
        XCTAssertTrue(publicRow.waitForExistence(timeout: 15), "conversation list didn't load")
        shot(app, "2-conversations")
        publicRow.tap()

        let composer = app.textFields["Message Public"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let text = "Hello from the iOS app \(Int.random(in: 1000...9999))"
        composer.tap()
        composer.typeText(text)
        app.buttons["Send"].tap()
        // Each bubble is one accessibility element: "<text>, <time>, · <state>".
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "sent message not shown")
        let sent = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'Sent by radio'", text)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 20), "delivery state never reached 'Sent by radio'")
        shot(app, "3-thread")

        // Message menu → details sheet.
        bubble.press(forDuration: 1.0)
        app.buttons["Message details"].tap()
        XCTAssertTrue(app.navigationBars["Message details"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sent by radio'"))
            .firstMatch.waitForExistence(timeout: 10))
        shot(app, "4-details")
        app.buttons["Done"].tap()

        // Contacts: a person opens their conversation.
        app.navigationBars["Public"].buttons.firstMatch.tap()  // back to the list (and the keyboard away)
        app.tabBars.buttons["Contacts"].tap()
        let tracker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tracker'")).firstMatch
        XCTAssertTrue(tracker.waitForExistence(timeout: 10), "contacts didn't load")
        shot(app, "5-contacts")
        tracker.tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 10), "contact didn't open a conversation")
    }

    /// Settings → My contact code, then Contacts → + → Enter manually.
    func testContactCodes() throws {
        let server = try XCTUnwrap(env["MESHHOME_TEST_SERVER"], "no test server")
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        let url = "http://\(server)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        app.open(URL(string: "meshhome://pair?url=\(url)")!)
        let user = app.textFields["Username"]
        XCTAssertTrue(user.waitForExistence(timeout: 15))
        user.tap(); user.typeText(env["MESHHOME_TEST_USER"] ?? "owner")
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText(env["MESHHOME_TEST_PASSWORD"] ?? "")
        app.buttons["Sign in"].tap()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        app.buttons["My contact code"].tap()
        XCTAssertTrue(app.images["QR code"].waitForExistence(timeout: 10), "no QR code")
        shot(app, "6-my-code")
        app.navigationBars["My contact code"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()

        app.tabBars.buttons["Contacts"].tap()
        app.buttons["Add contact"].tap()
        app.buttons["Enter manually"].tap()
        let name = "Trail \(Int.random(in: 100...999))"
        app.textFields["Name"].tap(); app.textFields["Name"].typeText(name)
        let key = (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
        app.textFields["Public key (64 hex characters)"].tap()
        app.textFields["Public key (64 hex characters)"].typeText(key)
        app.collectionViews.buttons["Add contact"].tap()  // the form's button, not the + behind the sheet
        XCTAssertTrue(app.staticTexts["Added \(name)"].waitForExistence(timeout: 15), "contact not added")
        shot(app, "7-added")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.waitForExistence(timeout: 10))
    }

    /// The web UI's pairing QR code opens meshhome://pair?url=… and fills in the server.
    func testPairingLink() throws {
        let server = try XCTUnwrap(env["MESHHOME_TEST_SERVER"], "no test server")
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        let url = "http://\(server)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        app.open(URL(string: "meshhome://pair?url=\(url)")!)
        XCTAssertTrue(app.textFields["Username"].waitForExistence(timeout: 15), "pairing link didn't check the server")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways
        add(a)
        if let dir = env["MESHHOME_TEST_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
