import SwiftUI
import UIKit

// MARK: - Section header (uppercase mono meta label)

struct SectionHeader: View {
    let text: LocalizedStringKey
    var color: Color = .floweMuted

    var body: some View {
        Text(text)
            .font(FloweFont.mono(11))
            .foregroundStyle(color)
    }
}

// MARK: - Star rating (star glyph + number)

struct StarRatingView: View {
    let rating: Double
    var size: CGFloat = 10
    var tint: Color = .flowePink

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: size))
                .foregroundStyle(tint)
            Text(String(format: "%.1f", rating))
                .font(FloweFont.mono(size + 1))
                .foregroundStyle(Color.flowePinkDeep)
        }
    }
}

// MARK: - Specialty / discipline pill

struct SpecialtyTag: View {
    let text: String

    var body: some View {
        Text(localizedTag: text)
            .font(FloweFont.mono(10))
            .foregroundStyle(Color.flowePinkDeep)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.flowePink.opacity(0.10))
            .clipShape(Capsule())
    }
}

// MARK: - Status badge (booking state)

struct StatusBadge: View {
    let status: BookingStatus

    var body: some View {
        Text(LocalizedStringKey(status.label))
            .font(FloweFont.mono(10))
            .foregroundStyle(status.badgeForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(status.badgeBackground)
            .clipShape(Capsule())
    }
}

// MARK: - Recurring badge (standing weekly slot)

// MARK: - Waitlist badge (derived, not a BookingStatus case)

/// A small capsule marking a booking as on the waitlist — an OVERFLOW seat on a full group class.
/// Deliberately NOT a 5th `BookingStatus`: waitlisted-ness is COMPUTED from the hold's seat index
/// (`MockDataStore.isWaitlisted`), so it overlays the status badge without growing the enum. Optional
/// `rank` shows "#1" position.
struct WaitlistBadge: View {
    var rank: Int? = nil
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hourglass")
                .font(.system(size: 9, weight: .semibold))
            Text("Waitlisted")
                .font(FloweFont.mono(10))
            if let rank { Text(verbatim: "#\(rank)").font(FloweFont.mono(10)) }
        }
        .foregroundStyle(Color.flowePinkDeep)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.flowePink.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Stat tile (value over label)

struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    var accent: Color = .flowePinkDeep

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(FloweFont.serif(20, .medium))
                .foregroundStyle(accent)
            Text(label)
                .font(FloweFont.mono(10))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Full-width pink gradient CTA

struct GradientButton: View {
    let title: LocalizedStringKey
    var enabled: Bool = true
    /// While true the label is swapped for a spinner and taps are ignored — for async CTAs (a CloudKit
    /// round-trip) that would otherwise look inert after the tap. The label keeps its width so the button
    /// doesn't resize mid-action.
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            guard !isLoading else { return }
            Haptic.tap()
            action()
        } label: {
            ZStack {
                Text(title)
                    .font(FloweFont.sans(15, .medium))
                    .foregroundStyle(.white)
                    .opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(.white) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(FlowGradients.gradDark)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .flowePressable()
        .disabled(!enabled || isLoading)
        .opacity(enabled ? 1 : 0.3)
    }
}

// MARK: - Card surface (pale pink bg + hairline border)

extension View {
    func floweCard(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.floweBorder, lineWidth: 1)
            )
            // Two-layer warm elevation so cards LIFT off the surface instead of reading as flat
            // colour blocks: a soft ambient rose halo + a tighter ink key shadow.
            .shadow(color: Color.flowePink.opacity(0.10), radius: 14, x: 0, y: 6)
            .shadow(color: Color.floweInk.opacity(0.045), radius: 3, x: 0, y: 1)
    }
}

// ============================================================================
// MARK: - Gesture toolkit (Instagram-style interactions)
// Reusable, Reduce-Motion-aware building blocks shared across the app. All new
// gesture types live here (xcodegen is not installed → no new .swift files).
// ============================================================================

// MARK: Haptics

