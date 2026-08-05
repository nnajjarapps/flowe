import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Parse a "#RRGGBB" / "RRGGBB" brand-color string. Nil for empty or malformed input so callers
    /// fall back to the app accent. The model stores the raw string (UI-free); views resolve the Color
    /// here. Used by the Flowe Pro brand kit — see [[FlowePro]].
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
