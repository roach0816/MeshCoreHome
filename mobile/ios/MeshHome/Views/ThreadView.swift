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
    /// The first load scrolls straight into place; later new messages animate in.
    @State private var settled = false
    /// How far you'd read when the thread opened (unread messages come after it), and whether
    /// any were unread. Kept for this visit, though the conversation is marked read at once.
    @State private var readMark: Int?
    @State private var hadUnread = false
    /// Where to jump once the first load is in: the first unread message, or the newest.
    @State private var jump: Jump?
    private struct Jump: Equatable { let id: String; let toTop: Bool }
    @State private var showInfo = false
    @State private var contactID: String?
    @State private var deleting: Message?
    @FocusState private var composing: Bool

    /// The first message you hadn't read when you opened the thread (from someone else).
    private var firstUnreadID: String? {
        guard hadUnread, let mark = readMark else { return nil }
        return messages.first { $0.position > mark && !$0.isOutgoing }?.id
    }

    private static let bottomID = "thread-bottom"

    /// Scroll to the end, again once lazily-laid-out rows have their real heights (a single jump
    /// can land short when row heights were only estimated).
    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        let go = { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        if animated { withAnimation { go() } } else { go() }
        for delay in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { go() }
        }
    }

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
                                if m.id == firstUnreadID { UnreadDivider().id("unread-divider") }
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
                    // The very end of the thread: scrolling here shows the newest message in full.
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            // Keep the bottom in place when the view shrinks (the keyboard), so it never covers
            // the newest message.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .overlay { if loading && messages.isEmpty { ProgressView() } }
            .safeAreaInset(edge: .bottom) { composer(proxy) }
            .onChange(of: messages.last?.id) { _, id in
                // Later arrivals: follow the conversation down.
                if settled, id != nil { scrollToEnd(proxy, animated: true) }
            }
            .onChange(of: composing) { _, focused in
                // The keyboard shrinks the view: bring the newest message above it, as Messages does.
                guard focused else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { scrollToEnd(proxy, animated: true) }
            }
            .onChange(of: jump) { _, j in
                guard let j else { return }
                // After this layout pass, so the target row exists.
                // The unread line lands a little below the top, clear of the pinned date label.
                DispatchQueue.main.async {
                    if j.toTop { proxy.scrollTo("unread-divider", anchor: UnitPoint(x: 0.5, y: 0.08)) }
                    else { scrollToEnd(proxy, animated: false) }
                }
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
            if readMark == nil {
                readMark = conversation.readPosition
                hadUnread = conversation.unread > 0
            }
            if messages.isEmpty, let cached = Cache.load([Message].self, cacheName) { messages = cached; loading = false }
            // Not tied to this view's task: SwiftUI may cancel and restart it as the list re-renders,
            // which would otherwise abort the load half-way ("cancelled").
            await Task { await openingLoad() }.value
            // Jump to the unread line only when the unread messages won't fit on screen; a few
            // fit at the bottom (line still visible above them), with no empty space below.
            let unreadCount = readMark.map { mark in messages.filter { $0.position > mark && !$0.isOutgoing }.count } ?? 0
            if let target = firstUnreadID, unreadCount > 6 {
                jump = Jump(id: target, toTop: true)
            } else if let last = messages.last {
                jump = Jump(id: last.id, toTop: false)
            }
            try? await Task.sleep(for: .milliseconds(400))
            settled = true
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
                    .focused($composing)
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
        } catch is CancellationError {
            // superseded by a newer load
        } catch let e as URLError where e.code == .cancelled {
            // superseded by a newer load
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

    /// The newest page, plus earlier pages back to the first unread message (up to 200 messages).
    private func openingLoad() async {
        await refresh()
        guard hadUnread, let mark = readMark else { return }
        var pages = 1
        while hasMore, pages < 4, let first = messages.first, first.position > mark + 1 {
            await loadEarlier()
            pages += 1
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
            hadUnread = false  // you've replied: the "New messages" line has done its job
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

/// Marks where unread messages begin.
private struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.red).frame(height: 1)
            Text("New messages").font(.caption.weight(.semibold)).foregroundStyle(.red).fixedSize()
            Rectangle().fill(Color.red).frame(height: 1)
        }
        .padding(.vertical, 6)
        .accessibilityLabel("New messages start here")
    }
}
