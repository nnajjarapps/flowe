import Foundation
import SwiftData

/// A peer endorsement — one instructor recommending another. The "LinkedIn recommendation" of Flowe Pro
/// ([[FlowePro]]); students already endorse instructors via [[Review]], this is the instructor↔instructor
/// counterpart. Local cache of a **world-readable public record** (Reference config, like [[Opportunity]])
/// — no private mirror. Deterministic recordName `rec-<fromID>-<toID>` so a peer holds at most one
/// recommendation per colleague and re-writing it upserts rather than duplicates. Addressed to `toID`
/// (the recipient), whose profile queries it.
@Model
final class InstructorRecommendation {
    var fromID: String = ""      // author — the instructor writing the endorsement
    var fromName: String = ""    // denormalised so a row renders without a second lookup (like Review.studentName)
    var toID: String = ""        // recipient — the instructor being recommended (their profile's query key)
    var text: String = ""
    var createdAt: Date = Date.distantPast
    /// recordName in the public DB; nil until published.
    var remoteID: String?

    init(fromID: String = "", fromName: String = "", toID: String = "",
         text: String = "", createdAt: Date = Date()) {
        self.fromID = fromID
        self.fromName = fromName
        self.toID = toID
        self.text = text
        self.createdAt = createdAt
    }

    /// One recommendation per (author → recipient) pair — the deterministic name that makes re-writing an
    /// upsert. Publish and fetch both route through here.
    static func recordName(from fromID: String, to toID: String) -> String { "rec-\(fromID)-\(toID)" }
    var recordName: String { Self.recordName(from: fromID, to: toID) }

    var displayName: String { fromName.isEmpty ? String(localized: "An instructor") : fromName }

    /// "2D AGO" — mono meta styling, mirrors `Review.relativeTime`.
    var relativeTime: String {
        let seconds = Date().timeIntervalSince(createdAt)
        switch seconds {
        case ..<3600:    return "JUST NOW"
        case ..<86_400:  return "\(Int(seconds / 3600))H AGO"
        case ..<604_800: return "\(Int(seconds / 86_400))D AGO"
        default:         return "\(Int(seconds / 604_800))W AGO"
        }
    }
}
