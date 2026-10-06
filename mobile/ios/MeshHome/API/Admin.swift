import Foundation

// MARK: - Models for Settings (server administration)

struct RadioSettings: Codable, Sendable {
    var mode: String  // simulated, tcp, hat, none
    var host: String
    var port: Int
    var paused: Bool?
    var simIntervalSeconds: Int?
}

struct ServerStatus: Decodable, Sendable {
    struct App: Decodable, Sendable { let version: String }
    struct Database: Decodable, Sendable { let ok: Bool; let messages: Int }
    struct Radio: Decodable, Sendable {
        let state: String; let detail: String; let mode: String; let isSimulated: Bool; let radioName: String?
        let connectedSince: Double?; let lastError: String?; let reconnects: Int; let received: Int; let sent: Int
        let storageWarning: String?
    }
    struct Gap: Decodable, Sendable, Identifiable {
        let startedAt: Date; let endedAt: Date?; let reason: String; let open: Bool
        var id: Date { startedAt }
    }
    let app: App
    let database: Database
    let radio: Radio
    let gaps: [Gap]
}

struct BotSettings: Codable, Sendable { var enabled: Bool; var allow: String }
struct WeatherSettings: Codable, Sendable { var host: String }

struct APIKey: Decodable, Identifiable, Sendable {
    let id: String; let name: String; let prefix: String; let scope: String
    let createdAt: Date; let expiresAt: Date?; let lastUsedAt: Date?; let expired: Bool
}
struct APIKeyCreated: Decodable, Sendable { let key: String; let apiKey: APIKey }

struct SignedInDevice: Decodable, Identifiable, Sendable {
    let id: String; let client: String; let deviceName: String?; let userAgent: String?
    let createdAt: Date; let lastSeenAt: Date; let current: Bool
}

struct BackupFile: Decodable, Identifiable, Sendable { let name: String; let size: Int; let createdAt: Date; var id: String { name } }
struct BackupList: Decodable, Sendable { let persistent: Bool; let native: Bool; let backups: [BackupFile] }
struct BackupCreated: Decodable, Sendable { let name: String; let size: Int; let systemIncluded: Bool; let warning: String? }
struct RestoreSummary: Decodable, Sendable {
    let createdAt: String; let appVersion: String; let installKind: String; let homeName: String
    let counts: [String: Int]; let canRestore: Bool; let errors: [String]
    let restored: [String]; let notRestored: [String]; let notes: [String]; let systemRestore: Bool
}
struct RestoreApplied: Decodable, Sendable { let restored: Bool; let system: String; let safetyBackup: String?; let summary: RestoreSummary }

struct UpdateInfo: Decodable, Sendable {
    struct Release: Decodable, Sendable { let version: String; let url: String; let notes: String; let publishedAt: String? }
    struct Status: Decodable, Sendable { let state: String; let version: String; let message: String }
    let currentVersion: String; let installKind: String; let checksEnabled: Bool
    let error: String?; let latest: Release?; let updateAvailable: Bool; let canInstall: Bool; let status: Status?
}

struct FirmwareStatus: Decodable, Sendable {
    struct Latest: Decodable, Sendable { let version: String }
    let available: Bool; let reason: String?; let model: String?; let currentVersion: String?
    let latest: Latest?; let upToDate: Bool?; let error: String?
}

struct NetworkInfo: Decodable, Sendable {
    struct Config: Decodable, Sendable {
        let appPort: Int; let httpsEnabled: Bool; let hostname: String?; let httpsPort: Int; let redirectHttp: Bool
        let email: String?; let staging: Bool; let dnsProvider: String; let credentialsProvider: String?
        let propagationSeconds: Int; let autoRenew: Bool
    }
    struct Certificate: Decodable, Sendable { let host: String; let notAfter: String; let issuer: String? }
    struct Status: Decodable, Sendable { let state: String; let message: String }
    struct Field: Decodable, Sendable, Identifiable {
        let env: String; let label: String; let secret: Bool; let required: Bool; let kind: String?; let `default`: String?; let choices: [String]?
        var id: String { env }
    }
    struct Provider: Decodable, Sendable, Identifiable { let id: String; let name: String; let fields: [Field]; let help: String; let note: String? }
    let installKind: String; let configurable: Bool; let config: Config?; let certificate: Certificate?
    let status: Status?; let inProgress: Bool; let providers: [Provider]
}

// MARK: - Calls

extension APIClient {
    func status() async throws -> ServerStatus { try await get("/api/status") }
    func radioSettings() async throws -> RadioSettings { try await get("/api/settings/radio") }
    func saveRadioSettings(_ r: RadioSettings) async throws -> RadioSettings {
        struct Body: Encodable { let mode, host: String; let port: Int; let simIntervalSeconds: Int }
        return try await send("PUT", "/api/settings/radio", body: Body(mode: r.mode, host: r.host, port: r.port, simIntervalSeconds: r.simIntervalSeconds ?? 0))
    }
    func pauseRadio(_ pause: Bool) async throws -> RadioSettings {
        try await send("POST", pause ? "/api/radio/pause" : "/api/radio/resume", body: Optional<Int>.none)
    }
    func testConnection(host: String, port: Int) async throws -> String {
        struct Body: Encodable { let host: String; let port: Int }
        struct Out: Decodable { let reachable: Bool; let detail: String }
        let out: Out = try await send("POST", "/api/radio/test-connection", body: Body(host: host, port: port))
        return (out.reachable ? "Reachable: " : "Not reachable: ") + out.detail
    }

