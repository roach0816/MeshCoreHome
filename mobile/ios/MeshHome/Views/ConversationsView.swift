import SwiftUI

/// Conversation list, with the open thread beside it on iPad (split view) or pushed on iPhone.
struct ConversationsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var showSettings = false

    private enum Filter: String, CaseIterable { case all = "All", unread = "Unread", favorites = "Favorites" }

    private var shown: [Conversation] {
        model.conversations.filter { c in
            (search.isEmpty || c.title.localizedCaseInsensitiveContains(search))
                && (filter != .unread || c.unread > 0)
                && (filter != .favorites || c.favorite)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                if let error = model.listError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                ForEach(shown) { c in
                    ConversationRow(conversation: c)
                        .tag(c.id)
                        .swipeActions(edge: .leading) {
                            if c.unread > 0 {
                                Button { Task { await model.markRead(c) } } label: {
                                    Label("Read", systemImage: "envelope.open")
                                }.tint(.blue)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button { Task { await model.toggleFavorite(c) } } label: {
                                Label(c.favorite ? "Unfavorite" : "Favorite", systemImage: c.favorite ? "star.slash" : "star")
                            }.tint(.yellow)
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
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        } detail: {
            if let id = selection, let c = model.conversations.first(where: { $0.id == id }) {
                ThreadView(conversation: c).id(c.id)
            } else {
                ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.kind == .channel ? "number" : "person.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversation.title).font(.headline).lineLimit(1)
                    if conversation.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    if conversation.muted { Image(systemName: "bell.slash").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let date = conversation.lastMessageAt {
                        Text(listTime(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(previewText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
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
