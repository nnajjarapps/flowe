import SwiftUI
import WebKit

/// The in-app documents. Drives an item-based sheet so a screen presents both from ONE `.sheet`
/// (two `.sheet` modifiers on one view shadow each other in SwiftUI).
enum LegalDoc: String, Identifiable {
    case privacy, support, guidelines
    var id: String { rawValue }
    var resource: String {
        switch self {
        case .privacy:    return "PrivacyPolicy"
        case .support:    return "HelpSupport"
        case .guidelines: return "CommunityGuidelines"
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .privacy:    return "Privacy Policy"
        case .support:    return "Help & Support"
        case .guidelines: return "Community Guidelines"
        }
    }
}

/// Renders a bundled HTML document — the Privacy Policy, Help & Support — INSIDE the app instead of
/// bouncing the user out to a website. The pages are self-contained HTML in `Flowe/Resources`
/// (inline CSS, no external assets), so they load from the bundle and work offline, and they style
/// their own light/dark via `prefers-color-scheme`.
///
/// Links inside a document open the right place: `mailto:` opens Mail, a web link opens Safari — only
/// the local file itself renders here.
struct LegalDocumentView: View {
    let resource: String
    let title: LocalizedStringKey

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BundledHTMLView(resource: resource)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .tint(Color.flowePinkDeep)
                            .fontWeight(.semibold)
                    }
                }
        }
    }
}

/// Thin `WKWebView` wrapper that loads one bundled HTML file and routes tapped links out of the app.
private struct BundledHTMLView: UIViewRepresentable {
    let resource: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        // Let the page's own background (which follows prefers-color-scheme) show through, so there's
        // no white flash under a dark document.
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear

        if let url = Bundle.main.url(forResource: resource, withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.loadHTMLString(
                "<body style=\"font:16px -apple-system;padding:24px;color:#2d1520\">This document is "
                + "currently unavailable. Please contact pilatesflowe@gmail.com.</body>",
                baseURL: nil
            )
        }
        return web
    }

    // The document never changes for a given instance, so nothing to update — reloading here would
    // fight the initial load.
    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only a user tapping a link leaves the document; the initial file load is allowed through.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               ["mailto", "tel", "http", "https"].contains(scheme) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
