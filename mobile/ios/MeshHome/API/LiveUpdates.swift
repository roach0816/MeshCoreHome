import Foundation

/// The server's WebSocket (/ws). Events are hints to refetch over REST, never the data itself.
/// Reconnects with backoff (1 s doubling to 30 s); a 4401 close means this sign-in was revoked.
@MainActor
final class LiveUpdates {
    struct Event: Sendable {
        let type: String
        let conversationID: String?
    }

    var onEvent: ((Event) -> Void)?
    var onSignedOut: (() -> Void)?
    private(set) var connected = false

    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var client: APIClient?

    func start(_ client: APIClient) {
        if loop != nil, self.client?.base == client.base, self.client?.token == client.token { return }
        stop()
        self.client = client
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func run() async {
        var delay: UInt64 = 1
        while !Task.isCancelled, let client {
            var components = URLComponents(url: client.base.appending(path: "/ws"), resolvingAgainstBaseURL: false)!
            components.scheme = client.base.scheme == "https" ? "wss" : "ws"
            var req = URLRequest(url: components.url!)
            if let token = client.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let ws = URLSession.shared.webSocketTask(with: req)
            task = ws
            ws.resume()
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    connected = true
                    delay = 1
                    if case .string(let text) = message, let event = Self.parse(text) { onEvent?(event) }
                }
            } catch {
                connected = false
                if ws.closeCode.rawValue == 4401 {
                    onSignedOut?()
                    return
                }
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
    }

    private static func parse(_ text: String) -> Event? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        return Event(type: type, conversationID: obj["conversation_id"] as? String)
    }
}
