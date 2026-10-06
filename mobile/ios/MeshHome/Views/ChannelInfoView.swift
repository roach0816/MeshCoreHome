import SwiftUI

/// A channel's details: share it (Public and hashtag channels; a private key is never shown
/// again), its region scope, and removing it from the radio.
struct ChannelInfoView: View {
    let conversation: Conversation
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var channel: ConversationInfo.Channel?
    @State private var secret: String?
    @State private var scope = ""
    @State private var savedScope = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirmRemove = false

    private var link: ChannelCode.Link? {
        guard let channel, let secret else { return nil }
        return .init(name: channel.name, secret: secret, scope: savedScope)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let channel {
                    Section {
                        if let link {
                            QRCodeImage(text: ChannelCode.uri(link)).frame(maxWidth: 240).frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                            ShareLink(item: ChannelCode.uri(link)) { Label("Share channel link", systemImage: "square.and.arrow.up") }
                        } else {
                            Text("This is a private channel. MeshHome never shows its key again after it's created; share it from where you got it.")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Share")
                    }
                    Section {
                        TextField("No scope", text: $scope)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if scope != savedScope {
                            Button { Task { await saveScope() } } label: {
                                HStack { Text("Save scope"); if busy { Spacer(); ProgressView() } }
                            }
                            .disabled(busy)
                        }
                    } header: {
                        Text("Region scope")
                    } footer: {
                        Text("Messages you send flood only through repeaters serving this region.")
                    }
                    Section {
                        LabeledContent("Radio slot", value: "\(channel.slot)")
                        Button("Remove from radio", role: .destructive) { confirmRemove = true }
                    } footer: {
                        Text("Removing frees the slot on the radio. The archive keeps the messages.")
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove \(conversation.title) from the radio?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove channel", role: .destructive) { Task { await remove() } }
            } message: {
                Text("You'll stop receiving its messages. To rejoin a private channel you'll need its key again.")
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            guard let c = try await api.conversationInfo(conversation.id).channel else {
                error = "This channel is no longer on the radio."
                return
            }
            channel = c
            scope = c.floodScope ?? ""
            savedScope = scope
            if c.name.lowercased() == "public" || conversation.title == "Public" {
                secret = ChannelCode.publicKeyHex
            } else if c.name.hasPrefix("#") {
                secret = try? await api.hashtagKey(c.name)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveScope() async {
        guard let api = model.api, let channel else { return }
        let clean = scope.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        busy = true; defer { busy = false }
        do {
            try await api.setChannelScope(slot: channel.slot, scope: clean)
            scope = clean; savedScope = clean; error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        guard let api = model.api, let channel else { return }
        do {
            try await api.removeChannel(slot: channel.slot)
            dismiss()
            model.selectedConversation = nil
            await model.refreshConversations()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
