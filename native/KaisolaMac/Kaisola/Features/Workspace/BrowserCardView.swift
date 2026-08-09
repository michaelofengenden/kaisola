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
        guard BrowserCardOrigin(url: url) != nil else { return false }
        // `host(percentEncoded:)` strips IPv6 brackets ([::1] -> ::1) and, like
        // the host itself, preserves case — so normalize to lowercase. A bare
        // authority-less URL (e.g. file paths that slipped through) has no host.
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return false
        }
        return loopbackHosts.contains(host) || host.hasSuffix(".localhost")
    }
}

/// A normalized web origin for the embedded local browser. Paths, queries, and
/// fragments do not affect an origin; scheme, host, and effective port all do.
/// Credentials are rejected instead of being silently discarded because a URL
/// that looks host-equal can otherwise carry authority-changing userinfo.
struct BrowserCardOrigin: Equatable, Sendable {
    private let scheme: String
    private let host: String
    private let port: Int

    init?(url: URL) {
        guard url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else { return nil }

        let effectivePort = url.port ?? (scheme == "http" ? 80 : 443)
        guard (1...65_535).contains(effectivePort) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = effectivePort
    }

    func allows(_ url: URL) -> Bool {
        BrowserCardOrigin(url: url) == self
    }
}

/// What the card's web view is doing right now. A dev server that is still
/// starting, or has just died, otherwise shows as a blank page with nothing in
/// the accessibility tree to explain it, so the header mirrors this state.
enum BrowserCardLoadState: Equatable {
    case loading
    case loaded
    case failed(String)

    /// A navigation error as a card state, or `nil` when the error is not a
    /// real failure. WebKit reports a cancelled provisional navigation whenever
    /// a reload or a retarget supersedes the load in flight; announcing that as
    /// "failed to load" would be a lie the user hears on every reload.
    static func failure(for error: Error) -> Self? {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return nil
        }
        return .failed(error.localizedDescription)
    }
}

/// Spoken names for the card's header. The reload and close controls are
/// image-only, so without explicit labels VoiceOver falls back to the SF Symbol
/// name ("arrow.clockwise") and never says which page is being acted on — the
/// card sits beside the file preview and other cards can be open. Kept pure and
/// separate from the view so every announced string is directly testable.
struct BrowserCardAccessibility {
    let url: URL
    let state: BrowserCardLoadState

    /// The address as spoken in an action name: host and port
    /// ("localhost:3000") rather than the whole URL, so a button does not
    /// announce as "h t t p colon slash slash…" before naming its action.
    /// Falls back to the full string for anything without a host.
    var address: String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            return url.absoluteString
        }
        guard let port = url.port else { return host }
        // An IPv6 literal keeps its brackets, otherwise host and port run
        // together into one unreadable run of colons.
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Load state as spoken.
    var statusName: String {
        switch state {
        case .loading: "Loading"
        case .loaded: "Loaded"
        case .failed(let reason): "Failed to load: \(reason)"
        }
    }

    /// Value of the address element. The view labels that element "Address",
    /// which replaces its visible text for VoiceOver, so the full URL has to
    /// come back through the value — along with the state, which keeps it
    /// reachable even when no status indicator is showing.
    var addressValue: String {
        "\(url.absoluteString), \(statusName)"
    }

    /// The header's inline status element, or `nil` once the page is up: a
    /// loaded page needs no badge, and an empty one would just be noise to
    /// swipe past.
    var statusIndicatorLabel: String? {
        switch state {
        case .loading: "Loading \(address)"
        case .loaded: nil
        case .failed(let reason): "\(address) failed to load: \(reason)"
        }
    }

    /// Action names stay constant across load states: a control that renames
    /// itself mid-load is unusable by Voice Control.
    var reloadLabel: String { "Reload \(address)" }

    var openExternallyLabel: String { "Open in Browser, \(address)" }

    var closeLabel: String { "Close browser card for \(address)" }
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
    @State private var loadState: BrowserCardLoadState = .loading

    private var accessibility: BrowserCardAccessibility {
        BrowserCardAccessibility(url: url, state: loadState)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ConfinedWebView(url: url, reloadToken: reloadToken, loadState: $loadState)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(url.absoluteString)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel("Address")
                .accessibilityValue(accessibility.addressValue)
            statusIndicator
            Spacer(minLength: 12)
            Button {
                reloadToken &+= 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload this page")
            .accessibilityLabel(accessibility.reloadLabel)
            Button("Open in Browser") {
                NSWorkspace.shared.open(url)
            }
            .help("Open this URL in your default browser")
            .accessibilityLabel(accessibility.openExternallyLabel)
            Button {
                close()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Close the browser card")
            .accessibilityLabel(accessibility.closeLabel)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if let label = accessibility.statusIndicatorLabel {
            switch loadState {
            case .loading:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(label)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(label)
                    .accessibilityLabel(label)
            case .loaded:
                EmptyView()
            }
        }
    }
}

/// A WKWebView whose navigation is confined to the dev server: it only follows
/// links that share the card's exact normalized web origin.
/// Anything else (an OAuth bounce, an external link, a `target=_blank`) is
/// handed to the system browser for top-level navigations and silently dropped
/// for off-origin subframes, so the card can never wander onto the open web.
/// No JS message handlers are installed and the data store is non-persistent.
private struct ConfinedWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    @Binding var loadState: BrowserCardLoadState

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
        coordinator.origin = BrowserCardOrigin(url: url)
        coordinator.reloadToken = reloadToken
        coordinator.report = report
        webView.load(URLRequest(url: url))
        return webView
    }

    /// Load state is only ever published from a navigation callback, never from
    /// `makeNSView`/`updateNSView` — writing SwiftUI state inside a view update
    /// is what the "Modifying state during view update" warning is about, and
    /// `didStartProvisionalNavigation` already reports the reload as loading.
    private func report(_ state: BrowserCardLoadState) {
        guard loadState != state else { return }
        loadState = state
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.report = report
        // The card was retargeted at a different URL (user clicked another
        // localhost link while this card was already up).
        if coordinator.loadedURL != url {
            coordinator.loadedURL = url
            coordinator.origin = BrowserCardOrigin(url: url)
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
        var origin: BrowserCardOrigin?
        var reloadToken = 0
        var report: (BrowserCardLoadState) -> Void = { _ in }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            report(.loading)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(.loaded)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            if let state = BrowserCardLoadState.failure(for: error) { report(state) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if let state = BrowserCardLoadState.failure(for: error) { report(state) }
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
            if origin?.allows(target) == true {
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
