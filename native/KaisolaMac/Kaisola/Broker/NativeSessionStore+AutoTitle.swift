import Foundation

/// Live OSC title tracking, layered onto `NativeSessionStore` without touching
/// its file. Both helpers go exclusively through the store's existing public
/// API (`sessions()` / `upsert(_:)`), so the on-disk `Payload` and its atomic
/// write path are unchanged.
extension NativeSessionStore {
    /// Overwrite an owned session's sidebar title with a title derived live
    /// from its terminal's OSC stream, persisting it through the normal upsert.
    ///
    /// A no-op when `terminalID` is unknown here — an observed Electron
    /// terminal, or a session that just ended — because only sessions this app
    /// owns have a mutable title to carry.
    func applyAutoTitle(_ title: String, terminalID: String) {
        guard var stored = sessions().first(where: { $0.id == terminalID }) else { return }
        guard stored.title != title || stored.lastAutoTitle != title else { return }
        stored.title = title
        stored.lastAutoTitle = title
        upsert(stored)
    }

    /// Repair legacy automatic activity titles during AppModel startup. Each
    /// entry has already passed SessionTitleTracker's user-ownership and exact
    /// creation-default checks; applying through the ordinary write path keeps
    /// the archive schema and cache coherent.
    @discardableResult
    func repairTransientAutoTitles(_ replacementsByTerminalID: [String: String]) -> Int {
        var repaired = 0
        for stored in sessions() {
            guard let replacement = replacementsByTerminalID[stored.id],
                  stored.title != replacement || stored.lastAutoTitle != replacement else {
                continue
            }
            applyAutoTitle(replacement, terminalID: stored.id)
            repaired += 1
        }
        return repaired
    }

    /// Whether the user has taken this name over by hand, used as the
    /// `userRenamed` input to `SessionTitleTracker.shouldApply`.
    /// True when the stored title has diverged from the name the session was
    /// given at creation ("<agent> · <folder>" or just "<folder>").
    ///
    /// The stored last-auto-title marker distinguishes live naming from a
    /// manual rename. Old archives have no marker and therefore fail safe: a
    /// divergent old title is treated as user-owned. An unknown terminal reads
    /// as not-custom because there is nothing to protect.
    func hasCustomTitle(_ terminalID: String, defaultTitle: String) -> Bool {
        guard let stored = sessions().first(where: { $0.id == terminalID }) else { return false }
        if stored.title == defaultTitle { return false }
        return stored.lastAutoTitle != stored.title
    }
}
