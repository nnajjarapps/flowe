import SwiftUI

// MARK: - Font families (bundled TrueType, per Figma mockup)
//
// Serif  → Fraunces   (headings, instructor names, prices, hero copy)
// Sans   → DM Sans     (body text, buttons, tab labels)
// Mono   → DM Mono     (uppercase meta labels, ratings, tags, times)

enum FloweFont {

    enum SerifWeight { case light, regular, medium }
    enum SansWeight  { case light, regular, medium }

    /// Fraunces — set `italic` for the `<em>` accent words in the mockup headings.
    static func serif(_ size: CGFloat, _ weight: SerifWeight = .regular, italic: Bool = false) -> Font {
        let name: String
        switch (weight, italic) {
        case (.light,   false): name = "Fraunces-Light"
        case (.light,   true):  name = "Fraunces-LightItalic"
        case (.regular, false): name = "Fraunces-Regular"
        case (.regular, true):  name = "Fraunces-Italic"
        case (.medium,  false): name = "Fraunces-Medium"
        case (.medium,  true):  name = "Fraunces-Italic"   // no medium-italic cut bundled
        }
        return .custom(name, fixedSize: size)
    }

    /// DM Sans
    static func sans(_ size: CGFloat, _ weight: SansWeight = .regular) -> Font {
        let name: String
        switch weight {
        case .light:   name = "DMSans-Light"
        case .regular: name = "DMSans-Regular"
        case .medium:  name = "DMSans-Medium"
        }
        return .custom(name, fixedSize: size)
    }

    /// DM Mono (Light 300 / Regular 400)
    static func mono(_ size: CGFloat, light: Bool = false) -> Font {
        .custom(light ? "DMMono-Light" : "DMMono-Regular", fixedSize: size)
    }
}

// MARK: - Semantic scale (kept for existing onboarding call sites)

enum FlowFont {
    case displayLarge   // splash / hero
    case displayMedium
    case titleLarge     // screen titles
    case titleMedium
    case bodyLarge
    case bodyMedium
    case caption
    case label          // uppercase mono meta

    var font: Font {
        switch self {
        case .displayLarge:  return FloweFont.serif(32, .medium)
        case .displayMedium: return FloweFont.serif(26, .regular)
        case .titleLarge:    return FloweFont.serif(20, .regular)
        case .titleMedium:   return FloweFont.serif(17, .regular)
        case .bodyLarge:     return FloweFont.sans(16, .regular)
        case .bodyMedium:    return FloweFont.sans(14, .regular)
        case .caption:       return FloweFont.sans(12, .regular)
        case .label:         return FloweFont.mono(11)
        }
    }
}

extension View {
    func flowFont(_ style: FlowFont) -> some View {
        self.font(style.font)
    }
}
