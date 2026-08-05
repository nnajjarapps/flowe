import SwiftUI
import UIKit

enum EventCardStyle {
    /// The full photo-led card in the student events list.
    case hero
    /// A one-line row for the instructor Dashboard's "YOUR EVENTS" section — no photo, no footer.
    case compact
}

/// One event, as a whole tappable card. Shared between the student list (`.hero`) and the instructor
/// Dashboard (`.compact`), so fullness is decided in exactly one place — `event.status` — and the
/// card only *renders* it, never recomputes it.
///
/// The card is a link, not a control that joins: joining happens in `EventDetailView`. A Join button
/// on a scrolling card invites a mistap that commits a student to a class.
struct EventCardView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings

    let event: CommunityEvent
    var style: EventCardStyle = .hero
    var onOpen: () -> Void = {}

    /// `.full` / `.ended` / `.cancelled` all read as "unavailable" and get the scoped greying. A
    /// `.joined` or `.open` event never does — a student who holds a spot must never see it greyed.
    private var isUnavailable: Bool {
        switch event.status {
        case .full, .ended, .cancelled: return true
        case .joined, .open:            return false
        }
    }

    var body: some View {
        Button(action: onOpen) {
            switch style {
            case .hero:    heroCard
            case .compact: compactRow
            }
        }
        .buttonStyle(EventCardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event.card.\(event.legacyId)")
    }

    // MARK: - Hero

    private var heroCard: some View {
        // Hand-rolled rather than `.floweCard()`: that modifier clips its whole content to the
        // rounded rectangle, which would slice the date medallion in half where it straddles the
        // photo/body seam. Only the photo band is clipped here; the medallion overhangs freely.
        VStack(spacing: 0) {
            photoBand
            heroBody
            heroFooter
        }
        .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.floweBorder, lineWidth: 1)
        )
    }

    private var photoBand: some View {
        photoContent
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            // Fixed 16:9 (not a clamped range like the feed): a list of cards only scans as a list
            // when the heights line up.
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, Color.floweInk.opacity(0.55)],
                    startPoint: .center, endPoint: .bottom
                )
            }
            .saturation(isUnavailable ? 0.35 : 1)
            .overlay { if isUnavailable { Color.floweInk.opacity(0.12) } }
            .clipShape(.rect(topLeadingRadius: 20, topTrailingRadius: 20))
            // Added after the clip so the medallion's downward offset is never cut off.
            .overlay(alignment: .bottomLeading) {
                dateMedallion()
                    .padding(.leading, 16)
                    .offset(y: 30)
            }
    }

    /// The four states a highlight band can be in — a decoded photo, a photo known-to-exist but not
    /// yet downloaded, no photo at all, and no photo on an unavailable event (which inherits the
    /// desaturation applied above the band as a whole).
    @ViewBuilder
    private var photoContent: some View {
        if let bytes = event.highlight, let image = UIImage(data: bytes) {
            Color.clear.overlay {
                Image(uiImage: image).resizable().scaledToFill()
            }
        } else if event.hasHighlight {
            // The record carries a photo we haven't fetched yet. A muted plate + spinner so the row
            // never resizes under the reader's thumb when the asset lands.
            FlowGradients.grad.opacity(0.25)
                .overlay { ProgressView().tint(Color.flowePinkDeep) }
        } else {
            // Genuinely no photo — the composed gradient-with-watermark stand-in, so an event with
            // no picture still looks deliberate rather than broken.
            FlowGradients.grad
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.22))
                        .padding(20)
                }
        }
    }

    private func dateMedallion(compact: Bool = false) -> some View {
        let width: CGFloat = compact ? 46 : 54
        let height: CGFloat = compact ? 52 : 60
        return VStack(spacing: 1) {
            Text(event.startsAt.flowMonthShort.uppercased())
                .font(FloweFont.mono(9))
                .foregroundStyle(Color.floweMuted)
            Text(event.startsAt.flowDayNumber)
                .font(FloweFont.serif(compact ? 20 : 24, .medium))
                .foregroundStyle(Color.floweInk)
            Text(event.startsAt.flowWeekdayShort.uppercased())
                .font(FloweFont.mono(8))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(width: width, height: height)
        .background(Color.flowWhite, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.floweBorder, lineWidth: 1)
        )
        .shadow(color: Color.flowePink.opacity(0.15), radius: 6, y: 2)
    }

    private var heroBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title)
                .font(FloweFont.serif(19, .medium))
                .foregroundStyle(Color.floweInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            organizerRow
            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 38 clears the medallion overhang (it drops 30pt below the band into this space).
        .padding(.horizontal, 16)
        .padding(.top, 38)
        .padding(.bottom, 14)
    }

    private var organizerRow: some View {
        HStack(spacing: 7) {
            AvatarView(
                id: data.organizerListing(for: event)?.img ?? "",
                photo: data.organizerPhoto(for: event),
                size: 22
            )
            Text({ let n = data.displayIdentity(ownerID: event.organizerID, fallbackName: event.organizerName).name
                   return n.isEmpty ? String(localized: "Someone") : n }())
                .font(FloweFont.sans(12, .medium))
                .foregroundStyle(Color.floweInk)
                .lineLimit(1)
            Text("ORGANIZER")
                .font(FloweFont.mono(9))
                .foregroundStyle(Color.floweMuted)
        }
    }

    private var metaRow: some View {
        // Separate Text runs joined by an explicit bullet, so the sequence reorders correctly under
        // RTL rather than being baked into one left-to-right string.
        HStack(spacing: 8) {
            Text(event.startsAt.flowTimeString)
            Text(verbatim: "·")
            Text("\(event.durationMinutes) min")
            if !event.location.isEmpty {
                Text(verbatim: "·")
                Text(event.location).lineLimit(1)
            }
        }
        .font(FloweFont.mono(10))
        .foregroundStyle(Color.floweMuted)
    }

    private var heroFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PER PERSON")
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                    Text(priceText)
                        .font(FloweFont.serif(22, .medium))
                        .foregroundStyle(isUnavailable ? Color.floweMuted : priceColor)
                }
                Spacer()
                statusCapsule
            }
            .padding(16)
        }
    }

    // MARK: - Compact (Dashboard)

    private var compactRow: some View {
        HStack(spacing: 12) {
            dateMedallion(compact: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(FloweFont.serif(16, .medium))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(event.startsAt.flowTimeString)
                    Text(verbatim: "·")
                    Text("\(event.durationMinutes) min")
                }
                .font(FloweFont.mono(10))
                .foregroundStyle(Color.floweMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statusCapsule
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .floweCard()
    }

    // MARK: - Price

    private var priceText: String {
        guard let price = event.price else { return "—" }   // not stated — never a fabricated 0
        return price == 0 ? String(localized: "Free") : settings.money(price)
    }

    private var priceColor: Color {
        event.price == nil ? .floweMuted : .floweInk
    }

    // MARK: - Status capsule

    @ViewBuilder
    private var statusCapsule: some View {
        switch event.status {
        case .open(let spotsLeft):
            if let spotsLeft {
                capsule(Text("^[\(spotsLeft) spot](inflect: true) left"),
                        fill: AnyShapeStyle(FlowGradients.gradDark), foreground: .white)
            } else {
                // Capacity stated but never counted: show the capacity itself, not a fabricated
                // "spots left" number on evidence never gathered.
                capsule(Text("^[\(event.capacity) spot](inflect: true)"),
                        fill: AnyShapeStyle(FlowGradients.gradDark), foreground: .white)
            }
        case .joined:
            // `.joined` only means "I hold a registration" — but under the request→approve model that
            // one flag spans three reader states. Only an ACCEPTED guest is actually going; a pending
            // request reads "Requested" and a declined one "Not accepted", so the card never
            // over-promises a spot the organizer hasn't granted. The detail rail draws the same line.
            switch data.requestState(for: event) {
            case .accepted:
                capsule(
                    Label { Text("Going") } icon: { Image(systemName: "checkmark") },
                    fill: AnyShapeStyle(Color.flowePink.opacity(0.12)),
                    foreground: .flowePinkDeep
                )
            case .declined:
                capsule(Text("Not accepted"),
                        fill: AnyShapeStyle(Color.floweMuted.opacity(0.12)), foreground: .floweMuted)
            case .requested, .notRequested:
                capsule(
                    Label { Text("Requested") } icon: { Image(systemName: "clock") },
                    fill: AnyShapeStyle(Color.flowePink.opacity(0.10)),
                    foreground: .flowePinkDeep
                )
            }
        case .full:
            capsule(Text("FULLY BOOKED"),
                    fill: AnyShapeStyle(Color.floweMuted.opacity(0.12)), foreground: .floweMuted)
        case .ended:
            capsule(Text("ENDED"),
                    fill: AnyShapeStyle(Color.floweMuted.opacity(0.12)), foreground: .floweMuted)
        case .cancelled:
            capsule(Text("CANCELLED"),
                    fill: AnyShapeStyle(Color.floweCancel.opacity(0.12)), foreground: .floweCancel)
        }
    }

    private func capsule<Content: View>(_ content: Content,
                                        fill: AnyShapeStyle,
                                        foreground: Color) -> some View {
        content
            .font(FloweFont.mono(10))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(fill, in: Capsule())
    }
}

/// A gentler press than `PrimaryButton`'s 0.96 — a full-width card scaling 4% reads as cheap.
private struct EventCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
