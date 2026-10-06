import SwiftUI

@main
struct MeshHomeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.phase {
                case .signedOut: ConnectView()
                case .signedIn: MainView()
                }
            }
            .environment(model)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.appBecameActive() } else { model.appResignedActive() }
            }
            // meshhome://pair?url=… from the QR code under Account → Signed-in devices in the web UI.
            .onOpenURL { url in model.pairingAddress = Pairing.address(from: url) }
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Conversations", systemImage: "bubble.left.and.bubble.right", value: AppModel.Tab.conversations) {
                ConversationsView()
            }
            .badge(model.totalUnread)
            Tab("Contacts", systemImage: "person.2", value: AppModel.Tab.contacts) {
                ContactsView()
            }
            Tab("Map", systemImage: "map", value: AppModel.Tab.map) {
                MeshMapView()
            }
        }
    }
}

/// The pairing link shown as a QR code in the web UI: meshhome://pair?url=<server address>.
enum Pairing {
    static func address(from url: URL) -> String? {
        guard url.scheme == "meshhome", url.host() == "pair",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let server = URL(string: value), ["http", "https"].contains(server.scheme) else { return nil }
        return value
    }
}
