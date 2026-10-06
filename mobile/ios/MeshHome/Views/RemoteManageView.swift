import CoreLocation
import SwiftUI

/// Administer a repeater or room server over the mesh: status, command line and settings.
/// Nothing is fetched until you ask (refresh), to save airtime; passwords are never stored.
struct RemoteManageView: View {
    let contactID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store: RemoteStore?
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            Group {
                if let store, let s = store.state {
                    content(store, s)
                } else if let e = store?.error {
                    ContentUnavailableView("Can't open", systemImage: "exclamationmark.triangle", description: Text(e))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(store?.state?.contact.name ?? "Remote manage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let store, store.state?.session != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Log out") { Task { await store.logout() } }.disabled(store.busy)
                    }
                }
            }
            .task {
                guard let api = model.api else { return }
                let s = RemoteStore(contactID: contactID, api: api)
                store = s
                await s.load()
            }
            .onChange(of: model.remoteChanges) { _, _ in Task { await store?.load() } }
        }
    }

    @ViewBuilder private func content(_ store: RemoteStore, _ s: RemoteState) -> some View {
        VStack(spacing: 0) {
            if !s.radioConnected {
                Label("Your radio isn't connected.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.footnote).padding(8).frame(maxWidth: .infinity).background(.orange.opacity(0.2))
            }
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    .padding(8).frame(maxWidth: .infinity)
            }
            if s.session == nil {
                RemoteLoginView(store: store)
            } else {
                Picker("Section", selection: $tab) {
                    Text("Status").tag(0)
                    Text("Command line").tag(1)
                    Text("Settings").tag(2)
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                if tab == 0 { RemoteStatusView(store: store, state: s) }
                else if !s.session!.admin {
                    ContentUnavailableView("Admin only", systemImage: "lock",
                                           description: Text("You're logged in as a guest. Log out and log in with the admin password to use this."))
                } else if tab == 1 { RemoteCLIView(store: store, state: s) }
                else { RemoteSettingsView(store: store, state: s) }
            }
        }
    }
}

private struct RemoteLoginView: View {
    let store: RemoteStore
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                SecureField("Password", text: $password).textContentType(.password)
                Button {
                    Task { if await store.login(password: password) { password = "" } }
                } label: {
                    HStack { Text("Log in"); if store.busy { Spacer(); ProgressView() } }
                }
                .disabled(password.isEmpty || store.busy)
            } header: {
                Text("Log in to this node")
            } footer: {
                Text("The admin password gives full control; a guest password (if set) allows reading its status. Sent encrypted over the mesh and never stored. New repeaters use the admin password “password” until it's changed.")
            }
        }
    }
}

// MARK: - Status

private struct RemoteStatusView: View {
    let store: RemoteStore
    let state: RemoteState

    var body: some View {
        Form {
            Section {
                Button { Task { await store.request("status") } } label: {
                    HStack { Label("Refresh status", systemImage: "arrow.clockwise"); if store.busy { Spacer(); ProgressView() } }
                }
                .disabled(store.busy)
            } footer: {
                Text(fetchedText(state.sections.status?.at))
            }
            if let st = state.sections.status?.data {
                Section("Health") {
                    LabeledContent("Battery", value: "\(batteryPercent(st.bat))% (\(String(format: "%.2f", Double(st.bat) / 1000)) V)")
                    LabeledContent("Uptime", value: durationText(st.uptime))
                    LabeledContent("Last SNR", value: String(format: "%.1f dB", st.lastSnr))
                    LabeledContent("Last RSSI", value: "\(st.lastRssi) dBm")
                    LabeledContent("Noise floor", value: "\(st.noiseFloor) dBm")
                    LabeledContent("Transmit queue", value: "\(st.txQueueLen)")
                }
                Section("Packets") {
                    LabeledContent("Received", value: "\(st.nbRecv) (flood \(st.recvFlood) · direct \(st.recvDirect))")
                    LabeledContent("Sent", value: "\(st.nbSent) (flood \(st.sentFlood) · direct \(st.sentDirect))")
                    LabeledContent("Duplicates", value: "flood \(st.floodDups) · direct \(st.directDups)")
                    LabeledContent("Receive errors", value: "\(st.recvErrors)")
                    LabeledContent("Airtime", value: "TX \(durationText(st.airtime)) · RX \(durationText(st.rxAirtime))")
                }
            }
        }
    }
}

// MARK: - Command line

private struct RemoteCLIView: View {
    let store: RemoteStore
    let state: RemoteState
    @State private var command = ""
    private let quick = ["ver", "clock", "get radio", "get repeat", "neighbors", "stats-core"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if state.console.isEmpty {
                            Text("Commands and replies appear here. Try “ver”.").foregroundStyle(.secondary)
                        }
                        ForEach(state.console) { line in
                            Text(line.dir == "out" ? "> \(line.text)" : line.text)
                                .font(.callout.monospaced())
                                .foregroundStyle(line.dir == "out" ? Color.accentColor : line.dir == "note" ? Color.secondary : Color.primary)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: state.console.count) { _, _ in
                    if let last = state.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(quick, id: \.self) { q in
                        Button(q) { Task { await store.cli(q) } }.buttonStyle(.bordered).font(.caption.monospaced())
                    }
                    Button("Clear", role: .destructive) { Task { await store.clearConsole() } }.buttonStyle(.bordered).font(.caption)
                }
                .padding(.horizontal)
            }
            HStack {
                TextField("e.g. get advert.interval", text: $command)
                    .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.send).onSubmit(send)
                    .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
                if store.busy { ProgressView() }
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
                    .accessibilityLabel("Send command")
            }
            .padding().background(.bar)
        }
        .disabled(!state.radioConnected)
    }

    private func send() {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        command = ""
        Task { await store.cli(c) }
    }
}
