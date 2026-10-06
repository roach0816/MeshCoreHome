import CoreLocation
import SwiftUI

/// Pick a position: move the map under the crosshair, or use this phone's location.
struct LocationPickerView: View {
    let title: String
    var start: CLLocationCoordinate2D?
    let onPick: (CLLocationCoordinate2D) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tiles: MapConfig?
    @State private var center: CLLocationCoordinate2D?
    @State private var locator = PhoneLocation()

    var body: some View {
        NavigationStack {
            ZStack {
                if let tiles {
                    TileMapView(tiles: tiles, initialCenter: start ?? locator.last, onCenter: { center = $0 })
                        .id(locator.last.map { "\($0.latitude),\($0.longitude)" } ?? "map")
                    Image(systemName: "plus").font(.system(size: 30, weight: .light)).allowsHitTesting(false)
                } else {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let c = center {
                        Text(String(format: "%.5f, %.5f", c.latitude, c.longitude)).font(.callout.monospaced())
                    }
                    if let e = locator.error { Text(e).font(.caption).foregroundStyle(.red) }
                    Button { locator.request() } label: { Label("Use this phone's location", systemImage: "location") }
                }
                .padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { if let c = center { onPick(c) }; dismiss() }.disabled(center == nil)
                }
            }
            .task { tiles = try? await model.api?.mapConfig() }
        }
    }
}

/// One-shot "where is this phone" (When In Use permission only).
@MainActor @Observable
final class PhoneLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var last: CLLocationCoordinate2D?
    var error: String?

    override init() {
        super.init()
        manager.delegate = self
    }

    func request() {
        error = nil
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let c = locations.last?.coordinate
        Task { @MainActor in self.last = c }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let text = (error as? CLError)?.code == .denied
            ? "Location access is off for MeshHome (Settings → Privacy & Security → Location Services)."
            : "Couldn't get this phone's location."
        Task { @MainActor in self.error = text }
    }
}
