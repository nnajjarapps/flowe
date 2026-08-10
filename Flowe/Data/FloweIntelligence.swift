import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence for Flowe via Apple's **FoundationModels** framework (iOS 26+).
/// Offline, free, private — the model never transmits a byte, which is exactly Flowe's posture
/// ([[Privacy-Model]]). Everything here is a *progressive enhancement*: it degrades cleanly to the
/// app's normal non-AI path off iOS 26, on ineligible devices, or in unsupported languages.
///
/// ⚠️ **Hebrew & Arabic are NOT supported on-device** (verified 2026-08-05) — so for Flowe's
/// Israel-first market this reaches only English-speaking users. `isAvailable` enforces that.
/// See [[FloweIntelligence]].
enum FloweAI {
    /// Whether the on-device model can be used **right now**. Safe on every OS version (false below
    /// iOS 26). Drives the visibility of every ✨ affordance — when false, the app just shows its
    /// normal controls, no broken UI. `@MainActor` — every caller is a SwiftUI view.
    @MainActor
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return FloweIntelligence.shared.isAvailable }
        #endif
        return false
    }

    /// A **soft** second-pass moderation flag for public text — a short concern string, or nil when the
    /// text is fine, the model is unavailable, or it can't decide. NEVER the enforcing layer (the regex
    /// `ContentFilter` is, for everyone); this only surfaces a "post anyway / edit?" prompt for the
    /// English-on-device slice. Deliberately lenient — ordinary criticism must not trip it.
    @MainActor
    static func moderationConcern(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        if #available(iOS 26, *), isAvailable,
           let v = try? await FloweIntelligence.shared.moderate(trimmed), v.flagged {
            return v.reason.isEmpty ? String(localized: "This might not be right for a public post.") : v.reason
        }
        #endif
        return nil
    }
}

// MARK: - Pure helpers (unit-testable; no model, no actor)
//
// The deterministic glue around the model — mapping its (constrained) string outputs back onto Flowe's
// real types, and building the prompt digests. Extracted here so it can be exercised sim-free in
// FloweUnitTests without any on-device inference. See FloweUnitTests/IntelligenceLogicTests.
extension FloweAI {
    /// Resolve the model's category choice to a REAL Discover category (case-insensitive), else "All".
    /// The generation is only *asked* to pick from the list; this guarantees the filter is always valid.
    static func resolveCategory(_ choice: String, in categories: [String]) -> String {
        categories.first { $0.caseInsensitiveCompare(choice) == .orderedSame } ?? "All"
    }

    /// Map the model's constrained opportunity-kind keyword back to the enum (defaults to `.cover`).
    static func opportunityKind(from keyword: String) -> OpportunityKind {
        switch keyword.lowercased() {
        case "recurring":      return .recurring
        case "role":           return .role
        case "apprenticeship": return .apprenticeship
        case "space":          return .space
        default:               return .cover
        }
    }

    /// Map the model's eligibility keyword back to the enum (defaults to `.certifiedOnly` — the safer,
    /// more-restrictive side, so an ambiguous parse never accidentally opens a teaching role to students).
    static func opportunityEligibility(from keyword: String) -> OpportunityEligibility {
        keyword.caseInsensitiveCompare("openToAll") == .orderedSame ? .openToAll : .certifiedOnly
    }

    /// Compact natural-language digest of a student's quiz answers — the input to why-this-instructor.
    static func preferenceSummary(_ prefs: StudentPreferences) -> String {
        var parts: [String] = []
        if !prefs.disciplines.isEmpty { parts.append("wants \(prefs.disciplines.joined(separator: ", "))") }
        if !prefs.goals.isEmpty { parts.append("goals: " + prefs.goals.map(\.label).joined(separator: ", ")) }
        if let f = prefs.format { parts.append("prefers \(f.label)") }
        if let e = prefs.experience { parts.append(e.label) }
        return parts.joined(separator: "; ")
    }
}

#if canImport(FoundationModels)

/// Typed output for the "Draft my brand story" affordance (Flowe Pro Pillar B).
@available(iOS 26, *)
@Generable
struct BrandDraft {
    @Guide(description: "A punchy professional tagline for a Pilates instructor, under 8 words, title case, no emoji, no quotes.")
    var headline: String
    @Guide(description: "A warm first-person studio story of 2 to 3 sentences: teaching style and what a student can expect. No emoji, no phone numbers or emails.")
    var story: String
}