/// Thin wrapper over UIKit feedback generators. Call `Haptic.tap()` on a
/// successful gesture (like fired, image opened, tab switched) and
/// `Haptic.success()` for a heavier confirmation. Generators are cheap and
/// created per-call; the system coalesces rapid taps.
enum Haptic {
    /// Light selection-weight impact — the default "it worked" tick.
    static func tap() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
    }

    /// Medium impact — a slightly weightier confirmation (e.g. a like landing).
    static func impact() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.impactOccurred()
    }

    /// Selection tick — for discrete choice changes (segment/filter/tab switch,
    /// stepping through options). Lighter and drier than `tap()`.
    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.selectionChanged()
    }

    /// Success notification — for a completed, meaningful action (booking confirmed, request sent,
    /// review posted, package purchased).
    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.success)
    }

    /// Warning notification — for a consequential/destructive confirmation (cancel a session, delete,
    /// block, end a series). More "careful" than a selection tick, softer than an error.
    static func warning() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.warning)
    }

    /// Error notification — for a FAILED action only (a booking that didn't go through, a sign-in
    /// failure, a blocked submit). The one clearly-negative pattern; never for a normal tap.
    static func error() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.error)
    }
}

// ============================================================================
// MARK: - FloweMotion — the shared motion layer
// A single, restrained set of animation tokens + reduce-motion-aware modifiers.
// Every animated surface in the app pulls from HERE so motion reads as one
// cohesive system (never ad-hoc durations). Lives in FloweCommon.swift because
// xcodegen is not installed → no new .swift files. All modifiers respect
// `@Environment(\.accessibilityReduceMotion)`.
// ============================================================================

/// The three canonical curves. Pick by INTENT, not by feel:
/// - `spring` — default for content/layout changes (rows settling, sheets, reflow).
/// - `pop` — snappy taps & selection (press scale, toggles, picks).
/// - `gentle` — plain fades / appearance where a spring would feel fussy.
enum FloweMotion {
    /// Default content/layout spring — calm settle, no visible overshoot.
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.82)
    /// Snappier spring with a hint of life for taps/selection.
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.62)
    /// Soft ease for fades and appearances.
    static let gentle = Animation.easeOut(duration: 0.32)
}

// MARK: Press feedback (the standard tap response)

/// The app-wide press style: a subtle scale-down + dim while held, sprung with
/// `FloweMotion.pop`. Apply to any `Button` (directly, or via `.flowePressable()`)
/// so tappable cards/CTAs that today use `.buttonStyle(.plain)` gain consistent
/// feedback. Under Reduce Motion the scale is dropped — only the opacity dim
/// remains, so the press is still legible without motion.
struct FlowePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (pressed ? 0.96 : 1))
                .opacity(pressed ? 0.92 : 1)
                .animation(FloweMotion.pop, value: pressed)
        }
    }
}

extension View {
    /// Give a `Button` (or a subtree of buttons) the standard Flowe press
    /// feedback. Replace `.buttonStyle(.plain)` on tappable cards with this.
    func flowePressable() -> some View {
        buttonStyle(FlowePressStyle())
    }
}

// MARK: Appear (first-appearance fade + rise + settle)

/// Fades a view in while it rises ~8pt and scales up from 0.98 on its first
/// appearance, with a small per-`index` stagger for lists/sections. Under
/// Reduce Motion it is a plain fade (no transform, no offset). Idempotent — the
/// entrance plays once per view lifetime.
struct FloweAppearModifier: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Per-row stagger, capped so long lists don't cascade forever.
    private var delay: Double { min(Double(index) * 0.04, 0.32) }

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.98)
            .offset(y: appeared || reduceMotion ? 0 : 8)
            .onAppear {
                guard !appeared else { return }
                let anim = reduceMotion ? FloweMotion.gentle : FloweMotion.spring
                withAnimation(anim.delay(delay)) { appeared = true }
            }
    }
}

extension View {
    /// See `FloweAppearModifier`. Attach to list rows / cards / sections. Pass
    /// the row's index for a gentle staggered entrance; omit for a lone element.
    func floweAppear(_ index: Int = 0) -> some View {
        modifier(FloweAppearModifier(index: index))
    }
}

// MARK: Shimmer (loading-skeleton sweep)

