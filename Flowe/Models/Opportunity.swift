import Foundation
import SwiftData

/// The kind of gig an `Opportunity` is — a spectrum from a one-off sub through a permanent role. The
/// `cover` kind IS the existing Out-of-Studio coverage ([[InstructorCoverage]]); the rest extend it.
enum OpportunityKind: Int, CaseIterable, Identifiable {
    case cover = 0          // one-off sub / cover for a single session
    case recurring = 1      // a standing weekly class slot
    case role = 2           // part- or full-time position
    case apprenticeship = 3 // trainee / assistant track
    case space = 4          // chair / studio / room rental

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .cover:          return String(localized: "Sub / cover")
        case .recurring:      return String(localized: "Recurring class")
        case .role:           return String(localized: "Role")
        case .apprenticeship: return String(localized: "Apprenticeship")
        case .space:          return String(localized: "Space")
        }
    }

    var icon: String {
        switch self {
        case .cover:          return "arrow.left.arrow.right"
        case .recurring:      return "repeat"
        case .role:           return "briefcase"
        case .apprenticeship: return "graduationcap"
        case .space:          return "building.2"
        }
    }
}

/// Who may apply — the gate that keeps a teaching gig to certified instructors while letting a
/// front-desk / assistant / apprentice role be open to students too.
enum OpportunityEligibility: Int {
    case openToAll = 0
    case certifiedOnly = 1
}

enum OpportunityStatus: Int {
    case open = 0
    case closed = 1
    case filled = 2
}

/// A posted opportunity in the Flowe Pro career marketplace (see [[FlowePro]]). Stored in the local
/// **Reference** configuration — like `Instructor`, it is an on-device cache of a world-readable public
/// record (fetched via a future `OpportunityService`), not private user data, so it never rides the
/// CloudKit private mirror. Mirrors the shape of [[CommunityEvent]].
@Model
final class Opportunity {
    /// Stable client id → deterministic public recordName (`opp-<localID>`), like `Message.localID`.
    var localID: UUID = UUID()
    /// recordName in the public database; nil until published.
    var remoteID: String?

    var posterID: String = ""       // ownerID of the studio/instructor who posted it
    var posterName: String = ""
    var kindRaw: Int = 0            // OpportunityKind
    var eligibilityRaw: Int = 0    // OpportunityEligibility
    var statusRaw: Int = 0         // OpportunityStatus

    var title: String = ""
    var about: String = ""
    var location: String = ""      // studio address text (already public)
    var latitude: Double?
    var longitude: Double?
    var payText: String = ""       // free-text comp, e.g. "₪120/class" or "60% split" — no structured money
    var commitment: String = ""    // free-text, e.g. "Weekly, Sun mornings"

    var startsAt: Date?            // optional, for a dated cover / recurring slot
    var createdAt: Date = Date.distantPast
    var order: Int = 0

    init(
        localID: UUID = UUID(),
        remoteID: String? = nil,
        posterID: String = "",
        posterName: String = "",
        kind: OpportunityKind = .cover,
        eligibility: OpportunityEligibility = .openToAll,
        status: OpportunityStatus = .open,
        title: String = "",
        about: String = "",
        location: String = "",
        payText: String = "",
        commitment: String = "",
        startsAt: Date? = nil,
        createdAt: Date = Date(),
        order: Int = 0
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.posterID = posterID
        self.posterName = posterName
        self.kindRaw = kind.rawValue
        self.eligibilityRaw = eligibility.rawValue
        self.statusRaw = status.rawValue
        self.title = title
        self.about = about
        self.location = location
        self.payText = payText
        self.commitment = commitment
        self.startsAt = startsAt
        self.createdAt = createdAt
        self.order = order
    }

    var kind: OpportunityKind { OpportunityKind(rawValue: kindRaw) ?? .cover }
    var eligibility: OpportunityEligibility { OpportunityEligibility(rawValue: eligibilityRaw) ?? .openToAll }
    var status: OpportunityStatus { OpportunityStatus(rawValue: statusRaw) ?? .open }

    /// The deterministic public recordName this opportunity publishes under.
    var recordName: String { "opp-\(localID.uuidString)" }

