import AppKit
import SwiftUI
import WebKit

/// Classifies a URL as a local dev-server URL (something a `npm run dev` /
/// Vite / Rails prints). Pure so tests can drive it and the terminal link
/// router can decide, without side effects, whether a click opens an in-app
/// browser card instead of Safari. Matches http/https on the loopback hosts
/// {localhost, 127.0.0.1, ::1, 0.0.0.0} plus any `*.localhost` subdomain, on
/// any port. Everything else (other schemes, real hosts, suffix spoofs like
/// `localhost.evil.com`) is rejected.
enum LocalhostDetector {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    static func isLocalDevURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        // `host(percentEncoded:)` strips IPv6 brackets ([::1] -> ::1) and, like
        // the host itself, preserves case — so normalize to lowercase. A bare
        // authority-less URL (e.g. file paths that slipped through) has no host.
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return false
        }
        return loopbackHosts.contains(host) || host.hasSuffix(".localhost")
    }
}

/// The address a browser card header shows. The URL the card was opened with
/// is only a starting point: a redirect, an in-page link, or a back/forward
/// step swaps the document without telling the shell, so a header pinned to
/// the request ends up naming a page that is not on screen. `committed` is fed
/// by the web view's navigation delegate. Pure so tests can drive it.
struct BrowserCardAddress: Equatable {
    /// What the card was asked to open, most recently.
    private(set) var requested: URL
    /// The document the web view actually navigated to, once one commits.
    private(set) var committed: URL?

    init(requested: URL) {
        self.requested = requested
    }

    /// What the header renders: the live document when there is one, and the
    /// pending request until the first navigation commits.
    var displayed: URL { committed ?? requested }

    /// The card was pointed at a different URL. The previous document's
    /// address must not linger over the new page.
    mutating func retarget(to url: URL) {
        requested = url
        committed = nil
    }

    /// A navigation committed. WebKit reports a nil URL for loads that never
    /// produced a document, which must not blank out an address whose page is
    /// still on screen.
    mutating func commit(_ url: URL?) {
        guard let url else { return }
        committed = url
    }
}

/// An in-app browser card for local dev servers (Electron parity): clicking a
/// localhost URL in a terminal shows the page here instead of launching Safari.
/// Header mirrors `FilePreviewView` — an icon, the address, and trailing
/// actions ending in a close affordance — over a navigation-confined WKWebView.
struct BrowserCardView: View {
    let url: URL
    let close: () -> Void

    /// Bumping this drives a reload through the representable's `updateNSView`
    /// without holding a reference to the WKWebView from the header.
    @State private var reloadToken = 0
    /// The requested URL until the web view commits a document, then wherever
    /// it actually went.
    @State private var address: BrowserCardAddress

