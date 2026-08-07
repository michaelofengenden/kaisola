import AppKit

/// Keeps a session's SwiftTerm view (and its render state) alive across the
/// SwiftUI teardowns that a project tab switch causes.
///
/// `unifiedTerminalSurface` builds its `NativeTerminalSurface` inside a
/// `ForEach` keyed on the active project's pane layout, so switching projects
/// destroys every terminal card and builds new ones. A fresh coordinator has
/// `hasRendered == false`, so it re-parses the entire retained transcript — up
/// to 8 MB — through a virgin parser.
///
/// That re-parse is not merely slow, it is *incorrect*. Agent CLIs bake absolute
/// cursor moves (`ESC[nA`) into their output, computed against the pane width at
/// the time. Replay those bytes into a narrower terminal and each redraw block
/// wraps to more rows than the cursor-up rewinds, so the top of the previous
/// copy survives — once per redraw cycle. Since Claude Code and Codex redraw on
/// nearly every token, one turn becomes many visible copies. Panes only ever get
/// narrower over a session (a split opens, a rail appears, the font grows),
/// which is why the artifact reads as duplication rather than loss.
///
/// Reusing the view means the transcript is parsed exactly once, at the geometry
/// the PTY already agreed on.
///
/// **The view and its coordinator must be claimed together.** They are a pair:
/// the coordinator holds `hasRendered` and the byte offsets describing precisely
/// what that view has already been fed. Reusing one without the other either
/// re-feeds into a populated view (duplication) or skips feeding a blank one
/// (an empty terminal). `claim` therefore hands back both or neither.
@MainActor
final class TerminalSurfaceCache {
    static let shared = TerminalSurfaceCache()

    struct Entry {
        let view: ReadOnlyTerminalView
        let coordinator: NativeTerminalSurface.Coordinator
    }

    /// Smaller than `AppModel.maximumRetainedTerminalSurfaces` (12), which
    /// governs retained *documents* — plain strings. These are live SwiftTerm
    /// buffers, and a `BufferLine` heap-allocates 24 bytes per cell, so a
    /// terminal that has actually filled the scrollback is tens of MiB.
    ///
    /// A deliberate trade rather than a limit: retaining a parked view is
    /// what makes returning to a project instant *and* correct, since the
    /// alternative is re-parsing the transcript at a possibly-narrower width.
    /// Three covers the immediate cycle set; deeper history is one gesture
    /// away in the transcript viewer, paged from the broker's disk spool
    /// (2026-08-06 spec §2a).
    static let maximumRetainedSurfaces = 3

    /// The scrollback a parked, bottom-pinned view keeps. Its full depth
    /// comes back automatically on mount (`updateNSView` re-applies the
    /// setting), and the dropped rows remain reachable via the transcript.
    static let parkedScrollbackLines = 500

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    private init() {}

    /// Take the cached pair for `sessionID`, if it is genuinely free.
    ///
    /// A view still installed in a window (`superview != nil`) is in use by
    /// another pane or another window — an `NSView` has exactly one superview,
    /// so it cannot be shared. In that case this returns nil and the caller
    /// builds a fresh pair, which is the pre-existing behaviour.
    func claim(sessionID: String, isOwned: Bool? = nil) -> Entry? {
        guard let entry = entries[sessionID] else { return nil }
        guard entry.view.superview == nil else { return nil }
        // Ownership is a type-level security boundary: ReadOnlyTerminalView
        // compiles away every outbound byte, while OwnedTerminalView forwards
        // input to the controller lane. A parked observer must never come back
        // as an apparently writable terminal (or vice versa). Drop the stale
        // pair and let NSViewRepresentable build the correct concrete class.
        if let isOwned, (entry.view is OwnedTerminalView) != isOwned {
            remove(sessionID: sessionID)
            return nil
        }
        remove(sessionID: sessionID)
        return entry
    }

    /// Hand a pair back for reuse after SwiftUI tears its card down.
    ///
    /// A parked view pinned to the live bottom sheds its scrollback — those
    /// cell buffers are the app's single largest memory consumer, and a
    /// pinned view is by definition not being read into history. A view the
    /// user left scrolled INTO history keeps its buffer and its position.
    func store(sessionID: String, view: ReadOnlyTerminalView, coordinator: NativeTerminalSurface.Coordinator) {
        let pinnedToBottom = !view.canScroll || view.scrollPosition >= 0.99
        if pinnedToBottom,
           view.getTerminal().options.scrollback > Self.parkedScrollbackLines {
            view.changeScrollback(Self.parkedScrollbackLines)
        }
        entries[sessionID] = Entry(view: view, coordinator: coordinator)
        order.removeAll { $0 == sessionID }
        order.append(sessionID)
        while order.count > Self.maximumRetainedSurfaces, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// Drop a session's surface — used when a session ends, so its buffer is not
    /// retained for a terminal that can never come back.
    func evict(sessionID: String) {
        remove(sessionID: sessionID)
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    var retainedSessionIDs: [String] { order }

    private func remove(sessionID: String) {
        entries.removeValue(forKey: sessionID)
        order.removeAll { $0 == sessionID }
    }
}
