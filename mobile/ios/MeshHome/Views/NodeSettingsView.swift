import CoreLocation
import SwiftUI

/// The connected radio's own configuration. Each section saves on its own; the server checks values
/// against the firmware's limits before anything is sent.
struct NodeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var config: NodeConfig?
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        Form {
            if let notice { Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            if let c = config {
                Section {
                    LabeledContent("Firmware", value: [c.firmware.version, c.firmware.model].compactMap { $0 }.joined(separator: " · "))
                    if c.simulated { Text("Simulated radio").foregroundStyle(Palette.simulated) }
                }
                Section("Settings") {
                    link("Identity and location", "person.crop.circle") { IdentitySection(config: c, save: save) }
                    link("LoRa radio", "dot.radiowaves.left.and.right") { RadioSection(config: c, save: save) }
                    link("Channels (\(c.channels.count) of \(c.maxChannels))", "number") { ChannelsSection(config: c, reload: load) }
                    link("Contacts and routing", "point.topleft.down.to.point.bottomright.curvepath") { BehaviorSection(config: c, save: save) }
                    link("Telemetry", "thermometer.medium") { TelemetrySection(config: c, save: save) }
                    if c.tuning != nil { link("Advanced timing", "timer") { TuningSection(config: c, save: save) } }
                    if c.customVars != nil { link("Firmware variables", "slider.horizontal.3") { CustomVarsSection(config: c, setVar: setVar) } }
                }
                Section("Actions") {
                    Button("Send a zero-hop advert") { act("advert", flood: false, done: "Advert sent to nodes in direct range.") }
                    Button("Send a flood advert") { act("advert", flood: true, done: "Advert sent across the mesh.") }
                    Button("Sync the radio's clock") { act("sync-clock", done: "Clock set from the server.") }
                    Button("Reboot the radio", role: .destructive) { act("reboot", done: "Rebooting. MeshHome reconnects automatically.") }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Node settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func link<V: View>(_ title: String, _ icon: String, @ViewBuilder _ dest: @escaping () -> V) -> some View {
        NavigationLink { dest().navigationBarTitleDisplayMode(.inline) } label: { Label(title, systemImage: icon) }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { config = try await api.nodeConfig(); error = nil } catch { self.error = error.localizedDescription }
    }

    /// Returns nil on success, or the error to show.
    private func save(_ section: String, _ body: [String: JSONBody]) async -> String? {
        guard let api = model.api else { return "Not signed in" }
        do {
            config = try await api.putNodeConfig(section, body)
            notice = "Saved to the radio."; error = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func setVar(_ key: String, _ value: String) async -> String? {
        guard let api = model.api else { return "Not signed in" }
        do { config = try await api.setCustomVar(key: key, value: value); return nil } catch { return error.localizedDescription }
    }

    private func act(_ action: String, flood: Bool? = nil, done: String) {
        Task {
            guard let api = model.api else { return }
            do { try await api.nodeAction(action, flood: flood); notice = done; error = nil }
            catch { self.error = error.localizedDescription; notice = nil }
        }
    }
}

typealias SaveSection = (String, [String: JSONBody]) async -> String?

/// Save button with progress and the result, shared by the sections.
private struct SaveRow: View {
    let enabled: Bool
    let action: () async -> String?
    @State private var busy = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        Section {
            Button {
                Task { busy = true; result = await action(); ok = result == nil; if ok { result = "Saved to the radio." }; busy = false }
            } label: { HStack { Text("Save"); if busy { Spacer(); ProgressView() } } }
            .disabled(!enabled || busy)
            if let result { Text(result).font(.caption).foregroundStyle(ok ? .green : .red) }
        }
    }
}

private struct IdentitySection: View {
    let config: NodeConfig
    let save: SaveSection
    @State private var name = ""
    @State private var lat: Double?
    @State private var lon: Double?
    @State private var share = false
    @State private var picking = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } footer: { Text("Shown to others in adverts. At most 31 bytes.") }
            Section {
                LabeledContent("Location", value: lat.flatMap { la in lon.map { String(format: "%.5f, %.5f", la, $0) } } ?? "Not set")
                Button("Choose on the map…") { picking = true }
                if lat != nil { Button("Clear location", role: .destructive) { lat = nil; lon = nil } }
                Toggle("Share location in adverts", isOn: $share)
            } footer: { Text("Others see your position on their maps only if you share it.") }
            SaveRow(enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && name.utf8.count <= 31) {
                await save("identity", ["name": .string(name.trimmingCharacters(in: .whitespaces)),
                                        "lat": lat.map { .number($0) } ?? .null, "lon": lon.map { .number($0) } ?? .null,
                                        "share_location": .bool(share)])
            }
        }
        .navigationTitle("Identity")
        .onAppear { name = config.identity.name; lat = config.identity.lat; lon = config.identity.lon; share = config.identity.shareLocation }
        .sheet(isPresented: $picking) {
            LocationPickerView(title: "Your radio's location",
                               start: lat.flatMap { la in lon.map { CLLocationCoordinate2D(latitude: la, longitude: $0) } }) { c in
                lat = (c.latitude * 1e6).rounded() / 1e6; lon = (c.longitude * 1e6).rounded() / 1e6
            }
        }
    }
}

private struct RadioSection: View {
    let config: NodeConfig
    let save: SaveSection
    @Environment(AppModel.self) private var model
    @State private var presets: [RadioPreset] = []
    @State private var freq = ""
    @State private var bw = ""
    @State private var sf = 9
    @State private var cr = 5
    @State private var tx = 20
    @State private var repeatOn = false

    private var maxTx: Int { config.radio.maxTxPowerDbm ?? 30 }
    private var valid: Bool { Double(freq).map { (150...2500).contains($0) } == true && Double(bw) != nil }

    var body: some View {
        Form {
            if !presets.isEmpty {
                Section {
                    Menu("Apply a preset…") {
                        ForEach(presets) { p in
                            Button(p.title) { freq = fmt(p.freqMhz); bw = fmt(p.bwKhz); sf = p.sf; cr = p.cr }
                        }
                    }
                } footer: { Text("MeshCore's suggested settings for your area. Everyone in your mesh must match.") }
            }
            Section {
                LabeledContent("Frequency (MHz)") { TextField("", text: $freq).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                LabeledContent("Bandwidth (kHz)") { TextField("", text: $bw).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                Stepper("Spreading factor \(sf)", value: $sf, in: 5...12)
                Stepper("Coding rate 4/\(cr)", value: $cr, in: 5...8)
                Stepper("Transmit power \(tx) dBm", value: $tx, in: 1...maxTx)
                if config.radio.repeat != nil {
                    Toggle("Client repeat", isOn: $repeatOn)
                }
            } footer: {
                Text("Client repeat lets this companion also repeat packets, only on frequencies the firmware allows.")
            }
            SaveRow(enabled: valid) {
                await save("radio", ["freq_mhz": .number(Double(freq) ?? 0), "bw_khz": .number(Double(bw) ?? 0),
                                     "sf": .int(sf), "cr": .int(cr), "tx_power_dbm": .int(tx),
                                     "repeat": config.radio.repeat == nil ? .null : .bool(repeatOn)])
            }
        }
        .navigationTitle("LoRa radio")
        .onAppear {
            let r = config.radio
            freq = fmt(r.freqMhz); bw = fmt(r.bwKhz); sf = r.sf; cr = r.cr; tx = r.txPowerDbm; repeatOn = r.repeat ?? false
        }
        .task { presets = (try? await model.api?.presets().presets) ?? [] }
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
}

private struct ChannelsSection: View {
    let config: NodeConfig
    let reload: () async -> Void
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var removing: NodeConfig.Channel?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(config.channels) { ch in
                    HStack {
                        Text("\(ch.slot)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                        Text(ch.name)
                        Spacer()
                        Text(ch.key == "private" ? "Private" : ch.key == "hashtag" ? "Hashtag" : ch.key == "public" ? "Public" : "").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { removing = ch } }
                }
            } footer: { Text("Swipe to remove a channel. Private keys are never shown again after a channel is created.") }
            Section {
                Button("Add channel…") { adding = true }.disabled(config.channels.count >= config.maxChannels)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Channels")
        .sheet(isPresented: $adding, onDismiss: { Task { await reload() } }) { AddChannelView() }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: .constant(removing != nil), titleVisibility: .visible, presenting: removing) { ch in
            Button("Remove", role: .destructive) {
                Task {
                    removing = nil
                    do { try await model.api?.removeChannel(slot: ch.slot); await reload(); await model.refreshConversations() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { _ in Text("The archive keeps its messages.") }
    }
}

private struct BehaviorSection: View {
    let config: NodeConfig
    let save: SaveSection
    @State private var autoAdd = true
    @State private var multi = false
    @State private var hash = 0
    @State private var scope = ""

    var body: some View {
        Form {
            Section {
                Toggle("Add contacts automatically", isOn: $autoAdd)
                Toggle("Extra ACKs", isOn: $multi)
            } footer: { Text("Auto-add stores every node whose advert the radio hears. Extra ACKs make delivery confirmations more reliable at the cost of airtime.") }
            if config.behavior.pathHashMode != nil {
                Section {
                    Picker("Path hash size", selection: $hash) {
                        Text("1 byte (default)").tag(0); Text("2 bytes").tag(1); Text("3 bytes").tag(2)
                    }
                } footer: { Text("Must match the rest of your mesh.") }
            }
            if config.behavior.defaultFloodScope != nil {
                Section {
                    TextField("No scope", text: $scope).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Default region scope") } footer: { Text("For floods that don't set their own region.") }
            }
            SaveRow(enabled: true) {
                await save("behavior", ["auto_add_contacts": .bool(autoAdd), "multi_acks": .int(multi ? 1 : 0),
                                        "path_hash_mode": config.behavior.pathHashMode == nil ? .null : .int(hash),
                                        "default_flood_scope": config.behavior.defaultFloodScope == nil ? .null
                                            : .string(scope.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: ""))])
            }
        }
        .navigationTitle("Contacts and routing")
        .onAppear {
            let b = config.behavior
            autoAdd = b.autoAddContacts; multi = b.multiAcks > 0; hash = b.pathHashMode ?? 0; scope = b.defaultFloodScope ?? ""
        }
    }
}

private struct TelemetrySection: View {
    let config: NodeConfig
    let save: SaveSection
    @State private var base = 0
    @State private var location = 0
    @State private var environment = 0

    var body: some View {
        Form {
            Section {
                picker("Battery and status", $base)
                picker("Location", $location)
                picker("Sensors", $environment)
            } footer: { Text("Who may request each kind of reading from your radio.") }
            SaveRow(enabled: true) {
                await save("telemetry", ["base": .int(base), "location": .int(location), "environment": .int(environment)])
            }
        }
        .navigationTitle("Telemetry")
        .onAppear { base = config.telemetry.base; location = config.telemetry.location; environment = config.telemetry.environment }
    }

    private func picker(_ title: String, _ value: Binding<Int>) -> some View {
        Picker(title, selection: value) { Text("Nobody").tag(0); Text("Contacts I allow").tag(1); Text("Anyone").tag(2) }
    }
}

private struct TuningSection: View {
    let config: NodeConfig
    let save: SaveSection
    @State private var rx = ""
    @State private var af = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Receive delay") { TextField("", text: $rx).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                LabeledContent("Airtime factor") { TextField("", text: $af).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            } footer: { Text("Receive delay 0–20, airtime factor 0–9. Leave these alone unless you know you need to change them.") }
            SaveRow(enabled: Double(rx).map { (0...20).contains($0) } == true && Double(af).map { (0...9).contains($0) } == true) {
                await save("tuning", ["rx_delay": .number(Double(rx) ?? 0), "airtime_factor": .number(Double(af) ?? 0)])
            }
        }
        .navigationTitle("Advanced timing")
        .onAppear {
            if let t = config.tuning { rx = String(format: "%g", t.rxDelay); af = String(format: "%g", t.airtimeFactor) }
        }
    }
}

private struct CustomVarsSection: View {
    let config: NodeConfig
    let setVar: (String, String) async -> String?
    @State private var drafts: [String: String] = [:]
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                ForEach((config.customVars ?? [:]).keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key).font(.callout.monospaced())
                        TextField("", text: Binding(get: { drafts[key] ?? config.customVars?[key] ?? "" }, set: { drafts[key] = $0 }))
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let d = drafts[key], d != config.customVars?[key] {
                            Button("Save") { Task { result = await setVar(key, d) ?? "Saved \(key)."; drafts[key] = nil } }
                        }
                    }
                }
            } footer: { Text("Board-specific settings the firmware exposes, such as GPS.") }
            if let result { Text(result).font(.caption) }
        }
        .navigationTitle("Firmware variables")
    }
}
