import UserNotifications

/// Decrypts a MeshHome push into "sender: message". The relay and Apple only ever carry the
/// ciphertext; if it can't be decrypted (no key, e.g. after signing out), the generic
/// "New message" text the relay set is shown instead.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        if let payload = request.content.userInfo["p"] as? String,
           let secrets = PushSecrets.load(),
           let push = try? PushContent.decrypt(payload, key: secrets.key) {
            content.title = push.title
            content.subtitle = push.subtitle
            content.body = push.b
            if let c = push.c {
                content.threadIdentifier = c  // grouped per conversation
                content.userInfo["conversation"] = c
            }
            if secrets.badge, let n = push.n { content.badge = NSNumber(value: n) }
        }
        contentHandler(content)
    }
}
