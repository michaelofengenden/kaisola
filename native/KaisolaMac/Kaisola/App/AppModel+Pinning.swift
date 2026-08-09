import AppKit
import Foundation

/// Session pinning: favorites the user floats to the top of their project
/// group (Electron parity). State lives in a standalone `SessionPinStore`.
///
/// Reads use AppModel's in-memory snapshot so streamed output never triggers
/// disk I/O during view evaluation; writes refresh that snapshot immediately.
extension AppModel {
    /// Toggle a session's pinned state, then republish so the sidebar reorders.
    /// A failed durable write leaves the in-memory snapshot untouched and is
    /// surfaced immediately instead of presenting a pin that will vanish.
    func togglePin(_ terminalID: String) {
        let store = SessionPinStore()
        guard let updated = AppModel.persistPinChange(
            terminalID: terminalID,
            currentPins: persistedPinnedIDs,
            store: store,
            reportFailure: { message in
                ToastCenter.shared.show(message, style: .error, duration: 6)
            }
        ) else { return }

        persistedPinnedIDs = updated
        objectWillChange.send()
    }

    /// Testable durability boundary behind `togglePin`. Returning nil means the
    /// caller must retain its current in-memory pins.
    static func persistPinChange(
        terminalID: String,
        currentPins: Set<String>,
        store: SessionPinStore,
        reportFailure: (String) -> Void
    ) -> Set<String>? {
        do {
            return try store.setPinned(terminalID, !currentPins.contains(terminalID))
        } catch {
            reportFailure(error.localizedDescription)
            return nil
        }
    }

    /// Whether a session is pinned to the top of its project group.
    func isPinned(_ terminalID: String) -> Bool {
        persistedPinnedIDs.contains(terminalID)
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
