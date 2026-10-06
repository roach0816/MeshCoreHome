import Foundation
import Observation

/// Any JSON value (telemetry readings can be numbers, objects or lists).
enum JSONValue: Decodable, Sendable, CustomStringConvertible {
    case number(Double), string(String), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var description: String {
        switch self {
        case .number(let n): n == n.rounded() && abs(n) < 1e9 ? String(Int(n)) : String(format: "%.2f", n)
        case .string(let s): s
        case .bool(let b): b ? "yes" : "no"
        case .array(let a): a.map(\.description).joined(separator: ", ")
        case .object(let o): o.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        case .null: "—"
        }
    }
}

/// GET /api/remote/{contact_id}: the server's view of a repeater or room server we administer.
struct RemoteState: Decodable, Sendable {
    struct Target: Decodable, Sendable { let id: String; let name: String; let publicKey: String; let kind: Int; let lat: Double?; let lon: Double? }
    struct Session: Decodable, Sendable { let admin: Bool; let at: Date }
    struct Section<T: Decodable & Sendable>: Decodable, Sendable { let data: T; let at: Date }
    struct Status: Decodable, Sendable {
        let bat: Int; let txQueueLen: Int; let noiseFloor: Int; let lastRssi: Int; let nbRecv: Int; let nbSent: Int
        let airtime: Int; let uptime: Int; let sentFlood: Int; let sentDirect: Int; let recvFlood: Int; let recvDirect: Int
        let lastSnr: Double; let directDups: Int; let floodDups: Int; let rxAirtime: Int; let recvErrors: Int
    }
    struct Reading: Decodable, Sendable { let channel: Int; let type: String; let value: JSONValue }
    struct Telemetry: Decodable, Sendable { let lpp: [Reading] }
    struct ACLEntry: Decodable, Sendable, Identifiable { let key: String; let perm: Int; var id: String { key } }
    struct ACL: Decodable, Sendable { let acl: [ACLEntry] }
    struct Neighbour: Decodable, Sendable, Identifiable { let pubkey: String; let secsAgo: Int; let snr: Double; var id: String { pubkey } }
    struct Neighbours: Decodable, Sendable { let neighboursCount: Int; let neighbours: [Neighbour] }
    struct Text: Decodable, Sendable { let text: String }
    struct Sections: Decodable, Sendable {
        let status: Section<Status>?
        let telemetry: Section<Telemetry>?
        let acl: Section<ACL>?
        let neighbours: Section<Neighbours>?
        let owner: Section<Text>?
        let regions: Section<Text>?
    }
    struct Value: Decodable, Sendable { let value: String; let at: Date }
    struct Line: Decodable, Sendable, Identifiable {
        let at: Date; let dir: String; let text: String
        var id: String { "\(at.timeIntervalSince1970)-\(dir)-\(text.hashValue)" }
    }

    let contact: Target
    let simulated: Bool
    let radioConnected: Bool
    let session: Session?
    let busy: Bool
    let names: [String: String]
    let sections: Sections
    let values: [String: Value]
    let console: [Line]
}

/// One repeater's administration: state from the server, and mesh requests one at a time.
@MainActor @Observable
final class RemoteStore {
    let contactID: String
    private let api: APIClient
    private(set) var state: RemoteState?
    private(set) var busy = false
    var error: String?

    init(contactID: String, api: APIClient) {
        self.contactID = contactID
        self.api = api
    }

    func load() async {
        do { state = try await api.get("/api/remote/\(contactID)"); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func op<T>(_ body: () async throws -> T) async -> T? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let r = try await body()
            error = nil
            await load()
            return r
        } catch {
            self.error = error.localizedDescription
            await load()
            return nil
        }
    }

    func login(password: String) async -> Bool {
        struct Body: Encodable { let password: String }
        return await op { let _: APIClient.Empty = try await api.send("POST", "/api/remote/\(contactID)/login", body: Body(password: password)); return true } ?? false
    }

    func logout() async {
        _ = await op { try await api.send("POST", "/api/remote/\(contactID)/logout", body: Optional<Int>.none) }
    }

    /// kind: status, telemetry, acl, neighbours, owner, regions.
    func request(_ kind: String) async {
        struct Body: Encodable { let kind: String }
        _ = await op { let _: APIClient.Empty = try await api.send("POST", "/api/remote/\(contactID)/request", body: Body(kind: kind)) }
    }

    /// A CLI command; returns the node's reply (nil if none arrived).
    @discardableResult
    func cli(_ command: String) async -> String? {
        struct Body: Encodable { let command: String }
        struct Out: Decodable { let reply: String? }
        let out: Out? = await op { try await api.send("POST", "/api/remote/\(contactID)/cli", body: Body(command: command)) }
        return out?.reply
    }

    func changeIdentity(prefix: String) async -> String? {
        struct Body: Encodable { let prefix: String }
        struct Out: Decodable { let newPublicKey: String }
        let out: Out? = await op { try await api.send("POST", "/api/remote/\(contactID)/identity", body: Body(prefix: prefix)) }
        return out?.newPublicKey
    }

    func clearConsole() async {
        _ = await op { try await api.send("DELETE", "/api/remote/\(contactID)/console", body: Optional<Int>.none) }
    }

    func value(_ key: String) -> RemoteState.Value? { state?.values[key] }
}

/// "> value" is how the CLI answers "get"; anything else is an error message.
func cliValue(_ reply: String?) -> String? {
    guard let r = reply, r.hasPrefix("> ") else { return nil }
    return String(r.dropFirst(2)).trimmingCharacters(in: .whitespaces)
}
func cliOK(_ reply: String?) -> Bool { reply?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("ok") ?? false }

/// Li-ion charge from voltage, as the MeshCore app shows it: 3.0 V = 0%, 4.2 V = 100%, rounded down.
func batteryPercent(_ mV: Int) -> Int { max(0, min(100, Int((Double(mV - 3000) / 1200 * 100).rounded(.down)))) }

func durationText(_ secs: Int) -> String {
    let d = secs / 86400, h = secs % 86400 / 3600, m = secs % 3600 / 60
    return d > 0 ? "\(d)d \(h)h \(m)m" : h > 0 ? "\(h)h \(m)m" : "\(m)m \(secs % 60)s"
}

func fetchedText(_ at: Date?) -> String {
    guard let at else { return "Not requested yet" }
    let s = Int(Date.now.timeIntervalSince(at))
    return s < 60 ? "Fetched just now" : s < 3600 ? "Fetched \(s / 60) min ago" : s < 86400 ? "Fetched \(s / 3600) h ago" : "Fetched \(s / 86400) d ago"
}
