import SwiftUI
import UIKit

// Semantic system colors ONLY for chrome and text — light/dark come free and the palette
// tracks OS design changes (incl. Liquid Glass token updates) automatically. The named
// custom colors below are the app's few genuinely bespoke hues from the brand pack.
enum Theme {
    static let sun = Color(light: "#D97706", dark: "#FF9F0A")
    static let view = Color(light: "#7C3AED", dark: "#7C3AED")
    static let proBadge = Color(uiColor: .systemOrange)
    static let levelGreen = Color(uiColor: .systemGreen)
    static let needsRamp = Color(uiColor: .systemOrange)
    static let needsBigRamp = Color(uiColor: .systemRed)
}

extension Color {
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// Haptic + audio cues so the user doesn't have to keep walking back to the screen.
enum Haptics {
    static func levelReached() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func stepChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func saved() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
