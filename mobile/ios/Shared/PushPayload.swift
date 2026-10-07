import CryptoKit
import Foundation
import Security

/// The phone's push key and choices, in a Keychain group shared with the notification extension
/// (which decrypts pushes). Created when the phone signs up for push; deleted when it stops.
struct PushSecrets: Codable, Equatable {
    var key: Data  // 32 bytes, AES-256-GCM; the MeshHome server has a copy
    var badge: Bool  // show the unread count on the app icon

    private static let service = "app.meshhome.push"
    private static let account = "push"

    /// "<TeamID>.app.meshhome.push", from the AppIdentifierPrefix build setting (Info.plist).
    private static var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "MeshHomeKeychainPrefix") as? String,
              !prefix.isEmpty, !prefix.hasPrefix("$") else { return nil }
        return prefix + "app.meshhome.push"
    }

    private static func query() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    static func load() -> PushSecrets? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(PushSecrets.self, from: data)
    }

    func save() {
        Self.delete()
        var q = Self.query()
        // Readable while the phone is locked (after the first unlock), when most pushes arrive.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecValueData as String] = (try? JSONEncoder().encode(self)) ?? Data()
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(query() as CFDictionary) }

    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

/// What a MeshHome server puts in a push (encrypted; see backend/app/services/push.py).
struct PushContent: Decodable, Equatable {
    let v: Int
    let k: String  // "dm", "channel" or "test"
    let t: String  // conversation title (the contact, or the channel's name)
    let s: String  // sender (channels)
    let b: String  // text
    let c: String?  // conversation id
    let m: String?  // message id
    let n: Int?  // unread messages, for the badge

    /// AES-256-GCM, base64(nonce || ciphertext || tag).
    static func decrypt(_ payload: String, key: Data) throws -> PushContent {
        guard let combined = Data(base64Encoded: payload) else { throw CocoaError(.coderInvalidValue) }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        return try JSONDecoder().decode(PushContent.self, from: plain)
    }

    /// Title and body as Messages shows them: the contact for a DM; the channel and sender for a channel.
    var title: String { t }
    var subtitle: String { k == "channel" ? s : "" }
}
