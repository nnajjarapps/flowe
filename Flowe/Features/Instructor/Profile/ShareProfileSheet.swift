import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// "Share my profile" — surfaces the instructor's Universal Link so a student can be handed
/// straight into `StudentInstructorProfileView` (and its `BookingSheet`) by tapping it.
///
/// The link is `https://nnajjarapps.github.io/flowe-support/i/<ownerID>`. The `ownerID` is already
/// the public recordName of the instructor's catalog listing (see `CatalogService`), so there is no
/// slug table and nothing to publish here — the sheet only shows the instructor their own link.
/// Everything is generated on-device: the QR is CoreImage, there is no network hop.
struct ShareProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    @Environment(SubscriptionService.self) private var subscription
    @Environment(MockDataStore.self) private var data

    @State private var didCopy = false
    /// The rendered branded story card (Flowe Pro 2c-ii). Rendered once via `ImageRenderer` when the
    /// sheet appears, then both previewed and shared as an image.
    @State private var storyImage: UIImage?

    private var shareURL: URL? {
        URL(string: "https://nnajjarapps.github.io/flowe-support/i/\(session.ownerID)")
    }

    var body: some View {
        NavigationStack {
            Group {
                // `localOwnerID` only surfaces in UI-test launches that skip Sign in with Apple — a
                // real session always carries an Apple id. There is no link to share without one.
                if session.ownerID == FloweConstants.localOwnerID {
                    placeholder(
                        "Sign in to share",
                        detail: "Sign in with Apple to get a shareable profile link."
                    )
                } else if let shareURL {
                    content(for: shareURL)
                } else {
                    placeholder("Link unavailable", detail: "Couldn't build your profile link.")
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle("Share Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Color.flowePinkDeep)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Content

    private func content(for url: URL) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                brandCardSection(url: url)

                SectionHeader(text: "SCAN OR SHARE")
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Dark-on-white QR for scannability — the pink accents live on the card, never on
                // the code itself.
                VStack(spacing: 16) {
                    if let image = Self.qr(from: url.absoluteString) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240)
                            .padding(16)
                            .background(Color.flowWhite)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Text(verbatim: url.absoluteString)
                        .font(FloweFont.mono(13))
                        .foregroundStyle(Color.floweInk)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .floweCard()

                // A hidden listing has no catalog record yet, so its link resolves to nothing. The
                // Share entry point is already gated on visibility, but say so here too in case the
                // sheet is reached with a lapsed subscription.
                if !subscription.isVisible {
                    Text("Your profile isn't published yet, so this link won't open for students until you're discoverable.")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                VStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        withAnimation { didCopy = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { didCopy = false }
                        }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Link",
                              systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(FloweFont.sans(14, .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.floweBorder, lineWidth: 1)
                            )
                    }
                    .tint(Color.flowePinkDeep)

                    ShareLink(item: url) {
                        Text("Share…")
                            .font(FloweFont.sans(15, .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(FlowGradients.gradDark)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Branded story card (Flowe Pro 2c-ii)

    /// A shareable, Instagram-story-shaped card built from the instructor's brand identity (cover,
    /// brand color, name, headline, credentials) with the profile QR baked in. Rendered to an image so
    /// it can be posted to a story; students scan/tap through to book. Reuses existing fields — no
    /// schema change. See [[FlowePro]].
    @ViewBuilder
    private func brandCardSection(url: URL) -> some View {
        VStack(spacing: 12) {
            SectionHeader(text: "YOUR STORY CARD")
                .frame(maxWidth: .infinity, alignment: .leading)

            if let storyImage {
                Image(uiImage: storyImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: Color.flowePink.opacity(0.25), radius: 12, y: 5)

                ShareLink(
                    item: Image(uiImage: storyImage),
                    preview: SharePreview("My Flowe card", image: Image(uiImage: storyImage))
                ) {
                    Label("Share as story", systemImage: "square.and.arrow.up")
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(FlowGradients.gradDark)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                Text("Post it to your story — students tap through to book you.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.floweCardBg)
                    .frame(height: 460)
                    .overlay(ProgressView().tint(Color.flowePinkDeep))
            }
        }
        .task { renderStoryCard(url: url) }
    }

    /// Render the branded card to a UIImage once, off the live `Instructor`. `ImageRenderer` renders
    /// WITHOUT the app environment, so `BrandStoryCard` takes everything by value.
    @MainActor
    private func renderStoryCard(url: URL) {
        guard storyImage == nil, let me = data.currentInstructor else { return }
        let renderer = ImageRenderer(content: BrandStoryCard(instructor: me, qr: Self.qr(from: url.absoluteString)))
        renderer.scale = 3   // 360×640 base → 1080×1920, a crisp story image
        storyImage = renderer.uiImage
    }

    private func placeholder(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 40))
                .foregroundStyle(Color.floweMuted)
            Text(title)
                .font(FloweFont.serif(20, .medium))
                .foregroundStyle(Color.floweInk)
            Text(detail)
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - On-device QR

    private static let ciContext = CIContext()

    /// Encode `string` as a QR and upscale it: `CIQRCodeGenerator` emits a ~25pt image, so without
    /// the transform + nearest-neighbour interpolation on display the code would be a blurry,
    /// often-unscannable smudge. Rendered CIImage → CGImage → UIImage so the pixels are exact.
    private static func qr(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Branded story card

/// The instructor's brand identity as a fixed-size (360×640, 9:16) card, rendered to an image and
/// shared to Instagram/Stories. Everything is passed by value — `ImageRenderer` renders it detached
/// from the app environment. Cover photo (or a brand-color gradient) as the backdrop, brand-tinted
/// accents, name + headline + credentials, a "Book me on Flowe" CTA and the profile QR to scan.
private struct BrandStoryCard: View {
    let instructor: Instructor
    let qr: UIImage?

    private var tint: Color { Color(hexString: instructor.brandColor) ?? Color.flowePinkDeep }

    var body: some View {
        ZStack {
            backdrop
            // Legibility scrim under the text.
            LinearGradient(colors: [.clear, .clear, Color.floweInk.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("FLOWE").font(FloweFont.serif(20, .medium)).foregroundStyle(.white)
                    Spacer()
                    Text("PILATES").font(FloweFont.mono(10)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                bottomContent
            }
            .padding(24)
        }
        .frame(width: 360, height: 640)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    @ViewBuilder
    private var backdrop: some View {
        if let cover = instructor.coverPhoto, let ui = UIImage(data: cover) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var bottomContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            avatar
            Text(instructor.name)
                .font(FloweFont.serif(32, .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            if !instructor.headline.isEmpty {
                Text(instructor.headline)
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            credentials
            HStack(alignment: .bottom) {
                Text("Book me on Flowe")
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(tint, in: Capsule())
                Spacer(minLength: 8)
                if let qr {
                    Image(uiImage: qr)
                        .interpolation(.none).resizable().scaledToFit()
                        .frame(width: 62, height: 62)
                        .padding(6)
                        .background(Color.flowWhite)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.top, 6)
        }
    }

    /// Inline avatar (photo or a brand-tinted monogram) — avoids `AvatarView`'s environment reads,
    /// which `ImageRenderer` wouldn't satisfy.
    @ViewBuilder
    private var avatar: some View {
        if let photo = instructor.photo, let ui = UIImage(data: photo) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: 60, height: 60).clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 2))
        } else {
            Circle().fill(tint).frame(width: 60, height: 60)
                .overlay(Text(instructor.firstName.prefix(1))
                    .font(FloweFont.serif(26, .medium)).foregroundStyle(.white))
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 2))
        }
    }

    @ViewBuilder
    private var credentials: some View {
        HStack(spacing: 8) {
            if instructor.rating > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(tint)
                    Text(String(format: "%.1f", instructor.rating))
                        .font(FloweFont.sans(13, .medium)).foregroundStyle(.white)
                    if instructor.reviews > 0 {
                        Text("· ^[\(instructor.reviews) review](inflect: true)")
                            .font(FloweFont.sans(12)).foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            ForEach(instructor.specialties.prefix(2), id: \.self) { s in
                Text(s)
                    .font(FloweFont.mono(9)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(tint.opacity(0.45), in: Capsule())
            }
        }
    }
}
