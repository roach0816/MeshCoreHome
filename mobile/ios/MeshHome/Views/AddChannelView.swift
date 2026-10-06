import SwiftUI

/// The MeshCore app's "Add channel" choices: create or join a private channel, join Public, join a
/// hashtag channel, or scan a channel QR code. The server puts it in the radio's first free slot.
struct AddChannelView: View {
    /// Called with the new channel's conversation; the caller opens it once this sheet has closed.
    var onAdded: (String?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var created: ChannelAdded?
    @State private var createdScope = ""

    enum Step: Hashable {
        case create, joinPrivate(ChannelCode.Link?), joinPublic(ChannelCode.Link?), hashtag(ChannelCode.Link?), scan
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let created, let share = created.share {
                    CreatedChannelView(name: created.name, link: .init(name: created.name, secret: share.hex, scope: createdScope)) {
                        finish(created)
                    }
                } else {
                    menu
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .create: ChannelForm(kind: .create, prefill: nil, onAdded: added)
                case .joinPrivate(let l): ChannelForm(kind: .joinPrivate, prefill: l, onAdded: added)
                case .joinPublic(let l): ChannelForm(kind: .joinPublic, prefill: l, onAdded: added)
                case .hashtag(let l): ChannelForm(kind: .hashtag, prefill: l, onAdded: added)
                case .scan: ScanChannelView { link in path = [Self.step(for: link)] }
                }
            }
        }
    }

    private var menu: some View {
        List {
            Section {
                row("Create a private channel", "lock.badge.plus", "A new channel with a random key to share.", .create)
                row("Join a private channel", "lock", "Someone gave you its name and key.", .joinPrivate(nil))
                row("Join a hashtag channel", "number", "Public channels like #hikers; the name is the key.", .hashtag(nil))
                row("Join the Public channel", "globe", "The channel every MeshCore radio knows.", .joinPublic(nil))
                if QRScanner.isAvailable {
                    row("Scan a channel QR code", "qrcode.viewfinder", "From the MeshCore app or MeshHome.", .scan)
                }
            }
        }
        .navigationTitle("Add channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func row(_ title: String, _ icon: String, _ detail: String, _ step: Step) -> some View {
        NavigationLink(value: step) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: icon) }
        }
    }

    static func step(for link: ChannelCode.Link) -> Step {
        if link.secret == ChannelCode.publicKeyHex { return .joinPublic(link) }
        if link.name.hasPrefix("#") { return .hashtag(link) }
        return .joinPrivate(link)
    }

    /// Only a newly created private channel shows its key (once); joining opens the channel.
    private func added(_ result: ChannelAdded, scope: String, created isNew: Bool) {
        if isNew, result.share != nil {
            createdScope = scope
            path = []
            created = result
        } else {
            finish(result)
        }
    }

    private func finish(_ result: ChannelAdded) {
        onAdded(result.conversationId)
        dismiss()
    }
}

private struct ChannelForm: View {
    enum Kind { case create, joinPrivate, joinPublic, hashtag }
    let kind: Kind
    let prefill: ChannelCode.Link?
    let onAdded: (ChannelAdded, String, Bool) -> Void

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var key = ""
    @State private var scope = ""
    @State private var busy = false
    @State private var error: String?

