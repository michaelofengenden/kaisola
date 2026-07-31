import Foundation

/// When a filesystem event should become a real `git status` run.
///
/// The Git panel used to re-run git on a fixed 3s tick for as long as it was
/// open: late by up to three seconds after an agent staged or committed, and
/// still spawning git forever on a repository nobody was touching. The panel now
/// watches the workspace and the git directory instead, and every event is
/// filtered through this decision:
///
/// - **Debounce.** A burst (an agent rewriting a dozen files, a `git checkout`)
///   is collapsed by waiting `debounce` from the FIRST event of the window. The
///   first event of a burst — not the latest — arms the window, so a continuous
///   stream of writes can never postpone the refresh indefinitely.
/// - **Rate floor.** Two refreshes are never closer than `minimumInterval`, so a
///   long stream of bursts costs at most one `git status` per second.
/// - **Busy.** An operation already holds the service; a refresh started now
///   would be dropped by the model's `isBusy` guard and the event lost with it,
///   so the pending event is kept and re-checked shortly.
///
/// Pure: no clock, no I/O, no state — the caller supplies the timestamps, which
/// is what makes the whole refresh policy unit-testable.
struct GitRefreshPolicy: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        /// Nothing is pending; the driver can stop until the next event.
        case idle
        /// Something is pending but not due yet — re-decide after this delay.
        case wait(TimeInterval)
        /// Run `git status` now.
        case refresh
    }

    /// Trailing debounce from the first event of a burst.
    var debounce: TimeInterval = 0.4

    /// Floor between two consecutive refreshes.
    var minimumInterval: TimeInterval = 1.0

    /// Re-check delay while a git operation is in flight.
    var busyRetry: TimeInterval = 0.2

    func decide(
        pendingEventAt: Date?,
        lastRefreshAt: Date?,
        isBusy: Bool,
        now: Date
    ) -> Decision {
        guard let pendingEventAt else { return .idle }
        guard !isBusy else { return .wait(busyRetry) }

        var wait = remaining(from: pendingEventAt, interval: debounce, now: now)
        if let lastRefreshAt {
            wait = max(wait, remaining(from: lastRefreshAt, interval: minimumInterval, now: now))
        }
        return wait <= 0 ? .refresh : .wait(wait)
    }

    /// Time left on an interval that started at `start`, clamped to the interval
    /// itself: a backwards clock jump (or a future-stamped event) must never park
    /// the panel for hours — the worst case stays one interval.
    private func remaining(from start: Date, interval: TimeInterval, now: Date) -> TimeInterval {
        let left = start.addingTimeInterval(interval).timeIntervalSince(now)
        guard left > 0 else { return 0 }
        return min(left, interval)
    }
}
