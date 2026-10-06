import SwiftUI
import UniformTypeIdentifiers

/// The system share sheet, for a file the app downloaded.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable { let url: URL; var id: URL { url } }

// MARK: - Backup and restore

struct BackupView: View {
    @Environment(AppModel.self) private var model
    @State private var list: BackupList?
    @State private var pass1 = ""
    @State private var pass2 = ""
    @State private var creating = false
    @State private var result: (String, Bool)?
    @State private var sharing: SharedFile?
    @State private var deleting: BackupFile?
    @State private var picking = false
    @State private var restore: RestoreFlow?

    var body: some View {
        Form {
            Section {
                SecureField("Passphrase (at least 10 characters)", text: $pass1)
                SecureField("Repeat passphrase", text: $pass2)
                Button { Task { await create() } } label: { HStack { Text("Create backup"); if creating { Spacer(); ProgressView() } } }
                    .disabled(pass1.count < 10 || pass1 != pass2 || creating)
                ResultText(text: result?.0, ok: result?.1 ?? true)
            } header: { Text("New backup") } footer: {
                Text("Everything is encrypted with this passphrase. Without it the backup can't be restored, and nobody can recover it for you.")
            }
            if let list {
                Section {
                    if list.backups.isEmpty { Text("No backups yet.").foregroundStyle(.secondary) }
                    ForEach(list.backups) { b in
                        Button { Task { await download(b) } } label: {
                            VStack(alignment: .leading) {
                                Text(b.name).font(.callout.monospaced()).foregroundStyle(.primary)
                                Text("\(b.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(b.size), countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { deleting = b } }
                    }
                } header: { Text("Backups on the server") } footer: {
                    Text(list.persistent ? "Tap one to save it to Files or share it. Keep a copy off the server too." : "This server doesn't keep backups after a restart: save them to Files.")
                }
            }
            Section {
                Button("Restore from a file…") { picking = true }
            } header: { Text("Restore") } footer: {
                Text("Replaces everything on this server with the backup. A safety backup is made first. Sign-ins aren't part of a backup, so you'll sign in again afterwards.")
            }
        }
        .navigationTitle("Backup and restore")
        .task { list = try? await model.api?.backups() }
        .sheet(item: $sharing) { ShareSheet(url: $0.url) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { r in
            if case .success(let url) = r { restore = RestoreFlow(file: url) }
        }
        .sheet(item: $restore) { RestoreView(flow: $0) }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: .constant(deleting != nil), titleVisibility: .visible, presenting: deleting) { b in
            Button("Delete", role: .destructive) {
                Task { deleting = nil; try? await model.api?.deleteBackup(b.name); list = try? await model.api?.backups() }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private func create() async {
        guard let api = model.api else { return }
        creating = true; defer { creating = false }
        do {
            let c = try await api.createBackup(passphrase: pass1)
            pass1 = ""; pass2 = ""
            result = (c.warning ?? "Created \(c.name).", c.warning == nil)
            list = try? await api.backups()
            sharing = SharedFile(url: try await api.download("/api/backups/\(c.name)", as: c.name))
        } catch { result = (error.localizedDescription, false) }
    }

    private func download(_ b: BackupFile) async {
        do { sharing = SharedFile(url: try await model.api!.download("/api/backups/\(b.name)", as: b.name)) }
        catch { result = (error.localizedDescription, false) }
    }
}

struct RestoreFlow: Identifiable { let file: URL; var id: URL { file } }

private struct RestoreView: View {
    let flow: RestoreFlow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0
    @State private var uploadID: String?
    @State private var passphrase = ""
    @State private var summary: RestoreSummary?
    @State private var applied: RestoreApplied?
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if let applied {
                    Section {
                        Label("Restored", systemImage: "checkmark.circle").foregroundStyle(.green)
                        if applied.system == "applying" { Text("System settings (HTTPS, radio HAT) are being applied; the server restarts briefly.") }
                        if let s = applied.safetyBackup { Text("Safety backup of the previous state: \(s)").font(.caption) }
                        Button("Sign in again") { dismiss(); model.signedOutAfterRestore() }
                    }
                } else if uploadID == nil {
                    Section { ProgressView(value: progress) { Text("Uploading \(flow.file.lastPathComponent)") } }
                } else if let s = summary {
                    Section("Backup") {
                        LabeledContent("Made", value: s.createdAt)
                        LabeledContent("From", value: "\(s.homeName) · MeshHome \(s.appVersion) (\(s.installKind))")
                        ForEach(s.counts.sorted { $0.key < $1.key }, id: \.key) { LabeledContent($0.key.replacingOccurrences(of: "_", with: " "), value: "\($0.value)") }
                    }
                    if !s.errors.isEmpty { Section("Can't restore") { ForEach(s.errors, id: \.self) { Text($0).foregroundStyle(.red) } } }
                    if !s.notRestored.isEmpty { Section("Not restored here") { ForEach(s.notRestored, id: \.self) { Text($0) } } }
                    if !s.notes.isEmpty { Section("Notes") { ForEach(s.notes, id: \.self) { Text($0).font(.callout) } } }
                    Section {
                        Button("Restore this backup", role: .destructive) { confirm = true }.disabled(!s.canRestore || busy)
                        if busy { ProgressView() }
                    }
                } else {
                    Section {
                        SecureField("Backup passphrase", text: $passphrase)
                        Button("Check backup") { Task { await inspect() } }.disabled(passphrase.isEmpty || busy)
                    } footer: { Text("Nothing changes yet: this only opens the backup and shows what's in it.") }
                }
            }
            .navigationTitle("Restore").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { if applied == nil { Button("Cancel") { dismiss() } } } }
            .interactiveDismissDisabled(busy || applied != nil)
            .confirmationDialog("Replace everything on this server with the backup?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Restore", role: .destructive) { Task { await apply() } }
            } message: { Text("A safety backup is made first.") }
            .task { await upload() }
        }
    }

    private func upload() async {
        guard let api = model.api, uploadID == nil else { return }
        let scoped = flow.file.startAccessingSecurityScopedResource()
        defer { if scoped { flow.file.stopAccessingSecurityScopedResource() } }
        do {
            uploadID = try await api.uploadBackup(flow.file) { p in Task { @MainActor in progress = p } }
        } catch { self.error = error.localizedDescription }
    }

    private func inspect() async {
        guard let api = model.api, let id = uploadID else { return }
        busy = true; defer { busy = false }
        do { summary = try await api.inspectRestore(id, passphrase: passphrase); error = nil } catch { self.error = error.localizedDescription }
    }

    private func apply() async {
        guard let api = model.api, let id = uploadID else { return }
        busy = true; defer { busy = false }
        do { applied = try await api.applyRestore(id, passphrase: passphrase); error = nil } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Software updates

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @State private var info: UpdateInfo?
    @State private var error: String?
    @State private var confirm = false
    @State private var progress: UpdateInfo.Status?
    @State private var updating = false

    var body: some View {
        Form {
            if let i = info {
                Section {
                    LabeledContent("Installed", value: i.currentVersion)
                    LabeledContent("Latest", value: i.latest?.version ?? "—")
                    if let e = i.error { Text(e).font(.caption).foregroundStyle(.red) }
                    if !i.checksEnabled { Text("Update checks are turned off on this server.").foregroundStyle(.secondary) }
                }
                if i.updateAvailable, let latest = i.latest {
                    Section("What's new in \(latest.version)") {
                        Text(latest.notes).font(.callout)
                        if let u = URL(string: latest.url) { Link("Release notes", destination: u) }
                    }
                    Section {
                        if i.canInstall {
                            Button("Install \(latest.version)") { confirm = true }.disabled(updating)
                        } else {
                            Text(i.installKind == "container" ? "Container installs are updated by redeploying (e.g. Fleet does this automatically)." : "This server can't install updates from here.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if i.latest != nil {
                    Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }
            if let p = progress {
                Section("Progress") {
                    HStack { if !["done", "failed", "rolled_back"].contains(p.state) { ProgressView() }; Text(p.message) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Section { Button("Check for updates") { Task { await load(refresh: true) } }.disabled(updating) }
        }
        .navigationTitle("Software updates")
        .task { await load(refresh: false) }
        .confirmationDialog("Install MeshHome \(info?.latest?.version ?? "")?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Install") { Task { await install() } }
        } message: { Text("MeshHome restarts during the update and rolls back by itself if the new version doesn't start.") }
    }

    private func load(refresh: Bool) async {
        do { info = try await model.api?.updateInfo(refresh: refresh); error = nil } catch { self.error = error.localizedDescription }
    }

    private func install() async {
        guard let api = model.api, let v = info?.latest?.version else { return }
        updating = true; defer { updating = false }
        do { try await api.requestUpdate(v) } catch { self.error = error.localizedDescription; return }
        // Poll through the restart (requests fail while the server is down).
        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(2))
            if let s = try? await api.updateStatus() {
                progress = s
                if ["done", "failed", "rolled_back"].contains(s.state) { break }
            }
        }
        await model.refreshAll()
        await load(refresh: false)
    }
}

// MARK: - Network and HTTPS (native installs)

struct NetworkView: View {
    @Environment(AppModel.self) private var model
    @State private var info: NetworkInfo?
    @State private var https = false
    @State private var hostname = ""
    @State private var httpsPort = "443"
    @State private var appPort = "8080"
    @State private var redirect = true
    @State private var email = ""
    @State private var staging = false
    @State private var provider = "cloudflare"
    @State private var creds: [String: String] = [:]
    @State private var propagation = "0"
    @State private var progress: NetworkInfo.Status?
    @State private var error: String?
    @State private var applying = false
    @State private var confirm = false

    private var selected: NetworkInfo.Provider? { info?.providers.first { $0.id == provider } }
    private var newURL: URL? {
        let p = Int(httpsPort) ?? 443
        return https ? URL(string: "https://\(hostname)\(p == 443 ? "" : ":\(p)")") : nil
    }

    var body: some View {
        Form {
            if let i = info {
                if let c = i.certificate {
                    Section("Certificate") {
                        LabeledContent("For", value: c.host)
                        LabeledContent("Valid until", value: c.notAfter)
                        Button("Renew now") { Task { try? await model.api?.renewCertificate(); await poll() } }.disabled(applying || i.inProgress)
                    }
                }
                Section {
                    Toggle("HTTPS with a trusted certificate", isOn: $https)
                    if https {
                        TextField("Hostname, e.g. meshhome.example.com", text: $hostname).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        LabeledContent("HTTPS port") { TextField("443", text: $httpsPort).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                        Toggle("Redirect plain HTTP (port 80)", isOn: $redirect)
                    }
                    LabeledContent("App port") { TextField("8080", text: $appPort).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                } footer: {
                    Text("The certificate comes from Let's Encrypt through a DNS check at your DNS provider, so the server doesn't need to be reachable from the internet.")
                }
                if https {
                    Section("DNS provider") {
                        Picker("Provider", selection: $provider) { ForEach(i.providers) { Text($0.name).tag($0.id) } }
                        if let p = selected {
                            ForEach(p.fields) { f in
                                if f.secret {
                                    SecureField(f.label + (i.config?.credentialsProvider == p.id ? " (saved; blank keeps it)" : ""),
                                                text: Binding(get: { creds[f.env] ?? "" }, set: { creds[f.env] = $0 }))
                                } else {
                                    TextField(f.label, text: Binding(get: { creds[f.env] ?? "" }, set: { creds[f.env] = $0 }))
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                }
                            }
                            Text(p.help).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Advanced") {
                        TextField("Email for Let's Encrypt (optional)", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        Toggle("Use Let's Encrypt's staging server (testing)", isOn: $staging)
                        LabeledContent("DNS wait (seconds, 0 = automatic)") { TextField("0", text: $propagation).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    }
                }
                Section {
                    Button("Apply") { confirm = true }.disabled(applying || i.inProgress || (https && hostname.isEmpty))
                    if let p = progress {
                        HStack { if !["done", "failed"].contains(p.state) { ProgressView() }; Text(p.message).font(.callout) }
                    }
                } footer: {
                    if let u = newURL { Text("Afterwards MeshHome is at \(u.absoluteString). This app moves there by itself.") }
                }
            } else if error == nil { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Network and HTTPS")
        .task { await load() }
        .confirmationDialog("Apply these network settings?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Apply") { Task { await apply() } }
        } message: { Text("The server may restart and change address. If the new address doesn't work, this app stays on the current one.") }
    }

    private func load() async {
        do {
            let i = try await model.api!.network()
            info = i
            if let c = i.config {
                https = c.httpsEnabled; hostname = c.hostname ?? ""; httpsPort = String(c.httpsPort); appPort = String(c.appPort)
                redirect = c.redirectHttp; email = c.email ?? ""; staging = c.staging; provider = c.dnsProvider
                propagation = String(c.propagationSeconds)
            }
            if !i.configurable { error = "Network settings can only be changed on a Raspberry Pi / Debian install." }
        } catch { self.error = error.localizedDescription }
    }

    private func apply() async {
        guard let api = model.api else { return }
        applying = true; defer { applying = false }
        let body: [String: Any] = [
            "app_port": Int(appPort) ?? 8080, "https_enabled": https, "hostname": https ? hostname : NSNull(),
            "https_port": Int(httpsPort) ?? 443, "redirect_http": redirect, "email": email.isEmpty ? NSNull() : email,
            "staging": staging, "propagation_seconds": Int(propagation) ?? 0, "dns_provider": provider,
            "credentials": creds.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty },
        ]
        do { try await api.saveNetwork(body); creds = [:]; error = nil } catch { self.error = error.localizedDescription; return }
        await poll()
        // Follow the server to its new address (HTTPS on, or a new hostname), checking it first.
        if progress?.state == "done", let u = newURL, u != model.serverURL {
            for _ in 0..<10 {
                if (try? await model.moveServer(to: u)) != nil { error = nil; return }
                try? await Task.sleep(for: .seconds(3))
            }
            error = "MeshHome is set up at \(u.absoluteString), but this phone can't reach it yet. Check DNS on your network or VPN; the app keeps using the old address."
        }
    }

    private func poll() async {
        guard let api = model.api else { return }
        for _ in 0..<200 {
            try? await Task.sleep(for: .seconds(2))
            if let s = try? await api.networkStatus() {
                progress = s
                if ["done", "failed"].contains(s.state) { break }
            }
        }
        info = try? await api.network()
    }
}

// MARK: - Export and data

struct DataView: View {
    @Environment(AppModel.self) private var model
    @State private var sharing: SharedFile?
    @State private var busy = false
    @State private var result: (String, Bool)?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                Button { Task { await export() } } label: { HStack { Text("Export all messages (JSON)"); if busy { Spacer(); ProgressView() } } }
                    .disabled(busy)
            } footer: { Text("Every conversation and message in the archive, for your own records or other tools.") }
            Section {
                Button("Delete simulated data", role: .destructive) { confirmDelete = true }
            } footer: { Text("Removes the sample radio's contacts and messages. Only possible while the radio connection isn't Simulated.") }
            ResultText(text: result?.0, ok: result?.1 ?? true)
        }
        .navigationTitle("Export and data")
        .sheet(item: $sharing) { ShareSheet(url: $0.url) }
        .confirmationDialog("Delete all simulated data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do { try await model.api?.deleteSimulatedData(); result = ("Simulated data deleted.", true); await model.refreshConversations() }
                    catch { result = (error.localizedDescription, false) }
                }
            }
        }
    }

    private func export() async {
        busy = true; defer { busy = false }
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        do { sharing = SharedFile(url: try await model.api!.download("/api/export", as: "meshhome-export-\(stamp).json")) }
        catch { result = (error.localizedDescription, false) }
    }
}
