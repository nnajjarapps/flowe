import Foundation

// MARK: - MatchEngine
//
// The pure, deterministic scoring engine behind the student's "Recommended for you" feed. It scores
// an `Instructor` against a `StudentPreferences` across five weighted dimensions, renormalizes over
// only the dimensions the student actually answered (so a skipped question never drags the result
// down), and ranks a set of instructors with a fully deterministic tie-break chain.
//
// PURITY: no stored state, no IO, no SwiftData/LocationService imports. The two environment-derived
// inputs — an instructor's offered session formats (from lesson-type capacities) and its distance in
// metres (from LocationService) — arrive as plain values / closures, so given the same instructors +
// preferences + closure outputs the engine always returns the same results. This keeps it trivially
// unit-testable.
enum MatchEngine {

    // MARK: Base weights (sum = 100)
    //
    // These are the weights BEFORE active-dimension renormalization. `rating` is always active, which
    // guarantees the active-weight divisor is never 0.
    private enum Weight {
        static let disciplines: Double = 40
        static let budget: Double = 25
        static let format: Double = 15
        static let rating: Double = 10
        static let distance: Double = 10
    }

    // MARK: - Scoring

    /// Scores one instructor against the student's preferences.
    /// - Parameters:
    ///   - instructor: the listing being scored (carried by reference into the `MatchResult`).
    ///   - preferences: the student's persisted quiz answers.
    ///   - formats: the set of `SessionFormat`s this instructor offers, derived by the caller from
    ///     `ResolvedLessonType.capacity` (1 -> .privateOneOnOne, >=2 -> .smallGroup, 0 -> nothing).
    ///   - distanceMetres: on-device distance to the instructor, or nil when either the device fix or
    ///     the instructor's coordinates are missing (never a penalty — the dimension goes inactive).
    static func score(_ instructor: Instructor,
                      against preferences: StudentPreferences,
                      formats: Set<SessionFormat>,
                      distanceMetres: Double?) -> MatchResult {

        var components: [ScoredComponent] = []

        // 1) Disciplines. Active iff the student picked at least one style. Score = fraction of the
        //    requested styles the instructor lists (exact, case-sensitive membership — identical to
        //    DiscoverView's `specialties.contains`). Full coverage = 1.0, partial pro-rated.
        do {
            let requested = preferences.disciplines
            let isActive = !requested.isEmpty
            let raw: Double
            if isActive {
                let instructorSpecialties = Set(instructor.specialties)
                let overlap = requested.reduce(into: 0) { count, wanted in
                    if instructorSpecialties.contains(wanted) { count += 1 }
                }
                raw = Double(overlap) / Double(requested.count)
            } else {
                raw = 0
            }
            components.append(ScoredComponent(dimension: .disciplines,
                                              weight: Weight.disciplines,
                                              rawScore: raw,
                                              isActive: isActive))
        }

        // 2) Budget. Active iff the student set a cap. At or under budget scores 1.0; over budget it
        //    decays linearly, reaching 0 once the price hits twice the budget.
        do {
            let isActive = preferences.maxBudget != nil
            let raw: Double
            if let budget = preferences.maxBudget, budget > 0 {
                let price = instructor.price
                if price <= budget {
                    raw = 1.0
                } else {
                    raw = max(0.0, 1.0 - Double(price - budget) / Double(budget))
                }
            } else {
                raw = 0
            }
            components.append(ScoredComponent(dimension: .budget,
                                              weight: Weight.budget,
                                              rawScore: raw,
                                              isActive: isActive))
        }

        // 3) Format. Active iff the student expressed a format preference. A match scores 1.0; unknown
        //    capacity (no formats derivable) scores 0.5 so we don't punish missing data; offering only
        //    the other format scores 0.0.
        do {
            let isActive = preferences.format != nil
            let raw: Double
            if let wanted = preferences.format {
                if formats.contains(wanted) {
                    raw = 1.0
                } else if formats.isEmpty {
                    raw = 0.5
                } else {
                    raw = 0.0
                }
            } else {
                raw = 0
            }
            components.append(ScoredComponent(dimension: .format,
                                              weight: Weight.format,
                                              rawScore: raw,
                                              isActive: isActive))
        }

        // 4) Rating. ALWAYS active — the quality baseline that keeps the active-weight sum non-zero.
        //    A 0...5 rating is clamped then normalized to 0...1 (4.5 -> 0.9).
        do {
            let clamped = min(max(instructor.rating, 0.0), 5.0)
            components.append(ScoredComponent(dimension: .rating,
                                              weight: Weight.rating,
                                              rawScore: clamped / 5.0,
                                              isActive: true))
        }

        // 5) Distance. Active only when the student set a cap AND a real distance is available. Within
        //    the cap: 1.0 at the door decaying to 0.5 at the cap (nearer ranks higher); beyond the cap:
        //    0.0. No cap or no distance -> inactive (never a penalty).
        do {
            let isActive = preferences.maxDistanceMetres != nil && distanceMetres != nil
            let raw: Double
            if let cap = preferences.maxDistanceMetres, let d = distanceMetres, cap > 0 {
                raw = d <= cap ? (1.0 - 0.5 * (d / cap)) : 0.0
            } else {
                raw = 0
            }
            components.append(ScoredComponent(dimension: .distance,
                                              weight: Weight.distance,
                                              rawScore: raw,
                                              isActive: isActive))
        }

        // Renormalize over active dimensions only, so the result is a true 0-100 regardless of which
        // questions were answered. `rating` guarantees activeWeightSum >= 10 (never a divide-by-zero).
        let activeWeightSum = components
            .filter(\.isActive)
            .reduce(0.0) { $0 + $1.weight }
        let weightedScore = components
            .filter(\.isActive)
            .reduce(0.0) { $0 + $1.weight * $1.rawScore }

        let normalized = activeWeightSum > 0 ? weightedScore / activeWeightSum : 0.0
        let percent = min(max(Int((normalized * 100.0).rounded()), 0), 100)

        return MatchResult(instructor: instructor,
                           matchPercent: percent,
                           components: components)
    }

    // MARK: - Ranking

    /// Scores every instructor and returns results in descending match order.
    ///
    /// Ties are broken deterministically, in order: `matchPercent` desc, `visibilityRaw` desc (honor
    /// paid Boost placement, same economics as the feed), `rating` desc, `reviews` desc, `order` asc,
    /// then `legacyId` asc as the final total-order key. This yields a stable, reproducible ordering
    /// for any fixed input set.
    static func rank(_ instructors: [Instructor],
                     against preferences: StudentPreferences,
                     formats: (Instructor) -> Set<SessionFormat>,
                     distance: (Instructor) -> Double?) -> [MatchResult] {

        let results = instructors.map { instructor in
            score(instructor,
                  against: preferences,
                  formats: formats(instructor),
                  distanceMetres: distance(instructor))
        }

        return results.sorted { lhs, rhs in
            if lhs.matchPercent != rhs.matchPercent {
                return lhs.matchPercent > rhs.matchPercent
            }
            let a = lhs.instructor
            let b = rhs.instructor
            if a.visibilityRaw != b.visibilityRaw { return a.visibilityRaw > b.visibilityRaw }
            if a.rating != b.rating { return a.rating > b.rating }
            if a.reviews != b.reviews { return a.reviews > b.reviews }
            if a.order != b.order { return a.order < b.order }
            return a.legacyId < b.legacyId
        }
    }
}