/// Typed verdict for the soft moderation second-pass over public text.
@available(iOS 26, *)
@Generable
struct ModerationVerdict {
    @Guide(description: "True ONLY if the text is clearly inappropriate for a public Pilates community: hate or harassment, sexual content, a scam, or soliciting off-platform contact/payment. Ordinary criticism or a fair negative review is NOT flagged.")
    var flagged: Bool
    @Guide(description: "A short, non-accusatory reason if flagged, else an empty string.")
    var reason: String
}

/// Typed output for "draft an opportunity from a note" (Flowe Pro marketplace). `kind`/`eligibility` are
/// constrained to real values via `.anyOf` so the model can't invent one; the caller maps them to enums.
@available(iOS 26, *)
@Generable
struct OpportunityDraft {
    @Guide(.anyOf(["cover", "recurring", "role", "apprenticeship", "space"]))
    var kind: String
    @Guide(.anyOf(["openToAll", "certifiedOnly"]))
    var eligibility: String
    @Guide(description: "A short, specific title for the opportunity, under 8 words. No emoji, no quotes.")
    var title: String
    @Guide(description: "One to three sentences describing the opportunity and who they're looking for. No emoji, no contact details.")
    var about: String
    @Guide(description: "Free-text pay if the note mentions it (e.g. '₪180 / class' or '60% split'), else an empty string.")
    var payText: String
    @Guide(description: "Free-text commitment/timing if the note mentions it (e.g. 'One-off · Thu 8:00' or 'Weekly · Sundays'), else an empty string.")
    var commitment: String
}

/// Typed output for natural-language Discover search — a free query mapped onto the existing filters.
@available(iOS 26, *)
@Generable
struct ParsedSearch {
    @Guide(description: "The single best-matching class category from the allowed list given in the instructions, or 'All' if none fits.")
    var category: String
    @Guide(description: "A place, area, city, or instructor name to search for — an empty string if none is mentioned.")
    var locationOrName: String
    @Guide(description: "True only when the user asks for results near them (nearby / close / near me).")
    var nearMe: Bool
}

/// Typed output for smart reply suggestions in a DM thread.
@available(iOS 26, *)
@Generable
struct ReplySuggestions {
    @Guide(description: "Three short, natural reply options the user could send next, each under 12 words, no emoji, no quotes.")
    var replies: [String]
}

/// Typed output for the "What students say" review digest.
@available(iOS 26, *)
@Generable
struct ReviewDigest {
    @Guide(description: "One warm, honest sentence under 15 words capturing the overall vibe students describe. No emoji.")
    var vibe: String
    @Guide(description: "Two or three short phrases (2 to 4 words each) for what students praise most, e.g. 'clear alignment cues'.")
    var praisedFor: [String]
}

/// The single on-device inference entry point. `@MainActor` (UI-triggered, matches the store);
/// each call spins a fresh `LanguageModelSession` — cheap, and keeps requests independent.
@available(iOS 26, *)
@MainActor
final class FloweIntelligence {
    static let shared = FloweIntelligence()
    private let model = SystemLanguageModel.default

    /// Device eligible + Apple Intelligence on + model downloaded + the user's language supported.
    var isAvailable: Bool {
        guard case .available = model.availability else { return false }
        return isCurrentLanguageSupported
    }

    /// English-only reach today: gate on the model actually supporting the language the UI is ACTUALLY
    /// showing, so a Hebrew/Arabic user never sees an AI affordance that would fail (and an English user
    /// on a Hebrew *device* isn't wrongly denied). Never hardcode the list — query `supportedLanguages`,
    /// which grows as Apple adds languages.
    private var isCurrentLanguageSupported: Bool {
        guard let code = Self.effectiveLanguageCode else { return false }
        return model.supportedLanguages.contains { $0.languageCode?.identifier == code }
    }

