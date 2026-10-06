import Foundation

struct APIError: LocalizedError, Sendable {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    var isSignedOut: Bool { status == 401 }
}

/// Talks to one MeshHome server. Signed-in requests carry the app's session token as
/// "Authorization: Bearer mhd_…" (no cookies, no CSRF token needed).
struct APIClient: Sendable {
    let base: URL
    var token: String?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await request("GET", path, query: query, body: Optional<Int>.none)
    }

    func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?) async throws -> T {
        try await request(method, path, query: [], body: body)
    }

    func send<B: Encodable>(_ method: String, _ path: String, body: B?) async throws {
        let _: Empty = try await request(method, path, query: [], body: body)
    }

    private func request<T: Decodable, B: Encodable>(
        _ method: String, _ path: String, query: [URLQueryItem], body: B?
    ) async throws -> T {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Required on sign-in and setup; harmless elsewhere.
        req.setValue("meshhome", forHTTPHeaderField: "X-Requested-With")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSON.encoder.encode(body)
        }
        let (data, response) = try await Self.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: Self.detail(data) ?? "Request failed (HTTP \(status))")
        }
        if T.self == Empty.self || data.isEmpty { return Empty() as! T }
        return try JSON.decoder.decode(T.self, from: data)
    }

    /// FastAPI errors: {"detail": "text"} or {"detail": [{"msg": ...}, ...]}.
    private static func detail(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = obj["detail"] as? String { return s }
        if let list = obj["detail"] as? [[String: Any]] {
            return list.compactMap { ($0["msg"] as? String)?.replacingOccurrences(of: "Value error, ", with: "") }
                .joined(separator: "; ")
        }
        return nil
    }

    struct Empty: Decodable {}
}

// MARK: - Endpoints

extension APIClient {
    func meta() async throws -> Meta { try await get("/api/meta") }

    func signIn(username: String, password: String, deviceName: String) async throws -> SignedIn {
        struct Body: Encodable { let username, password, client, deviceName: String }
        return try await send("POST", "/api/auth/login",
                              body: Body(username: username, password: password, client: "ios", deviceName: deviceName))
    }

    func signOut() async throws { try await send("POST", "/api/auth/logout", body: Optional<Int>.none) }

    func me() async throws -> Me { try await get("/api/auth/me") }

    func conversations() async throws -> [Conversation] { try await get("/api/conversations") }

    func messages(_ conversationID: String, before: Int? = nil, limit: Int = 50) async throws -> MessagePage {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        return try await get("/api/conversations/\(conversationID)/messages", query: q)
    }

    func sendMessage(_ conversationID: String, body: String, clientMessageID: String) async throws -> Message {
        struct Body: Encodable { let clientMessageId, body: String }
        return try await send("POST", "/api/conversations/\(conversationID)/messages",
                              body: Body(clientMessageId: clientMessageID, body: body))
    }

    func markRead(_ conversationID: String, position: Int) async throws {
        struct Body: Encodable { let position: Int }
        try await send("PUT", "/api/conversations/\(conversationID)/read-position", body: Body(position: position))
    }

    func setFavorite(_ conversationID: String, _ favorite: Bool) async throws {
        struct Body: Encodable { let favorite: Bool }
        try await send("PATCH", "/api/conversations/\(conversationID)", body: Body(favorite: favorite))
    }
}
