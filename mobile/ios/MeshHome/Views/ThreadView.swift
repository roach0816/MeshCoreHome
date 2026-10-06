import SwiftUI

/// One conversation: day sections, delivery states, older pages on demand, and the composer.
struct ThreadView: View {
    let conversation: Conversation
    @Environment(AppModel.self) private var model
    @State private var messages: [Message] = []
    @State private var hasMore = false
    @State private var loading = true
    @State private var error: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var infoFor: Message?
    @State private var showInfo = false
    @State private var contactID: String?
    @State private var deleting: Message?

    private var days: [(day: Date, messages: [Message])] {
        let cal = Calendar.current
        return Dictionary(grouping: messages) { cal.startOfDay(for: $0.createdAt) }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: .sectionHeaders) {
                    if hasMore {
                        Button("Load earlier messages") { Task { await loadEarlier() } }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    ForEach(days, id: \.day) { day in
                        Section {
                            ForEach(day.messages) { m in
                                MessageBubble(message: m, kind: conversation.kind).id(m.id)
                                    .contextMenu {
                                        Button { infoFor = m } label: { Label("Message details", systemImage: "info.circle") }
                                        Button { UIPasteboard.general.string = m.body } label: { Label("Copy text", systemImage: "doc.on.doc") }
                                        Button(role: .destructive) { deleting = m } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        } header: {
                            Text(dayHeading(day.day))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                    }
                    if !loading && messages.isEmpty {
                        Text("No messages yet").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay { if loading && messages.isEmpty { ProgressView() } }
            .safeAreaInset(edge: .bottom) { composer(proxy) }
            .onChange(of: messages.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $infoFor) { m in MessageInfoView(message: m, kind: conversation.kind) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await openInfo() } } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel(conversation.kind == .channel ? "Channel info" : "Contact info")
            }
        }
        .sheet(isPresented: $showInfo) { ChannelInfoView(conversation: conversation) }
        .sheet(item: Binding(get: { contactID.map(IDBox.init) }, set: { contactID = $0?.id })) { ContactActionsView(contactID: $0.id) }
        .confirmationDialog("Delete this message?", isPresented: .constant(deleting != nil), titleVisibility: .visible, presenting: deleting) { m in
            Button("Delete", role: .destructive) { Task { await delete(m) } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("Removes it from MeshHome's archive only. Nothing is sent over the radio.")
        }
        .task {
            if messages.isEmpty, let cached = Cache.load([Message].self, cacheName) { messages = cached; loading = false }
            await refresh()
        }
        .onChange(of: model.changes) { _, _ in
            if model.lastChangedConversation == nil || model.lastChangedConversation == conversation.id {
                Task { await refresh() }
            }
        }
    }

    // MARK: Composer

    private var bytes: Int { draft.utf8.count }

    private func composer(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 4) {
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(conversation.kind == .channel ? "Message \(conversation.title)" : "Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bytes > conversation.maxBytes || sending)
                .accessibilityLabel("Send")
            }
            if bytes > conversation.maxBytes * 3 / 4 {
                Text("\(bytes)/\(conversation.maxBytes) bytes")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(bytes > conversation.maxBytes ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Data

    /// Reloads the newest page and merges it in (new messages and changed delivery states).
    private func refresh() async {
        guard let api = model.api else { return }
        do {
            let page = try await api.messages(conversation.id)
            merge(page.messages)
            Cache.save(Array(messages.suffix(100)), cacheName)
            if messages.count <= page.messages.count { hasMore = page.hasMore }
            error = nil
            if let last = messages.last { await model.markRead(conversation, position: last.position) }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func openInfo() async {
        if conversation.kind == .channel { showInfo = true; return }
        guard let api = model.api else { return }
        do {
            if let id = try await api.conversationInfo(conversation.id).contact?.id { contactID = id }
            else { error = "This conversation's contact isn't known." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var cacheName: String { "messages-\(conversation.id)" }

    private func delete(_ m: Message) async {
        deleting = nil
        guard let api = model.api else { return }
        do {
            try await api.deleteMessage(m.id)
            messages.removeAll { $0.id == m.id }
            Cache.save(Array(messages.suffix(100)), cacheName)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadEarlier() async {
        guard let api = model.api, let first = messages.first else { return }
        do {
            let page = try await api.messages(conversation.id, before: first.position)
            merge(page.messages)
            hasMore = page.hasMore
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func merge(_ incoming: [Message]) {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for m in incoming { byID[m.id] = m }
        messages = byID.values.sorted { $0.position < $1.position }
    }

    private func send() async {
        guard let api = model.api else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        defer { sending = false }
        do {
            // The same client_message_id on a retry can never send twice.
            let sent = try await api.sendMessage(conversation.id, body: text, clientMessageID: UUID().uuidString)
            merge([sent])
            draft = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MessageBubble: View {
    let message: Message
    let kind: Conversation.Kind

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            if !message.isOutgoing, kind == .channel, let who = message.senderLabel {
                Text(who).font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
            Text(message.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(message.isOutgoing ? .white : .primary)
                .background(message.isOutgoing ? Color.accentColor : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 4) {
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                if message.isOutgoing {
                    Text("· \(stateLabel(message.state, kind: kind))")
                        .foregroundStyle(["failed", "expired"].contains(message.state) ? .red : .secondary)
                }
                if message.isSimulated { Text("· SIM").foregroundStyle(.orange) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .padding(message.isOutgoing ? .leading : .trailing, 48)
        .accessibilityElement(children: .combine)
    }
}

private func dayHeading(_ day: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(day) { return "Today" }
    if cal.isDateInYesterday(day) { return "Yesterday" }
    return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
}

private struct IDBox: Identifiable { let id: String }
