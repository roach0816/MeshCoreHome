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
    @FocusState private var focus: Field?

    private enum Field { case address, username, password }

    var body: some View {
        NavigationStack {
            Form {
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

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Section {
                    if meta == nil {
                        Button { Task { await check() } } label: { progressLabel("Connect") }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || busy)
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
            .onAppear { focus = .address }
        }
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
            do {
                meta = try await AppModel.check(url)
                server = url
                focus = .username
                return
            } catch {
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
            case .appTransportSecurityRequiresSecureConnection:
                return "Plain HTTP is only allowed to local-network addresses. Use HTTPS, or the server's IP address."
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