/// A soft left-to-right highlight sweep for loading skeletons. Drive it with the
/// same `active` flag that gates the skeleton; it sweeps only while `active` and
/// is masked to the content's own shape, so rounded placeholder blocks shimmer
/// correctly. Under Reduce Motion it renders the static content with no sweep.
struct FloweShimmerModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.55), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.45)
                    // Travel fully off the left edge to fully off the right.
                    .offset(x: -w * 0.725 + phase * (w * 1.45))
                    .onAppear {
                        withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                            phase = 1
                        }
                    }
                }
                .allowsHitTesting(false)
                .mask(content)
            }
        } else {
            content
        }
    }
}

extension View {
    /// See `FloweShimmerModifier`. Wrap a loading skeleton; pass `true` while it
    /// is loading. No sweep under Reduce Motion.
    func floweShimmer(_ active: Bool) -> some View {
        modifier(FloweShimmerModifier(active: active))
    }
}

// MARK: Double-tap-to-like

/// Attach to a post's image/card to add Instagram-style double-tap-to-like:
/// a centered heart-burst overlay + haptic, firing the LIKE-only `onLike`
/// closure (never an unlike — call sites should pass their *like* action, and
/// the action itself should no-op if already liked).
///
/// **Call-site ordering matters.** Add `.doubleTapToLike { … }` FIRST, then any
/// single-tap handler AFTER it, so the double-tap wins and single taps still
/// pass through:
/// ```swift
/// postImage
///     .doubleTapToLike { store.like(post) }   // count:2, high priority
///     .onTapGesture { openViewer = true }      // count:1, falls through
/// ```
/// The heart animation is skipped/curtailed under Reduce Motion.
struct DoubleTapToLikeModifier: ViewModifier {
    let onLike: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heartScale: CGFloat = 0.3
    @State private var heartOpacity: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay { heart }
            // High-priority double-tap so it beats a call-site single tap;
            // a lone tap fails this gesture and falls through unchanged.
            .highPriorityGesture(TapGesture(count: 2).onEnded { fire() })
    }

    private var heart: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 92))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
            .scaleEffect(reduceMotion ? 1 : heartScale)
            .opacity(heartOpacity)
            .allowsHitTesting(false)   // never steal taps from the image
    }

    private func fire() {
        onLike()
        Haptic.impact()
        if reduceMotion {
            // No zoom/scale — just a brief fade in/out.
            heartOpacity = 1
            withAnimation(.easeOut(duration: 0.4).delay(0.55)) { heartOpacity = 0 }
            return
        }
        heartScale = 0.3
        heartOpacity = 0
        withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
            heartScale = 1
            heartOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.45)) {
            heartOpacity = 0
            heartScale = 1.35
        }
    }
}

extension View {
    /// See `DoubleTapToLikeModifier`. LIKE-only; heart-burst + haptic.
    func doubleTapToLike(_ onLike: @escaping () -> Void) -> some View {
        modifier(DoubleTapToLikeModifier(onLike: onLike))
    }
}

// MARK: Full-screen zoomable image viewer

/// The image source for `ZoomableImageView` / `.fullScreenImageZoom`. Covers the
/// three shapes call sites already hold: raw `Data?`, a decoded `UIImage?`, or a
/// `RemoteImage`-style id + uploaded-photo pair (post/listing/certificate/event).
enum ZoomableImageSource {
    case data(Data?)
    case uiImage(UIImage?)
    case remote(id: String, photo: Data?)
}

/// Full-screen, pinch-zoomable image with double-tap-zoom (1×/2× centered on the
/// tap) and drag-DOWN-to-dismiss (the black backdrop fades as you drag). Present
/// it via `.fullScreenImageZoom(source:isPresented:)` — it manages its own
/// transparent cover backdrop, so the fade reads against the app underneath.
/// Zoom/scale animations are curtailed under Reduce Motion.
struct ZoomableImageView: View {
    let source: ZoomableImageSource
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scale: CGFloat = 1        // committed zoom
    @State private var pinch: CGFloat = 1         // live pinch multiplier
    @State private var offset: CGSize = .zero     // committed pan
    @State private var dragPan: CGSize = .zero    // live pan
    @State private var dismissDrag: CGFloat = 0   // downward dismiss distance