    /// The stable key other records (applications, decisions) reference this opportunity by — its
    /// published recordName if it has one, else the deterministic name.
    var key: String { remoteID ?? recordName }
}

/// Whether an applicant is applying as a student or an instructor — shown to the poster so they can
/// tell a certified applicant from a student (matters most for `certifiedOnly` posts).
enum ApplicantRole: Int {
    case student = 0
    case instructor = 1
}

/// The recruiting-pipeline stage of one application (Flowe Pro Phase 4). The poster advances it; the
/// applicant sees where they stand.
enum ApplicationStage: Int, CaseIterable {
    case applied = 0
    case shortlisted = 1
    case talking = 2
    case offer = 3
    case hired = 4
    case declined = 5

    var label: String {
        switch self {
        case .applied:     return String(localized: "Applied")
        case .shortlisted: return String(localized: "Shortlisted")
        case .talking:     return String(localized: "Talking")
        case .offer:       return String(localized: "Offer")
        case .hired:       return String(localized: "Hired")
        case .declined:    return String(localized: "Not selected")
        }
    }
}

/// An application to an `Opportunity` — the applicant's expression of interest, addressed to the poster.
/// Local cache of a world-readable public record (Reference config, like `Opportunity`); deterministic
/// recordName `oppapp-<opportunityKey>-<applicantID>` so applying is idempotent (apply-once). The POST is
/// public but this reveals the applicant's identity — same pilot deanon posture as coverage claims. See
/// [[FlowePro]].
@Model
final class OpportunityApplication {
    var opportunityID: String = ""   // the opportunity's `key`
    var posterID: String = ""        // recipient — the poster's inbox query
    var applicantID: String = ""
    var applicantName: String = ""
    var applicantRoleRaw: Int = 1
    var note: String = ""            // the applicant's short pitch
    var withdrawn: Bool = false
    var createdAt: Date = Date.distantPast
    var remoteID: String?
    /// A local note/withdraw edit hasn't been confirmed uploaded yet. LOCAL-ONLY (not published). While
    /// true, a background `syncOpportunities` must NOT overwrite `note`/`withdrawn` from the server — a
    /// query-index lag would otherwise revert a just-made withdrawal (the "withdraw not working" bug).
    var pendingUpload: Bool = false

    init(opportunityID: String = "", posterID: String = "",
         applicantID: String = "", applicantName: String = "",
         role: ApplicantRole = .instructor, note: String = "",
         withdrawn: Bool = false, createdAt: Date = Date()) {
        self.opportunityID = opportunityID
        self.posterID = posterID
        self.applicantID = applicantID
        self.applicantName = applicantName
        self.applicantRoleRaw = role.rawValue
        self.note = note
        self.withdrawn = withdrawn
        self.createdAt = createdAt
    }

    var role: ApplicantRole { ApplicantRole(rawValue: applicantRoleRaw) ?? .instructor }
    var recordName: String { "oppapp-\(opportunityID)-\(applicantID)" }
}

/// The POSTER's decision on one application — the other half of the request→decision split (the
/// application is applicant-creator-owned, so the poster can't edit it; they write this separate record
/// instead, mirroring `SessionDecision`/`EventDecision`). Local cache of a world-readable public record,
/// deterministic recordName `oppdec-<oppKey>-<applicantID>` so it UPSERTS as the stage advances. See
/// [[FlowePro]].
@Model
final class ApplicationDecision {
    var opportunityID: String = ""
    var applicantID: String = ""     // recipient — the applicant this decision is news for
    var posterID: String = ""
    var stageRaw: Int = 0
    var updatedAt: Date = Date.distantPast
    var remoteID: String?

    init(opportunityID: String = "", applicantID: String = "", posterID: String = "",
         stage: ApplicationStage = .applied, updatedAt: Date = Date()) {
        self.opportunityID = opportunityID
        self.applicantID = applicantID
        self.posterID = posterID
        self.stageRaw = stage.rawValue
        self.updatedAt = updatedAt
    }

    var stage: ApplicationStage { ApplicationStage(rawValue: stageRaw) ?? .applied }
    var recordName: String { "oppdec-\(opportunityID)-\(applicantID)" }
}