    func bot() async throws -> BotSettings { try await get("/api/settings/bot") }
    func saveBot(_ b: BotSettings) async throws -> BotSettings { try await send("PUT", "/api/settings/bot", body: b) }
    func weather() async throws -> WeatherSettings { try await get("/api/settings/weather") }
    func saveWeather(_ w: WeatherSettings) async throws -> WeatherSettings { try await send("PUT", "/api/settings/weather", body: w) }
    func testWeather(_ w: WeatherSettings) async throws -> String {
        struct Out: Decodable { let reply: String? ; let detail: String? }
        let out: Out = try await send("POST", "/api/settings/weather/test", body: w)
        return out.reply ?? out.detail ?? "No reply"
    }
    func saveNotifications(_ n: NotificationConfig) async throws -> NotificationConfig { try await send("PUT", "/api/settings/notifications", body: n) }
    func saveMap(_ m: MapConfig) async throws -> MapConfig { try await send("PUT", "/api/settings/map", body: m) }

    func changeUsername(_ username: String, password: String) async throws -> Me {
        struct Body: Encodable { let username, currentPassword: String }
        return try await send("PUT", "/api/auth/username", body: Body(username: username, currentPassword: password))
    }
    func changePassword(current: String, new: String) async throws {
        struct Body: Encodable { let currentPassword, newPassword: String }
        try await send("POST", "/api/auth/password", body: Body(currentPassword: current, newPassword: new))
    }
    func devices() async throws -> [SignedInDevice] { try await get("/api/auth/sessions") }
    func signOutDevice(_ id: String?) async throws {
        try await send("DELETE", id.map { "/api/auth/sessions/\($0)" } ?? "/api/auth/sessions", body: Optional<Int>.none)
    }

    func apiKeys() async throws -> [APIKey] { try await get("/api/api-keys") }
    func createAPIKey(name: String, scope: String, days: Int?) async throws -> APIKeyCreated {
        struct Body: Encodable { let name, scope: String; let expiresInDays: Int? }
        return try await send("POST", "/api/api-keys", body: Body(name: name, scope: scope, expiresInDays: days))
    }
    func revokeAPIKey(_ id: String) async throws { try await send("DELETE", "/api/api-keys/\(id)", body: Optional<Int>.none) }

    func backups() async throws -> BackupList { try await get("/api/backups") }
    func createBackup(passphrase: String) async throws -> BackupCreated {
        struct Body: Encodable { let passphrase: String }
        return try await send("POST", "/api/backups", body: Body(passphrase: passphrase))
    }
    func deleteBackup(_ name: String) async throws { try await send("DELETE", "/api/backups/\(name)", body: Optional<Int>.none) }
    func inspectRestore(_ id: String, passphrase: String) async throws -> RestoreSummary {
        struct Body: Encodable { let passphrase: String }
        return try await send("POST", "/api/restore/\(id)/inspect", body: Body(passphrase: passphrase))
    }
    func applyRestore(_ id: String, passphrase: String) async throws -> RestoreApplied {
        struct Body: Encodable { let passphrase: String }
        return try await send("POST", "/api/restore/\(id)/apply", body: Body(passphrase: passphrase))
    }

    func updateInfo(refresh: Bool) async throws -> UpdateInfo {
        try await get("/api/system/update", query: refresh ? [URLQueryItem(name: "refresh", value: "true")] : [])
    }
    func requestUpdate(_ version: String) async throws {
        struct Body: Encodable { let version: String }
        let _: APIClient.Empty = try await send("POST", "/api/system/update", body: Body(version: version))
    }
    func updateStatus() async throws -> UpdateInfo.Status? {
        struct Out: Decodable { let status: UpdateInfo.Status? }
        let out: Out = try await get("/api/system/update/status")
        return out.status
    }

    func firmware(check: Bool) async throws -> FirmwareStatus {
        check ? try await send("POST", "/api/radio/firmware/check", body: Optional<Int>.none) : try await get("/api/radio/firmware")
    }

    func network() async throws -> NetworkInfo { try await get("/api/system/network") }
    /// PUT /api/system/network with the server's own field names (snake_case, and DNS credential
    /// names such as CLOUDFLARE_DNS_API_TOKEN kept exactly).
    func saveNetwork(_ body: [String: Any]) async throws {
        try await sendRawJSON("PUT", "/api/system/network", json: try JSONSerialization.data(withJSONObject: body))
    }
    func renewCertificate() async throws { let _: APIClient.Empty = try await send("POST", "/api/system/network/renew", body: Optional<Int>.none) }
    func networkStatus() async throws -> NetworkInfo.Status? {
        struct Out: Decodable { let status: NetworkInfo.Status? }
        let out: Out = try await get("/api/system/network/status")
        return out.status
    }

    func deleteSimulatedData() async throws { let _: APIClient.Empty = try await send("DELETE", "/api/simulated-data", body: Optional<Int>.none) }

    /// A file from the server (backup, export), saved to a temporary file with its name.
    func download(_ path: String, as name: String) async throws -> URL {
        var req = URLRequest(url: base.appending(path: path))
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (tmp, response) = try await URLSession.shared.download(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(status: status, message: "Download failed (HTTP \(status))") }
        let dest = FileManager.default.temporaryDirectory.appending(path: name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Uploads a backup file for restoring; reports progress 0…1. Returns the upload id.
    func uploadBackup(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        var req = URLRequest(url: base.appending(path: "/api/restore/upload"))
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("meshhome", forHTTPHeaderField: "X-Requested-With")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let delegate = UploadProgress(progress)
        let (data, response) = try await URLSession.shared.upload(for: req, fromFile: file, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Out: Decodable { let uploadId: String }
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError(status: status, message: detail ?? "Upload failed (HTTP \(status))")
        }
        return try JSON.decoder.decode(Out.self, from: data).uploadId
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
