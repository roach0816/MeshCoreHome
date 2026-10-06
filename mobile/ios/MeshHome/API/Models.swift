import Foundation

// Mirrors the server's schemas (backend/openapi.json). Fields the app doesn't use are left out;
// unknown fields are ignored, so newer servers stay compatible.

struct Meta: Decodable, Sendable {
    let product: String
    let version: String
    let apiVersion: Int
    let installKind: String
    let needsSetup: Bool
    let features: [String]
}

struct SignedIn: Decodable, Sendable {
    let username: String
    let homeName: String
    let token: String?
}

struct Me: Decodable, Sendable {
    let username: String
    let homeName: String
}

struct Preview: Decodable, Hashable, Sendable {
    let body: String
    let direction: String
    let senderLabel: String?
    let state: String
    let createdAt: Date
}

struct Conversation: Decodable, Identifiable, Hashable, Sendable {
    enum Kind: String, Decodable, Sendable { case dm, channel }

    let id: String
    let kind: Kind
    let title: String
    let favorite: Bool
    let muted: Bool
    let blocked: Bool?
    let lastMessageAt: Date?
    let lastPosition: Int
    let readPosition: Int
    let unread: Int
    let isSimulated: Bool
    let maxBytes: Int
    let preview: Preview?
}

struct Message: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let position: Int
    let conversationId: String
    let direction: String
    let senderLabel: String?
    let body: String
    let createdAt: Date
    let state: String
    let error: String?
    let isSimulated: Bool
    let clientMessageId: String?

    var isOutgoing: Bool { direction == "out" }
}

struct MessagePage: Decodable, Sendable {
    let messages: [Message]  // oldest first
    let hasMore: Bool
}

/// Delivery state, worded like the web app: never claims more than the radio confirmed.
func stateLabel(_ state: String, kind: Conversation.Kind) -> String {
    switch state {
    case "queued": "Queued"
    case "sending": "Sending…"
    case "accepted": kind == .dm ? "Sent · awaiting delivery" : "Sent by radio"
    case "acknowledged": "Delivered"
    case "no_ack": "Not confirmed delivered"
    case "uncertain": "Outcome uncertain"
    case "failed": "Failed"
    case "expired": "Expired · not sent"
    default: ""
    }
}

// MARK: - JSON

enum JSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
            }
            return date
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// The server sends ISO 8601 with up to microseconds ("2026-10-03T21:28:04.123456Z" or "+00:00").
    static func parseDate(_ s: String) -> Date? {
        var text = s
        // Trim fractional seconds to milliseconds, which ISO8601DateFormatter understands.
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let rest = text[text.index(dot, offsetBy: digits.count + 1)...]
            text = String(text[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: text)
    }
}
