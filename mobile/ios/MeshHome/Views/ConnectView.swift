import SwiftUI

/// Add a server and sign in. Step 1 checks the address (GET /api/meta); step 2 signs in.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var server: URL?
    @State private var meta: Meta?
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var scanning = false
    @State private var browser = ServerBrowser()
    /// A server whose certificate iOS doesn't trust: its fingerprint, for trust on first use.
    @State private var untrusted: (url: URL, fingerprint: String)?
    @FocusState private var focus: Field?

    private enum Field { case address, username, password }

    var body: some View {
        NavigationStack {
            Form {
                if meta == nil, !browser.servers.isEmpty {
                    Section {
                        ForEach(browser.servers) { found in
                            Button {
                                address = found.url
                                Task { await check() }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(found.name).foregroundStyle(.primary)
                                    Text(found.url).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(busy)
                            .accessibilityHint("Connects to this server")
                        }
                    } header: {
                        Text("On your network")
                    }
                }
                Section {
                    TextField("meshhome.example.com or 192.168.1.20:8080", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { Task { await check() } }
                        .disabled(meta != nil)
                } header: {
                    Text("Server")
                } footer: {
                    if let meta, let server {
                        Label("MeshHome \(meta.version) at \(server.host() ?? "")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("The address you use for MeshHome in a browser. The app connects only to this server, on your home network or over your VPN.")
                    }
                }

                if meta != nil {
                    if meta?.needsSetup == true {
                        Section {
                            Text("This server hasn't been set up yet. Finish the setup wizard in a browser first, then sign in here.")
                        }
                    } else {
                        Section("Sign in") {
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .username)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .focused($focus, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { Task { await signIn() } }
                        }
                    }
                }

                if let u = untrusted {
                    Section {
                        Text("This server's certificate isn't one your iPhone trusts (it may be self-signed). Only trust it if this fingerprint matches the certificate on your server.")
                        Text(u.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Trust this certificate") {
                            CertificateTrust.shared.pin(u.fingerprint, for: u.url)
                            untrusted = nil
                            Task { await check() }
                        }
                        Button("Cancel", role: .cancel) { untrusted = nil }
                    } header: {
                        Text("Unrecognised certificate")
                    } footer: {
                        Text("On the server: openssl x509 -in <certificate file> -noout -fingerprint -sha256")
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Section {
                    if meta == nil {
                        Button { Task { await check() } } label: { progressLabel("Connect") }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        if QRScanner.isAvailable {
                            Button { scanning = true } label: { Label("Scan pairing QR code", systemImage: "qrcode.viewfinder") }
                        }
                    } else if meta?.needsSetup == false {
                        Button { Task { await signIn() } } label: { progressLabel("Sign in") }
                            .disabled(username.isEmpty || password.isEmpty || busy)
                    }
                    if meta != nil {
                        Button("Use a different server", role: .cancel) {
                            meta = nil; server = nil; error = nil; password = ""
                            focus = .address
                        }
                    }
                }
            }
            .navigationTitle("MeshHome")
            .onAppear { focus = .address; usePairing(); browser.start() }
            .onDisappear { browser.stop() }
            .onChange(of: model.pairingAddress) { _, _ in usePairing() }
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    if let url = URL(string: code), let found = Pairing.address(from: url) {
                        model.pairingAddress = found
                    } else {
                        error = "That QR code isn't a MeshHome pairing code. Show it from Account → Signed-in devices → Add a phone in the web interface."
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    /// A pairing link (QR code or meshhome:// URL) fills in the server and checks it.
    private func usePairing() {
        guard let found = model.pairingAddress else { return }
        model.pairingAddress = nil
        meta = nil; server = nil; error = nil
        address = found
        Task { await check() }
    }

    private func progressLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            if busy { Spacer(); ProgressView() }
        }
    }

    /// "host", "host:port" or a full URL. Without a scheme, HTTPS is tried first, then HTTP.
    private func candidates() -> [URL] {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.contains("://") { return URL(string: text).map { [$0] } ?? [] }
        return ["https://", "http://"].compactMap { URL(string: $0 + text) }
    }

    private func check() async {
        busy = true; error = nil
        defer { busy = false }
        var lastError: Error?
        for url in candidates() {
            CertificateTrust.shared.clearRejected(for: url)
            do {
                meta = try await AppModel.check(url)
                server = url
                focus = .username
                return
            } catch {
                // An untrusted certificate: ask, rather than quietly falling back to plain HTTP.
                if url.scheme == "https", let fp = CertificateTrust.shared.rejectedFingerprint(for: url) {
                    untrusted = (url, fp)
                    return
                }
                lastError = error
            }
        }
        error = Self.describe(lastError)
    }

    private func signIn() async {
        guard let server else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.signIn(server: server, username: username, password: password)
        } catch {
            self.error = Self.describe(error)
        }
    }

    private static func describe(_ error: Error?) -> String {
        if let e = error as? APIError { return e.message }
        if let e = error as? URLError {
            switch e.code {
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .serverCertificateHasBadDate:
                return "The server's HTTPS certificate isn't trusted by this device."
            case .cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return "Can't reach that server. Check the address, and that you're on your home network or VPN. If iOS asked about local network access, allow it in Settings → Privacy & Security → Local Network."
            default:
                return e.localizedDescription
            }
        }
        return error?.localizedDescription ?? "Can't reach that server."
    }
}