    /// The language Flowe is displaying: an explicit in-app override (`AppSettings.language`, persisted
    /// under `flowe.language`) wins over the device locale — mirroring how `AppSettings.locale` drives the
    /// UI — because that, not the device setting, is the language any AI output would be produced in.
    private static var effectiveLanguageCode: String? {
        if let raw = UserDefaults.standard.string(forKey: "flowe.language"),
           raw != "system", !raw.isEmpty {
            return Locale(identifier: raw).language.languageCode?.identifier ?? raw
        }
        return Locale.current.language.languageCode?.identifier
    }

    // MARK: - Brand story (Flowe Pro Pillar B)

    /// Draft a headline + studio story from the instructor's specialties and a few free-text notes.
    func draftBrandStory(name: String, specialties: [String], notes: String) async throws -> BrandDraft {
        let session = LanguageModelSession {
            """
            You write concise, warm marketing copy for a Pilates instructor's public profile.
            Be authentic and specific to what they teach — never generic hype. British/neutral English.
            Never include emoji, phone numbers, email addresses, or prices.
            """
        }
        let prompt = """
        Write a headline and a short studio story for a Pilates instructor.
        Name: \(name.isEmpty ? "the instructor" : name)
        Specialties: \(specialties.isEmpty ? "Pilates" : specialties.joined(separator: ", "))
        Their own notes: \(notes.isEmpty ? "(none)" : notes)
        """
        return try await session.respond(to: Prompt(prompt),
                                         generating: BrandDraft.self,
                                         includeSchemaInPrompt: false).content
    }

    // MARK: - Opportunity draft (Flowe Pro marketplace)

    /// Turn an instructor's short note ("sub my Thursday reformer, ₪180") into a structured opportunity
    /// post — kind, eligibility, title, about, and any pay/commitment mentioned. Guided generation; the
    /// caller maps `kind`/`eligibility` to enums and lets the instructor edit before posting.
    func draftOpportunity(from note: String) async throws -> OpportunityDraft {
        let session = LanguageModelSession {
            """
            You turn a Pilates instructor's short note into an opportunity post for the Flowe marketplace.
            Infer the kind — cover = one-off sub, recurring = standing weekly class, role = part/full-time
            position, apprenticeship = trainee/assistant, space = chair/studio/room rental — and the
            eligibility — openToAll when a student could do it (front-desk, assistant, apprentice), else
            certifiedOnly for teaching. Only fill pay/commitment if the note mentions them. Neutral
            English, no emoji, no contact details.
            """
        }
        return try await session.respond(to: Prompt("Note: \(note)"),
                                         generating: OpportunityDraft.self,
                                         includeSchemaInPrompt: false).content
    }

    // MARK: - Moderation assist (soft second pass)

    /// Classify whether public text is clearly inappropriate — the model behind `FloweAI.moderationConcern`.
    /// Deliberately lenient (see the instructions): a small model over-flags, and this is an assist, not the
    /// enforcing `ContentFilter`.
    func moderate(_ text: String) async throws -> ModerationVerdict {
        let session = LanguageModelSession {
            """
            You are a LENIENT content check for a Pilates community app. Flag text ONLY if it is clearly
            inappropriate for a public post or profile: hate or harassment, sexual content, scams, or
            soliciting off-platform contact or payment. Do NOT flag ordinary criticism, a fair negative
            review, or normal fitness talk. When unsure, do not flag.
            """
        }
        return try await session.respond(to: Prompt("Text: \(text)"),
                                         generating: ModerationVerdict.self,
                                         includeSchemaInPrompt: false).content
    }

    // MARK: - Why this instructor (Discover match rationale)

    /// One short sentence on why an instructor fits a student, grounded ONLY in the overlap between the
    /// student's stated preferences and the instructor's specialties (no invented credentials). Plain
    /// text; the caller shows it on the recommendation card.
    func whyThisInstructor(studentSummary: String, instructor: String, specialties: [String]) async throws -> String {
        let session = LanguageModelSession {
            """
            You explain in ONE short sentence (under 16 words) why a Pilates instructor is a good match for
            a student, based only on the overlap between the student's stated preferences and the
            instructor's specialties. Warm, specific, second person ("you"). No emoji. If there's little
            overlap, say something honest and general rather than overclaiming. Neutral English.
            """
        }
        let prompt = """
        Student: \(studentSummary)
        Instructor \(instructor) specialties: \(specialties.isEmpty ? "Pilates" : specialties.joined(separator: ", "))
        Why are they a good match for this student?
        """
        return try await session.respond(to: Prompt(prompt)).content
    }

