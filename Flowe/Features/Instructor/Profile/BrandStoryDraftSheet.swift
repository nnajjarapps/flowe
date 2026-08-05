import SwiftUI

/// The "✨ On-device · Private" badge shown on every Flowe Intelligence touchpoint — the privacy story
/// made visible (the model never transmits a byte). Ungated: it's just a label. See [[FloweIntelligence]].
struct AIPrivacyBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 9))
            Text("On-device · Private").font(FloweFont.mono(8))
        }
        .foregroundStyle(Color.flowePinkDeep)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.flowePink.opacity(0.10), in: Capsule())
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// "Draft my brand story" (Flowe Pro Pillar B) — generates a headline + studio story **on-device** from
/// the instructor's specialties and a few notes, previews it, and hands the accepted copy back to
/// EditProfile to fill the fields. Presented only when `FloweAI.isAvailable`. See [[FloweIntelligence]].
@available(iOS 26, *)
struct BrandStoryDraftSheet: View {
    @Environment(\.dismiss) private var dismiss

    let name: String
    let specialties: [String]
    /// Called with the accepted (headline, story) — the caller fills its editor fields.
    let onApply: (String, String) -> Void

    @State private var notes = ""
    @State private var draft: BrandDraft?
    @State private var phase: Phase = .input
    private enum Phase { case input, generating, result, failed }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AIPrivacyBadge()
                    Text("A few words about your teaching is enough — I'll draft a headline and studio story. It all stays on your device.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("e.g. reformer, postnatal, calm and precise", text: $notes, axis: .vertical)
                        .font(FloweFont.sans(14))
                        .lineLimit(2...4)
                        .padding(12)
                        .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))

                    if phase == .generating {
                        HStack(spacing: 8) { ProgressView(); Text("Drafting on your device…").font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted) }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }

                    if let draft, phase == .result { resultCard(draft) }

                    if phase == .failed {
                        Text("Couldn't draft that one. Try a few different words.")
                            .font(FloweFont.sans(12))
                            .foregroundStyle(Color.floweCancel)
                    }
                }
                .padding(20)
                .padding(.bottom, 80)
            }
            .background(Color.flowWhite)
            .navigationTitle("Draft with AI")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.tint(Color.floweMuted) }
            }
        }
    }

    private func resultCard(_ d: BrandDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HEADLINE").font(FloweFont.mono(9)).foregroundStyle(Color.floweMuted)
            Text(d.headline).font(FloweFont.serif(17, .medium)).foregroundStyle(Color.floweInk)
            Divider()
            Text("MY STUDIO").font(FloweFont.mono(9)).foregroundStyle(Color.floweMuted)
            Text(d.story).font(FloweFont.sans(14)).foregroundStyle(Color.floweInk)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can edit it after — nothing's saved until you do.")
                .font(FloweFont.sans(11)).foregroundStyle(Color.floweMuted).padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floweCard(cornerRadius: 16)
    }

    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: 12) {
            if phase == .result, let draft {
                Button("Regenerate") { generate() }
                    .font(FloweFont.sans(15, .medium)).tint(Color.flowePinkDeep)
                Spacer()
                Button {
                    onApply(draft.headline, draft.story)
                    dismiss()
                } label: {
                    Text("Use this")
                        .font(FloweFont.sans(16, .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 16))
                }
            } else {
                Button { generate() } label: {
                    Text("Draft")
                        .font(FloweFont.sans(16, .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(phase == .generating || notes.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func generate() {
        phase = .generating
        Task {
            do {
                draft = try await FloweIntelligence.shared.draftBrandStory(name: name, specialties: specialties, notes: notes)
                phase = .result
            } catch {
                phase = .failed
            }
        }
    }
}
#endif
