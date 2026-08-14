import SwiftUI

extension Color {
    // Primary
    static let flowEspressoBrown = Color(hex: 0x4E3B31)
    static let flowDustyRose     = Color(hex: 0xD98C95)
    static let flowBlushPink     = Color(hex: 0xF3C9CF)
    static let flowWarmCream     = Color(hex: 0xFAF6F2)
    static let flowSoftBeige     = Color(hex: 0xF2EAE3)

    // Neutral & supporting
    static let flowWarmGray      = Color(hex: 0xD8CFC7)
    static let flowTaupeGray     = Color(hex: 0x8F827A)
    static let flowDarkBrown     = Color(hex: 0x3B2F2A)
    static let flowLightBeige    = Color(hex: 0xF7F2ED)
    static let flowWhite         = Color(hex: 0xFFFFFF)

    // MARK: - Figma pink palette (app source of truth)
    static let flowePink     = Color(hex: 0xE8789A)
    static let flowePinkDeep = Color(hex: 0xB23E63)   // WCAG AA >=4.5:1 as text on white/cream/cardBg AND for white text on pink fills/badges (was 0xD45880, ~3.4:1 — failing)
    static let flowePinkSoft = Color(hex: 0xF4A8C0)
    static let flowePinkPale = Color(hex: 0xFFC2D4)
    static let floweCardBg   = Color(hex: 0xFFF0F4)
    static let floweInk      = Color(hex: 0x2D1520)
    static let floweMuted    = Color(hex: 0x86586A)   // WCAG AA >=4.5:1 on white (was 0xB08090)
    static let floweBorder   = Color(hex: 0xE8789A).opacity(0.18)

    // Status badges (bookings)
    static let floweSuccess  = Color(hex: 0x2F6E4F)   // warmer, darker on-palette green (was 0x4CAF50 stock Material)
    static let floweCancel   = Color(hex: 0xE05070)
}
