import MapKit
import SwiftUI

/// Nodes that share their position, filtered by type and by when they were last heard.
struct MeshMapView: View {
    @Environment(AppModel.self) private var model
    @State private var data: MapData?
    @State private var error: String?
    @State private var kinds: Set<Int> = [1, 2, 3, 4]
    @State private var heard: Heard = .all
    @State private var selected: TileMapView.Pin?

    private enum Heard: String, CaseIterable {
        case day = "Last 24 hours", week = "Last 7 days", month = "Last 30 days", all = "Any time"
        var seconds: TimeInterval? {
            switch self { case .day: 86_400; case .week: 604_800; case .month: 2_592_000; case .all: nil }
        }
    }

    private var pins: [TileMapView.Pin] {
        guard let data else { return [] }
        let cutoff = heard.seconds.map { Date.now.addingTimeInterval(-$0) }
        let nodes = data.nodes.filter { n in
            kinds.contains(n.kind) && (cutoff == nil || (n.lastAdvertAt ?? .distantPast) >= cutoff!)
        }
        let kindName = [1: "Companion", 2: "Repeater", 3: "Room server", 4: "Sensor"]
        return data.gateways.enumerated().map { i, g in
            .init(id: "gw\(i)", coordinate: .init(latitude: g.lat, longitude: g.lon), title: g.name, subtitle: "Your radio", kind: 0)
        } + nodes.map { n in
            let when = n.lastAdvertAt.map { "heard " + listTime($0) } ?? "never heard"
            return .init(id: n.id, coordinate: .init(latitude: n.lat, longitude: n.lon), title: n.displayName,
                         subtitle: "\(kindName[n.kind] ?? "Node") · \(when)", kind: n.kind)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if let data {
                    TileMapView(tiles: data.tiles, pins: pins) { selected = $0 }
                        .ignoresSafeArea(edges: .horizontal)
                    VStack(spacing: 4) {
                        if data.withoutLocation > 0 {
                            Text("\(data.withoutLocation) contact\(data.withoutLocation == 1 ? "" : "s") without a shared position")
                                .font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                        }
                        Text(data.tiles.attribution).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(.bottom, 8)
                } else if let error {
                    ContentUnavailableView("Map unavailable", systemImage: "map", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Show") {
                            ForEach([(1, "Companions"), (2, "Repeaters"), (3, "Room servers"), (4, "Sensors")], id: \.0) { k, label in
                                Toggle(label, isOn: Binding(get: { kinds.contains(k) },
                                                            set: { on in if on { kinds.insert(k) } else { kinds.remove(k) } }))
                            }
                        }
                        Picker("Heard", selection: $heard) { ForEach(Heard.allCases, id: \.self) { Text($0.rawValue) } }
                    } label: {
                        Image(systemName: kinds.count == 4 && heard == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter map")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh map")
                }
            }
            .sheet(item: Binding(get: { selected.map { IDString(id: $0.id) } }, set: { if $0 == nil { selected = nil } })) { s in
                if let node = data?.nodes.first(where: { $0.id == s.id }) {
                    if node.kind == 2 || node.kind == 3 {
                        RemoteManageView(contactID: node.id)
                    } else {
                        ContactActionsView(contactID: node.id)
                    }
                }
            }
            .task { await load() }
            .onChange(of: model.contactChanges) { _, _ in Task { await load() } }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { data = try await api.mapData(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct IDString: Identifiable { let id: String }
