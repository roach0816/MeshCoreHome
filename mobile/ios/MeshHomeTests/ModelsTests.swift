import XCTest
@testable import MeshHome

final class ModelsTests: XCTestCase {
    func testServerDates() {
        XCTAssertNotNil(JSON.parseDate("2026-10-03T21:28:04.123456Z"))
        XCTAssertNotNil(JSON.parseDate("2026-10-03T21:28:04.1+00:00"))
        XCTAssertNotNil(JSON.parseDate("2026-10-03T21:28:04Z"))
        XCTAssertNil(JSON.parseDate("yesterday"))
        let a = JSON.parseDate("2026-10-03T21:28:04.123456Z")!, b = JSON.parseDate("2026-10-03T21:28:04.123Z")!
        XCTAssertEqual(a, b)
    }

    func testDecodesConversationAndPage() throws {
        let conv = """
        {"id":"c1","kind":"channel","title":"Public","favorite":false,"muted":false,"sound":null,"blocked":false,
         "last_message_at":"2026-10-03T21:28:04.123456Z","last_position":7,"read_position":5,"unread":2,
         "is_simulated":true,"archived":false,"channel_slot":0,"max_bytes":140,"something_new":1,
         "preview":{"body":"hi","direction":"in","sender_label":"Bob","state":"received","created_at":"2026-10-03T21:28:04Z"}}
        """
        let c = try JSON.decoder.decode(Conversation.self, from: Data(conv.utf8))
        XCTAssertEqual(c.kind, .channel)
        XCTAssertEqual(c.unread, 2)
        XCTAssertEqual(c.preview?.senderLabel, "Bob")

        let page = """
        {"messages":[{"id":"m1","position":7,"conversation_id":"c1","direction":"out","sender_label":null,
          "sender_key_prefix":null,"body":"hello","sender_timestamp":null,"created_at":"2026-10-03T21:28:04Z",
          "state":"accepted","error":null,"duplicate_count":0,"is_simulated":false,"client_message_id":"x","meta":{}}],
         "has_more":false}
        """
        let p = try JSON.decoder.decode(MessagePage.self, from: Data(page.utf8))
        XCTAssertTrue(p.messages[0].isOutgoing)
        XCTAssertEqual(stateLabel(p.messages[0].state, kind: .channel), "Sent by radio")
        XCTAssertEqual(stateLabel(p.messages[0].state, kind: .dm), "Sent · awaiting delivery")
    }

    func testChannelLinksRoundTrip() {
        let link = ChannelCode.Link(name: "#hikers & friends", secret: String(repeating: "ab", count: 16), scope: "us-md")
        let uri = ChannelCode.uri(link)
        XCTAssertTrue(uri.hasPrefix("meshcore://channel/add?name=%23hikers%20%26%20friends&secret="))
        XCTAssertEqual(ChannelCode.parse(uri), link)
        XCTAssertNil(ChannelCode.parse("meshcore://channel/add?name=X&secret=short"))
        XCTAssertNil(ChannelCode.parse("meshcore://contact/add?name=X&public_key=00"))
        XCTAssertEqual(ChannelCode.parse("meshcore://channel/add?name=Public&secret=8B3387E9C5CDEA6AC9E5EDBAA115CD72&region_scope=%23md")?.scope, "md")
    }
}