    private let maxScale: CGFloat = 4
    private let dismissThreshold: CGFloat = 120

    private var effectiveScale: CGFloat { scale * pinch }
    private var isZoomed: Bool { effectiveScale > 1.01 }
    private var backdropOpacity: Double { max(0, 1 - Double(dismissDrag) / 400) }
    private var dismissScale: CGFloat {
        reduceMotion ? 1 : max(0.85, 1 - dismissDrag / 1200)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(backdropOpacity).ignoresSafeArea()

                imageContent
                    .scaleEffect(effectiveScale * dismissScale)
                    .offset(x: offset.width + dragPan.width,
                            y: offset.height + dragPan.height + dismissDrag)
                    .gesture(magnify(geo.size).simultaneously(with: drag(geo.size)))
                    .simultaneousGesture(doubleTap(geo.size))

                // Close affordance — top-trailing, always available.
                VStack {
                    HStack {
                        Spacer()
                        Button { Haptic.tap(); onDismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                        .accessibilityLabel("Close")
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .opacity(backdropOpacity)
            }
        }
        .presentationBackground(.clear)   // let the backdrop fade to the app
    }

    // MARK: Image rendering

    @ViewBuilder private var imageContent: some View {
        switch source {
        case .uiImage(let img):
            if let img {
                Image(uiImage: img).resizable().scaledToFit()
            } else { fallback }
        case .data(let data):
            if let data, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFit()
            } else { fallback }
        case .remote(let id, let photo):
            if let photo, let img = UIImage(data: photo) {
                Image(uiImage: img).resizable().scaledToFit()
            } else if !id.isEmpty {
                AsyncImage(url: UnsplashImage.url(id, w: 1400, h: 1400)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else { fallback }
                }
            } else { fallback }
        }
    }

    private var fallback: some View {
        FlowGradients.grad.aspectRatio(1, contentMode: .fit)
    }

    // MARK: Gestures

    private func magnify(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in pinch = v.magnification }
            .onEnded { _ in
                var s = scale * pinch
                s = min(max(s, 1), maxScale)
                pinch = 1
                if s <= 1.01 {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                        scale = 1; offset = .zero
                    }
                } else {
                    scale = s
                    offset = clampedOffset(offset, scale: s, size: size)
                }
            }
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if isZoomed {
                    dragPan = v.translation                 // pan the zoomed image
                } else if v.translation.height > 0 {
                    dismissDrag = v.translation.height       // downward dismiss
                }
            }
            .onEnded { v in
                if isZoomed {
                    offset = clampedOffset(
                        CGSize(width: offset.width + v.translation.width,
                               height: offset.height + v.translation.height),
                        scale: effectiveScale, size: size)
                    dragPan = .zero
                } else if dismissDrag > dismissThreshold {
                    Haptic.tap()
                    onDismiss()
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                        dismissDrag = 0
                    }
                }
            }
    }

    private func doubleTap(_ size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { e in
                Haptic.tap()
                let animate: Animation? = reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)
                if isZoomed {
                    withAnimation(animate) { scale = 1; offset = .zero }
                } else {
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let target: CGFloat = 2
                    let raw = CGSize(width: -(e.location.x - c.x) * (target - 1),
                                     height: -(e.location.y - c.y) * (target - 1))
                    withAnimation(animate) {
                        scale = target
                        offset = clampedOffset(raw, scale: target, size: size)
                    }
                }
            }
    }

    /// Keep the panned image from drifting entirely off-screen.
    private func clampedOffset(_ o: CGSize, scale s: CGFloat, size: CGSize) -> CGSize {
        let maxX = max(0, size.width * (s - 1) / 2)
        let maxY = max(0, size.height * (s - 1) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }
}

extension View {
    /// Present a full-screen zoomable viewer for `source` when `isPresented` is
    /// true. One-line call site:
    /// ```swift
    /// .fullScreenImageZoom(source: .remote(id: post.imageID, photo: post.photo),
    ///                      isPresented: $showViewer)
    /// ```
    func fullScreenImageZoom(source: ZoomableImageSource,
                             isPresented: Binding<Bool>) -> some View {
        fullScreenCover(isPresented: isPresented) {
            ZoomableImageView(source: source) { isPresented.wrappedValue = false }
        }
    }

