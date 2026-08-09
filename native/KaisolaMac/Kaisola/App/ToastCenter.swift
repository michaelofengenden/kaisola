import Combine
import Foundation

/// Transient, in-window confirmations: the bottom-center strip that says
/// "File saved", "Layout saved", "Checkpoint restored", "Committed abc1234",
/// and surfaces failures in orange. This is the native analogue of Electron's
/// toast row — a short, severity-aware queue of auto-dismissing messages that
/// any call site (a model, a view, the app delegate) can post without threading
/// a reference through. `ToastOverlayView` renders `toasts`; this type owns them.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable, Sendable {
        let id: UUID
        let message: String
        let style: Style
        /// Caller-supplied identity, or a deterministic identity derived from
        /// style + message. It is process-local and never persisted.
        let stableKey: String
        /// How many still-visible events this row represents.
        let occurrenceCount: Int
        /// Fences an old expiry task after a coalesced toast renews its timer.
        let expiryToken: UUID
        /// Changes only when spoken content or severity changes. Identical
        /// repeats coalesce without making VoiceOver announce a burst N times.
        let announcementToken: UUID

        enum Style: Sendable {
            case info
            case success
            case error

            fileprivate var isCritical: Bool { self == .error }

            fileprivate var storageKey: String {
                switch self {
                case .info: "info"
                case .success: "success"
                case .error: "error"
                }
            }

            fileprivate static func preservingCritical(_ current: Style, _ incoming: Style) -> Style {
                current.isCritical ? current : incoming
            }
        }
    }

    /// At most three toasts are visible at once; a fourth evicts the oldest
    /// non-critical notice first so a burst of confirmations stays a hint,
    /// never a wall, without hiding an error that still needs attention.
    static let maxVisible = 3
    static let maxRecent = 50

    private let maximumVisible: Int
    private let recentLimit: Int
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    @Published private(set) var toasts: [Toast] = []
    /// Bounded, coalesced history retained after a visible toast is dismissed
    /// or expires. `ToastOverlayView` exposes it through Recent notifications.
    @Published private(set) var recentToasts: [Toast] = []

    init(maxVisible: Int = ToastCenter.maxVisible, recentLimit: Int = ToastCenter.maxRecent) {
        maximumVisible = max(1, maxVisible)
        self.recentLimit = max(0, recentLimit)
    }

    /// Post a toast and schedule its removal after `duration`. Removal is
    /// generation-safe: a repeated stable key renews one row, and the old task
    /// cannot dismiss that newer generation. Without an explicit key, exactly
    /// identical style/message events coalesce automatically.
    func show(
        _ message: String,
        style: Toast.Style = .info,
        duration: TimeInterval = 2.6,
        key: String? = nil
    ) {
        let stableKey = Self.stableKey(explicit: key, message: message, style: style)
        let expiryToken = UUID()

        if let existingIndex = toasts.firstIndex(where: { $0.stableKey == stableKey }) {
            var nextToasts = toasts
            let existing = nextToasts.remove(at: existingIndex)
            let updatedStyle = Toast.Style.preservingCritical(existing.style, style)
            let updated = Toast(
                id: existing.id,
                message: message,
                style: updatedStyle,
                stableKey: stableKey,
                occurrenceCount: existing.occurrenceCount == Int.max
                    ? Int.max
                    : existing.occurrenceCount + 1,
                expiryToken: expiryToken,
                announcementToken: existing.message == message && existing.style == updatedStyle
                    ? existing.announcementToken
                    : UUID()
            )
            nextToasts.append(updated)
            toasts = nextToasts
            recordRecent(updated)
            scheduleExpiry(for: updated, duration: duration)
            return
        }

        let toast = Toast(
            id: UUID(),
            message: message,
            style: style,
            stableKey: stableKey,
            occurrenceCount: 1,
            expiryToken: expiryToken,
            announcementToken: UUID()
        )
        recordRecent(toast)

        guard admit(toast) else {
            // An all-error stack has priority over a routine update. The update
            // remains inspectable in recent history instead of disappearing.
            return
        }
        scheduleExpiry(for: toast, duration: duration)
    }

    /// Remove a toast now (tap-to-dismiss or expiry). Idempotent.
    func dismiss(_ id: UUID) {
        expiryTasks.removeValue(forKey: id)?.cancel()
        toasts.removeAll { $0.id == id }
    }

    /// Clear only the inspectable history. Visible notices remain visible and
    /// keep their independent expiry tasks.
    func clearRecent() {
        recentToasts.removeAll()
    }

    /// Expire only the exact visible generation that scheduled the task.
    /// Internal so deterministic tests can prove stale tasks are harmless.
    func expire(_ id: UUID, token: UUID) {
        guard let index = toasts.firstIndex(where: { $0.id == id }),
              toasts[index].expiryToken == token else { return }
        expiryTasks.removeValue(forKey: id)?.cancel()
        toasts.remove(at: index)
    }

    /// Publish each admission as one array assignment. SwiftUI never observes
    /// an intermediate over-cap or under-cap stack while a burst is coalesced.
    private func admit(_ toast: Toast) -> Bool {
        var nextToasts = toasts
        var evictedID: UUID?
        if nextToasts.count >= maximumVisible {
            if let noncritical = nextToasts.firstIndex(where: { !$0.style.isCritical }) {
                evictedID = nextToasts.remove(at: noncritical).id
            } else if toast.style.isCritical {
                evictedID = nextToasts.removeFirst().id
            } else {
                return false
            }
        }
        nextToasts.append(toast)
        toasts = nextToasts
        if let evictedID {
            expiryTasks.removeValue(forKey: evictedID)?.cancel()
        }
        return true
    }

    private func recordRecent(_ toast: Toast) {
        guard recentLimit > 0 else { return }
        var nextRecent = recentToasts
        if let existing = nextRecent.firstIndex(where: { $0.stableKey == toast.stableKey }) {
            nextRecent.remove(at: existing)
        }
        nextRecent.append(toast)
        if nextRecent.count > recentLimit {
            nextRecent.removeFirst(nextRecent.count - recentLimit)
        }
        recentToasts = nextRecent
    }

    private func scheduleExpiry(for toast: Toast, duration: TimeInterval) {
        expiryTasks.removeValue(forKey: toast.id)?.cancel()
        let nanoseconds = Self.expiryNanoseconds(duration)
        expiryTasks[toast.id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expire(toast.id, token: toast.expiryToken)
        }
    }

    private static func stableKey(explicit: String?, message: String, style: Toast.Style) -> String {
        if let explicit, !explicit.isEmpty { return "explicit:\(explicit)" }
        return "automatic:\(style.storageKey):\(message.utf8.count):\(message)"
    }

    private static func expiryNanoseconds(_ duration: TimeInterval) -> UInt64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        // Toasts are transient. The cap also keeps an adversarial finite Double
        // from overflowing the Double-to-UInt64 conversion before Task.sleep.
        let boundedSeconds = min(duration, 24 * 60 * 60)
        return UInt64(boundedSeconds * 1_000_000_000)
    }
}
