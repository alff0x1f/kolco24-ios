import SwiftUI

// MARK: - Color tokens (A2 Grey v2 palette)
extension Color {
    static let ink         = Color(hex: "161A1F")
    static let sub         = Color(hex: "56606A")
    static let paper       = Color(hex: "EEF0F3")
    static let brandRed    = Color(hex: "C3011C")
    static let kolcoOrange = Color(hex: "C65A2E")
    static let good        = Color(hex: "1F7A3D")
    static let charcoal    = Color(hex: "1D242D")
    static let charcoalHi  = Color(hex: "2A323C")
    static let amber       = Color(hex: "F2B36B")

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