    /// Convenience overload for a decoded `UIImage?`.
    func fullScreenImageZoom(image: UIImage?, isPresented: Binding<Bool>) -> some View {
        fullScreenImageZoom(source: .uiImage(image), isPresented: isPresented)
    }

    /// Convenience overload for raw `Data?`.
    func fullScreenImageZoom(data: Data?, isPresented: Binding<Bool>) -> some View {
        fullScreenImageZoom(source: .data(data), isPresented: isPresented)
    }
}

// MARK: Scroll-to-top on active-tab reselect

/// Shared anchor id for the top of a scrollable tab. Put it on the FIRST element
/// inside each tab's scroll content, and wrap that content in a `ScrollViewReader`:
/// ```swift
/// ScrollViewReader { proxy in
///     ScrollView {
///         Color.clear.frame(height: 0).id(ScrollToTop.anchorID)   // top anchor
///         … content …
///     }
///     .scrollToTopOnTabReselect(trigger: reselectTick, proxy: proxy)
/// }
/// ```
/// `reselectTick` is any `Equatable` the tab shell bumps when the already-selected
/// tab is tapped again (e.g. an incrementing Int). Scrolls with animation, or
/// instantly under Reduce Motion.
enum ScrollToTop {
    static let anchorID = "flowe.scrollToTop.anchor"
}

struct ScrollToTopOnTabReselect<T: Equatable>: ViewModifier {
    let trigger: T
    let proxy: ScrollViewProxy
    var anchorID: AnyHashable = ScrollToTop.anchorID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _, _ in
            if reduceMotion {
                proxy.scrollTo(anchorID, anchor: .top)
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        }
    }
}

extension View {
    /// See `ScrollToTop`. Attach to the ScrollView inside a `ScrollViewReader`.
    func scrollToTopOnTabReselect<T: Equatable>(trigger: T,
                                                proxy: ScrollViewProxy,
                                                anchorID: AnyHashable = ScrollToTop.anchorID) -> some View {
        modifier(ScrollToTopOnTabReselect(trigger: trigger, proxy: proxy, anchorID: anchorID))
    }
}

// ============================================================================
// MARK: - Class packages / credits ([[ClassPackages]]) — shared UI components
// Live here (not new files) because xcodegen is not installed. The CreditRing is
// the feature's hero: "6 classes left" as a gradient progress ring that ticks
// DOWN with a numeric transition + haptic when a credit is redeemed. All are
// Reduce-Motion-aware and RTL-safe. See ClassPackages.md.
// ============================================================================

/// The hero credit meter. `remaining`/`total` drive a gradient arc from 12 o'clock; the centre shows the
/// count (numeric-transition so a redeem ticks it down live). `.hero` adds the "CLASSES LEFT" caption;
/// `.compact` is a bare number for wallet cards / inline use.
struct CreditRing: View {
    enum Style { case hero, compact }
    let remaining: Int
    let total: Int
    var size: CGFloat = 132
    var style: Style = .hero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animated: CGFloat = 0

    private var fraction: CGFloat { total <= 0 ? 0 : min(1, CGFloat(remaining) / CGFloat(total)) }
    private var lineWidth: CGFloat { max(4, size * 0.075) }
    private var low: Bool { remaining <= 1 }

    var body: some View {
        ZStack {
            Circle().stroke(Color.flowePink.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: animated)
                .stroke(FlowGradients.gradDark, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))   // start the arc at 12 o'clock
            centre
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion { animated = fraction }
            else { withAnimation(FloweMotion.spring.delay(0.05)) { animated = fraction } }
        }
        .onChange(of: fraction) { _, new in
            withAnimation(reduceMotion ? nil : FloweMotion.pop) { animated = new }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(remaining) of \(total) classes left"))
    }

