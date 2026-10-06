import SwiftUI

/// The radio's contacts: search, filters, sorting (favourites first), favourite and block.
/// Tapping a person opens your conversation with them.
struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @State private var contacts: [Contact] = []
    @State private var total = 0
    @State private var page = 1
    @State private var search = ""
    @State private var show: Show = .all
    @State private var sort: Sort = .lastHeard
    @State private var ascending = false
    @State private var error: String?
    @State private var details: Contact?
    @State private var blocking: Contact?
    @State private var adding: AddContactView.Mode?
    @State private var managing: Contact?

    private enum Show: String, CaseIterable { case all, favorites, blocked, removed
        var label: String { self == .removed ? "Removed from radio" : rawValue.capitalized }
    }
    private enum Sort: String, CaseIterable { case lastHeard = "last_heard", name, kind
        var label: String { [.lastHeard: "Last heard", .name: "Name", .kind: "Type"][self]! }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                ForEach(contacts) { c in
                    Button { open(c) } label: { ContactRow(contact: c) }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .trailing) {
                            Button { Task { await setFavorite(c, !c.favorite) } } label: {
                                Label(c.favorite ? "Unfavorite" : "Favorite", systemImage: c.favorite ? "star.slash" : "star")
                            }.tint(.yellow)
                            Button { toggleBlock(c) } label: {
                                Label(c.blocked ? "Unblock" : "Block", systemImage: c.blocked ? "hand.raised.slash" : "hand.raised")
                            }.tint(c.blocked ? .gray : .red)
                        }
                        .contextMenu {
                            if c.isPerson { Button { open(c) } label: { Label("Message", systemImage: "bubble.left") } }
                            if c.kind == 2 || c.kind == 3 { Button { managing = c } label: { Label("Remote manage", systemImage: "slider.horizontal.3") } }
                            Button { details = c } label: { Label("Details", systemImage: "info.circle") }
                            Button { Task { await setFavorite(c, !c.favorite) } } label: {
                                Label(c.favorite ? "Remove from favorites" : "Add to favorites", systemImage: c.favorite ? "star.slash" : "star")
                            }
                            Button(role: c.blocked ? nil : .destructive) { toggleBlock(c) } label: { Label(c.blocked ? "Unblock" : "Block", systemImage: "hand.raised") }
                        }
                }
                if contacts.count < total {
                    Button("Show more") { Task { await load(page: page + 1) } }
                }
                if contacts.isEmpty && error == nil {
                    Text(search.isEmpty ? "No contacts" : "Nothing matches").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Search contacts")
            .refreshable { await load(page: 1) }
            .navigationTitle(total > 0 ? "Contacts (\(total))" : "Contacts")
            .toolbar {
                if model.features.contains("contact_import") { ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { adding = .scan } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                        Button { adding = .manual } label: { Label("Enter manually", systemImage: "keyboard") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add contact")
                } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $show) { ForEach(Show.allCases, id: \.self) { Text($0.label) } }
                        Picker("Sort by", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.label) } }
                        Toggle(sort == .lastHeard ? "Oldest first" : "Reverse order", isOn: $ascending)
                    } label: {
                        Image(systemName: show == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter and sort")
                }
            }
            .sheet(item: $managing) { RemoteManageView(contactID: $0.id) }
            .sheet(item: $details, onDismiss: { Task { await load(page: 1, keepPages: true) } }) {
                ContactActionsView(contactID: $0.id)
            }
            .sheet(isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
                if let mode = adding {
                    AddContactView(mode: mode) { _ in Task { await load(page: 1) } }
                }
            }
            .confirmationDialog("Block \(blocking?.displayName ?? "")?", isPresented: .constant(blocking != nil),
                                titleVisibility: .visible, presenting: blocking) { c in
                Button("Block", role: .destructive) { Task { await setBlocked(c, true) } }
                Button("Cancel", role: .cancel) { blocking = nil }
            } message: { _ in
                Text("Their messages are still archived, but hidden, never unread and silent. The contact stays on the radio.")
            }
            .task(id: "\(search)|\(show)|\(sort)|\(ascending)") {
                if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }  // debounce typing
                await load(page: 1)
            }
            .onChange(of: model.contactChanges) { _, _ in Task { await load(page: 1, keepPages: true) } }
        }
    }

    /// Unblocking is immediate; blocking asks first.
    private func toggleBlock(_ c: Contact) {
        if c.blocked { Task { await setBlocked(c, false) } } else { blocking = c }
    }

    /// People open your conversation; repeaters and room servers open Remote manage.
    private func open(_ c: Contact) {
        if c.isPerson { Task { await model.openConversation(with: c) } }
        else if c.kind == 2 || c.kind == 3 { managing = c }
        else { details = c }
    }

    private func load(page: Int, keepPages: Bool = false) async {
        guard let api = model.api else { return }
        // Name and type sort A→Z by default; last heard newest first.
        let natural = sort == .lastHeard ? "desc" : "asc"
        let order = ascending ? (natural == "asc" ? "desc" : "asc") : natural
        do {
            if keepPages && self.page > 1 {
                var all: [Contact] = []
                for p in 1...self.page { all += try await api.contacts(query: search, show: show.rawValue, sort: sort.rawValue, order: order, page: p).items }
                contacts = all
            } else {
                let result = try await api.contacts(query: search, show: show.rawValue, sort: sort.rawValue, order: order, page: page)
                contacts = page == 1 ? result.items : contacts + result.items
                total = result.total
                self.page = page
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setFavorite(_ c: Contact, _ on: Bool) async {
        do { try await model.api?.setContactFavorite(c.id, on) } catch { self.error = error.localizedDescription }
        await load(page: 1, keepPages: true)
        await model.refreshConversations()
    }

    private func setBlocked(_ c: Contact, _ on: Bool) async {
        blocking = nil
        do { try await model.api?.setContactBlocked(c.id, on) } catch { self.error = error.localizedDescription }
        await load(page: 1, keepPages: true)
        await model.refreshConversations()
    }
}

private struct ContactRow: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(contact.blocked ? Color.secondary : Color.accentColor)
                .frame(width: 36, height: 36)
                .background((contact.blocked ? Color.secondary : Color.accentColor).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(contact.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if contact.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    if contact.blocked { Text("Blocked").font(.caption2).foregroundStyle(.red) }
                }
                HStack(spacing: 4) {
                    Text(contact.kindLabel)
                    if !contact.onRadio { Text("· Removed from radio") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let heard = contact.lastAdvertAt {
                Text(listTime(heard)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch contact.kind {
        case 2: "antenna.radiowaves.left.and.right"
        case 3: "person.3"
        case 4: "sensor"
        default: "person.fill"
        }
    }
}
