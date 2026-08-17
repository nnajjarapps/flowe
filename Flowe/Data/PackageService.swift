import Foundation

// MARK: - DTOs (plain, decoded from the backend JSON — no CloudKit, no SwiftData @Model)

/// An instructor-defined package on offer. `active` is only meaningful on the instructor's own
/// `/offerings/mine` read; the public browse read returns active offerings only.
struct RemoteOffering: Identifiable, Equatable {
    let id: String
    let instructorID: String
    let title: String
    let credits: Int
    let price: Int              // whole shekels
    let validityDays: Int?      // nil = never expires
    let active: Bool
}

enum PurchaseStatus: String {
    case pending, approved, declined
}

/// A student's request to buy a package + the instructor's decision, collapsed into one row.
struct RemotePurchase: Identifiable, Equatable {
    let id: String
    let offeringID: String
    let instructorID: String
    let studentID: String
    let studentName: String
    let credits: Int
    let price: Int
    let validityDays: Int?
    let status: PurchaseStatus
    let createdAt: Date
    let respondedAt: Date?
}

/// One of an instructor's students and the credits they still hold (Finance Center, Phase B). `value`
/// is the ₪ worth of the unredeemed credits (Σ remaining × per-credit price), computed server-side.
struct InstructorClientBalance: Identifiable {
    let studentID: String
    let studentName: String
    let remaining: Int
    let granted: Int
    let value: Int
    let nextExpiry: Date?
    var id: String { studentID }
}

/// One non-empty credit lot in a per-instructor balance (drives the "6 of 10" ring denominator).
struct CreditLot: Identifiable, Equatable {
    let id: String
    let remaining: Int
    let total: Int
    let expiresAt: Date?
    let createdAt: Date
}

/// A student's credit standing with ONE instructor.
struct CreditBalance: Equatable {
    let instructorID: String
    let balance: Int
    let nextExpiry: Date?
    let lots: [CreditLot]
}

/// A wallet entry — the student's credit standing summarised per instructor.
struct InstructorBalance: Identifiable, Equatable {
    var id: String { instructorID }
    let instructorID: String
    let balance: Int
    let nextExpiry: Date?
}

/// Outcome of a purchase request, so the UI can tell "sent" from "you already have one pending".
enum PurchaseRequestResult: Equatable {
    case requested
    case duplicate
    case failed
}

/// Class packages / credit ledger over the authorization backend ([[FloweBackendClient]]). ALL state is
/// money-adjacent and lives ONLY on the backend (never world-readable CloudKit): offerings, purchase
/// requests, grants and redemptions. Mirrors the [[BookingService]] hybrid shape — one `@MainActor` HTTP
/// domain service returning plain `Remote*` DTOs, so [[MockDataStore]] holds only in-memory caches.
/// Reads are non-interactive (degrade to nil until a session exists); user-driven writes pass
/// `interactive: true` so a session-less user gets a contextual Apple re-auth. See ClassPackages.md.
@MainActor
final class PackageService {
    private let backend = FloweBackendClient.shared

    // MARK: - Instructor: offerings

    /// Create (id nil) or edit (id set) a package offering. Returns the offering id, or nil on failure.
    func saveOffering(id: String?, title: String, credits: Int, price: Int, validityDays: Int?) async -> String? {
        struct Body: Encodable {
            let id: String?
            let title: String
            let credits: Int
            let price: Int
            let validityDays: Int?
        }
        do {
            let data = try await backend.authorized("/offerings", method: "POST",
                                                    body: Body(id: id, title: title, credits: credits, price: price, validityDays: validityDays),
                                                    interactive: true)
            struct Resp: Decodable { let id: String }
            return try JSONDecoder().decode(Resp.self, from: data).id
        } catch {
            return nil
        }
    }

    /// The instructor's whole menu (active + archived) for the package manager. nil = request failed.
    func fetchMyOfferings() async -> [RemoteOffering]? {
        do {
            let data = try await backend.authorized("/offerings/mine")
            struct Resp: Decodable { let offerings: [WireOffering] }
            return try JSONDecoder.pkgSnake.decode(Resp.self, from: data).offerings.map(\.remote)
        } catch {
            return nil
        }
    }

