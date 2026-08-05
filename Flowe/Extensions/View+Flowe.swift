import SwiftUI

extension View {
    func floweBackground() -> some View {
        self.background(Color.floweCardBg.ignoresSafeArea())
    }

    func cardStyle(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color.flowWhite)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Color.flowePink.opacity(0.15), radius: 8, x: 0, y: 4)
    }
}

extension Text {
    /// Renders a runtime data value (discipline / specialty / category / session-type / status) through
    /// the String Catalog. `LocalizedStringKey(runtimeString)` does a catalog lookup at render honoring
    /// the env `\.locale`, and falls back to the raw string verbatim when no key exists — so canonical
    /// values (Mat/Reformer/…/Private/Duet/Confirmed/…) translate while free-form names pass through
    /// unchanged. Always localize FIRST; never `.uppercased()` before lookup (use `.textCase(.uppercase)`).
    init(localizedTag value: String) { self.init(LocalizedStringKey(value)) }
}
