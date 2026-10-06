import CoreLocation
import SwiftUI

/// The node's settings and tools. Each reads current values only when you tap refresh.
struct RemoteSettingsView: View {
    let store: RemoteStore
    let state: RemoteState

    var body: some View {
        Form {
            Section("Public info") {
                CliSettingRow(store: store, key: "name", label: "Name", kind: .text(maxBytes: 31))
                LabeledContent("Public key") {
                    Text(keyLines(state.contact.publicKey)).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
            Section("Tools") {
                tool("Radio settings", "dot.radiowaves.left.and.right") { RemoteRadioView(store: store) }
                tool("Owner info", "person.text.rectangle") { OwnerInfoView(store: store, state: state) }
                tool("Advert", "megaphone") { AdvertView(store: store) }
                tool("Advert intervals", "timer") {
                    Form {
                        CliSettingRow(store: store, key: "advert.interval", label: "Zero-hop interval (minutes)", kind: .number(0...240),
                                      hint: "60–240 minutes, or 0 to turn off.")
                        CliSettingRow(store: store, key: "flood.advert.interval", label: "Flood interval (hours)", kind: .number(0...168),
                                      hint: "3–168 hours, or 0 to turn off. Flood adverts reach the whole mesh: keep this long.")
                    }.navigationTitle("Advert intervals")
                }
                tool("Position", "mappin.and.ellipse") { RemotePositionView(store: store) }
                tool("Clock", "clock") { ClockView(store: store) }
                tool("Access control", "checkmark.shield") { ACLView(store: store, state: state) }
                tool("Admin password", "key") { AdminPasswordView(store: store) }
                tool("Guest password", "person.2") {
                    Form {
                        CliSettingRow(store: store, key: "guest.password", label: "Guest password", kind: .secret,
                                      hint: "Read-only access for others. Values are never stored by MeshHome.")
                    }.navigationTitle("Guest password")
                }
                tool("Change identity key", "touchid") { IdentityKeyView(store: store) }
                tool("Regions", "globe") { RegionsView(store: store, state: state) }
                tool("Neighbours", "point.3.connected.trianglepath.dotted") { NeighboursView(store: store, state: state) }
                tool("Network settings", "network") {
                    Form {
                        CliSettingRow(store: store, key: "path.hash.mode", label: "Path hash size",
                                      kind: .options([("0", "1 byte"), ("1", "2 bytes"), ("2", "3 bytes")]), hint: "Must match the rest of your mesh.")
                        CliSettingRow(store: store, key: "txdelay", label: "Flood transmit delay factor", kind: .decimal)
                        CliSettingRow(store: store, key: "direct.txdelay", label: "Direct transmit delay factor", kind: .decimal)
                        CliSettingRow(store: store, key: "af", label: "Airtime factor", kind: .decimal,
                                      hint: "Higher values make the node wait longer between transmissions.")
                        CliSettingRow(store: store, key: "loop.detect", label: "Loop detection",
                                      kind: .options([("off", "Off"), ("minimal", "Minimal"), ("moderate", "Moderate"), ("strict", "Strict")]))
                        CliSettingRow(store: store, key: "multi.acks", label: "Extra ACKs", kind: .options([("0", "Off"), ("1", "On")]))
                        CliSettingRow(store: store, key: "int.thresh", label: "Interference threshold", kind: .number(0...255))
                    }.navigationTitle("Network settings")
                }
                tool("Repeat settings", "repeat") {
                    Form {
                        CliSettingRow(store: store, key: "repeat", label: "Repeat packets", kind: .options([("on", "On"), ("off", "Off")]))
                        CliSettingRow(store: store, key: "flood.max", label: "Maximum flood hops", kind: .number(0...64))
                        CliSettingRow(store: store, key: "flood.max.unscoped", label: "Maximum hops without a region", kind: .number(0...64))
                        CliSettingRow(store: store, key: "flood.max.advert", label: "Maximum hops for flood adverts", kind: .number(0...64))
                    }.navigationTitle("Repeat settings")
                }
                tool("Telemetry", "thermometer.medium") { TelemetryView(store: store, state: state) }
                tool("Reboot", "power") { RebootView(store: store) }
                tool("Version", "cpu") { VersionView(store: store) }
            }
        }
    }

    private func tool<V: View>(_ title: String, _ icon: String, @ViewBuilder _ dest: @escaping () -> V) -> some View {
        NavigationLink { dest().navigationBarTitleDisplayMode(.inline) } label: { Label(title, systemImage: icon) }
    }
}

// MARK: - A setting read with "get <key>" and written with "set <key> <value>"

struct CliSettingRow: View {
    enum Kind {
        case text(maxBytes: Int), number(ClosedRange<Int>), decimal, secret, options([(String, String)])
    }
    let store: RemoteStore
    let key: String
    let label: String
    let kind: Kind
    var hint: String?
    @State private var draft: String?
    @State private var reply: String?

    private var cached: String? { store.value(key)?.value }
    private var text: String { draft ?? cached ?? "" }
    private var problem: String? {
        guard let d = draft else { return nil }
        switch kind {
        case .number(let r): return Int(d).map { r.contains($0) } == true ? nil : "A whole number from \(r.lowerBound) to \(r.upperBound)."
        case .decimal: return Double(d) == nil ? "Enter a number." : nil
        case .text(let max): return d.utf8.count > max ? "At most \(max) bytes." : d.isEmpty ? "Can't be empty." : nil
        case .secret: return d.contains(" ") ? "No spaces." : nil
        case .options: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Button { Task { reply = nil; _ = await store.cli("get \(key)"); draft = nil } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(store.busy).accessibilityLabel("Read \(label) from the node")
                Button {
                    Task {
                        let r = await store.cli("set \(key) \(text)")
                        reply = r ?? "No reply"
                        if cliOK(r) { draft = nil; _ = await store.cli("get \(key)") }
                    }
                } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).disabled(store.busy || draft == nil || problem != nil)
                    .accessibilityLabel("Save \(label) to the node")
            }
            switch kind {
            case .options(let opts):
                Picker(label, selection: Binding(get: { text }, set: { draft = $0 })) {
                    if cached == nil && draft == nil { Text("Not read yet").tag("") }
                    ForEach(opts, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
            case .secret:
                SecureField(cached == nil ? "Not read yet" : "Password", text: Binding(get: { text }, set: { draft = $0 }))
            default:
                TextField(cached == nil ? "Not read yet" : "", text: Binding(get: { text }, set: { draft = $0 }))
                    .keyboardType({ if case .number = kind { return .numberPad }; if case .decimal = kind { return .decimalPad }; return .default }())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            else if let reply { Text(cliOK(reply) ? "Saved." : reply).font(.caption).foregroundStyle(cliOK(reply) ? .green : .red) }
            else if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            Text(store.value(key).map { fetchedText($0.at) } ?? "Not read yet").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Tools

private struct RemoteRadioView: View {
    let store: RemoteStore
    @Environment(AppModel.self) private var model
    @State private var presets: [RadioPreset] = []
    @State private var freq = ""
    @State private var bw = ""
    @State private var sf = 0
    @State private var cr = 0
    @State private var reply: String?

    var body: some View {
        Form {
            Section {
                Button { Task { await read() } } label: { Label("Read from node", systemImage: "arrow.clockwise") }.disabled(store.busy)
                Text(store.value("radio").map { fetchedText($0.at) } ?? "Not read yet").font(.caption).foregroundStyle(.secondary)
            }
            if !presets.isEmpty {
                Section("Preset") {
                    Menu("Apply a preset…") {
                        ForEach(presets) { p in
                            Button(p.title) { freq = trim(p.freqMhz); bw = trim(p.bwKhz); sf = p.sf; cr = p.cr }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Frequency (MHz)") { TextField("", text: $freq).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                LabeledContent("Bandwidth (kHz)") { TextField("", text: $bw).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                Stepper("Spreading factor \(sf)", value: $sf, in: 5...12)
                Stepper("Coding rate 4/\(cr)", value: $cr, in: 5...8)
            } footer: {
                Text("All nodes in your mesh must use the same settings. A wrong value can cut the node off: you'd have to fix it in person.")
            }
            Section {
                Button("Save to node") {
                    Task { reply = await store.cli("set radio \(freq),\(bw),\(sf),\(cr)") ?? "No reply" }
                }
                .disabled(store.busy || Double(freq) == nil || Double(bw) == nil || sf == 0)
                if let reply { Text(cliOK(reply) ? "Saved. The node applies it after a reboot." : reply).font(.caption) }
            }
            Section {
                CliSettingRow(store: store, key: "tx", label: "Transmit power (dBm)", kind: .number(1...30))
            }
        }
        .navigationTitle("Radio settings")
        .task {
            presets = (try? await model.api?.presets().presets) ?? []
            fill()
        }
    }

    private func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    private func read() async {
        _ = await store.cli("get radio")
        fill()
    }

    private func fill() {
        guard let v = store.value("radio")?.value else { return }
        let p = v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard p.count >= 4 else { return }
        freq = p[0]; bw = p[1]; sf = Int(p[2]) ?? 0; cr = Int(p[3]) ?? 0
    }
}

private struct OwnerInfoView: View {
    let store: RemoteStore
    let state: RemoteState
    @State private var text: String?
    @State private var reply: String?

    private var current: String { text ?? store.value("owner.info")?.value.replacingOccurrences(of: "|", with: "\n") ?? "" }

    var body: some View {
        Form {
            Section {
                TextEditor(text: Binding(get: { current }, set: { text = $0 })).frame(minHeight: 120)
            } footer: {
                Text("Anyone can request this, without a password. \(store.value("owner.info").map { fetchedText($0.at) } ?? "Not read yet").")
            }
            Section {
                Button("Read from node") { Task { _ = await store.cli("get owner.info"); text = nil } }.disabled(store.busy)
                Button("Save to node") {
                    Task {
                        let encoded = current.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "|")
                        reply = await store.cli("set owner.info \(encoded)") ?? "No reply"
                        if cliOK(reply) { text = nil }
                    }
                }
                .disabled(store.busy || text == nil)
                if let reply { Text(cliOK(reply) ? "Saved." : reply).font(.caption) }
            }
        }
        .navigationTitle("Owner info")
    }
}

private struct AdvertView: View {
    let store: RemoteStore
    @State private var reply: String?
    var body: some View {
        Form {
            Section {
                Button("Send a zero-hop advert") { Task { reply = await store.cli("advert.zerohop") ?? "No reply" } }
                Button("Send a flood advert") { Task { reply = await store.cli("advert") ?? "No reply" } }
            } footer: {
                Text("A zero-hop advert reaches only nodes in direct range. A flood advert is repeated across the whole mesh: use it sparingly.")
            }
            .disabled(store.busy)
            if let reply { Text(reply).font(.caption.monospaced()) }
        }
        .navigationTitle("Advert")
    }
}

private struct RemotePositionView: View {
    let store: RemoteStore
    @State private var picking = false
    @State private var reply: String?

    private var lat: Double? { store.value("lat").flatMap { Double($0.value) } }
    private var lon: Double? { store.value("lon").flatMap { Double($0.value) } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Latitude", value: lat.map { String(format: "%.5f", $0) } ?? "—")
                LabeledContent("Longitude", value: lon.map { String(format: "%.5f", $0) } ?? "—")
                Button("Read from node") { Task { _ = await store.cli("get lat"); _ = await store.cli("get lon") } }.disabled(store.busy)
                Button("Choose on the map…") { picking = true }.disabled(store.busy)
            } footer: {
                Text("Two short requests each way (latitude, then longitude). \(store.value("lat").map { fetchedText($0.at) } ?? "Not read yet").")
            }
            if let reply { Text(reply).font(.caption) }
        }
        .navigationTitle("Position")
        .sheet(isPresented: $picking) {
            LocationPickerView(title: "Node position",
                               start: lat.flatMap { la in lon.map { CLLocationCoordinate2D(latitude: la, longitude: $0) } }) { c in
                Task {
                    let a = await store.cli(String(format: "set lat %.6f", c.latitude))
                    let b = await store.cli(String(format: "set lon %.6f", c.longitude))
                    reply = cliOK(a) && cliOK(b) ? "Saved." : (b ?? a ?? "No reply")
                    _ = await store.cli("get lat"); _ = await store.cli("get lon")
                }
            }
        }
    }
}

private struct ClockView: View {
    let store: RemoteStore
    @State private var clock: String?
    @State private var reply: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("Node's clock", value: clock ?? "—")
                Button("Read the node's clock") { Task { clock = await store.cli("clock") } }
                Button("Set it from this phone") { Task { reply = await store.cli("time \(Int(Date.now.timeIntervalSince1970))") ?? "No reply" } }
            } footer: {
                Text("The firmware refuses to move its clock backwards.")
            }
            .disabled(store.busy)
            if let reply { Text(reply).font(.caption.monospaced()) }
        }
        .navigationTitle("Clock")
    }
}

private struct ACLView: View {
    let store: RemoteStore
    let state: RemoteState
    @State private var key = ""
    @State private var perm = 3
    private let perms = [(0, "Guest"), (1, "Read only"), (2, "Read / write"), (3, "Admin")]

    var body: some View {
        Form {
            Section {
                Button("Request the access list") { Task { await store.request("acl") } }.disabled(store.busy)
                if let acl = state.sections.acl {
                    if acl.data.acl.isEmpty { Text("No entries.").foregroundStyle(.secondary) }
                    ForEach(acl.data.acl) { a in
                        HStack {
                            Text(state.names[a.key] ?? a.key.uppercased()).font(.callout).lineLimit(1)
                            Spacer()
                            Menu(perms.first { $0.0 == a.perm }?.1 ?? "\(a.perm)") {
                                ForEach(perms, id: \.0) { p in Button(p.1) { Task { _ = await store.cli("setperm \(a.key) \(p.0)") } } }
                                Button("Remove access", role: .destructive) { Task { _ = await store.cli("setperm \(a.key)") } }
                            }
                        }
                    }
                }
            } footer: {
                Text(fetchedText(state.sections.acl?.at))
            }
            Section {
                TextField("Public key (at least 12 hex characters)", text: $key)
                    .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Rights", selection: $perm) { ForEach(perms, id: \.0) { Text($0.1).tag($0.0) } }
                Button("Add or change") {
                    Task { _ = await store.cli("setperm \(key.trimmingCharacters(in: .whitespaces).lowercased()) \(perm)"); key = "" }
                }
                .disabled(store.busy || key.trimmingCharacters(in: .whitespaces).count < 12)
            } header: {
                Text("Add or change access")
            } footer: {
                Text("Refresh the list afterwards to check.")
            }
        }
        .navigationTitle("Access control")
    }
}

private struct AdminPasswordView: View {
    let store: RemoteStore
    @State private var a = ""
    @State private var b = ""
    @State private var reply: String?
    private var problem: String? {
        if a.contains(" ") { return "Spaces aren't allowed." }
        if a.count > 15 { return "Up to 15 characters." }
        if !b.isEmpty && a != b { return "The passwords don't match." }
        return nil
    }
    var body: some View {
        Form {
            Section {
                SecureField("New admin password", text: $a)
                SecureField("Repeat it", text: $b)
            } footer: {
                Text(problem ?? "Up to 15 characters. Keep it safe: without it, the node can only be reset in person.")
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
            }
            Section {
                Button("Change password") {
                    Task { reply = await store.cli("password \(a)") ?? "No reply"; if cliOK(reply) { a = ""; b = "" } }
                }
                .disabled(store.busy || a.isEmpty || a != b || problem != nil)
                if let reply { Text(cliOK(reply) ? "Password changed." : reply).font(.caption) }
            }
        }
        .navigationTitle("Admin password")
    }
}

private struct IdentityKeyView: View {
    let store: RemoteStore
    @State private var prefix = ""
    @State private var confirm = false
    @State private var newKey: String?
    private var valid: Bool { prefix.isEmpty || (prefix.count <= 4 && prefix.allSatisfy(\.isHexDigit)) }
    var body: some View {
        Form {
            Section {
                TextField("Prefix (optional, hex)", text: $prefix).font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("The node gets a new key starting with these hex characters. 1–2 characters are instant; 4 can take up to a minute. Leave empty for a random key. Every node that knows the old key must re-learn it from the next advert.")
            }
            Section {
                Button("Change identity key", role: .destructive) { confirm = true }.disabled(store.busy || !valid)
                if store.busy { ProgressView() }
                if let newKey { Text("New key: \(newKey)").font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        .navigationTitle("Identity key")
        .confirmationDialog("Give this node a new identity?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Change key", role: .destructive) { Task { newKey = await store.changeIdentity(prefix: prefix.lowercased()) } }
        }
    }
}

private struct RegionsView: View {
    let store: RemoteStore
    let state: RemoteState
    @State private var name = ""
    @State private var parent = ""
    @State private var reply: String?
    private var valid: Bool { !name.isEmpty && !name.contains(" ") }

    var body: some View {
        Form {
            Section {
                Button("Read the region table") { Task { _ = await store.cli("region") } }.disabled(store.busy)
                Text(state.values["region"]?.value ?? state.sections.regions?.data.text ?? "Tap to read the node's region table.")
                    .font(.callout.monospaced()).textSelection(.enabled)
            } footer: {
                Text("* is the wildcard (floods without a region), ^ marks home, F means floods are repeated.")
            }
            Section("Change a region") {
                TextField("Region name, e.g. us-md", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Parent (optional)", text: $parent).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Add or move") { run("region put \(name)\(parent.isEmpty ? "" : " \(parent)")") }.disabled(!valid)
                Button("Allow floods") { run("region allowf \(name)") }.disabled(!valid)
                Button("Deny floods") { run("region denyf \(name)") }.disabled(!valid)
                Button("Make home") { run("region home \(name)") }.disabled(!valid)
                Button("Remove", role: .destructive) { run("region remove \(name)") }.disabled(!valid)
            }
            Section {
                Button("Save regions") { run("region save") }.bold()
                if let reply { Text(reply).font(.caption.monospaced()) }
            } footer: {
                Text("Changes apply now but are lost on reboot until saved.")
            }
        }
        .disabled(store.busy)
        .navigationTitle("Regions")
    }

    private func run(_ c: String) { Task { reply = await store.cli(c) ?? "No reply" } }
}

private struct NeighboursView: View {
    let store: RemoteStore
    let state: RemoteState
    var body: some View {
        Form {
            Section {
                Button("Request neighbours") { Task { await store.request("neighbours") } }.disabled(store.busy)
                if let nb = state.sections.neighbours {
                    if nb.data.neighbours.isEmpty { Text("It hasn't heard other repeaters directly.").foregroundStyle(.secondary) }
                    ForEach(nb.data.neighbours) { n in
                        LabeledContent(state.names[n.pubkey] ?? n.pubkey.uppercased(),
                                       value: String(format: "SNR %.1f dB · %@ ago", n.snr, durationText(n.secsAgo)))
                    }
                }
            } footer: {
                Text(fetchedText(state.sections.neighbours?.at))
            }
        }
        .navigationTitle("Neighbours")
    }
}

private struct TelemetryView: View {
    let store: RemoteStore
    let state: RemoteState
    var body: some View {
        Form {
            Section {
                Button("Request telemetry") { Task { await store.request("telemetry") } }.disabled(store.busy)
                if let t = state.sections.telemetry {
                    if t.data.lpp.isEmpty { Text("The node sent no readings.").foregroundStyle(.secondary) }
                    ForEach(Array(t.data.lpp.enumerated()), id: \.offset) { _, r in
                        LabeledContent("\(r.type.replacingOccurrences(of: "_", with: " ")) · ch \(r.channel)", value: r.value.description)
                    }
                }
            } footer: {
                Text(fetchedText(state.sections.telemetry?.at))
            }
        }
        .navigationTitle("Telemetry")
    }
}

private struct RebootView: View {
    let store: RemoteStore
    @State private var confirm = false
    var body: some View {
        Form {
            Section {
                Button("Reboot the node", role: .destructive) { confirm = true }.disabled(store.busy)
            } footer: {
                Text("It stops repeating for a few seconds and forgets logins: you'll need to log in again.")
            }
        }
        .navigationTitle("Reboot")
        .confirmationDialog("Reboot this node?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) { Task { _ = await store.cli("reboot") } }
        } message: { Text("Messages relayed through it are dropped while it restarts.") }
    }
}

private struct VersionView: View {
    let store: RemoteStore
    @State private var ver: String?
    @State private var board: String?
    var body: some View {
        Form {
            LabeledContent("Firmware", value: ver ?? "—")
            LabeledContent("Board", value: board ?? "—")
            Button("Read") { Task { ver = await store.cli("ver"); board = await store.cli("board") } }.disabled(store.busy)
        }
        .navigationTitle("Version")
    }
}
