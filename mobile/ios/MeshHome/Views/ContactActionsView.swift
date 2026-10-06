import SwiftUI

/// A contact's details and actions: message, share its code, re-advertise, its route (set or
/// reset), favourite, block, and remove from the radio.
struct ContactActionsView: View {
    let contactID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ContactDetail?
    @State private var repeaters: [Contact] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmRemove = false
    @State private var editingPath = false
    @State private var managing = false

    var body: some View {
        NavigationStack {
            Form {
                // Results at the top, where they're seen without scrolling.
                if let notice { Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green) } }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                if let d = detail { content(d) } else if error == nil { ProgressView().frame(maxWidth: .infinity) }
            }
            .navigationTitle(detail?.displayName ?? "Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $editingPath) {
                if let d = detail {
                    PathEditorView(contact: d, repeaters: repeaters) { hops in
                        await run("Route saved") { try await $0.setPath(d.id, hops: hops) }
                    }
                }
            }
            .sheet(isPresented: $managing) { RemoteManageView(contactID: contactID) }
            .task { await load() }
        }
    }

    @ViewBuilder private func content(_ d: ContactDetail) -> some View {
        Section {
            LabeledContent("Type", value: kindLabel(d.kind))
            LabeledContent("Last heard", value: d.lastAdvertAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            if let lat = d.lat, let lon = d.lon {
                LabeledContent("Position", value: String(format: "%.5f, %.5f", lat, lon))
            }
            LabeledContent("Messages", value: "\(d.messagesReceived) received · \(d.messagesSent) sent")
            if !d.onRadio { Text("Removed from the radio. The archive keeps the conversation.").foregroundStyle(.secondary) }
            if (d.kind == 2 || d.kind == 3), d.onRadio {
                Button { managing = true } label: { Label("Log in to manage", systemImage: "lock.open") }
            }
            if d.kind == 1, d.onRadio {
                Button { dismiss(); Task { await model.openConversation(with: asContact(d)) } } label: {
                    Label("Send a message", systemImage: "bubble.left")
                }
            }
        }
        if d.onRadio {
            Section {
                LabeledContent("Route", value: routeText(d))
                Button { editingPath = true } label: { Label("Set route…", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                if d.pathLen >= 0 {
                    Button { Task { await run("Route reset: messages will flood") { try await $0.resetPath(d.id) } } } label: {
                        Label("Reset route (flood)", systemImage: "arrow.counterclockwise")
                    }
                }
            } header: {
                Text("Route")
            } footer: {
                Text("Flood reaches everyone in range of any repeater; a fixed route goes only through the repeaters you pick.")
            }
            Section("Share") {
                let code = ContactCode.uri(name: d.name, publicKey: d.publicKey, kind: d.kind)
                QRCodeImage(text: code).frame(maxWidth: 200).frame(maxWidth: .infinity).listRowBackground(Color.clear)
                ShareLink(item: code) { Label("Share contact link", systemImage: "square.and.arrow.up") }
                Button { Task { await run("Advert re-broadcast to nearby nodes") { try await $0.shareContact(d.id) } } } label: {
                    Label("Re-advertise to nearby nodes", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        }
        Section("Public key") {
            Text(keyLines(d.publicKey)).font(.caption.monospaced()).textSelection(.enabled)
        }
        if d.onRadio {
            Section {
                Button("Remove from radio", role: .destructive) { confirmRemove = true }
                    .confirmationDialog("Remove \(d.displayName) from the radio?", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) {
                            Task { await run("Removed from the radio") { try await $0.removeContact(d.id) } }
                        }
                    } message: {
                        Text("The archive keeps the conversation. The radio adds them back when it hears their advert, if auto-add is on.")
                    }
            }
        }
    }

    private func kindLabel(_ k: Int) -> String { [1: "Companion", 2: "Repeater", 3: "Room server", 4: "Sensor"][k] ?? "Type \(k)" }

    private func routeText(_ d: ContactDetail) -> String {
        switch d.pathLen {
        case ..<0: return "Flood (no known route)"
        case 0: return "Direct"
        default: return d.pathHops.map { name(forHop: $0) }.joined(separator: " → ")
        }
    }

    private func name(forHop hop: String) -> String {
        repeaters.first { $0.publicKey.hasPrefix(hop.lowercased()) }?.displayName ?? hop.uppercased()
    }

    private func asContact(_ d: ContactDetail) -> Contact {
        Contact(id: d.id, publicKey: d.publicKey, name: d.name, alias: d.alias, kind: d.kind, lastAdvertAt: d.lastAdvertAt,
                onRadio: d.onRadio, favorite: d.favorite, blocked: d.blocked, isSimulated: nil, conversationId: nil)
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            detail = try await api.contactDetail(contactID)
            if repeaters.isEmpty {
                repeaters = (try? await api.contacts(query: "", show: "all", sort: "name", order: "asc", page: 1, kind: 2).items) ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ done: String, _ call: (APIClient) async throws -> Void) async {
        guard let api = model.api else { return }
        do {
            try await call(api)
            notice = done; error = nil
            await load()
        } catch {
            notice = nil
            self.error = error.localizedDescription
        }
    }
}

/// Pick the repeaters a direct message should travel through, in order. None selected = direct.
private struct PathEditorView: View {
    let contact: ContactDetail
    let repeaters: [Contact]
    let onSave: ([String]) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hops: [Contact] = []
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if hops.isEmpty { Text("Direct: no repeaters").foregroundStyle(.secondary) }
                    ForEach(Array(hops.enumerated()), id: \.offset) { i, r in
                        Label("\(i + 1). \(r.displayName)", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .onDelete { hops.remove(atOffsets: $0) }
                    .onMove { hops.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Route to \(contact.displayName)")
                } footer: {
                    Text("From your radio outwards. Swipe to remove a hop.")
                }
                Section("Add a repeater") {
                    if repeaters.isEmpty { Text("No repeaters in your contacts.").foregroundStyle(.secondary) }
                    ForEach(repeaters) { r in
                        Button { hops.append(r) } label: { Label(r.displayName, systemImage: "plus.circle") }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Set route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task { await onSave(hops.map(\.publicKey)); dismiss() }
                    }
                    .disabled(saving)
                }
            }
            .onAppear {
                if contact.pathLen > 0 {
                    hops = contact.pathHops.compactMap { h in repeaters.first { $0.publicKey.hasPrefix(h.lowercased()) } }
                }
            }
        }
    }
}
