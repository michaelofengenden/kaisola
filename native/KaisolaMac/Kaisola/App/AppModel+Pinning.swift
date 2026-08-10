import AppKit
import Foundation

/// Session pinning: favorites the user floats to the top of their project
/// group (Electron parity). State lives in a standalone `SessionPinStore`.
///
/// Reads use AppModel's in-memory snapshot so streamed output never triggers
/// disk I/O during view evaluation; writes refresh that snapshot immediately.
/// The snapshot is also the last-known-good pin set: when the file underneath
/// it stops being readable the sidebar keeps showing the pins it already knew
/// instead of silently unpinning every row.
extension AppModel {
    /// Toggle a session's pinned state, then republish so the sidebar reorders.
    /// A pin that never reached disk is reported at once — the row order the
    /// user sees is only ever the order that persisted.
    func togglePin(_ terminalID: String) {
        do {
            try pinStore.setPinned(terminalID, !persistedPinnedIDs.contains(terminalID))
        } catch {
            ToastCenter.shared.show(
                AppModel.pinFailureMessage(for: error),
                style: .error,
                duration: 6
            )
        }
        refreshPersistedNavigationState()
    }

    /// Whether a session is pinned to the top of its project group.
    func isPinned(_ terminalID: String) -> Bool {
        persistedPinnedIDs.contains(terminalID)
    }

    /// Reload the pin snapshot from disk. A file this build cannot read leaves
    /// the previous snapshot in place: dropping to empty here would unpin every
    /// row on screen, and the next ordinary pin would write that emptiness back
    /// over pins the app never managed to read.
    func reloadPersistedPins() {
        let load = pinStore.load()
        persistedPinnedIDs = load.pins ?? persistedPinnedIDs
        let previous = pinsUnreadable
        pinsUnreadable = load.failure
        // `refreshPersistedNavigationState` runs at every mutation boundary, so
        // announce a problem when it appears rather than once per refresh.
        if let failure = load.failure, previous == nil {
            ToastCenter.shared.show(failure.notice, style: .error, duration: 6)
        }
    }

    /// Move a pin file this build cannot read aside and start a fresh, empty
    /// one. The only path that gives up on unreadable pins, and the user asks
    /// for it explicitly from the session menu.
    func resetUnreadablePins() {
        do {
            switch try pinStore.resetPreservingUnreadableFile() {
            case .movedAside(let preservedCopyURL):
                ToastCenter.shared.show(
                    "Pinned sessions reset. The damaged file was kept as "
                        + preservedCopyURL.lastPathComponent,
                    style: .info,
                    duration: 6
                )
            case .nothingToPreserve:
                ToastCenter.shared.show("Pinned sessions reset", style: .info)
            }
        } catch {
            ToastCenter.shared.show(
                AppModel.pinFailureMessage(for: error),
                style: .error,
                duration: 6
            )
        }
        refreshPersistedNavigationState()
    }

    /// The sentence shown when pinning fails. `SessionPinStore` throws its own
    /// error type; anything else still has to reach the user in words rather
    /// than disappear.
    nonisolated static func pinFailureMessage(for error: Error) -> String {
        if let failure = error as? SessionPinStore.WriteFailure { return failure.message }
        return "Pinned sessions couldn't be saved: \((error as NSError).localizedDescription)."
    }

    /// Order sessions for display: pinned rows first, then by title, stable
    /// within each group by original position.
    func pinnedSort(_ sessions: [BrokerTerminalRecord]) -> [BrokerTerminalRecord] {
        AppModel.pinnedOrder(sessions, pinned: persistedPinnedIDs)
    }

    /// Pure ordering behind `pinnedSort` with pin membership supplied
    /// explicitly, so the ordering can be tested without touching the persisted
    /// store. Pinned rows sort ahead of unpinned; within each group rows sort by
    /// title, and equal titles keep their original relative order (stable).
    nonisolated static func pinnedOrder(
        _ sessions: [BrokerTerminalRecord],
        pinned: Set<String>
    ) -> [BrokerTerminalRecord] {
        sessions.enumerated().sorted { lhs, rhs in
            let lhsPinned = pinned.contains(lhs.element.id)
            let rhsPinned = pinned.contains(rhs.element.id)
            if lhsPinned != rhsPinned { return lhsPinned }
            if lhs.element.title != rhs.element.title {
                return lhs.element.title < rhs.element.title
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
