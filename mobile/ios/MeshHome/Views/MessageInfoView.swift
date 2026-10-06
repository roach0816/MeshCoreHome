import SwiftUI

/// Message details, the sender, and every path the radio heard the message take.
struct MessageInfoView: View {
    let message: Message
    let kind: Conversation.Kind
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var info: MessageInfo?
    @State private var error: String?
    @State private var confirmBlock = false

    var body: some View {
        NavigationStack {
            Form {
                if let info {
                    details(info)
                    sender(info)
                    paths(info)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Message details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func details(_ info: MessageInfo) -> some View {
        Section {
            Text(info.message.body).textSelection(.enabled)
            if info.message.isOutgoing {
                LabeledContent("Sent", value: info.message.createdAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Status", value: stateLabel(info.message.state, kind: kind))
                if let e = info.message.error { LabeledContent("Error", value: e) }
            } else {
                LabeledContent("Received", value: info.message.createdAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Hops", value: hopsText(info.received))
                if let size = info.received.pathHashSize { LabeledContent("Path hash size", value: "\(size) byte\(size == 1 ? "" : "s")") }
                if let snr = info.received.snr { LabeledContent("SNR", value: String(format: "%.1f dB", snr)) }
                if let rssi = info.received.rssi { LabeledContent("RSSI", value: String(format: "%.0f dBm", rssi)) }
            }
        }
    }

    @ViewBuilder private func sender(_ info: MessageInfo) -> some View {
        if !info.message.isOutgoing {
            Section {
                if let c = info.sender.contact {
                    LabeledContent("Contact", value: c.displayName)
                    LabeledContent("Type", value: c.kindLabel)
                    LabeledContent("Public key", value: String(c.publicKey.prefix(16)) + "…").monospaced()
                    if c.blocked {
                        Button("Unblock \(c.displayName)") { Task { await setBlocked(c, false) } }
                    } else {
                        Button("Block \(c.displayName)", role: .destructive) { confirmBlock = true }
                            .confirmationDialog("Block \(c.displayName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                                Button("Block", role: .destructive) { Task { await setBlocked(c, true) } }
                            } message: {
                                Text("Their messages are still archived, but hidden, never unread and silent. MeshCore radios can't block traffic.")
                            }
                    }
                } else {
                    LabeledContent("Sender", value: info.sender.label ?? "Unknown")
                    Text("Not in your contacts.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Sender")
            } footer: {
                if info.sender.match == "name" {
                    Text("Matched by name. Channel messages only carry the sender's name, so this isn't verified.")
                }
            }
        }
    }

    @ViewBuilder private func paths(_ info: MessageInfo) -> some View {
        Section {
            if info.paths.isEmpty {
                Text(info.message.isOutgoing ? "Paths are recorded for received messages."
                     : "No paths recorded. They're captured from the radio's packet log while MeshHome is connected.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(info.paths.enumerated()), id: \.offset) { _, path in
                VStack(alignment: .leading, spacing: 4) {
                    Text(path.hops.isEmpty ? "Direct (no repeaters)"
                         : path.hops.map { $0.names.first ?? $0.hash.uppercased() }.joined(separator: " → "))
                    HStack(spacing: 8) {
                        if let route = path.route { Text(route.capitalized) }
                        if let snr = path.snr { Text(String(format: "SNR %.1f dB", snr)) }
                        if let rssi = path.rssi { Text(String(format: "RSSI %.0f dBm", rssi)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Paths heard (\(info.paths.count))")
        }
    }

    private func hopsText(_ r: MessageInfo.Received) -> String {
        if r.route == "direct" { return "Direct" }
        guard let hops = r.hops else { return "—" }
        return hops == 0 ? "0 (heard directly)" : "\(hops)"
    }

    private func load() async {
        guard let api = model.api else { return }
        do { info = try await api.messageInfo(message.id) } catch { self.error = error.localizedDescription }
    }

    private func setBlocked(_ c: Contact, _ blocked: Bool) async {
        guard let api = model.api else { return }
        do {
            try await api.setContactBlocked(c.id, blocked)
            await load()
            await model.refreshConversations()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
