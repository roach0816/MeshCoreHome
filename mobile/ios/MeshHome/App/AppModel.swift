import Foundation
import Observation
import UIKit

/// The signed-in server and everything shared between screens.
@MainActor @Observable
final class AppModel {
    enum Phase { case signedOut, signedIn }

    private(set) var phase: Phase = .signedOut
    private(set) var api: APIClient?
    private(set) var me: Me?
    var conversations: [Conversation] = []
    var listError: String?

    /// Bumped on every live event, so open screens know to refetch.
    private(set) var changes = 0
    private(set) var lastChangedConversation: String?
    let live = LiveUpdates()

    private static let serverKey = "server"

    init() {
        live.onEvent = { [weak self] event in self?.handle(event) }
        live.onSignedOut = { [weak self] in self?.signedOutByServer() }
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset"), let saved = UserDefaults.standard.string(forKey: Self.serverKey) {
            Keychain.delete(for: saved)  // UI tests start signed out
        }
        if let saved = UserDefaults.standard.string(forKey: Self.serverKey), let url = URL(string: saved),
           let token = Keychain.token(for: saved) {
            start(APIClient(base: url, token: token))
        }
    }

    var serverURL: URL? { api?.base }

    // MARK: Sign in and out

    /// Checks that the address is a MeshHome server this app can use.
    static func check(_ url: URL) async throws -> Meta {
        let meta = try await APIClient(base: url).meta()
        guard ["meshhome", "meshcore-home"].contains(meta.product) else {
            throw APIError(status: 0, message: "That address is not a MeshHome server.")
        }
        guard meta.apiVersion == 1, meta.features.contains("app_sessions") else {
            throw APIError(status: 0, message: "This server needs updating before the app can use it (it runs MeshHome \(meta.version)).")
        }
        return meta
    }

    func signIn(server: URL, username: String, password: String) async throws {
        let result = try await APIClient(base: server).signIn(
            username: username, password: password, deviceName: UIDevice.current.name)
        guard let token = result.token else { throw APIError(status: 0, message: "The server did not return a sign-in token.") }
        Keychain.save(token, for: server.absoluteString)
        UserDefaults.standard.set(server.absoluteString, forKey: Self.serverKey)
        start(APIClient(base: server, token: token))
    }

    func signOut() async {
        if let api { try? await api.signOut() }
        forget()
    }

    private func signedOutByServer() {
        forget()
    }

    private func forget() {
        live.stop()
        if let server = api?.base.absoluteString { Keychain.delete(for: server) }
        api = nil
        me = nil
        conversations = []
        phase = .signedOut
    }

    private func start(_ client: APIClient) {
        api = client
        phase = .signedIn
        live.start(client)
        Task { await refreshAll() }
    }

    // MARK: Data

    func refreshAll() async {
        guard let api else { return }
        if me == nil { me = try? await api.me() }
        await refreshConversations()
    }

    func refreshConversations() async {
        guard let api else { return }
        do {
            conversations = try await api.conversations()
            listError = nil
        } catch let e as APIError where e.isSignedOut {
            forget()
        } catch {
            listError = error.localizedDescription
        }
    }

    func markRead(_ conversation: Conversation, position: Int? = nil) async {
        let target = position ?? conversation.lastPosition
        guard let api, target > conversation.readPosition else { return }
        try? await api.markRead(conversation.id, position: target)
        await refreshConversations()
    }

    func toggleFavorite(_ conversation: Conversation) async {
        guard let api else { return }
        try? await api.setFavorite(conversation.id, !conversation.favorite)
        await refreshConversations()
    }

    func appBecameActive() {
        guard phase == .signedIn, let api else { return }
        live.start(api)  // reconnects if the socket dropped in the background
        Task { await refreshAll() }
    }

    private func handle(_ event: LiveUpdates.Event) {
        switch event.type {
        case "hello":
            Task { await refreshConversations() }  // after any reconnect, resync
            changes += 1
            lastChangedConversation = nil
        case "message-created", "delivery-updated", "read-position-updated", "conversations-updated":
            lastChangedConversation = event.conversationID
            changes += 1
            Task { await refreshConversations() }
        default:
            break
        }
    }
}
