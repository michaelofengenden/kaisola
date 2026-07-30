import Combine
import Foundation

/// Transient, in-window confirmations: the bottom-center strip that says
/// "File saved", "Layout saved", "Checkpoint restored", "Committed abc1234",
/// and surfaces failures in orange. This is the native analogue of Electron's
/// toast row — a short FIFO queue of auto-dismissing messages that any call
/// site (a model, a view, the app delegate) can post without threading a
/// reference through. `ToastOverlayView` renders `toasts`; this type owns them.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id: UUID
        let message: String
        let style: Style

        enum Style {
            case info
            case success
            case error
        }
    }

    /// At most three toasts are visible at once; a fourth evicts the oldest
    /// (FIFO) so a burst of confirmations stays a hint, never a wall.
    static let maxVisible = 3

    @Published private(set) var toasts: [Toast] = []

    /// Post a toast and schedule its removal after `duration`. Removal is
    /// cancel-safe: the timer dismisses only its own toast by id, and only if
    /// it still exists — so a toast that was tapped away or evicted first never
    /// disturbs the ones that replaced it, and unique ids make a stale timer a
    /// no-op rather than a mis-fire.
    func show(_ message: String, style: Toast.Style = .info, duration: TimeInterval = 2.6) {
        let toast = Toast(id: UUID(), message: message, style: style)
        toasts.append(toast)
        if toasts.count > Self.maxVisible {
            toasts.removeFirst(toasts.count - Self.maxVisible)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, self.toasts.contains(where: { $0.id == toast.id }) else { return }
            self.dismiss(toast.id)
        }
    }

    /// Remove a toast now (tap-to-dismiss or expiry). Idempotent.
    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }
}