    private var cleanScope: String { scope.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "") }
    private var scopeError: String? {
        if cleanScope.contains(" ") { return "Scope names can't contain spaces." }
        if cleanScope.utf8.count > 30 { return "At most 30 bytes." }
        return nil
    }
    private var fullName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return kind == .hashtag ? "#" + n.drop { $0 == "#" } : n
    }
    private var keyValid: Bool {
        let k = key.trimmingCharacters(in: .whitespaces)
        return (k.count == 32 && k.allSatisfy(\.isHexDigit)) || (k.count == 24 && Data(base64Encoded: k)?.count == 16)
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && scopeError == nil && (kind != .joinPrivate || keyValid)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 2) {
                    if kind == .hashtag { Text("#").foregroundStyle(.secondary) }
                    TextField(kind == .hashtag ? "hikers" : "Channel name", text: $name)
                        .textInputAutocapitalization(kind == .hashtag ? .never : .words)
                        .autocorrectionDisabled(kind == .hashtag)
                }
                if kind == .joinPrivate {
                    TextField("Key: 32 hex characters or base64", text: $key, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text(footer)
            }
            Section {
                TextField("Region scope (optional)", text: $scope)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text(scopeError ?? "Messages you send flood only through repeaters serving this region. Leave empty for no limit.")
                    .foregroundStyle(scopeError == nil ? Color.secondary : Color.red)
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section {
                Button { Task { await add() } } label: {
                    HStack { Text(kind == .create ? "Create channel" : "Join channel"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(!valid || busy)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let p = prefill {
                name = kind == .hashtag ? String(p.name.drop { $0 == "#" }) : p.name
                key = p.secret
                scope = p.scope
            } else if kind == .joinPublic, name.isEmpty {
                name = "Public"
            }
        }
    }

    private var title: String {
        switch kind {
        case .create: "Create a private channel"
        case .joinPrivate: "Join a private channel"
        case .joinPublic: "Join Public"
        case .hashtag: "Join a hashtag channel"
        }
    }

    private var footer: String {
        switch kind {
        case .create: "Shown in your channel list; members can name it anything. You'll get its key and QR code to share next."
        case .joinPrivate: "The key exactly as the MeshCore app shows it, or scan the channel's QR code instead."
        case .joinPublic: "Uses MeshCore's shared Public key. You can rename it on your radio."
        case .hashtag: "Names are case-sensitive: #Hikers and #hikers are different channels."
        }
    }

    private func add() async {
        guard let api = model.api else { return }
        busy = true; error = nil
        defer { busy = false }
        let mode = switch kind { case .create: "random"; case .joinPrivate: "custom"; case .joinPublic: "public"; case .hashtag: "hashtag" }
        do {
            let r = try await api.addChannel(name: fullName, keyMode: mode,
                                             key: kind == .joinPrivate ? key.trimmingCharacters(in: .whitespaces) : nil,
                                             scope: cleanScope)
            onAdded(r, cleanScope, kind == .create)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ScanChannelView: View {
    let onLink: (ChannelCode.Link) -> Void
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            QRScanner { text in
                if let link = ChannelCode.parse(text) {
                    onLink(link)
                } else {
                    error = text.hasPrefix("meshcore://contact/") ? "That's a contact code. Add contacts from the Contacts tab."
                        : "That isn't a MeshCore channel code."
                }
            }
            .ignoresSafeArea()
            Text(error ?? "Point the camera at a channel QR code.")
                .foregroundStyle(error == nil ? Color.primary : Color.red)
                .padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .navigationTitle("Scan channel code")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// After creating a private channel: its key, once. MeshHome can't show it again later.
private struct CreatedChannelView: View {
    let name: String
    let link: ChannelCode.Link
    let onDone: () -> Void

    var body: some View {
        Form {
            Section {
                QRCodeImage(text: ChannelCode.uri(link)).frame(maxWidth: 260).frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                Text("\(name) is on your radio. Share it with the people you want in the channel. The key is shown only this once: MeshHome doesn't keep a copy it can show again.")
            }
            Section("Key") {
                Text(link.secret).font(.body.monospaced()).textSelection(.enabled)
                ShareLink(item: ChannelCode.uri(link)) { Label("Share channel link", systemImage: "square.and.arrow.up") }
                Button { UIPasteboard.general.string = link.secret } label: { Label("Copy key", systemImage: "doc.on.doc") }
            }
            Section { Button("Open channel", action: onDone).bold() }
        }
        .navigationTitle("Channel created")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
    }
}
