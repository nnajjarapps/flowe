import Foundation

/// Outcome of publishing a review — distinguishes a definitive rejection (don't retry) from a
/// transient failure (retry), so a review the backend refuses isn't queued forever.
enum ReviewSubmitResult {
    case published(String)   // the review id
    case notEarned           // 403 — no completed booking with this instructor; do NOT retry
    case failed              // transient (offline / not authenticated) — retry later
}

/// A review as it exists in the backend (plain DTO decoded from JSON).
struct RemoteReview {
    let id: String
    let bookingID: String
    let instructorID: String
    /// Empty on the PUBLIC read (the backend strips the reviewer's ownerID); the author's own fetch
    /// carries it. Display falls back to `studentName` when empty.
    let studentID: String
    let studentName: String
    let rating: Int
    let text: String
    let createdAt: Date

    init(id: String, bookingID: String, instructorID: String, studentID: String,
         studentName: String, rating: Int, text: String, createdAt: Date) {
        self.id = id
        self.bookingID = bookingID
        self.instructorID = instructorID
        self.studentID = studentID
        self.studentName = studentName
        self.rating = rating
        self.text = text
        self.createdAt = createdAt
    }
}

/// Session reviews. Moved behind the authz backend — was world-readable `SessionReview`, whose QUERYABLE
/// `studentID` let anyone pull a person's whole review history (each row proof of a completed session) or
/// an instructor's named client roster. Reviews stay PUBLIC and named (first name, by design): the public
/// read is served **per-instructor with the reviewer's stable ownerID STRIPPED**, and there is NO
/// by-student query — so the enumeration/re-linking leak is closed while the profile wall (guests
/// included) still renders. Writing is authorized + EARNED (the backend verifies a real booking with that
/// instructor — impossible to enforce on CloudKit). See [[BookingBackend]] / flowe-booking-privacy-deferred.
@MainActor
final class ReviewService {
    /// Legacy CloudKit constants, kept for the AccountDeletionService one-time sweep of pre-cutover records.
    static let recordType = "SessionReview"
    static let recipientField = "instructorID"
    static func recordName(for bookingID: String) -> String { "review-\(bookingID)" }

    private let backend = FloweBackendClient.shared

    /// Publish (or update) the review for a booking. The backend files it under the verified caller and
    /// enforces earned-ness; `studentID`/`createdAt` are advisory. Returns the id, or nil if it didn't land.
    func submit(bookingID: String,
                instructorID: String,
                studentID: String,
                studentName: String,
                rating: Int,
                text: String,
                createdAt: Date) async -> ReviewSubmitResult {
        struct Body: Encodable {
            let bookingID: String
            let instructorID: String
            let studentName: String
            let rating: Int
            let text: String
        }
        let body = Body(bookingID: bookingID, instructorID: instructorID, studentName: studentName, rating: rating, text: text)
        do {
            let data = try await backend.authorized("/reviews", method: "POST", body: body, interactive: true)
            struct Resp: Decodable { let id: String }
            return .published(try JSONDecoder().decode(Resp.self, from: data).id)
        } catch BackendError.http(403) {
            return .notEarned   // no completed booking — a definitive rejection, not a transient error
        } catch {
            return .failed      // offline / not authenticated — retry later
        }
    }

    /// Every review about an instructor — the PUBLIC profile wall (guests included, so this uses the
    /// UNAUTHENTICATED read). The reviewer's studentID is not returned (stripped server-side).
    func fetchForInstructor(ownerID: String) async -> [RemoteReview] {
        do {
            let data = try await backend.publicData("/reviews", query: [URLQueryItem(name: "instructorID", value: ownerID)])
            return Self.decode(data)
        } catch {
            return []
        }
    }

    /// Every review THIS user wrote — full rows (incl. bookingID) so the app can match them to local
    /// bookings and let the author edit. Requires a session (a guest wrote none).
    func fetchForStudent(ownerID: String) async -> [RemoteReview] {
        do {
            let data = try await backend.authorized("/reviews/mine")
            return Self.decode(data)
        } catch {
            return []
        }
    }

    private static func decode(_ data: Data) -> [RemoteReview] {
        struct Resp: Decodable { let reviews: [WireReview] }
        return ((try? JSONDecoder.reviewSnakeCase.decode(Resp.self, from: data))?.reviews ?? []).map(\.remote)
    }
}

// MARK: - Wire decoding

private struct WireReview: Decodable {
    let id: String              // stable OPAQUE dedup key — present on BOTH reads (hash of booking id)
    let bookingId: String?      // real booking id — ONLY on the author's own fetch (for edit-matching)
    let instructorId: String
    let studentId: String?      // stripped on the public read; present on the author's own fetch
    let studentName: String
    let rating: Int
    let text: String
    let createdAt: Double

    var remote: RemoteReview {
        RemoteReview(id: id, bookingID: bookingId ?? "", instructorID: instructorId,
                     studentID: studentId ?? "", studentName: studentName, rating: rating, text: text,
                     createdAt: Date(reviewMsEpoch: createdAt))
    }
}

private extension JSONDecoder {
    static var reviewSnakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private extension Date {
    init(reviewMsEpoch ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
}
