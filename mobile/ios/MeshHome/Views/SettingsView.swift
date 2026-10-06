import SwiftUI

/// For now: who you're signed in as, where, and signing out. The full settings come in a later phase.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Signed in") {
                    LabeledContent("User", value: model.me?.username ?? "—")
                    LabeledContent("Home", value: model.me?.homeName ?? "—")
                    LabeledContent("Server", value: model.serverURL?.host() ?? "—")
                    LabeledContent("Live updates", value: model.live.connected ? "Connected" : "Reconnecting…")
                }
                Section {
                    NavigationLink { MyContactCodeView() } label: { Label("My contact code", systemImage: "qrcode") }
                } footer: {
                    Text("A QR code others can scan to add your radio as a contact.")
                }
                Section {
                    Toggle("Unread count on app icon", isOn: Binding(
                        get: { model.badgeEnabled },
                        set: { on in if on { Task { await model.requestBadge() } } else { model.badgeEnabled = false } }))
                } footer: {
                    Text("Updated while MeshHome is open. Sounds follow Settings → Notifications on the server.")
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Signing out removes this phone from Account → Signed-in devices on the server.")
                }
                Section {
                    LabeledContent("App version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of MeshHome on this phone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { await model.signOut(); dismiss() }
                }
            }
        }
    }
}