    init(url: URL, close: @escaping () -> Void) {
        self.url = url
        self.close = close
        _address = State(initialValue: BrowserCardAddress(requested: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ConfinedWebView(url: url, reloadToken: reloadToken) { committed in
                address.commit(committed)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // The card stays mounted when the shell retargets it at another
        // localhost link, so `@State` has to be reset by hand.
        .onChange(of: url) { _, newURL in address.retarget(to: newURL) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text(address.displayed.absoluteString)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel("Address")
            Spacer(minLength: 12)
            Button {
                reloadToken &+= 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload this page")
            Button("Open in Browser") {
                // Hand over the page on screen, not the link that opened the
                // card — otherwise the button contradicts the address beside it.
                NSWorkspace.shared.open(address.displayed)
            }
            .help("Open this URL in your default browser")
            Button {
                close()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Close the browser card")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }
}

/// A WKWebView whose navigation is confined to the dev server: it only follows
/// links that are themselves local dev URLs or share the card's origin host.
/// Anything else (an OAuth bounce, an external link, a `target=_blank`) is
/// handed to the system browser for top-level navigations and silently dropped
/// for off-origin subframes, so the card can never wander onto the open web.
/// No JS message handlers are installed and the data store is non-persistent.
struct ConfinedWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    /// Reports the address the web view is actually showing, so the header can
    /// follow it. Called with the URL of every committed document plus the
    /// same-document navigations the delegate never reports.
    let onCommit: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Ephemeral, shared with the HTML preview (spec §2e) — nothing here
        // touches on-disk cookies/cache.
        configuration.websiteDataStore = SharedWebKit.ephemeralContentStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        let coordinator = context.coordinator
        coordinator.loadedURL = url
        coordinator.originHost = url.host(percentEncoded: false)?.lowercased()
        coordinator.reloadToken = reloadToken
        coordinator.onCommit = onCommit
        coordinator.observeAddress(of: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        // SwiftUI rebuilds this struct on every render, so the closure the
        // coordinator holds has to be refreshed or it captures a stale view.
        coordinator.onCommit = onCommit
        // The card was retargeted at a different URL (user clicked another
        // localhost link while this card was already up).
        if coordinator.loadedURL != url {
            coordinator.loadedURL = url
            coordinator.originHost = url.host(percentEncoded: false)?.lowercased()
            webView.load(URLRequest(url: url))
        }
        // Header reload button was pressed.
        if coordinator.reloadToken != reloadToken {
            coordinator.reloadToken = reloadToken
            webView.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var originHost: String?
        var reloadToken = 0
        /// Publishes the address the card is showing back to the header.
        var onCommit: ((URL?) -> Void)?
        private var urlObservation: NSKeyValueObservation?

        /// Watches `url` for the same-document navigations (a fragment link, a
        /// router's `pushState`) that no WKNavigationDelegate callback reports.
        /// A single-page dev server does most of its routing that way, so
        /// without this the address freezes on the first route.
        func observeAddress(of webView: WKWebView) {
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] observed, change in
                // WebKit mutates `url` on the main thread; the header state
                // this feeds is MainActor-isolated.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.addressChangedOutsideNavigation(
                        to: change.newValue ?? nil,
                        isLoading: observed.isLoading
                    )
                }
            }
        }

        /// `url` also moves partway through a cross-document load, while the
        /// new document is still provisional and can still fail — publishing it
        /// there would leave the header naming a page that never appeared.
        /// Those loads arrive through `didCommit` instead, so only take an
        /// address that changed while nothing was loading.
        func addressChangedOutsideNavigation(to url: URL?, isLoading: Bool) {
            guard !isLoading else { return }
            onCommit?(url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            navigationCommitted(to: webView.url)
        }

        /// The document is now on screen. After a redirect chain, or a
        /// back/forward step, this is the URL that actually rendered — which is
        /// the only address the header may claim.
        func navigationCommitted(to url: URL?) {
            onCommit?(url)
        }

        // The closure attributes must match the optional requirement exactly
        // (`@MainActor @Sendable`); otherwise Swift treats this as an unrelated
        // method and WebKit never calls it — silently defeating confinement.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let targetHost = target.host(percentEncoded: false)?.lowercased()
            let sameHost = originHost != nil && targetHost == originHost
            if LocalhostDetector.isLocalDevURL(target) || sameHost {
                decisionHandler(.allow)
                return
            }
            // Off-origin. Hand top-level / new-window navigations (a nil target
            // frame is a `target=_blank`) to the real browser; drop off-origin
            // subframes silently so an embedded third-party iframe can't spam
            // browser tabs.
            let isTopLevel = navigationAction.targetFrame?.isMainFrame ?? true
            if isTopLevel {
                NSWorkspace.shared.open(target)
            }
            decisionHandler(.cancel)
        }
    }
}

extension Notification.Name {
    /// Posted (object: the tapped `URL`) when a terminal/agent link resolves to
    /// a local dev URL, so the shell can raise a `BrowserCardView` in the detail
    /// pane instead of leaving it to the system browser.
    static let kaisolaOpenBrowserCard = Notification.Name("kaisolaOpenBrowserCard")
}
