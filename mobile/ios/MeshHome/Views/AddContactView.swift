import SwiftUI

/// Add a contact the radio hasn't heard an advert from: scan their contact QR code, or type in
/// their public key and name.
struct AddContactView: View {
    enum Mode { case scan, manual }
    let mode: Mode
    var onAdded: (Contact) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var publicKey = ""
    @State private var kind = 1
    @State private var busy = false
    @State private var error: String?
    @State private var result: ContactImportResult?

    private var cleanKey: String { publicKey.filter { !$0.isWhitespace }.lowercased() }
    private var keyValid: Bool { cleanKey.count == 64 && cleanKey.allSatisfy(\.isHexDigit) }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    done(result)
                } else if mode == .scan {
                    scanner
                } else {
                    form
                }
            }
            .navigationTitle(result != nil ? "" : mode == .scan ? "Scan contact code" : "Add contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if result == nil { Button("Cancel") { dismiss() } }
                }
            }
        }
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            if QRScanner.isAvailable {
                QRScanner { code in Task { await add(uri: code) } }.ignoresSafeArea()
            } else {
                ContentUnavailableView("Camera unavailable", systemImage: "camera.fill",
                                       description: Text("Use Enter manually instead."))
            }
            VStack(spacing: 6) {
                if busy { ProgressView() }
                Text(error ?? "Point the camera at a MeshCore contact QR code.")
                    .foregroundStyle(error == nil ? Color.primary : Color.red)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Public key (64 hex characters)", text: $publicKey, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Type", selection: $kind) {
                    Text("Companion").tag(1)
                    Text("Repeater").tag(2)
                    Text("Room server").tag(3)
                    Text("Sensor").tag(4)
                }
            } footer: {
                if !publicKey.isEmpty && !keyValid {
                    Text("\(cleanKey.count) of 64 hex characters (0–9, a–f).").foregroundStyle(.red)
                } else {
                    Text("Ask them for their public key, or copy it from their MeshCore app. Their location and route arrive with their next advert.")
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section {
                Button {
                    Task { await add(name: name, key: cleanKey) }
                } label: {
                    HStack { Text("Add contact"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(!keyValid || name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
    }

    private func done(_ r: ContactImportResult) -> some View {
        ContentUnavailableView {
            Label(r.added ? "Added \(r.contact.displayName)" : "\(r.contact.displayName) is already a contact",
                  systemImage: r.added ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
        } description: {
            Text(r.added ? "It's on your radio now. You can message them right away." : "Nothing was changed.")
        } actions: {
            if r.contact.isPerson {
                Button("Send a message") {
                    dismiss()
                    Task { await model.openConversation(with: r.contact) }
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Done") { dismiss() }
        }
    }

    private func add(uri: String) async {
        guard !busy, result == nil else { return }
        guard uri.hasPrefix("meshcore://contact/") else {
            error = uri.hasPrefix("meshhome://") ? "That's a MeshHome pairing code, not a contact." : "That isn't a MeshCore contact code."
            return
        }
        await perform { try await $0.importContact(uri: uri) }
    }

    private func add(name: String, key: String) async {
        await perform { try await $0.importContact(publicKey: key, name: name.trimmingCharacters(in: .whitespaces), kind: kind) }
    }

    private func perform(_ call: (APIClient) async throws -> ContactImportResult) async {
        guard let api = model.api else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let r = try await call(api)
            result = r
            onAdded(r.contact)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
