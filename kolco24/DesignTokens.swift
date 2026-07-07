import SwiftUI
import UIKit

// MARK: - Color tokens (A2 Grey v2 palette)
// Adaptive: each token mirrors the dark/light token table from `design_dark.html`
// and switches automatically with the system `userInterfaceStyle` trait.
extension Color {
    static let ink         = Color(light: "161A1F", dark: "F2F4F7")
    static let sub         = Color(light: "56606A", dark: "98A2AD")
    static let paper       = Color(light: "EEF0F3", dark: "0C0F14")
    static let brandRed    = Color(light: "C3011C", dark: "FF4759")
    static let kolcoOrange = Color(light: "C65A2E", dark: "F0763C")
    static let good        = Color(light: "1F7A3D", dark: "34C759")
    static let charcoal    = Color(light: "1D242D", dark: "27313D")
    static let charcoalHi  = Color(light: "2A323C", dark: "171D25")
    static let amber       = Color(hex: "F2B36B") // unchanged in dark

    // Progress bar gradient end-stop (lighter green, distinct from `good` token).
    static let goodEnd      = Color(light: "2FA055", dark: "2EBD52")

    // Surfaces / lines / shadows (previously hard-coded literals in views).
    static let card        = Color(light: "FFFFFF", dark: "181D24")
    // Elevated control surface (buttons on card): same as card in light (shadow provides lift),
    // visibly lighter than card in dark so button affordance is distinct from parent surface.
    static let cardElevated = Color(light: "FFFFFF", dark: "252C38")
    // Hairline dividers/strokes: light `rgba(60,60,67,0.13)`, dark `rgba(255,255,255,0.08)`.
    static let hairline    = Color(lightUI: UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.13),
                                   darkUI:  UIColor(white: 1, alpha: 0.08))
    // Card shadow: light black α≈0.05, dark black α≈0.45.
    static let cardShadow  = Color(lightUI: UIColor(white: 0, alpha: 0.05),
                                   darkUI:  UIColor(white: 0, alpha: 0.45))
    // Hero-card drop shadow (radius ≥ 18): warmer charcoal tint in light (0.45), pure-black in dark (0.45).
    static let heroShadow  = Color(lightUI: UIColor(red: 29/255, green: 36/255, blue: 45/255, alpha: 0.45),
                                   darkUI:  UIColor(white: 0, alpha: 0.45))

    /// Adaptive opaque color from two hex strings, resolved per `userInterfaceStyle`.
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// Adaptive color from two `UIColor`s — used for tokens that carry their own alpha.
    init(lightUI: UIColor, darkUI: UIColor) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? darkUI : lightUI
        })
    }

    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }
}

// MARK: - Typography
// JetBrains Mono must be added to the app bundle + Info.plist (UIAppFonts).
// Falls back to system monospaced if not bundled.
extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", size: size).weight(weight)
    }
}

// MARK: - Spacing / radius constants
enum DS {
    static let hPad: CGFloat       = 16
    static let cardRadius: CGFloat = 13
    static let heroRadius: CGFloat = 18
    static let ctaRadius: CGFloat  = 16
}
