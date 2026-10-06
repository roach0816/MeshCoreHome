import SwiftUI

/// Your radio's contact as a QR code, so others can add you by scanning it (in MeshHome or any
/// MeshCore app that reads contact codes).
struct MyContactCodeView: View {
    @Environment(AppModel.self) private var model
    @State private var radio: DeviceInfo.Radio?
    @State private var error: String?

    var body: some View {
        Form {
            if let radio {
                let code = ContactCode.uri(name: radio.name, publicKey: radio.publicKey)
                Section {
                    QRCodeImage(text: code)
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Others scan this to add \(radio.name) to their contacts, then can message you without waiting for an advert.")
                }
                Section("Contact") {
                    LabeledContent("Name", value: radio.name)
                    Text(keyLines(radio.publicKey)).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item: code) { Label("Share contact link", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = radio.publicKey } label: {
                        Label("Copy public key", systemImage: "doc.on.doc")
                    }
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("My contact code")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let api = model.api else { return }
            do {
                radio = try await api.device().radio
                if radio == nil { error = "No radio has connected yet." }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
