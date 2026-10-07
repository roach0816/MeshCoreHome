import SwiftUI

/// Everything about this MeshHome: account, radio, features, keys and maintenance.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false
    @AppStorage(MapPreference.key) private var serverTiles = false

    private var native: Bool { model.features.contains("network_settings") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Signed in as", value: model.me?.username ?? "—")
                    LabeledContent("Home", value: model.me?.homeName ?? "—")
                    LabeledContent("Server", value: model.serverURL?.host() ?? "—")
                    LabeledContent("Live updates", value: model.live.connected ? "Connected" : "Reconnecting…")
                }
                Section("Account") {
                    link("Username and password", "person.badge.key") { AccountView() }
                    link("Signed-in devices", "iphone.and.arrow.forward") { DevicesView() }
                }
                Section("Radio") {
                    link("Radio connection", "antenna.radiowaves.left.and.right") { RadioConnectionView() }
                    link("Node settings", "slider.horizontal.3") { NodeSettingsView() }
                    link("My contact code", "qrcode") { MyContactCodeView() }
                    link("Radio firmware", "cpu") { FirmwareView() }
                }
                Section("Features") {
                    link("Bot", "bubble.left.and.text.bubble.right") { BotSettingsView() }
                    link("Weather station", "cloud.sun") { WeatherSettingsView() }
                    link("Notifications", "bell") { NotificationSettingsView() }
                    link("Map", "map") { MapSettingsView() }
                }
                Section("Integrations") {
                    link("API keys", "key") { APIKeysView() }
                }
                Section("Maintenance") {
                    link("Backup and restore", "externaldrive") { BackupView() }
                    link("Software updates", "arrow.down.circle") { UpdatesView() }
                    if native { link("Network and HTTPS", "lock.shield") { NetworkView() } }
                    link("Export and data", "square.and.arrow.up") { DataView() }
                }
                Section {
                    Toggle("Unread count on app icon", isOn: Binding(
                        get: { model.badgeEnabled },
                        set: { on in if on { Task { await model.requestBadge() } } else { model.badgeEnabled = false } }))
                    Toggle("Map from MeshHome's tile server", isOn: $serverTiles)
                } header: {
                    Text("This phone")
                } footer: {
                    Text("The badge is updated while MeshHome is open. The map uses Apple Maps unless you choose the tile server set under Map. App version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—").")
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Signing out removes this phone from Signed-in devices on the server.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of MeshHome on this phone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await model.signOut(); dismiss() } }
            }
        }
    }

    private func link<V: View>(_ title: String, _ icon: String, @ViewBuilder _ dest: @escaping () -> V) -> some View {
        NavigationLink { dest().navigationBarTitleDisplayMode(.inline) } label: { Label(title, systemImage: icon) }
    }
}

/// Shared result line for settings pages.
struct ResultText: View {
    let text: String?
    var ok = true
    var body: some View {
        if let text { Text(text).font(.footnote).foregroundStyle(ok ? .green : .red) }
    }
}

// MARK: - Account

private struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var userPassword = ""
    @State private var current = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var userResult: (String, Bool)?
    @State private var passResult: (String, Bool)?

    private var usernameValid: Bool { !username.isEmpty && username.range(of: "^[A-Za-z0-9_.@-]+$", options: .regularExpression) != nil }

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                SecureField("Current password", text: $userPassword).textContentType(.password)
                Button("Change username") {
                    Task {
                        do { model.setMe(try await model.api!.changeUsername(username, password: userPassword)); userPassword = ""; userResult = ("Username changed.", true) }
                        catch { userResult = (error.localizedDescription, false) }
                    }
                }
                .disabled(!usernameValid || userPassword.isEmpty || username == model.me?.username)
                ResultText(text: userResult?.0, ok: userResult?.1 ?? true)
            } header: { Text("Username") } footer: { Text("Letters, numbers and . _ @ - only.") }
            Section {
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password (at least 10 characters)", text: $new1).textContentType(.newPassword)
                SecureField("Repeat new password", text: $new2).textContentType(.newPassword)
                Button("Change password") {
                    Task {
                        do { try await model.api!.changePassword(current: current, new: new1); current = ""; new1 = ""; new2 = ""
                             passResult = ("Password changed. Other browsers and apps were signed out.", true) }
                        catch { passResult = (error.localizedDescription, false) }
                    }
                }
                .disabled(current.isEmpty || new1.count < 10 || new1 != new2)
                ResultText(text: passResult?.0, ok: passResult?.1 ?? true)
            } header: { Text("Password") } footer: { Text("Changing it signs out every other browser and app.") }
        }
        .navigationTitle("Account")
        .onAppear { if username.isEmpty { username = model.me?.username ?? "" } }
    }
}

private struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [SignedInDevice] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(devices) { d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: d.client == "web" ? "desktopcomputer" : "iphone")
                        Text(label(d)).font(.body.weight(.medium))
                        if d.current { Text("This phone").font(.caption).foregroundStyle(.tint) }
                    }
                    Text("Last active \(d.lastSeenAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    if !d.current { Button("Sign out", role: .destructive) { Task { await signOut(d.id) } } }
                }
            }
            if devices.filter({ !$0.current }).count > 1 {
                Button("Sign out all other devices", role: .destructive) { Task { await signOut(nil) } }
            }
        }
        .navigationTitle("Signed-in devices")
        .refreshable { await load() }
        .task { await load() }
    }

    private func label(_ d: SignedInDevice) -> String {
        if d.client != "web" { return d.deviceName.map { "\($0) (\(d.client == "ios" ? "iOS" : "Android") app)" } ?? "App" }
        let ua = d.userAgent ?? ""
        let browser = ua.contains("Edg/") ? "Edge" : ua.contains("Firefox") ? "Firefox" : ua.contains("Chrome") || ua.contains("CriOS") ? "Chrome" : ua.contains("Safari") ? "Safari" : "Browser"
        let os = ua.contains("iPhone") ? "iPhone" : ua.contains("iPad") ? "iPad" : ua.contains("Android") ? "Android" : ua.contains("Mac OS X") ? "macOS" : ua.contains("Windows") ? "Windows" : ua.contains("Linux") ? "Linux" : ""
        return os.isEmpty ? browser : "\(browser) on \(os)"
    }

    private func load() async {
        do { devices = try await model.api?.devices() ?? []; error = nil } catch { self.error = error.localizedDescription }
    }

    private func signOut(_ id: String?) async {
        do { try await model.api?.signOutDevice(id); await load() } catch { self.error = error.localizedDescription }
    }
}
