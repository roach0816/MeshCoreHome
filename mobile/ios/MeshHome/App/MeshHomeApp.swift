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
                case .signedIn: ConversationsView()
                }
            }
            .environment(model)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.appBecameActive() }
            }
        }
    }
}
