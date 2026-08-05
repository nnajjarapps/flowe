import SwiftUI
import UIKit

/// One instructor-authored lesson type, as a rich display card — the student-facing upgrade of the old
/// flat `flowePink.opacity(0.12)` capsule row. Shared by the OFFERS section on
/// `StudentInstructorProfileView` and, in a compacter guise, informs the booking type picker.
///
/// It renders a `ResolvedLessonType` (the flattened value the store hands out), so one component
/// degrades per-field: a fully authored type shows a photo band, details and a meta footer, while a
/// legacy name-only offer collapses to just the serif name — the same card, honest degradation, no
/// broken-looking placeholder for a photo that was never claimed.
///
/// Capacity here is DISPLAYED GROUP SIZE, a static descriptive attribute ("Up to 10" / "1-on-1") — never
/// a live "spots left / fully booked" gauge. A Flowe booking is a 1:1 request, not a shared instance a
/// type could fill, so a spots-remaining number would be state nobody counted. That is why there is no
/// `EventStatus`/`spotsLeft`/`attendees` analog and no coloured status capsule here.
struct LessonTypeCard: View {
    @Environment(AppSettings.self) private var settings

    let type: ResolvedLessonType
    /// The parent `ForEach` index, used only as the accessibility-id suffix for a name-only fallback
    /// (whose `legacyId` is 0 and would collide across several offers). An authored row uses its own
    /// `legacyId` instead — mirrors `event.card.<legacyId>`.
    var index: Int = 0

    private var identifierSuffix: Int { type.legacyId > 0 ? type.legacyId : index }

    var body: some View {
        VStack(spacing: 0) {
            photoBand
            cardBody
        }
        // Hand-rolled rather than `.floweCard()`: that modifier clips its whole content to the rounded
        // rectangle, which would slice the top corners of the photo band. Here the band clips its own
        // top corners (below) and the card just draws the border. Mirrors `EventCardView.heroCard`.
        .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.floweBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lessonType.card.\(identifierSuffix)")
    }

    // MARK: - Photo band

    /// Drawn ONLY when the type has (or claims) a photo. A genuinely photo-less type shows no band at
    /// all — a name-only card is a clean text card, not a gradient with a watermark implying a missing
    /// picture that was never promised.
    @ViewBuilder
    private var photoBand: some View {
        if type.hasPhoto {
            photoContent
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(topLeadingRadius: 20, topTrailingRadius: 20))
        }
    }

    /// Two states, reached only once `hasPhoto` is true: a decoded photo, or a photo known-to-exist but
    /// not yet fetched (a muted plate + spinner, so the row doesn't resize under the reader's thumb when
    /// the asset lands). Copied from `EventCardView.photoContent`.
    @ViewBuilder
    private var photoContent: some View {
        if let bytes = type.photo, let image = UIImage(data: bytes) {
            Color.clear.overlay {
                Image(uiImage: image).resizable().scaledToFill()
            }
        } else {
            FlowGradients.grad.opacity(0.25)
                .overlay { ProgressView().tint(Color.flowePinkDeep) }
        }
    }

    // MARK: - Body

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User text — shown verbatim, never localized.
            Text(type.name)
                .font(FloweFont.serif(18, .medium))
                .foregroundStyle(Color.floweInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !type.details.isEmpty {
                Text(type.details)
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let meta = metaText {
                meta
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Capacity · duration · price, built from separate `Text` runs joined by an explicit bullet so the
    /// sequence reorders correctly under RTL rather than being baked into one left-to-right string
    /// (the `EventCardView.metaRow` idiom). Each run appears only when its field is stated, and a
    /// name-only type yields nil — the footer simply doesn't render.
    private var metaText: Text? {
        var runs: [Text] = []

        // Displayed group size, never a live availability count. 0 == not stated → omitted.
        if type.capacity == 1 {
            runs.append(Text("1-on-1"))
        } else if type.capacity >= 2 {
            runs.append(Text("Up to ") + Text("^[\(type.capacity) spot](inflect: true)"))
        }

        if type.durationMinutes > 0 {
            runs.append(Text("\(type.durationMinutes) min"))
        }

        // nil == not stated (omitted); 0 == genuinely Free; n == money(n). Never a fabricated 0.
        if let price = type.price {
            runs.append(price == 0 ? Text("Free") : Text(settings.money(price)))
        }

        guard let first = runs.first else { return nil }
        return runs.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
    }
}
