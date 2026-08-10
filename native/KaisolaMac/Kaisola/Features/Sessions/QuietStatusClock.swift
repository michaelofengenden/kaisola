import Foundation

/// Remembers when this window OBSERVED each surface change status.
///
/// The distinction matters: the broker does not persist a transition timestamp
/// for every derived rail status. The first status seen after launch/restore is
/// therefore marked as `.firstObservation`; treating that observation time as
/// the beginning of the state would invent a duration. Only a later change
/// observed by this live clock has a known start within this window.
struct QuietStatusClock {
    /// Wall time is retained for diagnostics, while elapsed age is measured
    /// exclusively from `continuous`. Swift's continuous clock advances while
    /// the Mac sleeps and is not adjusted by wall-clock corrections.
    struct Reading: Equatable {
        let wall: Date
        let continuous: ContinuousClock.Instant

        static var now: Reading {
            Reading(wall: Date(), continuous: ContinuousClock.now)
        }
    }

    struct Entry: Equatable {
        enum Origin: Equatable {
            case firstObservation
            case observedTransition
        }

        let status: QuietSessionStatus
        let at: Reading
        let origin: Origin
    }

    private var entries: [String: Entry] = [:]

    mutating func note(id: String, status: QuietSessionStatus, at: Reading) {
        guard let previous = entries[id] else {
            entries[id] = Entry(status: status, at: at, origin: .firstObservation)
            return
        }
        if previous.status != status {
            entries[id] = Entry(status: status, at: at, origin: .observedTransition)
        }
    }

    func entry(id: String) -> Entry? { entries[id] }
}

/// The deliberately tiny rail label. Values are continuous-time age buckets, not
/// session age, task duration, time since output, or active compute time. Ages
/// over 99 days are capped so the sidebar lane cannot keep widening.
enum QuietTimeLabel {
    enum Age: Equatable {
        case unavailable
        case lessThanMinute
        case minutes(Int)
        case hours(Int)
        case days(Int)
        case moreThan99Days

        var compact: String {
            switch self {
            case .unavailable: return "—"
            case .lessThanMinute: return "now"
            case .minutes(let value): return "\(value)m"
            case .hours(let value): return "\(value)h"
            case .days(let value): return "\(value)d"
            case .moreThan99Days: return "99d+"
            }
        }

        var expanded: String? {
            switch self {
            case .unavailable: return nil
            case .lessThanMinute: return "less than a minute"
            case .minutes(1): return "1 minute"
            case .minutes(let value): return "\(value) minutes"
            case .hours(1): return "1 hour"
            case .hours(let value): return "\(value) hours"
            case .days(1): return "1 day"
            case .days(let value): return "\(value) days"
            case .moreThan99Days: return "more than 99 days"
            }
        }
    }

    static func label(elapsed: Duration) -> String {
        age(elapsed: elapsed).compact
    }

    static func age(elapsed: Duration) -> Age {
        let seconds = seconds(elapsed: elapsed)
        guard seconds.isFinite, seconds >= 0 else { return .unavailable }
        switch seconds {
        case ..<60: return .lessThanMinute
        case ..<3600: return .minutes(Int(seconds / 60))
        case ..<86_400: return .hours(Int(seconds / 3600))
        case ..<(100 * 86_400): return .days(Int(seconds / 86_400))
        default: return .moreThan99Days
        }
    }

    static func seconds(elapsed: Duration) -> Double {
        let components = elapsed.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// The inspectable meaning paired with a compact rail label.
///
/// A known value is continuous elapsed time since this window observed the
/// derived status change. It intentionally includes time asleep, ignores wall
/// clock corrections, and does not claim the agent computed throughout that
/// interval. An initial/restored state has no value because its actual
/// transition cannot be recovered from the first sample.
struct QuietTimeInStatePresentation: Equatable {
    let compactLabel: String
    let expandedDescription: String

    static func make(
        status: QuietSessionStatus,
        entry: QuietStatusClock.Entry?,
        now: QuietStatusClock.Reading
    ) -> QuietTimeInStatePresentation {
        let statusName = status.timeInStateName
        guard let entry,
              entry.status == status,
              entry.origin == .observedTransition else {
            return QuietTimeInStatePresentation(
                compactLabel: "—",
                expandedDescription: "Current status: \(statusName). Kaisola first observed this status when this "
                    + "window began tracking the surface, so the transition time is unknown."
            )
        }

        let elapsed = entry.at.continuous.duration(to: now.continuous)
        let age = QuietTimeLabel.age(elapsed: elapsed)
        guard let expandedAge = age.expanded else {
            return QuietTimeInStatePresentation(
                compactLabel: age.compact,
                expandedDescription: "Current status: \(statusName). Continuous elapsed time since Kaisola observed "
                    + "the status change is unavailable."
            )
        }

        let wallElapsed = now.wall.timeIntervalSince(entry.at.wall)
        let continuousElapsed = QuietTimeLabel.seconds(elapsed: elapsed)
        let wallClockChanged = !wallElapsed.isFinite
            || abs(wallElapsed - continuousElapsed) >= 5
        let meaning = wallClockChanged
            ? "The system wall clock changed during this state, so the value uses continuous elapsed time "
                + "since that observation. It includes time asleep and is not active compute time."
            : "The value uses continuous elapsed time since that observation, including time asleep; "
                + "wall-clock changes do not alter it, and it is not active compute time."

        return QuietTimeInStatePresentation(
            compactLabel: age.compact,
            expandedDescription: "Current status: \(statusName). Kaisola observed the status change \(expandedAge) ago. "
                + meaning
        )
    }
}

/// Pure row strings keep the visible tooltip and accessibility contract in
/// lockstep. The compact bucket stays in the visual lane; assistive technology
/// receives the full meaning as AXValue rather than a bare `34m` in AXLabel.
enum QuietSurfaceRowSemantics {
    static func accessibilityLabel(title: String, status: QuietSessionStatus) -> String {
        "\(title), \(status.timeInStateName)"
    }

    static func accessibilityValue(time: QuietTimeInStatePresentation) -> String {
        time.expandedDescription
    }

    static func tooltip(base: String, time: QuietTimeInStatePresentation) -> String {
        [base, time.expandedDescription]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private extension QuietSessionStatus {
    /// Status-specific vocabulary for the time-in-state explanation. Every
    /// case is explicit, including silent `.idle` and `.ended` states.
    var timeInStateName: String {
        switch self {
        case .needsYou: return "needs your attention"
        case .working: return "working"
        case .doneUnseen: return "done, awaiting review"
        case .failed: return "failed"
        case .idle: return "idle"
        case .ended: return "ended"
        }
    }
}
