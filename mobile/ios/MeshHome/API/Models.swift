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

struct Preview: Codable, Hashable, Sendable {
    let body: String
    let direction: String
    let senderLabel: String?
    let state: String
    let createdAt: Date
}

struct Conversation: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case dm, channel }

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
    /// Per-conversation chime: "on", "off", or nil to follow the app-wide setting.
    let sound: String?
}

struct Message: Codable, Identifiable, Hashable, Sendable {
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

struct Contact: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let publicKey: String
    let name: String
    let alias: String?
    let kind: Int
    let lastAdvertAt: Date?
    let onRadio: Bool
    let favorite: Bool
    let blocked: Bool
    let isSimulated: Bool?
    let conversationId: String?

    var displayName: String { alias ?? name }
    var kindLabel: String { [1: "Companion", 2: "Repeater", 3: "Room server", 4: "Sensor"][kind] ?? "Type \(kind)" }
    var isPerson: Bool { kind == 1 }
}

struct ContactPage: Decodable, Sendable {
    let items: [Contact]
    let total: Int
    let page: Int
    let pageSize: Int
}

struct MessagePath: Decodable, Hashable, Sendable {
    struct Hop: Decodable, Hashable, Sendable {
        let hash: String
        let names: [String]
    }
    let hops: [Hop]
    let hashSize: Int?
    let route: String?
    let snr: Double?
    let rssi: Double?
}

struct MessageInfo: Decodable, Sendable {
    struct Sender: Decodable, Sendable {
        let label: String?
        let keyPrefix: String?
        let contact: Contact?
        let match: String?
    }
    struct Received: Decodable, Sendable {
        let snr: Double?
        let rssi: Double?
        let route: String?
        let hops: Int?
        let pathHashSize: Int?
    }
    let message: Message
    let conversationKind: Conversation.Kind
    let sender: Sender
    let received: Received
    let paths: [MessagePath]
}

/// GET /api/device (only what the app uses): the home radio.
struct DeviceInfo: Decodable, Sendable {
    struct Radio: Decodable, Sendable {
        let name: String
        let publicKey: String
    }
    let radio: Radio?
}

struct ContactImportResult: Decodable, Sendable {
    let contact: Contact
    let added: Bool
}

struct ContactDetail: Decodable, Sendable {
    let id: String
    let publicKey: String
    let name: String
    let alias: String?
    let kind: Int
    let lastAdvertAt: Date?
    let onRadio: Bool
    let favorite: Bool
    let blocked: Bool
    let lat: Double?
    let lon: Double?
    /// -1: no known route (flood); 0: direct; n: n repeater hops, listed in pathHops (hash prefixes).
    let pathLen: Int
    let pathHops: [String]
    let pathHashSize: Int
    let messagesReceived: Int
    let messagesSent: Int

    var displayName: String { alias ?? name }
}

struct ConversationInfo: Decodable, Sendable {
    struct Channel: Decodable, Sendable {
        let slot: Int
        let name: String
        let active: Bool
        let floodScope: String?
    }
    struct ContactRef: Decodable, Sendable { let id: String }
    let channel: Channel?
    let contact: ContactRef?
}

struct ChannelAdded: Decodable, Sendable {
    struct Share: Decodable, Sendable { let hex: String }
    let slot: Int
    let name: String
    let conversationId: String?
    /// Only for a newly created private channel: its key, shown once.
    let share: Share?
}

/// MeshCore channel links (docs.meshcore.io/qr_codes): meshcore://channel/add?name=…&secret=<32 hex>[&region_scope=…]
enum ChannelCode {
    static let publicKeyHex = "8b3387e9c5cdea6ac9e5edbaa115cd72"

    struct Link: Hashable, Sendable { var name: String; var secret: String; var scope: String }

    static func uri(_ l: Link) -> String {
        var c = URLComponents()
        c.scheme = "meshcore"; c.host = "channel"; c.path = "/add"
        var q = [URLQueryItem(name: "name", value: l.name), URLQueryItem(name: "secret", value: l.secret.lowercased())]
        if !l.scope.isEmpty { q.append(URLQueryItem(name: "region_scope", value: l.scope)) }
        c.queryItems = q
        // URLComponents leaves "#" and "&" in values alone; encode them so every reader round-trips.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "#", with: "%23")
        return c.string ?? ""
    }