    @ViewBuilder private var centre: some View {
        switch style {
        case .hero:
            VStack(spacing: size * 0.015) {
                Text(verbatim: "\(remaining)")
                    .font(FloweFont.serif(size * 0.34, .medium))
                    .foregroundStyle(low ? Color.flowePinkDeep : Color.floweInk)
                    .contentTransition(.numericText())
                Text("CLASSES LEFT")
                    .font(FloweFont.mono(max(8, size * 0.072)))
                    .foregroundStyle(Color.floweMuted)
            }
        case .compact:
            Text(verbatim: "\(remaining)")
                .font(FloweFont.serif(size * 0.42, .medium))
                .foregroundStyle(Color.flowePinkDeep)
                .contentTransition(.numericText())
        }
    }
}

/// Secondary texture for small packs (total ≤ 12): a row of filled/hollow dots. The ring carries the
/// a11y label, so this is decorative.
struct CreditDots: View {
    let remaining: Int
    let total: Int
    var dot: CGFloat = 10

    var body: some View {
        HStack(spacing: dot * 0.5) {
            ForEach(0..<max(total, 0), id: \.self) { i in
                Circle()
                    .fill(i < remaining ? AnyShapeStyle(FlowGradients.gradDark) : AnyShapeStyle(Color.clear))
                    .overlay(Circle().strokeBorder(Color.flowePink.opacity(i < remaining ? 0 : 0.4), lineWidth: 1.5))
                    .frame(width: dot, height: dot)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One instructor package on offer — used on the student profile (with a "Request to buy" footer) and in
/// the instructor's manager (with a menu row). Pass any trailing content via `footer`.
struct PackageOfferingCard: View {
    @Environment(AppSettings.self) private var settings
    let offering: RemoteOffering
    var footer: AnyView? = nil

    private var perClass: Int { offering.credits > 0 ? offering.price / offering.credits : offering.price }

    var body: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(offering.title)
                    .font(FloweFont.serif(18, .medium))
                    .foregroundStyle(Color.floweInk)
                Spacer()
                Text(settings.money(offering.price))
                    .font(FloweFont.serif(18, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            HStack(spacing: FlowSpacing.xs) {
                Label("\(offering.credits) classes", systemImage: "ticket.fill")
                    .font(FloweFont.sans(12, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
                Text("· \(settings.money(perClass))/class")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                Spacer()
                validityChip
            }
            if let footer { footer }
        }
        .padding(FlowSpacing.lg)
        .floweCard()
    }

    private var validityChip: some View {
        Group {
            if let days = offering.validityDays {
                Text("\(days)-day")
            } else {
                Text("No expiry")
            }
        }
        .font(FloweFont.mono(10))
        .foregroundStyle(Color.floweMuted)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.floweMuted.opacity(0.10))
        .clipShape(Capsule())
    }
}

/// An instructor's purchase-request approval card. Approve only once you've been paid offline; approval
/// grants the credits server-side.
struct PackagePurchaseRequestCard: View {
    @Environment(AppSettings.self) private var settings
    let purchase: RemotePurchase
    var studentPhoto: Data? = nil   // resolved by the caller — the card has no store to look it up
    /// Live-resolved buyer name, same contract as `studentPhoto`: the caller looks it up via
    /// `displayIdentity` because this card has no store. `purchase.studentName` is only a FROZEN
    /// snapshot taken at request time, so it can read "Member" (the sign-in fallback for a student
    /// who had not set a name yet) even after they set a real one — hence the live override.
    var resolvedName: String? = nil
    var onApprove: () -> Void = {}
    var onDecline: () -> Void = {}
    @State private var deciding = false

    private var name: String {
        if let resolvedName, !resolvedName.isEmpty { return resolvedName }
        return purchase.studentName.isEmpty ? String(localized: "a student") : purchase.studentName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.md) {
            HStack(spacing: FlowSpacing.md) {
                // The resolved buyer photo if we have it, else initials (the app's standard fallback) —
                // NOT the pink gradient (passing a dotted appleUserID as `id` would hit the release-
                // disabled Unsplash path and fall through to the gradient).
                if let studentPhoto {
                    AvatarView(id: "", photo: studentPhoto, size: 44)
                } else {
                    InitialAvatar(name: name, size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(FloweFont.serif(16, .medium)).foregroundStyle(Color.floweInk)
                    Text("\(purchase.credits)-class pack · \(settings.money(purchase.price))")
                        .font(FloweFont.sans(13)).foregroundStyle(Color.floweMuted)
                }
                Spacer()
            }
            switch purchase.status {
            case .pending:
                Text("Approve once you've received \(settings.money(purchase.price)) from \(name).")
                    .font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted)
                HStack(spacing: FlowSpacing.sm) {
                    Button { deciding = true; Haptic.tap(); onDecline() } label: {
                        Text("Decline").font(FloweFont.sans(14, .medium)).foregroundStyle(Color.floweInk)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                    }.flowePressable()
                    Button { deciding = true; Haptic.success(); onApprove() } label: {
                        Text("Approve").font(FloweFont.sans(14, .medium)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(FlowGradients.gradDark).clipShape(RoundedRectangle(cornerRadius: 14))
                    }.flowePressable()
                }
                .disabled(deciding)
                .opacity(deciding ? 0.5 : 1)
            case .approved:
                Label("Approved · \(purchase.credits) credits added", systemImage: "checkmark.circle.fill")
                    .font(FloweFont.mono(11)).foregroundStyle(Color.floweSuccess)
            case .declined:
                Label("Declined", systemImage: "xmark.circle")
                    .font(FloweFont.mono(11)).foregroundStyle(Color.floweMuted)
            }
        }
        .padding(FlowSpacing.lg)
        .floweCard()
    }
}

/// A wallet-carousel tile — the student's credit standing with one instructor. Tap opens the detail.
struct CreditWalletCard: View {
    let balance: InstructorBalance
    var instructorName: String = ""
    var instructorPhoto: Data? = nil
    var onTap: () -> Void = {}

    var body: some View {
        Button { Haptic.tap(); onTap() } label: {
            VStack(alignment: .leading, spacing: FlowSpacing.sm) {
                HStack(spacing: FlowSpacing.sm) {
                    AvatarView(id: balance.instructorID, photo: instructorPhoto, size: 30)
                    Text(verbatim: instructorName.isEmpty ? String(localized: "Instructor") : instructorName)
                        .font(FloweFont.sans(13, .medium)).foregroundStyle(Color.floweInk).lineLimit(1)
                }
                CreditRing(remaining: balance.balance, total: max(balance.balance, 1), size: 56, style: .compact)
                    .frame(maxWidth: .infinity)
                Text(expiryText)
                    .font(FloweFont.mono(10)).foregroundStyle(Color.floweMuted)
            }
            .padding(FlowSpacing.md)
            .frame(width: 150)
            .floweCard()
        }
        .flowePressable()
    }

    private var expiryText: LocalizedStringKey {
        guard let exp = balance.nextExpiry else { return "Never expires" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0
        return days <= 0 ? "Expires today" : "Expires in \(days)d"
    }
}

/// The booking-sheet redeem control — shown only when the student holds credits with this instructor.
/// Toggling it makes the booking spend one class-credit; the count preview ticks as it flips.
struct CreditRedeemToggle: View {
    let remaining: Int
    @Binding var useCredit: Bool

    private var after: Int { max(0, remaining - (useCredit ? 1 : 0)) }

    var body: some View {
        HStack(spacing: FlowSpacing.md) {
            ZStack {
                Circle().fill(Color.flowePink.opacity(0.12)).frame(width: 40, height: 40)
                Text(verbatim: "\(remaining)")
                    .font(FloweFont.serif(17, .medium)).foregroundStyle(Color.flowePinkDeep)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Use 1 class credit")
                    .font(FloweFont.sans(14, .medium)).foregroundStyle(Color.floweInk)
                Text("\(after) left after this")
                    .font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted)
                    .contentTransition(.numericText())
            }
            Spacer()
            Toggle("", isOn: $useCredit).labelsHidden().tint(Color.flowePinkDeep)
        }
        .padding(FlowSpacing.md)
        .floweCard()
        .onChange(of: useCredit) { _, _ in Haptic.selection() }
    }
}
