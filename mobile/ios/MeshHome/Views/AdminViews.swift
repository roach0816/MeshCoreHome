import SwiftUI

// MARK: - Radio connection

struct RadioConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var settings: RadioSettings?
    @State private var status: ServerStatus?
    @State private var mode = "tcp"
    @State private var host = ""
    @State private var port = "5000"
    @State private var result: (String, Bool)?
    @State private var testResult: String?
    @State private var busy = false

    private var dirty: Bool {
        guard let s = settings else { return false }
        return mode != s.mode || (mode == "tcp" && (host != s.host || Int(port) != s.port))
    }

    var body: some View {
        Form {
            if let st = status {
                Section("Now") {
                    LabeledContent("State", value: st.radio.detail)
                    if let name = st.radio.radioName { LabeledContent("Radio", value: name) }
                    LabeledContent("Messages", value: "\(st.radio.received) received · \(st.radio.sent) sent")
                    if let e = st.radio.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                    if let w = st.radio.storageWarning { Text(w).font(.caption).foregroundStyle(Palette.simulated) }
                }
            }
            Section {
                Picker("Connection", selection: $mode) {
                    Text("MeshCore over TCP").tag("tcp")
                    if model.features.contains("radio_hat") { Text("Radio HAT on this Pi").tag("hat") }
                    Text("Simulated").tag("simulated")
                    Text("None").tag("none")
                }
                if mode == "tcp" {
                    TextField("Radio address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    Button("Test connection") {
                        Task { testResult = (try? await model.api?.testConnection(host: host, port: Int(port) ?? 5000)) ?? "Test failed" }
                    }
                    .disabled(host.isEmpty)
                    if let testResult { Text(testResult).font(.footnote) }
                }
            } footer: {
                Text(mode == "simulated" ? "Labelled sample traffic, no hardware." : mode == "none" ? "MeshHome keeps the archive but doesn't connect to a radio." : "The radio's TCP port has no password: allow it only from the MeshHome server.")
            }
            Section {
                Button { Task { await save() } } label: { HStack { Text("Save and reconnect"); if busy { Spacer(); ProgressView() } } }
                    .disabled(!dirty || busy || (mode == "tcp" && (host.isEmpty || Int(port) == nil)))
                ResultText(text: result?.0, ok: result?.1 ?? true)
            }
            if let s = settings, s.mode != "none" {
                Section {
                    Button(s.paused == true ? "Resume the radio" : "Pause the radio (maintenance)") {
                        Task {
                            do { settings = try await model.api?.pauseRadio(!(s.paused ?? false)); await loadStatus() }
                            catch { result = (error.localizedDescription, false) }
                        }
                    }
                } footer: { Text("Pausing disconnects so another tool can use the radio. Messages sent meanwhile are recorded as a gap.") }
            }
            if let gaps = status?.gaps, !gaps.isEmpty {
                Section("Collection gaps") {
                    ForEach(gaps) { g in
                        VStack(alignment: .leading) {
                            Text(g.reason).font(.callout)
                            Text("\(g.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(g.endedAt?.formatted(date: .omitted, time: .shortened) ?? "now")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Radio connection")
        .task {
            if let s = try? await model.api?.radioSettings() { settings = s; mode = s.mode; host = s.host; port = String(s.port) }
            await loadStatus()
        }
    }

    private func loadStatus() async { status = try? await model.api?.status() }

    private func save() async {
        guard var s = settings else { return }
        s.mode = mode; s.host = host; s.port = Int(port) ?? 5000
        busy = true; defer { busy = false }
        do { settings = try await model.api?.saveRadioSettings(s); result = ("Saved. MeshHome is reconnecting.", true)
             try? await Task.sleep(for: .seconds(2)); await loadStatus() }
        catch { result = (error.localizedDescription, false) }
    }
}

// MARK: - Firmware

struct FirmwareView: View {
    @Environment(AppModel.self) private var model
    @State private var fw: FirmwareStatus?
    @State private var error: String?

    var body: some View {
        Form {
            if let fw {
                if !fw.available { Text(fw.reason ?? "Not available for this radio.").foregroundStyle(.secondary) }
                else {
                    LabeledContent("Radio", value: fw.model ?? "—")
                    LabeledContent("Installed", value: fw.currentVersion ?? "—")
                    LabeledContent("Latest", value: fw.latest?.version ?? "—")
                    if let up = fw.upToDate {
                        Label(up ? "Up to date" : "An update is available", systemImage: up ? "checkmark.circle" : "arrow.down.circle")
                            .foregroundStyle(up ? .green : .orange)
                    }
                    if let e = fw.error { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Section {
                Button("Check now") { Task { await load(check: true) } }
            } footer: {
                Text("Companion radios are updated with MeshCore's flasher (USB or Bluetooth); MeshHome only tells you when there's a new release.")
            }
        }
        .navigationTitle("Radio firmware")
        .task { await load(check: false) }
    }

    private func load(check: Bool) async {
        do { fw = try await model.api?.firmware(check: check); error = nil } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Features

struct BotSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var bot: BotSettings?
    @State private var result: (String, Bool)?

    var body: some View {
        Form {
            if let b = bot {
                Section {
                    Toggle("Answer commands", isOn: Binding(get: { b.enabled }, set: { v in save(BotSettings(enabled: v, allow: b.allow)) }))
                    Picker("Who may use it", selection: Binding(get: { b.allow }, set: { v in save(BotSettings(enabled: b.enabled, allow: v)) })) {
                        Text("Favourite contacts").tag("favorites")
                        Text("Every contact").tag("everyone")
                    }
                } footer: {
                    Text("Direct messages starting with / get a reply: /info, /ping, /weather and /help. Channels are never answered, and replies are rate-limited to save airtime.")
                }
                ResultText(text: result?.0, ok: result?.1 ?? true)
            } else { ProgressView() }
        }
        .navigationTitle("Bot")
        .task { bot = try? await model.api?.bot() }
    }

    private func save(_ b: BotSettings) {
        bot = b
        Task {
            do { bot = try await model.api?.saveBot(b); result = nil } catch { result = (error.localizedDescription, false) }
        }
    }
}

struct WeatherSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var saved = ""
    @State private var result: (String, Bool)?
    @State private var preview: String?

    var body: some View {
        Form {
            Section {
                TextField("Gateway address, e.g. 192.168.1.50", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } footer: {
                Text("An Ecowitt gateway or Wi-Fi console (GW1100, GW2000, GW3000, …) on your network. MeshHome reads its live data directly, not through the Ecowitt cloud. Leave empty to turn /weather off.")
            }
            Section {
                Button("Test station") {
                    Task {
                        do { preview = try await model.api?.testWeather(WeatherSettings(host: host)); result = nil }
                        catch { preview = nil; result = (error.localizedDescription, false) }
                    }
                }
                .disabled(host.isEmpty)
                if let preview { Text(preview).font(.callout.monospaced()) }
                Button("Save") {
                    Task {
                        do { saved = try await model.api?.saveWeather(WeatherSettings(host: host)).host ?? host; result = ("Saved.", true) }
                        catch { result = (error.localizedDescription, false) }
                    }
                }
                .disabled(host == saved)
                ResultText(text: result?.0, ok: result?.1 ?? true)
            }
        }
        .navigationTitle("Weather station")
        .task { if let w = try? await model.api?.weather() { host = w.host; saved = w.host } }
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sound = "all"
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker("Sound for new messages", selection: $sound) {
                    Text("All messages").tag("all")
                    Text("Direct messages only").tag("dms")
                    Text("Off").tag("off")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("For browsers and this app while open. Conversations can override it (mute).")
            }
        }
        .navigationTitle("Notifications")
        .task { if let n = try? await model.api?.notificationConfig() { sound = n.sound }; loaded = true }
        .onChange(of: sound) { _, v in
            guard loaded else { return }
            Task { _ = try? await model.api?.saveNotifications(NotificationConfig(sound: v)) }
        }
    }
}

struct MapSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var attribution = ""
    @State private var maxZoom = 19
    @State private var result: (String, Bool)?

    var body: some View {
        Form {
            Section {
                TextField("https://tile.example.org/{z}/{x}/{y}.png", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Attribution", text: $attribution)
                Stepper("Maximum zoom \(maxZoom)", value: $maxZoom, in: 1...22)
            } header: { Text("Tile server") } footer: {
                Text("The map loads tiles straight from this server, which sees your IP address and the areas you view. A self-hosted tile server avoids third parties.")
            }
            Section {
                Button("Save") {
                    Task {
                        do { _ = try await model.api?.saveMap(MapConfig(tileUrl: url, attribution: attribution, maxZoom: maxZoom)); result = ("Saved.", true) }
                        catch { result = (error.localizedDescription, false) }
                    }
                }
                .disabled(!url.contains("{z}"))
                ResultText(text: result?.0, ok: result?.1 ?? true)
            }
        }
        .navigationTitle("Map")
        .task { if let m = try? await model.api?.mapConfig() { url = m.tileUrl; attribution = m.attribution; maxZoom = m.maxZoom } }
    }
}

// MARK: - API keys

struct APIKeysView: View {
    @Environment(AppModel.self) private var model
    @State private var keys: [APIKey] = []
    @State private var creating = false
    @State private var created: APIKeyCreated?
    @State private var revoking: APIKey?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if keys.isEmpty { Text("No API keys yet.").foregroundStyle(.secondary) }
                ForEach(keys) { k in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(k.name).font(.body.weight(.medium))
                            Text(k.scope == "write" ? "Read & write" : "Read only").font(.caption).foregroundStyle(.secondary)
                            if k.expired { Text("Expired").font(.caption).foregroundStyle(.red) }
                        }
                        Text("\(k.prefix)… · last used \(k.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Revoke", role: .destructive) { revoking = k } }
                }
            } footer: {
                Text("Let other services and scripts read and send messages (Authorization: Bearer). Account, network and radio settings stay with signed-in browsers and apps.")
            }
            if let error { Text(error).foregroundStyle(.red) }
            Button("Create API key…") { creating = true }
        }
        .navigationTitle("API keys")
        .task { await load() }
        .sheet(isPresented: $creating) { CreateKeyView { created = $0; Task { await load() } } }
        .sheet(item: Binding(get: { created.map { IDString(id: $0.key) } }, set: { if $0 == nil { created = nil } })) { _ in
            if let c = created {
                NavigationStack {
                    Form {
                        Section {
                            Text(c.key).font(.callout.monospaced()).textSelection(.enabled)
                            Button { UIPasteboard.general.string = c.key } label: { Label("Copy key", systemImage: "doc.on.doc") }
                        } footer: { Text("This is the only time the key is shown. MeshHome stores only a fingerprint.") }
                    }
                    .navigationTitle(c.apiKey.name).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { created = nil } } }
                }
                .interactiveDismissDisabled()
            }
        }
        .confirmationDialog("Revoke “\(revoking?.name ?? "")”?", isPresented: .constant(revoking != nil), titleVisibility: .visible, presenting: revoking) { k in
            Button("Revoke key", role: .destructive) {
                Task { revoking = nil; do { try await model.api?.revokeAPIKey(k.id); await load() } catch { self.error = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { revoking = nil }
        } message: { _ in Text("Anything using this key stops working immediately.") }
    }

    private func load() async {
        do { keys = try await model.api?.apiKeys() ?? []; error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct CreateKeyView: View {
    let onCreated: (APIKeyCreated) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scope = "read"
    @State private var expires = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, e.g. Home Assistant", text: $name)
                Picker("Permission", selection: $scope) { Text("Read only").tag("read"); Text("Read & write").tag("write") }
                Picker("Expires", selection: $expires) {
                    Text("Never").tag(0); Text("In 30 days").tag(30); Text("In 90 days").tag(90); Text("In a year").tag(365)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New API key").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                let c = try await model.api!.createAPIKey(name: name.trimmingCharacters(in: .whitespaces), scope: scope, days: expires == 0 ? nil : expires)
                                dismiss(); onCreated(c)
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
