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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ConfinedWebView(url: url, reloadToken: reloadToken)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text(url.absoluteString)
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
                NSWorkspace.shared.open(url)
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
private struct ConfinedWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Ephemeral: nothing this card loads touches on-disk cookies/cache.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        let coordinator = context.coordinator
        coordinator.loadedURL = url
        coordinator.originHost = url.host(percentEncoded: false)?.lowercased()
        coordinator.reloadToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
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