    // MARK: - Natural-language Discover search

    /// Turn a free-text query ("reformer for lower back, evenings near me") into the Discover filters:
    /// a category picked from the REAL list (`categories`, injected so the model can only aim at a real
    /// one — the caller still validates), a place/name to search, and a near-me flag. Guided generation,
    /// so no parsing.
    func parseSearch(_ query: String, categories: [String]) async throws -> ParsedSearch {
        let session = LanguageModelSession {
            """
            You convert a student's free-text search for a Pilates instructor into filters.
            Pick the single best category from this exact list, or "All" if none fits:
            \(categories.joined(separator: ", ")).
            Extract any place, area, city, or instructor name to search for. Neutral English.
            """
        }
        return try await session.respond(to: Prompt("Search: \(query)"),
                                         generating: ParsedSearch.self,
                                         includeSchemaInPrompt: false).content
    }

    // MARK: - Smart replies (DMs)

    /// Suggest short replies the signed-in user could send next, from the recent thread. `recent` is
    /// ordered oldest→newest; `mine` marks the signed-in user's own messages. On-device, so the E2E-
    /// encrypted thread stays private — the plaintext never leaves the phone (see [[E2E-Messaging]]).
    func suggestReplies(recent: [(mine: Bool, text: String)]) async throws -> [String] {
        let transcript = recent.suffix(8)
            .map { "\($0.mine ? "Me" : "Them"): \($0.text)" }
            .joined(separator: "\n")
        let session = LanguageModelSession {
            """
            You suggest short, natural replies for a chat between a Pilates instructor and a student.
            Friendly and professional. Each reply is something the person labelled "Me" could send next.
            No emoji, neutral English.
            """
        }
        let prompt = "Conversation so far:\n\(transcript)\n\nSuggest replies for Me."
        return try await session.respond(to: Prompt(prompt),
                                         generating: ReplySuggestions.self,
                                         includeSchemaInPrompt: false).content.replies
    }

    // MARK: - Review-writing assist (student)

    /// Help a student write a short review, grounded in their star rating (so it stays honest — 2 stars
    /// reads constructive, 5 glowing) and any rough notes they jotted. Deliberately does NOT invent
    /// specific events — the rating anchors the sentiment, the student edits before posting.
    func draftReview(rating: Int, instructor: String, sessionType: String, notes: String) async throws -> String {
        let sentiment: String
        switch rating {
        case 1:  sentiment = "disappointed"
        case 2:  sentiment = "somewhat disappointed"
        case 3:  sentiment = "satisfied"
        case 4:  sentiment = "happy"
        default: sentiment = "very happy"
        }
        let session = LanguageModelSession {
            """
            You help a Pilates student write a short, honest, first-person review of a session that matches
            their star rating. 2 to 4 sentences. Do NOT invent specific events the student didn't mention —
            keep it general and genuine. No emoji, neutral English.
            """
        }
        let prompt = """
        Instructor: \(instructor)
        Session type: \(sessionType.isEmpty ? "Pilates" : sessionType)
        Star rating: \(rating) of 5 (\(sentiment))
        Student's rough notes: \(notes.isEmpty ? "(none)" : notes)
        Write the review.
        """
        return try await session.respond(to: Prompt(prompt)).content
    }

    // MARK: - Review digest ("What students say")

    /// Summarize real review text into a one-line vibe + a few praised-for themes. Caller passes only
    /// non-empty review bodies; we cap the count so the prompt stays within the small context window.
    func digestReviews(_ texts: [String]) async throws -> ReviewDigest {
        let sample = texts.filter { !$0.isEmpty }.prefix(20)
        let joined = sample.joined(separator: "\n- ")
        let session = LanguageModelSession {
            """
            You summarize students' written reviews of a Pilates instructor into a short, honest
            highlight for their profile. Only reflect what the reviews actually say — never invent
            praise. Neutral English, no emoji.
            """
        }
        let prompt = "Summarize these student reviews:\n- \(joined)"
        return try await session.respond(to: Prompt(prompt),
                                         generating: ReviewDigest.self,
                                         includeSchemaInPrompt: false).content
    }
}

#endif
