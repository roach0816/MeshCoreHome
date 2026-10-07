import SwiftUI

/// Conversation list, with the open thread beside it on iPad (split view) or pushed on iPhone.
struct ConversationsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var deleting: Conversation?
    @State private var addingChannel = false
    @State private var openAfterAdd: String?
    @State private var filter: Filter = .all
    @State private var showSettings = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var deleteTitle: String {
        guard let d = deleting else { return "" }
        return d.kind == .channel ? "Clear the history of \(d.title)?" : "Delete the conversation with \(d.title)?"
    }

    private enum Filter: String, CaseIterable { case all = "All", unread = "Unread", favorites = "Favorites" }

    private var shown: [Conversation] {
        model.conversations.filter { c in
            (search.isEmpty || c.title.localizedCaseInsensitiveContains(search))
                && (filter != .unread || c.unread > 0)
                && (filter != .favorites || c.favorite)
        }
    }

    /// iPhone: a push stack keyed by conversation, so list updates (frequent on a busy mesh)
    /// never close the open thread. iPad: the list beside the thread.
    var body: some View {
        @Bindable var model = model
        if sizeClass == .compact {
            NavigationStack(path: $model.conversationPath) {
                list(compact: true)
                    .navigationDestination(for: String.self) { id in ThreadContainer(id: id) }
            }
            .onChange(of: model.selectedConversation) { _, id in
                // Opened from elsewhere (Contacts, Add channel): show it.
                if let id, model.conversationPath.last != id { model.conversationPath = [id] }
            }
        } else {
            NavigationSplitView {
                list(compact: false)
            } detail: {
                if let id = model.selectedConversation { ThreadContainer(id: id).id(id) }
                else { ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right") }
            }
        }
    }

    @ViewBuilder private func list(compact: Bool) -> some View {
        @Bindable var model = model
            List(selection: compact ? nil : $model.selectedConversation) {  // iPhone: no selection, or List pops the stack
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                if let error = model.listError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if model.offline {
                    Label("Can't reach the server. Showing the last saved copy.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(shown) { c in
                    Group {
                        if compact {
                            NavigationLink(value: c.id) { ConversationRow(conversation: c) }
                        } else {
                            ConversationRow(conversation: c).tag(c.id)
                        }
                    }
                        .swipeActions(edge: .leading) {
                            if c.unread > 0 {
                                Button { Task { await model.markRead(c) } } label: {
                                    Label("Read", systemImage: "envelope.open")
                                }.tint(.blue)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = c } label: { Label("Delete", systemImage: "trash") }
                            Button { Task { await model.toggleMuted(c) } } label: {
                                Label(c.muted ? "Unmute" : "Mute", systemImage: c.muted ? "bell" : "bell.slash")
                            }.tint(.indigo)
                            Button { Task { await model.toggleFavorite(c) } } label: {
                                Label(c.favorite ? "Unfavorite" : "Favorite", systemImage: c.favorite ? "star.slash" : "star")
                            }.tint(.yellow)
                        }
                        .contextMenu {
                            if c.unread > 0 {
                                Button { Task { await model.markRead(c) } } label: { Label("Mark as read", systemImage: "envelope.open") }
                            }
                            Button { Task { await model.toggleFavorite(c) } } label: {
                                Label(c.favorite ? "Remove from favorites" : "Add to favorites", systemImage: c.favorite ? "star.slash" : "star")
                            }
                            Button { Task { await model.toggleMuted(c) } } label: {
                                Label(c.muted ? "Unmute" : "Mute", systemImage: c.muted ? "bell" : "bell.slash")
                            }
                            Button(role: .destructive) { deleting = c } label: {
                                Label(c.kind == .channel ? "Clear history" : "Delete", systemImage: "trash")
                            }
                        }
                }
                if shown.isEmpty && model.listError == nil {
                    Text(model.conversations.isEmpty ? "No conversations yet" : "Nothing matches")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Search conversations")
            .refreshable { await model.refreshConversations() }
            .navigationTitle(model.me?.homeName ?? "MeshHome")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addingChannel = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add channel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $addingChannel, onDismiss: {
                // Open the new channel only after the sheet is gone, or iPhone navigation drops the push.
                guard let id = openAfterAdd else { return }
                openAfterAdd = nil
                Task {
                    await model.refreshConversations()
                    model.selectedConversation = id
                }
            }) { AddChannelView { openAfterAdd = $0 } }
            .confirmationDialog(deleteTitle, isPresented: .constant(deleting != nil), titleVisibility: .visible, presenting: deleting) { c in
                Button(c.kind == .channel ? "Clear history" : "Delete conversation", role: .destructive) {
                    Task { await model.delete(c) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { c in
                Text(c.kind == .channel
                     ? "Removes this channel's messages from MeshHome's archive. The channel stays on the radio."
                     : "Removes this conversation from MeshHome's archive. Nothing is sent, and it reappears if \(c.title) writes again.")
            }
    }
}

/// The thread for a conversation id, following the live list (title, read position, etc.).
private struct ThreadContainer: View {
    let id: String
    @Environment(AppModel.self) private var model
    var body: some View {
        if let c = model.conversations.first(where: { $0.id == id }) {
            ThreadView(conversation: c)
        } else {
            ContentUnavailableView("Conversation not found", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("It may have been deleted."))
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.kind == .channel ? "number" : "person.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                // At accessibility text sizes the name gets its own lines instead of being cut short.
                let large = typeSize.isAccessibilitySize
                HStack {
                    Text(conversation.title).font(.headline).lineLimit(large ? 3 : 1)
                    if conversation.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    if conversation.muted { Image(systemName: "bell.slash").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if !large, let date = conversation.lastMessageAt {
                        Text(listTime(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if large, let date = conversation.lastMessageAt {
                    Text(listTime(date)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(previewText).font(.subheadline).foregroundStyle(.secondary).lineLimit(large ? 2 : 1)
                    Spacer()
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)")
                            .font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(conversation.muted ? Color.gray : Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var previewText: String {
        guard let p = conversation.preview else { return "No messages yet" }
        if p.direction == "out" { return "You: \(p.body)" }
        if conversation.kind == .channel, let who = p.senderLabel { return "\(who): \(p.body)" }
        return p.body
    }
}

func listTime(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
