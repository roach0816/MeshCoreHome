import Foundation
import Observation
import UIKit
import UserNotifications

// MARK: API

struct PushSettings: Codable, Sendable, Equatable {
    var enabled: Bool
    var relayUrl: String
    var devices: Int?
}

struct PushDeviceStatus: Decodable, Sendable, Equatable {
    let registered: Bool
    let dms: Bool
    let channels: Bool
    let lastSentAt: Date?
    let lastError: String?
}

extension APIClient {
    func pushSettings() async throws -> PushSettings { try await get("/api/settings/push") }
    func savePushSettings(_ p: PushSettings) async throws -> PushSettings {
        struct Body: Encodable { let enabled: Bool; let relayUrl: String }
        return try await send("PUT", "/api/settings/push", body: Body(enabled: p.enabled, relayUrl: p.relayUrl))
    }
    func pushDevice() async throws -> PushDeviceStatus { try await get("/api/push/device") }
    func savePushDevice(environment: String, token: String, ticket: String, key: Data, dms: Bool, channels: Bool) async throws -> PushDeviceStatus {
        struct Body: Encodable { let platform, environment, token, ticket, key: String; let dms, channels: Bool }
        return try await send("PUT", "/api/push/device", body: Body(
            platform: "ios", environment: environment, token: token, ticket: ticket,
            key: key.base64EncodedString(), dms: dms, channels: channels))
    }
    func deletePushDevice() async throws { try await send("DELETE", "/api/push/device", body: Optional<String>.none) }
    func testPush() async throws -> (ok: Bool, error: String?) {
        struct Out: Decodable { let ok: Bool; let error: String? }
        let out: Out = try await send("POST", "/api/push/device/test", body: Optional<String>.none)
        return (out.ok, out.error)
    }
}

// MARK: Signing this phone up

/// Push notifications for this phone: asks iOS for permission and a push token, gets a ticket for
/// it from the relay, makes a key, and signs up with the MeshHome server (which encrypts each
/// notification with that key). See docs/push-notifications.md.
@MainActor @Observable
final class PushNotifications {
    static let shared = PushNotifications()

    /// This phone wants pushes (it signed up and hasn't turned them off).
    private(set) var wanted = UserDefaults.standard.bool(forKey: "push.wanted") {
        didSet { UserDefaults.standard.set(wanted, forKey: "push.wanted") }
    }
    private var tokenWaiters: [CheckedContinuation<Data, Error>] = []
    private var refreshedAt: Date?  // in memory: every launch refreshes once

    #if DEBUG
    static let environment = "development"  // run from Xcode: Apple's sandbox
    #else
    static let environment = "production"  // TestFlight and the App Store
    #endif

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // Called by the app delegate.
    func received(token: Data) {
        let waiters = tokenWaiters; tokenWaiters = []
        waiters.forEach { $0.resume(returning: token) }
    }
    func failed(_ error: Error) {
        let waiters = tokenWaiters; tokenWaiters = []
        waiters.forEach { $0.resume(throwing: Failure("iOS didn't give MeshHome a push address: \(error.localizedDescription)")) }
    }

    private func deviceToken() async throws -> Data {
        Task { @MainActor in  // iOS normally answers within a second or two
            try? await Task.sleep(for: .seconds(20))
            let waiters = self.tokenWaiters; self.tokenWaiters = []
            waiters.forEach { $0.resume(throwing: Failure("iOS didn't give MeshHome a push address. Check the internet connection and try again.")) }
        }
        return try await withCheckedThrowingContinuation { c in
            tokenWaiters.append(c)
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func ticket(relay: String, token: String) async throws -> String {
        guard let url = URL(string: relay + "/v1/register") else { throw Failure("The server's relay address isn't valid") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["platform": "ios", "environment": Self.environment, "token": token])
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Out: Decodable { let ticket: String?; let error: String? }
        let out = try? JSONDecoder().decode(Out.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let ticket = out?.ticket else {
            throw Failure("The push relay didn't accept this phone\(out?.error.map { ": \($0)" } ?? "")")
        }
        return ticket
    }

    /// Sign this phone up (or refresh its token, ticket and choices). Asks for permission first.
    @discardableResult
    func enable(_ api: APIClient, dms: Bool, channels: Bool, badge: Bool) async throws -> PushDeviceStatus {
        let settings = try await api.pushSettings()
        guard settings.enabled else { throw Failure("Push notifications are turned off on your MeshHome server.") }
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            throw Failure("Notifications are turned off for MeshHome. Turn them on in the Settings app → Notifications → MeshHome.")
        }
        let token = try await deviceToken().map { String(format: "%02x", $0) }.joined()
        let ticket = try await ticket(relay: settings.relayUrl, token: token)
        var secrets = PushSecrets.load() ?? PushSecrets(key: PushSecrets.newKey(), badge: badge)
        secrets.badge = badge
        secrets.save()
        let status = try await api.savePushDevice(
            environment: Self.environment, token: token, ticket: ticket, key: secrets.key, dms: dms, channels: channels)
        wanted = true
        return status
    }

    func disable(_ api: APIClient?) async {
        wanted = false
        try? await api?.deletePushDevice()
        PushSecrets.delete()
    }

    /// On launch and when the app comes back: push tokens can change, so re-sign-up quietly.
    func refresh(_ api: APIClient, badge: Bool) async {
        guard wanted, refreshedAt.map({ Date().timeIntervalSince($0) > 12 * 3600 }) ?? true else { return }
        refreshedAt = Date()
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        guard let current = try? await api.pushDevice() else { return }
        _ = try? await enable(api, dms: current.registered ? current.dms : true,
                              channels: current.registered ? current.channels : false, badge: badge)
    }

    /// The app-icon badge setting, for the notification extension.
    func setBadge(_ on: Bool) {
        guard var secrets = PushSecrets.load(), secrets.badge != on else { return }
        secrets.badge = on
        secrets.save()
    }

    /// Signing out: the server forgets this phone with the session; forget the key here too.
    func signedOut() {
        wanted = false
        PushSecrets.delete()
    }
}

// MARK: App delegate (push tokens and notification taps)

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushNotifications.shared.received(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushNotifications.shared.failed(error) }
    }

    /// In the app: show a banner unless that conversation is already open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let conversation = notification.request.content.userInfo["conversation"] as? String
        Task { @MainActor in
            let open = self.model?.selectedConversation
            completionHandler(conversation != nil && conversation == open ? [] : [.banner, .list, .sound])
        }
    }

    /// A tapped notification opens its conversation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let conversation = response.notification.request.content.userInfo["conversation"] as? String
        Task { @MainActor in
            if let conversation { self.model?.open(conversation: conversation) }
            completionHandler()
        }
    }
}
