import WebKit

/// Shared ephemeral browsing state for the app's CONTENT webviews — the HTML
/// preview and the browser card (2026-08-06 spec §2e, adjusted): WKProcessPool
/// is deprecated and inert on modern macOS (WebKit already coalesces
/// WebContent processes), so the remaining lever is the data store — views on
/// one store share caches and process affinity instead of each spinning up
/// isolated ephemeral state. The CodeMirror editor deliberately does NOT use
/// this: its privileged scheme handler and script bridge stay in their own
/// isolated configuration and store.
@MainActor
enum SharedWebKit {
    static let ephemeralContentStore = WKWebsiteDataStore.nonPersistent()
}
