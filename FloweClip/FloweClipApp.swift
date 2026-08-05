import SwiftUI

/// App Clip entry point for Flowe.
///
/// A Clip is invoked when someone opens an instructor share link / QR
/// (https://nnajjarapps.github.io/flowe-support/i/<ownerID>) without the full app installed. Unlike the
/// full app — which receives the same link through `onOpenURL` (see `FlowApp`) — an App Clip is ALWAYS
/// launched with an `NSUserActivity` of type `NSUserActivityTypeBrowsingWeb` whose `webpageURL` is the
/// invocation URL. `onOpenURL` does NOT fire for a Clip invocation, so `.onContinueUserActivity` is the
/// single supported seam (covers both cold-start and warm foreground).
///
/// For on-simulator testing without a live link, set the Run scheme's "App Clip Invocation URL"
/// (stored as the `_XCAppClipURL` environment value) to a real link, e.g.
/// https://nnajjarapps.github.io/flowe-support/i/<someRealOwnerID> — it surfaces here as the normal
/// `webpageURL` on the browsing-web activity.
@main
struct FloweClipApp: App {
    @State private var model = ClipModel()

    var body: some Scene {
        WindowGroup {
            ClipRootView()
                .environment(model)
                .tint(.flowePinkDeep)
                // Both cold-start and warm re-invocation of the Clip arrive here.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    model.handle(url: activity.webpageURL)
                }
        }
    }
}
