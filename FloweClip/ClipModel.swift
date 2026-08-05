import SwiftUI

/// Drives the single-screen Clip: parse the invocation URL → fetch the public listing → render.
///
/// Anonymous by design — there is no `AppSession`, no iCloud sign-in, no SwiftData. A public-DB read is
/// world-readable, so `ClipCatalogService` resolves the instructor with zero auth.
@MainActor
@Observable
final class ClipModel {

    enum Phase {
        case idle                     // no invocation URL yet
        case loading
        case loaded(ClipInstructor)
        case notFound                 // link resolved to no such listing (bad/stale ownerID)
        case offline                  // the fetch itself failed (network / CloudKit unreachable)
    }

    private(set) var phase: Phase = .idle

    private let service = ClipCatalogService()
    /// The ownerID currently loaded/loading — guards against `onContinueUserActivity` firing repeatedly
    /// with the same URL, and gives `retry()` something to re-fetch.
    private var ownerID: String?

    /// Feed every invocation `webpageURL` through here. A nil/unparseable URL with nothing already
    /// loaded shows the not-found state.
    func handle(url: URL?) {
        guard let url, let id = Self.ownerID(from: url) else {
            if case .loaded = phase { return }   // already showing a profile — keep it
            phase = .notFound
            return
        }
        // Same link delivered again while it's already resolved — nothing to do.
        if id == ownerID, case .loaded = phase { return }
        ownerID = id
        load(id)
    }

    /// Re-run the last fetch — wired to the offline state's "Try again" button.
    func retry() {
        guard let id = ownerID else { return }
        load(id)
    }

    private func load(_ id: String) {
        phase = .loading
        Task {
            switch await service.fetch(ownerID: id) {
            case .success(let instructor): phase = .loaded(instructor)
            case .notFound:                phase = .notFound
            case .failure:                 phase = .offline
            }
        }
    }

    /// The ownerID is the path segment immediately after `i` — the exact rule `FlowApp.onOpenURL`
    /// uses, so the Clip and the full app parse a share link identically. Robust to both `/i/<id>`
    /// and the GitHub project-pages `/flowe-support/i/<id>` shape.
    static func ownerID(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let idx = parts.firstIndex(of: "i"), idx + 1 < parts.count else { return nil }
        let id = parts[idx + 1]
        return id.isEmpty ? nil : id
    }
}
