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