    /// Archive (active=false) or reactivate (active=true) an offering. Existing grants are untouched.
    @discardableResult
    func setOfferingActive(id: String, active: Bool) async -> Bool {
        struct Body: Encodable { let active: Bool }
        do {
            _ = try await backend.authorized("/offerings/\(id)/deactivate", method: "POST", body: Body(active: active), interactive: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Public browse (unauthenticated — a student on a profile, even before signing in)

    func fetchOfferings(instructorID: String) async -> [RemoteOffering]? {
        do {
            let data = try await backend.publicData("/offerings", query: [URLQueryItem(name: "instructorID", value: instructorID)])
            struct Resp: Decodable { let offerings: [WireOffering] }
            return try JSONDecoder.pkgSnake.decode(Resp.self, from: data).offerings.map(\.remote)
        } catch {
            return nil
        }
    }

    // MARK: - Student: purchase

    /// Request to buy a package. Payment is OFFLINE (cash/Bit) — this only files the request the
    /// instructor then approves. `.duplicate` when a pending request for this offering already exists.
    func requestPurchase(offeringID: String, studentName: String) async -> PurchaseRequestResult {
        struct Body: Encodable { let offeringID: String; let studentName: String }
        do {
            let data = try await backend.authorized("/purchases", method: "POST",
                                                    body: Body(offeringID: offeringID, studentName: studentName), interactive: true)
            struct Resp: Decodable { let duplicate: Bool? }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            return resp.duplicate == true ? .duplicate : .requested
        } catch {
            return .failed
        }
    }

    /// The student's own purchase requests (pending/approved/declined), newest first.
    func fetchMyPurchases() async -> [RemotePurchase]? {
        await fetchPurchases("/purchases/student")
    }

    // MARK: - Instructor: purchase inbox + decision

    /// The instructor's incoming purchase requests (pending first) — the approval inbox.
    func fetchIncomingPurchases() async -> [RemotePurchase]? {
        await fetchPurchases("/purchases/instructor")
    }

    /// Approve (grants the credits) or decline a purchase request. The backend does the grant atomically.
    @discardableResult
    func decidePurchase(id: String, approved: Bool) async -> Bool {
        struct Body: Encodable { let approved: Bool }
        do {
            _ = try await backend.authorized("/purchases/\(id)/decision", method: "POST", body: Body(approved: approved), interactive: true)
            return true
        } catch {
            return false
        }
    }

    private func fetchPurchases(_ path: String) async -> [RemotePurchase]? {
        do {
            let data = try await backend.authorized(path)
            struct Resp: Decodable { let purchases: [WirePurchase] }
            return try JSONDecoder.pkgSnake.decode(Resp.self, from: data).purchases.map(\.remote)
        } catch {
            return nil
        }
    }

    // MARK: - Balances

    /// The student's credit standing with one instructor (balance + non-empty lots), fetched when the
    /// booking sheet opens so "N left" is server-fresh at the redeem decision.
    func fetchBalance(instructorID: String) async -> CreditBalance? {
        do {
            let data = try await backend.authorized("/balance", query: [URLQueryItem(name: "instructorID", value: instructorID)])
            let wire = try JSONDecoder.pkgSnake.decode(WireBalance.self, from: data)
            return wire.balance(instructorID: instructorID)
        } catch {
            return nil
        }
    }

    /// The student's whole wallet — every instructor they hold credits with (for the wallet carousel).
    /// All of the instructor's clients + their remaining credits and ₪ value (Finance Center Phase B).
    /// nil until `GET /credits/clients` is deployed — Finance degrades to "—" for liability.
    func fetchClientBalances() async -> [InstructorClientBalance]? {
        do {
            let data = try await backend.authorized("/credits/clients")
            struct Resp: Decodable { let clients: [WireClientBalance] }
            return try JSONDecoder.pkgSnake.decode(Resp.self, from: data).clients.map(\.remote)
        } catch { return nil }
    }

    func fetchWallet() async -> [InstructorBalance]? {
        do {
            let data = try await backend.authorized("/balances")
            struct Resp: Decodable { let balances: [WireWalletEntry] }
            return try JSONDecoder.pkgSnake.decode(Resp.self, from: data).balances.map(\.entry)
        } catch {
            return nil
        }
    }

}

// MARK: - Wire decoding (snake_case JSON → DTOs)

private struct WireOffering: Decodable {
    let id: String
    let instructorId: String
    let title: String
    let credits: Int
    let price: Int
    let validityDays: Int?
    let active: Int?
    var remote: RemoteOffering {
        RemoteOffering(id: id, instructorID: instructorId, title: title, credits: credits, price: price,
                       validityDays: validityDays, active: (active ?? 1) == 1)
    }
}

private struct WirePurchase: Decodable {
    let id: String
    let offeringId: String
    let instructorId: String
    let studentId: String
    let studentName: String
    let credits: Int
    let price: Int
    let validityDays: Int?
    let status: String
    let createdAt: Double
    let respondedAt: Double?
    var remote: RemotePurchase {
        RemotePurchase(id: id, offeringID: offeringId, instructorID: instructorId, studentID: studentId,
                       studentName: studentName, credits: credits, price: price, validityDays: validityDays,
                       status: PurchaseStatus(rawValue: status) ?? .pending,
                       createdAt: Date(pkgMs: createdAt), respondedAt: respondedAt.map(Date.init(pkgMs:)))
    }
}

private struct WireLot: Decodable {
    let id: String
    let remaining: Int
    let total: Int
    let expiresAt: Double?
    let createdAt: Double
    var lot: CreditLot {
        CreditLot(id: id, remaining: remaining, total: total,
                  expiresAt: expiresAt.map(Date.init(pkgMs:)), createdAt: Date(pkgMs: createdAt))
    }
}

private struct WireBalance: Decodable {
    let balance: Int
    let nextExpiry: Double?
    let lots: [WireLot]
    func balance(instructorID: String) -> CreditBalance {
        CreditBalance(instructorID: instructorID, balance: balance,
                      nextExpiry: nextExpiry.map(Date.init(pkgMs:)), lots: lots.map(\.lot))
    }
}

private struct WireClientBalance: Decodable {
    let studentId: String
    let studentName: String?
    let remaining: Int
    let granted: Int
    let value: Double?
    let nextExpiry: Double?    // ms epoch
    var remote: InstructorClientBalance {
        InstructorClientBalance(studentID: studentId, studentName: studentName ?? "",
                                remaining: remaining, granted: granted,
                                value: Int((value ?? 0).rounded()),
                                nextExpiry: nextExpiry.map(Date.init(pkgMs:)))
    }
}

private struct WireWalletEntry: Decodable {
    let instructorId: String
    let balance: Int
    let nextExpiry: Double?
    var entry: InstructorBalance {
        InstructorBalance(instructorID: instructorId, balance: balance, nextExpiry: nextExpiry.map(Date.init(pkgMs:)))
    }
}

// File-private mirrors of BookingService's transport helpers (kept private so there is no cross-file
// redeclaration; the shared home can be hoisted into FloweBackendClient later without touching callers).
private extension JSONDecoder {
    static var pkgSnake: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

#if DEBUG
/// Internal decode seam for **FloweUnitTests only** — excluded from Release, so it never ships. It
/// exposes the exact snake_case decoders the service uses so `PackageDecodeTests` can lock the wire
/// contract (notably `instructor_id`→`instructorID`, whose break silently emptied the student wallet)
/// without widening the file-private `Wire*` DTOs. See [[ClassPackages]].
enum PackageWireDecodeSeam {
    static func offering(_ data: Data) throws -> RemoteOffering {
        try JSONDecoder.pkgSnake.decode(WireOffering.self, from: data).remote
    }
    static func purchase(_ data: Data) throws -> RemotePurchase {
        try JSONDecoder.pkgSnake.decode(WirePurchase.self, from: data).remote
    }
    static func balance(_ data: Data, instructorID: String) throws -> CreditBalance {
        try JSONDecoder.pkgSnake.decode(WireBalance.self, from: data).balance(instructorID: instructorID)
    }
    static func walletEntry(_ data: Data) throws -> InstructorBalance {
        try JSONDecoder.pkgSnake.decode(WireWalletEntry.self, from: data).entry
    }
}
#endif

private extension Date {
    init(pkgMs ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
}
