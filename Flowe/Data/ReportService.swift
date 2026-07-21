import Foundation
import CloudKit

/// What a piece of reported content is, so a reviewer knows where to look.
enum ReportedContent: String {
    case message                // a single chat message
    case instructorListing      // a public profile's text (bio / cert / name)
    case communityPost          // a post in the community feed
    case communityComment       // a reply on a community post
}

/// Why the reporter flagged it. Fixed set so reports can be triaged without reading every one.
enum ReportReason: String, CaseIterable, Identifiable {
    case harassment    = "Harassment or bullying"
    case sexual        = "Sexual or explicit content"
    case spam          = "Spam or a scam"
    case impersonation = "Impersonation"
    case misleading    = "Misleading credentials"
    case other         = "Something else"

    var id: String { rawValue }
}

/// Delivers user reports of objectionable content, as App Store Review Guideline 1.2 requires.
///
/// Reports go to the **public** database because that is the only shared store available without a
/// server — but unlike every other record type here, `ContentReport` must have `_world` read
/// **disabled** in the CloudKit Dashboard. A report names its reporter, and a world-readable report
/// would let the reported person discover who flagged them. Creator-only read still lets the
/// developer triage from the Dashboard, which is where reports are reviewed.
///
/// See `BOOKING-SYSTEM.md` for the schema and the exact security role.
@MainActor
final class ReportService {
    static let recordType = "ContentReport"

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// File a report. Returns whether it reached the server, so the UI can be honest about it
    /// rather than showing a thank-you for something that never sent.
    func submit(reporterID: String,
                reportedID: String,
                reportedName: String,
                content: ReportedContent,
                contentID: String,
                reason: ReportReason,
                snapshot: String,
                details: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let record = CKRecord(recordType: Self.recordType)
        record["reporterID"] = reporterID
        record["reportedID"] = reportedID
        record["reportedName"] = reportedName
        record["contentType"] = content.rawValue
        record["contentID"] = contentID
        record["reason"] = reason.rawValue
        // The offending text is copied in: the original may be deleted or edited before review,
        // and a report with nothing to look at can't be actioned.
        record["snapshot"] = String(snapshot.prefix(2000))
        record["details"] = String(details.prefix(2000))
        record["createdAt"] = Date()
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }
}
