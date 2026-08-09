import WebKit

/// Ephemeral browsing state for the app's CONTENT webviews — the HTML preview
/// and the browser card (2026-08-06 spec §2e, revised 2026-08-09). Each surface
/// gets its OWN non-persistent store: an approved project file and an
/// authenticated local dev server are different trust classes, so cookies,
/// storage and caches must never cross between them. Views on the same surface
/// still share one store, which is where the original §2e win came from
/// (shared caches and process affinity instead of isolated ephemeral state per
/// view); WKProcessPool is deprecated and inert on modern macOS, so the data
/// store is the only lever left. The CodeMirror editor deliberately uses
/// neither: its privileged scheme handler and script bridge stay in their own
/// isolated configuration and store.
@MainActor
enum SharedWebKit {
    /// A content surface, one per trust class. Two surfaces must never map to
    /// the same store — `SharedWebKitTests` enforces that pairwise.
    enum ContentSurface: CaseIterable {
        /// Project HTML opened from the file tree. Untrusted markup; scripts
        /// run only after a per-file opt-in.
        case filePreview
        /// A local dev server raised from a terminal or agent link, which may
        /// be carrying the developer's own login session.
        case browserCard
    }

    /// The non-persistent store backing `surface`.
    static func ephemeralStore(for surface: ContentSurface) -> WKWebsiteDataStore {
        switch surface {
        case .filePreview: filePreviewStore
        case .browserCard: browserCardStore
        }
    }

    /// A configuration already pinned to `surface`'s store. Callers layer their
    /// own preferences on top and must not reassign `websiteDataStore`.
    static func contentConfiguration(for surface: ContentSurface) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ephemeralStore(for: surface)
        return configuration
    }

    private static let filePreviewStore = WKWebsiteDataStore.nonPersistent()
    private static let browserCardStore = WKWebsiteDataStore.nonPersistent()
}