    static func parse(_ text: String) -> Link? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "meshcore", c.host == "channel", c.path == "/add" else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let name = (q["name"] ?? "").trimmingCharacters(in: .whitespaces)
        let secret = (q["secret"] ?? "").lowercased()
        guard !name.isEmpty, secret.count == 32, secret.allSatisfy(\.isHexDigit) else { return nil }
        let scope = (q["region_scope"] ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        return Link(name: name, secret: secret, scope: scope)
    }
}

struct MapConfig: Codable, Sendable {
    let tileUrl: String
    let attribution: String
    let maxZoom: Int
}

struct MapNode: Decodable, Identifiable, Sendable {
    let id: String
    let publicKey: String
    let name: String
    let alias: String?
    let kind: Int
    let lat: Double
    let lon: Double
    let lastAdvertAt: Date?
    let onRadio: Bool
    let isSimulated: Bool
    let conversationId: String?
    var displayName: String { alias ?? name }
}

struct MapData: Decodable, Sendable {
    struct Gateway: Decodable, Sendable { let name: String; let lat: Double; let lon: Double; let live: Bool }
    let gateways: [Gateway]
    let nodes: [MapNode]
    let withoutLocation: Int
    let tiles: MapConfig
}

/// GET /api/radio/config: the connected radio's own settings (every PUT returns it updated).
struct NodeConfig: Decodable, Sendable {
    struct Firmware: Decodable, Sendable { let version: String?; let model: String? }
    struct Identity: Decodable, Sendable { let name: String; let lat: Double?; let lon: Double?; let shareLocation: Bool }
    struct Radio: Decodable, Sendable {
        let freqMhz: Double; let bwKhz: Double; let sf: Int; let cr: Int; let txPowerDbm: Int
        let maxTxPowerDbm: Int?; let `repeat`: Bool?
    }
    struct Behavior: Decodable, Sendable { let autoAddContacts: Bool; let multiAcks: Int; let pathHashMode: Int?; let defaultFloodScope: String? }
    struct Telemetry: Decodable, Sendable { let base: Int; let location: Int; let environment: Int }
    struct Tuning: Decodable, Sendable { let rxDelay: Double; let airtimeFactor: Double }
    struct Channel: Decodable, Sendable, Identifiable { let slot: Int; let name: String; let key: String; var id: Int { slot } }
    let simulated: Bool
    let firmware: Firmware
    let identity: Identity
    let radio: Radio
    let behavior: Behavior
    let telemetry: Telemetry
    let tuning: Tuning?
    let channels: [Channel]
    let maxChannels: Int
    let customVars: [String: String]?
}

struct RadioPreset: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let freqMhz: Double
    let bwKhz: Double
    let sf: Int
    let cr: Int
}

struct PresetList: Decodable, Sendable {
    let presets: [RadioPreset]
}

/// A 64-character key as two 32-character lines: iOS would otherwise wrap it with a hyphen.
func keyLines(_ key: String) -> String {
    key.count > 32 ? String(key.prefix(32)) + "\n" + String(key.dropFirst(32)) : key
}

/// MeshCore's contact QR code format (docs.meshcore.io/qr_codes), read by MeshCore apps too.
enum ContactCode {
    static func uri(name: String, publicKey: String, kind: Int = 1) -> String {
        var c = URLComponents()
        c.scheme = "meshcore"; c.host = "contact"; c.path = "/add"
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "public_key", value: publicKey),
                        URLQueryItem(name: "type", value: String(kind))]
        return c.string ?? ""
    }
}

struct NotificationConfig: Codable, Sendable {
    /// "all", "dms" or "off".
    var sound: String
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

    /// For the local cache: Swift's own key names and date encoding, read back by decoderPlain.
    static let encoderPlain = JSONEncoder()
    static let decoderPlain = JSONDecoder()

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
