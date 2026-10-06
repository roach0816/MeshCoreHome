import AudioToolbox
import Foundation
import Observation
import UIKit
import UserNotifications

/// The signed-in server and everything shared between screens.
@MainActor @Observable
final class AppModel {
    enum Phase { case signedOut, signedIn }
    enum Tab: Hashable { case conversations, contacts, map }

    private(set) var phase: Phase = .signedOut
    private(set) var api: APIClient?
    private(set) var me: Me?
    /// What the server supports (GET /api/meta), to hide features an older server lacks.
    private(set) var features: Set<String> = []
    var conversations: [Conversation] = []
    var listError: String?
    /// The last refresh failed to reach the server; what's shown is the cached copy.
    private(set) var offline = false

    // Navigation shared between tabs (Contacts opens a conversation in the Conversations tab).
    var tab: Tab = .conversations
    var selectedConversation: String? {
        // Deselected (e.g. the channel was removed): close the open thread on iPhone too.
        didSet { if selectedConversation == nil, !conversationPath.isEmpty { conversationPath = [] } }
    }
    /// iPhone navigation (the open thread), kept here so it survives the tab's view being rebuilt,
    /// which happens whenever the unread badge changes.
    var conversationPath: [String] = [] {
        didSet { if selectedConversation != conversationPath.last { selectedConversation = conversationPath.last } }
    }
    /// A server address from a scanned pairing QR code, for the connect screen.
    var pairingAddress: String?

    /// Bumped on every live event, so open screens know to refetch.
    private(set) var changes = 0
    private(set) var lastChangedConversation: String?
    /// Bumped when the radio's contact list changes (adverts, paths, edits).
    private(set) var contactChanges = 0
    /// Bumped when remote administration state changes (replies, logins).
    private(set) var remoteChanges = 0
    let live = LiveUpdates()

    private var sound = NotificationConfig(sound: "all")
    /// Whether the app may set its icon badge (asked for once, from Settings).
    var badgeEnabled = UserDefaults.standard.bool(forKey: "badge") {
        didSet { UserDefaults.standard.set(badgeEnabled, forKey: "badge"); updateBadge() }
    }

    private static let serverKey = "server"
    private var isActive = true

    init() {
        live.onEvent = { [weak self] event in self?.handle(event) }
        live.onSignedOut = { [weak self] in self?.forget() }
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset"),
           let saved = UserDefaults.standard.string(forKey: Self.serverKey) {
            Keychain.delete(for: saved)  // UI tests start signed out
        }
        if let saved = UserDefaults.standard.string(forKey: Self.serverKey), let url = URL(string: saved),
           let token = Keychain.token(for: saved) {
            conversations = Cache.load([Conversation].self, "conversations") ?? []
            start(APIClient(base: url, token: token))
        }
    }

    var serverURL: URL? { api?.base }
    var totalUnread: Int { conversations.filter { !$0.muted }.reduce(0) { $0 + $1.unread } }

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

    private func forget() {
        live.stop()
        if let server = api?.base.absoluteString { Keychain.delete(for: server) }
        Cache.clear()
        api = nil
        me = nil
        conversations = []
        selectedConversation = nil
        phase = .signedOut
        updateBadge()
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
        if let meta = try? await api.meta() { features = Set(meta.features) }
        if let config = try? await api.notificationConfig() { sound = config }
        await refreshConversations()
    }

    func refreshConversations() async {
        guard let api else { return }
        do {
            // Only publish real changes: every assignment re-renders the list (and, on iPhone, the
            // open thread), which on a busy mesh would happen with every event.
            let fresh = try await api.conversations()
            if fresh != conversations { conversations = fresh }
            Cache.save(conversations, "conversations")
            listError = nil
            offline = false
        } catch let e as APIError where e.isSignedOut {
            forget()
        } catch let e as APIError {
            listError = e.message
        } catch {
            offline = true  // keep showing the cached list
        }
        updateBadge()
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

    func toggleMuted(_ conversation: Conversation) async {
        guard let api else { return }
        try? await api.setMuted(conversation.id, !conversation.muted)
        await refreshConversations()
    }

    func delete(_ conversation: Conversation) async {
        guard let api else { return }
        try? await api.deleteConversation(conversation.id)
        if selectedConversation == conversation.id { selectedConversation = nil }
        await refreshConversations()
    }

    /// Opens (creating if needed) the DM with a contact, in the Conversations tab.
    func openConversation(with contact: Contact) async {
        guard let api, let id = try? await api.openConversation(contactID: contact.id) else { return }
        await refreshConversations()
        tab = .conversations
        selectedConversation = id
    }

    func appBecameActive() {
        isActive = true
        guard phase == .signedIn, let api else { return }
        live.start(api)  // reconnects if the socket dropped in the background
        Task { await refreshAll() }
    }

    func appResignedActive() { isActive = false }

    // MARK: Live events, chimes and the badge

    private func handle(_ event: LiveUpdates.Event) {
        switch event.type {
        case "hello":
            lastChangedConversation = nil
            changes += 1
            Task { await refreshAll() }  // after any reconnect, resync
        case "message-created", "delivery-updated", "read-position-updated", "conversations-updated":
            lastChangedConversation = event.conversationID
            changes += 1
            if event.type == "message-created", event.direction == "in", !event.suppressed { chime(event) }
            Task { await refreshConversations() }
        case "contacts-updated":
            contactChanges += 1
        case "remote-updated":
            remoteChanges += 1
        case "settings-updated":
            Task { if let api, let c = try? await api.notificationConfig() { sound = c } }
        default:
            break
        }
    }

    /// Same rules as the web app: the conversation's own setting wins, else the app-wide one.
    /// Silent for the conversation you're reading.
    private func chime(_ event: LiveUpdates.Event) {
        guard isActive, event.conversationID != selectedConversation || tab != .conversations else { return }
        let conv = conversations.first { $0.id == event.conversationID }
        let enabled: Bool = switch conv?.sound {
        case "on": true
        case "off": false
        default: sound.sound == "all" || (sound.sound == "dms" && event.kind == "dm")
        }
        guard enabled else { return }
        AudioServicesPlaySystemSound(1007)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func requestBadge() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])) ?? false
        badgeEnabled = granted
    }

    private func updateBadge() {
        let count = badgeEnabled && phase == .signedIn ? totalUnread : 0
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// Last-known data, so the app opens instantly and stays readable without a connection.
/// Cleared on sign-out.
enum Cache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "meshhome")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSON.encoderPlain.encode(value) else { return }
        try? data.write(to: dir.appending(path: "\(name).json"), options: [.atomic, .completeFileProtection])
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appending(path: "\(name).json")) else { return nil }
        return try? JSON.decoderPlain.decode(T.self, from: data)
    }

    static func clear() { try? FileManager.default.removeItem(at: dir) }
}
