import SwiftUI
import UIKit

/// Colours that keep text readable (WCAG AA, 4.5:1) in light and dark mode.
enum Palette {
    /// Sent-message bubbles: a deeper blue than the system one, so white text passes 4.5:1.
    static let bubble = Color(uiColor: UIColor { _ in UIColor(red: 0.0, green: 0.40, blue: 0.85, alpha: 1) })
    /// "SIM" and other simulated-data markers: dark orange on light, light orange on dark.
    static let simulated = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.66, green: 0.30, blue: 0.0, alpha: 1)
    })
}
