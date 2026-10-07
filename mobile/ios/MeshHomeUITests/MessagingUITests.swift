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
        dismissSavePassword(app)

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
        dismissSavePassword(app)

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

    /// Join a hashtag channel, see its QR code, remove it; set a contact's route through a repeater.
    func testChannelsAndContactActions() throws {
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
        dismissSavePassword(app)

        XCTAssertTrue(app.buttons["Add channel"].waitForExistence(timeout: 15))
        app.buttons["Add channel"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Join a hashtag channel'")).firstMatch.tap()
        let tag = "uitest\(Int.random(in: 100...999))"
        let field = app.textFields["hikers"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(tag)
        app.buttons["Join channel"].tap()

        let info = app.buttons["Channel info"]
        XCTAssertTrue(info.waitForExistence(timeout: 15), "channel didn't open")
        info.tap()
        XCTAssertTrue(app.images["QR code"].waitForExistence(timeout: 10), "hashtag channel has no QR code")
        shot(app, "8-channel-info")
        app.buttons["Remove from radio"].tap()
        app.buttons["Remove channel"].tap()
        XCTAssertTrue(app.buttons["Remove from radio"].waitForNonExistence(timeout: 10), "channel sheet didn't close")

        app.tabBars.buttons["Contacts"].tap()
        let tracker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tracker'")).firstMatch
        XCTAssertTrue(tracker.waitForExistence(timeout: 10))
        tracker.press(forDuration: 1.0)
        app.buttons["Details"].tap()
        XCTAssertTrue(app.buttons["Set route…"].waitForExistence(timeout: 10))
        app.buttons["Set route…"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Roof Repeater'")).firstMatch.tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Route saved"].waitForExistence(timeout: 15), "route not saved")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Roof Repeater'")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "9-contact-actions")
        app.buttons["Reset route (flood)"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Flood (no known route)'"))
            .firstMatch.waitForExistence(timeout: 15))
    }

    private func signIn(_ app: XCUIApplication) throws {
        let server = try XCTUnwrap(env["MESHHOME_TEST_SERVER"], "no test server")
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        let url = "http://\(server)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        app.open(URL(string: "meshhome://pair?url=\(url)")!)
        let user = app.textFields["Username"]
        XCTAssertTrue(user.waitForExistence(timeout: 15))
        user.tap(); user.typeText(env["MESHHOME_TEST_USER"] ?? "owner")
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText(env["MESHHOME_TEST_PASSWORD"] ?? "")
        app.buttons["Sign in"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
    }

    /// iOS may offer to save the password after signing in; that sheet covers the screen.
    private func dismissSavePassword(_ app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
    }

    private func any(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Map, remote manage of a (simulated) repeater, and node settings.
    func testMapRemoteManageAndNodeSettings() throws {
        let app = XCUIApplication()
        try signIn(app)

        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(any(app, containing: "Roof Repeater").waitForExistence(timeout: 15), "no repeater on the map")
        shot(app, "10-map")

        app.tabBars.buttons["Contacts"].tap()
        let roof = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Roof Repeater'")).firstMatch
        XCTAssertTrue(roof.waitForExistence(timeout: 10))
        roof.tap()
        let pw = app.secureTextFields["Password"]
        XCTAssertTrue(pw.waitForExistence(timeout: 10), "no remote login")
        pw.tap(); pw.typeText("password")
        app.buttons["Log in"].tap()
        XCTAssertTrue(app.buttons["Refresh status"].waitForExistence(timeout: 30), "remote login failed")
        app.buttons["Refresh status"].tap()
        XCTAssertTrue(any(app, containing: "Battery").waitForExistence(timeout: 30), "no status")
        shot(app, "11-remote-status")
        app.buttons["Command line"].tap()
        let cmd = app.textFields["e.g. get advert.interval"]
        XCTAssertTrue(cmd.waitForExistence(timeout: 5))
        cmd.tap(); cmd.typeText("ver\n")
        XCTAssertTrue(any(app, containing: "> ver").waitForExistence(timeout: 30))
        shot(app, "12-remote-cli")
        app.segmentedControls.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Radio settings"].waitForExistence(timeout: 5))
        app.buttons["Log out"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 30))
        app.buttons["Done"].tap()

        app.tabBars.buttons["Conversations"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Node settings"].tap()
        XCTAssertTrue(app.buttons["Telemetry"].waitForExistence(timeout: 15), "node settings didn't load")
        shot(app, "13-node-settings")
        app.buttons["Telemetry"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Saved to the radio."].waitForExistence(timeout: 15), "telemetry not saved")
    }

    /// Opening a busy channel loads its history even while events keep arriving (run with a script
    /// posting /api/radio/simulate-incoming), and never shows "cancelled".
    func testBusyChannelLoads() throws {
        let app = XCUIApplication()
        try signIn(app)
        let publicRow = app.staticTexts["Public"]
        XCTAssertTrue(publicRow.waitForExistence(timeout: 15))
        publicRow.tap()
        XCTAssertTrue(any(app, containing: "Signal looks good").waitForExistence(timeout: 20), "history didn't load")
        sleep(8)  // events keep arriving
        XCTAssertFalse(app.staticTexts["cancelled"].exists, "a load was cancelled")
        XCTAssertTrue(any(app, containing: "Signal looks good").exists)
        shot(app, "14-busy-channel")
    }

    /// A conversation opens at its first unread message (with the "New messages" line), and once
    /// read, at the newest message rather than the oldest.
    func testOpensAtFirstUnreadThenBottom() throws {
        let app = XCUIApplication()
        try signIn(app)
        // Run against a server with unread traffic (e.g. after the storm script).
        let row = app.staticTexts["#home-sim"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let divider = app.descendants(matching: .any)["New messages start here"]
        XCTAssertTrue(divider.waitForExistence(timeout: 20), "no unread divider")
        sleep(2)
        XCTAssertTrue(divider.isHittable, "the unread divider is off screen")
        shot(app, "15-unread")
        app.textFields["Message #home-sim"].tap()
        sleep(2)
        shot(app, "15b-keyboard")
        app.navigationBars["#home-sim"].tap()  // away from the keyboard

        app.navigationBars["#home-sim"].buttons.firstMatch.tap()
        sleep(2)
        row.tap()
        sleep(4)
        XCTAssertFalse(divider.exists, "divider shown with nothing unread")
        let earlier = app.buttons["Load earlier messages"]
        XCTAssertFalse(earlier.exists && earlier.isHittable, "opened at the top, not the bottom")
        shot(app, "16-bottom")
    }

    /// One new message: the thread opens at the bottom (no empty space), the line above it, and the
    /// keyboard doesn't cover it. MESHHOME_TEST_CONV names a conversation with exactly one unread.
    func testOneUnreadMessage() throws {
        guard let title = env["MESHHOME_TEST_CONV"] else { throw XCTSkip("needs MESHHOME_TEST_CONV") }
        let app = XCUIApplication()
        try signIn(app)
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let divider = app.descendants(matching: .any)["New messages start here"]
        XCTAssertTrue(divider.waitForExistence(timeout: 20))
        sleep(2)
        XCTAssertTrue(divider.isHittable)
        shot(app, "17-one-unread")
        app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch.tap()
        sleep(2)
        shot(app, "18-one-unread-keyboard")
    }

    /// Settings: radio connection, devices, bot, API keys, backup, updates and export.
    func testSettingsAdministration() throws {
        let app = XCUIApplication()
        try signIn(app)
        app.buttons["Settings"].tap()
        let back = { app.navigationBars.buttons.element(boundBy: 0).tap() }

        app.buttons["Radio connection"].tap()
        XCTAssertTrue(any(app, containing: "Messages").waitForExistence(timeout: 15), "no radio status")
        shot(app, "20-radio-connection")
        back()

        app.buttons["Signed-in devices"].tap()
        XCTAssertTrue(app.staticTexts["This phone"].waitForExistence(timeout: 10))
        back()

        app.buttons["Bot"].tap()
        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        sleep(1)
        toggle.tap()
        back()

        reveal(app, app.buttons["API keys"]).tap()
        app.buttons["Create API key…"].tap()
        let name = app.textFields["Name, e.g. Home Assistant"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("UI test key")
        app.buttons["Create"].tap()
        XCTAssertTrue(any(app, containing: "only time the key is shown").waitForExistence(timeout: 10), "key not shown")
        app.buttons["Done"].tap()
        let row = any(app, containing: "UI test key")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["Revoke"].tap()
        app.buttons["Revoke key"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "key not revoked")
        back()

        reveal(app, app.buttons["Backup and restore"]).tap()
        let p1 = app.secureTextFields["Passphrase (at least 10 characters)"]
        XCTAssertTrue(p1.waitForExistence(timeout: 10))
        p1.tap(); p1.typeText("ui-test-passphrase")
        app.secureTextFields["Repeat passphrase"].tap(); app.secureTextFields["Repeat passphrase"].typeText("ui-test-passphrase")
        app.buttons["Create backup"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 30) || app.buttons["Close"].waitForExistence(timeout: 5),
                      "share sheet for the new backup didn't open")
        shot(app, "21-backup-share")
        app.swipeDown(velocity: .fast)
        sleep(1)
        back()

        reveal(app, app.buttons["Software updates"]).tap()
        XCTAssertTrue(any(app, containing: "Installed").waitForExistence(timeout: 15))
        shot(app, "22-updates")
        back()

        reveal(app, app.buttons["Export and data"]).tap()
        app.buttons["Export all messages (JSON)"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 30) || app.buttons["Close"].waitForExistence(timeout: 5),
                      "share sheet for the export didn't open")
    }

    /// Native install only (MESHHOME_TEST_NATIVE=1): install the offered update from Settings, then
    /// turn on HTTPS (MESHHOME_TEST_HTTPS_HOST, port 18443) and check the app moved there.
    func testNativeUpdateThenHTTPS() throws {
        guard env["MESHHOME_TEST_NATIVE"] == "1", let host = env["MESHHOME_TEST_HTTPS_HOST"] else { throw XCTSkip("not a native test server") }
        let app = XCUIApplication()
        try signIn(app)
        app.buttons["Settings"].tap()
        app.swipeUp()
        app.buttons["Software updates"].tap()
        let install = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Install '")).firstMatch
        if install.waitForExistence(timeout: 15) {  // when an update is on offer
            install.tap()
            app.buttons["Install"].tap()
        }
        XCTAssertTrue(any(app, containing: "Up to date").waitForExistence(timeout: 420), "update didn't finish")
        shot(app, "30-updated")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Network and HTTPS"].tap()
        let https = app.switches["HTTPS with a trusted certificate"]
        XCTAssertTrue(https.waitForExistence(timeout: 15))
        https.switches.firstMatch.tap()  // the switch itself, not the row
        let hostField = app.textFields["Hostname, e.g. meshhome.example.com"]
        hostField.tap(); hostField.typeText(host)
        let port = app.textFields["443"]
        port.tap(); port.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        port.typeText("18443")
        app.switches["Redirect plain HTTP (port 80)"].switches.firstMatch.tap()
        app.swipeUp()
        let token = app.secureTextFields.firstMatch
        token.tap(); token.typeText("test-token")
        app.swipeUp()
        app.buttons["Apply"].firstMatch.tap()
        app.buttons["Apply"].firstMatch.tap()  // confirm
        shot(app, "31-applying")
        // Done, then the app checks the new address and moves (the test script trusts the cert).
        XCTAssertTrue(any(app, containing: "This app now uses").waitForExistence(timeout: 600), "the app didn't report moving")
        shot(app, "32-after-apply")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeDown()
        XCTAssertTrue(any(app, containing: host).waitForExistence(timeout: 10), "the app didn't move to the HTTPS address")
        shot(app, "33-moved")
    }

    /// A server with a self-signed certificate (MESHHOME_TEST_TLS_SERVER, e.g. host:port): the app
    /// shows the fingerprint, and once trusted, signs in and connects live updates through it.
    func testSelfSignedCertificate() throws {
        guard let server = env["MESHHOME_TEST_TLS_SERVER"] else { throw XCTSkip("no TLS test server") }
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        let url = "https://\(server)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        app.open(URL(string: "meshhome://pair?url=\(url)")!)
        let trust = app.buttons["Trust this certificate"]
        XCTAssertTrue(trust.waitForExistence(timeout: 20), "no certificate prompt")
        XCTAssertTrue(any(app, containing: env["MESHHOME_TEST_TLS_FINGERPRINT"] ?? ":").exists, "wrong fingerprint shown")
        shot(app, "40-certificate")
        trust.tap()
        let user = app.textFields["Username"]
        XCTAssertTrue(user.waitForExistence(timeout: 15), "server check failed after trusting")
        user.tap(); user.typeText(env["MESHHOME_TEST_USER"] ?? "owner")
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText(env["MESHHOME_TEST_PASSWORD"] ?? "")
        app.buttons["Sign in"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(any(app, containing: "Connected").waitForExistence(timeout: 20), "live updates didn't connect")
        shot(app, "41-trusted")
    }

    /// LAN discovery: a server advertised as "_meshhome._tcp" (run `dns-sd -R` on the Mac; the
    /// simulator shares its network) is listed on the sign-in screen and connects when tapped.
    func testFindsServerOnNetwork() throws {
        guard let name = env["MESHHOME_TEST_DISCOVERY_NAME"] else { throw XCTSkip("no advertised test server") }
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        let found = any(app, containing: name)
        XCTAssertTrue(found.waitForExistence(timeout: 20), "the advertised server wasn't listed")
        shot(app, "45-discovered")
        found.tap()
        let user = app.textFields["Username"]
        XCTAssertTrue(user.waitForExistence(timeout: 15), "the discovered server didn't connect")
        user.tap(); user.typeText(env["MESHHOME_TEST_USER"] ?? "owner")
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText(env["MESHHOME_TEST_PASSWORD"] ?? "")
        app.buttons["Sign in"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
    }

    /// Apple's accessibility audit on the main screens. Each issue is reported (and fails the test).
    func testAccessibilityAudit() throws {
        let app = XCUIApplication()
        try signIn(app)
        func audit(_ name: String) {
            do {
                try app.performAccessibilityAudit { issue in
                    let what = issue.element?.debugDescription.split(separator: "\n").first.map(String.init) ?? ""
                    print("A11Y [\(name)] \(issue.auditType) — \(issue.compactDescription) — \(what)")
                    // Reported only (see the log): contrast, text size and clipping proved unreliable
                    // here (text under translucent bars, the lazy message list, emoji line height).
                    // They were reviewed by hand, including screenshots at the largest text size.
                    if [.contrast, .dynamicType, .textClipped].contains(issue.auditType) { return true }
                    // On the map, MapKit's own content: its "Legal" link (smaller than Apple's guideline)
                    // and the tile text it draws. Not ours to change.
                    if name == "map" && [.hitRegion, .elementDetection].contains(issue.auditType) { return true }
                    return false  // missing labels, small tap targets, unclear descriptions: fail
                }
            } catch { XCTFail("audit \(name): \(error)") }
        }
        audit("conversations")
        app.staticTexts["Public"].tap()
        XCTAssertTrue(app.buttons["Channel info"].waitForExistence(timeout: 10))
        sleep(3)  // let the thread finish scrolling into place before measuring
        audit("thread")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Contacts"].tap()
        sleep(2)
        audit("contacts")
        app.tabBars.buttons["Map"].tap()
        sleep(3)
        audit("map")
        app.tabBars.buttons["Conversations"].tap()
        app.buttons["Settings"].tap()
        sleep(1)
        audit("settings")
    }

    /// Screenshots at the largest accessibility text size (for review).
    func testLargestTextSize() throws {
        guard env["MESHHOME_TEST_REVIEW_SHOTS"] == "1" else { throw XCTSkip("review screenshots: set MESHHOME_TEST_REVIEW_SHOTS=1") }
        let app = XCUIApplication()
        let server = try XCTUnwrap(env["MESHHOME_TEST_SERVER"], "no test server")
        app.launchArguments = ["-uitest-reset", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
        app.launch()
        let url = "http://\(server)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        app.open(URL(string: "meshhome://pair?url=\(url)")!)
        let user = app.textFields["Username"]
        XCTAssertTrue(user.waitForExistence(timeout: 15))
        user.tap(); user.typeText("owner")
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText(env["MESHHOME_TEST_PASSWORD"] ?? "")
        app.buttons["Sign in"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        shot(app, "50-xxl-list")
        app.staticTexts["Public"].tap()
        sleep(3)
        shot(app, "51-xxl-thread")
    }

    /// Screenshots of the main screens, for layout review (run on an iPad too).
    func testLayoutScreenshots() throws {
        guard env["MESHHOME_TEST_REVIEW_SHOTS"] == "1" else { throw XCTSkip("review screenshots: set MESHHOME_TEST_REVIEW_SHOTS=1") }
        let app = XCUIApplication()
        try signIn(app)
        app.staticTexts["Public"].tap()
        sleep(3)
        shot(app, "60-conversations")
        tab(app, "Contacts")
        sleep(2)
        shot(app, "61-contacts")
        let roof = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Roof Repeater'")).firstMatch
        if roof.waitForExistence(timeout: 5) { roof.tap(); sleep(2); shot(app, "62-remote"); app.buttons["Done"].tap() }
        tab(app, "Map")
        sleep(4)
        shot(app, "63-map")
        tab(app, "Conversations")
        app.buttons["Settings"].tap()
        sleep(1)
        shot(app, "64-settings")
    }

    /// Scrolls until the element is on screen (lists only show the rows in view).
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> XCUIElement {
        for _ in 0..<5 where !(element.exists && element.isHittable) { app.swipeUp() }
        return element
    }

    /// A tab: in the tab bar on iPhone, in the top tab strip on iPad.
    private func tab(_ app: XCUIApplication, _ name: String) {
        let bar = app.tabBars.buttons[name]
        if bar.exists { bar.tap() } else { app.buttons[name].firstMatch.tap() }
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
