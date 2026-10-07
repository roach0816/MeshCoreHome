import XCTest
@testable import MeshHome

/// The server encrypts (backend/app/services/push.py, AES-256-GCM); the notification extension
/// decrypts. This vector came from the server's code, so the two must stay compatible.
final class PushPayloadTests: XCTestCase {
    let key = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")!
    let payload = "YvbmvQ2S9mXc8rXhQRAeg6rKXhsGhJ2YAsTYDu/7dOIlrCIrkKoBt6rtIIsuYTcOMVMxLG6Csv/gA+cj6HGJK5uCcYHPKxvI6IWeJOJZkhSmIHDqwuU8BInmO7l38FeOjgU2phDcZLL30FvfyKUt0NXIYS8uj//YxgWc5/LLp+R/izbjw1/RJflH99UVR0DgeXk96cs="

    func testDecryptsServerPayload() throws {
        let c = try PushContent.decrypt(payload, key: key)
        XCTAssertEqual(c.k, "channel")
        XCTAssertEqual(c.title, "Public")
        XCTAssertEqual(c.subtitle, "Kayak 🚣")
        XCTAssertEqual(c.b, "Weather turning, bring a jacket")
        XCTAssertEqual(c.c, "c1")
        XCTAssertEqual(c.n, 3)
    }

    func testWrongKeyOrTamperingFails() {
        XCTAssertThrowsError(try PushContent.decrypt(payload, key: Data(repeating: 7, count: 32)))
        var bytes = Data(base64Encoded: payload)!
        bytes[20] ^= 1
        XCTAssertThrowsError(try PushContent.decrypt(bytes.base64EncodedString(), key: key))
    }

    func testDirectMessageHasNoSubtitle() throws {
        let json = #"{"v":1,"k":"dm","t":"Kayak","s":"","b":"hi"}"#
        let c = try JSONDecoder().decode(PushContent.self, from: Data(json.utf8))
        XCTAssertEqual(c.subtitle, "")
        XCTAssertNil(c.c)
    }
}
