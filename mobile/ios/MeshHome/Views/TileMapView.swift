import MapKit
import SwiftUI

/// A map drawn from MeshHome's configured tile server (Settings → Map on the server), so it can be
/// fully self-hosted. Apple's own map tiles are not shown.
struct TileMapView: UIViewRepresentable {
    struct Pin: Identifiable, Equatable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let title: String
        let subtitle: String
        let kind: Int  // contact kind; 0 = your radio
        static func == (a: Pin, b: Pin) -> Bool {
            a.id == b.id && a.title == b.title && a.subtitle == b.subtitle
                && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    let tiles: MapConfig
    var pins: [Pin] = []
    /// The region to show first; nil fits the pins.
    var initialCenter: CLLocationCoordinate2D?
    var onSelect: ((Pin) -> Void)?
    /// For pickers: reports the map centre as it moves.
    var onCenter: ((CLLocationCoordinate2D) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        let template = tiles.tileUrl.replacingOccurrences(of: "{s}", with: "a")
        let overlay = MKTileOverlay(urlTemplate: template)
        overlay.canReplaceMapContent = true
        overlay.maximumZ = tiles.maxZoom
        map.addOverlay(overlay, level: .aboveLabels)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "pin")
        if let c = initialCenter {
            map.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 3000, longitudinalMeters: 3000), animated: false)
        }
        context.coordinator.fitted = initialCenter != nil
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        let current = map.annotations.compactMap { $0 as? PinAnnotation }
        if current.map(\.pin) != pins {
            map.removeAnnotations(current)
            map.addAnnotations(pins.map(PinAnnotation.init))
            if !context.coordinator.fitted, !pins.isEmpty {
                context.coordinator.fitted = true
                map.showAnnotations(map.annotations, animated: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class PinAnnotation: NSObject, MKAnnotation {
        let pin: Pin
        init(_ pin: Pin) { self.pin = pin }
        var coordinate: CLLocationCoordinate2D { pin.coordinate }
        var title: String? { pin.title }
        var subtitle: String? { pin.subtitle }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TileMapView
        var fitted = false
        init(_ parent: TileMapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? PinAnnotation else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: a) as! MKMarkerAnnotationView
            let (color, glyph): (UIColor, String) = switch a.pin.kind {
            case 0: (.systemTeal, "house.fill")
            case 2: (.systemOrange, "antenna.radiowaves.left.and.right")
            case 3: (.systemPurple, "person.3.fill")
            case 4: (.systemGreen, "sensor.fill")
            default: (.systemBlue, "person.fill")
            }
            v.markerTintColor = color
            v.glyphImage = UIImage(systemName: glyph)
            v.canShowCallout = true
            v.rightCalloutAccessoryView = a.pin.kind == 0 ? nil : UIButton(type: .detailDisclosure)
            v.displayPriority = a.pin.kind == 0 ? .required : .defaultHigh
            return v
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let a = view.annotation as? PinAnnotation { parent.onSelect?(a.pin) }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onCenter?(mapView.centerCoordinate)
        }
    }
}
