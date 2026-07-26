import Foundation

// MARK: - Quiz vocabulary
//
// These value types back the student onboarding quiz and the MatchEngine. They are the single
// source of truth other files reference; keep them self-contained. `StudentPreferences` is the only
// PERSISTED type (UserDefaults, via AppSession's Codable pattern), so it — and everything it stores —
// is `Codable`. `Instructor` and `ResolvedLessonType` referenced below are defined elsewhere in the
// same module, so no extra import is needed.

/// A focus discipline the student wants. Raw values are the EXACT strings the catalog stores in
/// `Instructor.specialties` and that `FloweConstants.discoverCategories` uses (case-sensitive), so a
/// preference matches an instructor by plain membership — no mapping table. Named `FocusDiscipline`
/// to AVOID colliding with the existing `Discipline` enum in DisciplineTag.swift (which has a
/// different, smaller case set: .mat/.reformer/.barre/.prenatal).
enum FocusDiscipline: String, Codable, CaseIterable, Identifiable, Hashable {
    case mat = "Mat"
    case reformer = "Reformer"
    case barre = "Barre"
    case tower = "Tower"
    case prenatal = "Prenatal"
    case rehab = "Rehab"

    var id: String { rawValue }
    /// Chip label. Same as the catalog string today, but decoupled so copy can change without
    /// touching the value stored in / matched against `Instructor.specialties`.
    var label: String { rawValue }
}

/// Why the student is here. INFORMATIONAL ONLY — there is no instructor field to match a goal
/// against, so goals are persisted and echoed back in the recap but never scored (must not fabricate
/// a match signal). Typed vocabulary so quiz + any future analytics agree.
enum StudentGoal: String, Codable, CaseIterable, Identifiable, Hashable {
    case strength
    case flexibility
    case posture
    case recovery
    case prenatal
    case stressRelief
    case generalFitness

    var id: String { rawValue }
    var label: String {
        switch self {
        case .strength: return "Build strength"
        case .flexibility: return "Flexibility"
        case .posture: return "Posture"
        case .recovery: return "Recovery & rehab"
        case .prenatal: return "Prenatal"
        case .stressRelief: return "Stress relief"
        case .generalFitness: return "General fitness"
        }
    }
}

/// Self-declared experience. INFORMATIONAL ONLY (no reliable instructor field to match against —
/// `yearsExp` describes the teacher, not the student), persisted and shown in the recap.
enum ExperienceLevel: String, Codable, CaseIterable, Identifiable, Hashable {
    case beginner
    case intermediate
    case advanced

    var id: String { rawValue }
    var label: String {
        switch self {
        case .beginner: return "New to Pilates"
        case .intermediate: return "Some experience"
        case .advanced: return "Advanced"
        }
    }
}

/// How a lesson is delivered. There is NO typed format field on a listing; format is inferred from
/// `ResolvedLessonType.capacity` (1 = one-on-one, ≥2 = small group, 0 = not stated). This is a
/// HEURISTIC signal, used both as the student's single preference (nil = no preference) and, as a
/// `Set`, as an instructor's offered formats.
enum SessionFormat: String, Codable, CaseIterable, Identifiable, Hashable {
    case privateOneOnOne
    case smallGroup

    var id: String { rawValue }
    var label: String {
        switch self {
        case .privateOneOnOne: return "Private (1-on-1)"
        case .smallGroup: return "Small group"
        }
    }
}

/// The persisted result of the onboarding quiz. Encoded to UserDefaults by AppSession, keyed by
/// `ownerID` (mirrors the durable-profile pattern), so it survives logout and is restored on
/// re-sign-in for the same account.
struct StudentPreferences: Codable, Equatable {
    /// Informational only (not scored).
    var goals: [StudentGoal]
    /// PRIMARY match dimension. Raw specialty strings (see `FocusDiscipline.rawValue`), matched
    /// against `Instructor.specialties` by exact membership.
    var disciplines: [String]
    /// Informational only (not scored).
    var experience: ExperienceLevel?
    /// nil == "no preference".
    var format: SessionFormat?
    /// Upper per-session rate the student will pay, in ILS whole units (same unit as
    /// `Instructor.price`). nil == "no limit".
    var maxBudget: Int?
    /// Distance cap in METRES. nil == "any distance". Only affects scoring when both a device
    /// location fix and instructor coordinates exist.
    var maxDistanceMetres: Double?
    /// Set when the quiz is finished OR explicitly skipped. Presence == "has onboarded".
    var completedAt: Date?
    /// Schema version for forward migration.
    var version: Int

    static let currentVersion = 1

    init(goals: [StudentGoal] = [],
         disciplines: [String] = [],
         experience: ExperienceLevel? = nil,
         format: SessionFormat? = nil,
         maxBudget: Int? = nil,
         maxDistanceMetres: Double? = nil,
         completedAt: Date? = nil,
         version: Int = StudentPreferences.currentVersion) {
        self.goals = goals
        self.disciplines = disciplines
        self.experience = experience
        self.format = format
        self.maxBudget = maxBudget
        self.maxDistanceMetres = maxDistanceMetres
        self.completedAt = completedAt
        self.version = version
    }

    /// Selected disciplines as typed cases (defensively drops any unknown raw string).
    var focusDisciplines: [FocusDiscipline] {
        disciplines.compactMap(FocusDiscipline.init(rawValue:))
    }

    var hasOnboarded: Bool { completedAt != nil }
}

// MARK: - Match output

/// One scored dimension, exposed for an optional breakdown/debug view.
enum MatchDimension: String, Codable, CaseIterable {
    case disciplines
    case budget
    case format
    case rating
    case distance
}

/// A single dimension's contribution. `weight` is the BASE weight (before renormalization over
/// active dimensions); `isActive` is false when the student expressed no preference for it (or the
/// datum was unavailable), in which case it is excluded from the renormalized total.
struct ScoredComponent: Equatable {
    let dimension: MatchDimension
    let weight: Double
    let rawScore: Double   // 0...1
    let isActive: Bool
}

/// The result of scoring one instructor against a student's preferences. Carries the instructor by
/// REFERENCE (it is a SwiftData `@Model`, resolved in-module) so the Discover UI can render it
/// directly. Transient — never persisted, so it deliberately is NOT Codable.
struct MatchResult: Identifiable {
    let instructor: Instructor
    let matchPercent: Int          // 0...100
    let components: [ScoredComponent]

    var id: Int { instructor.legacyId }
}
