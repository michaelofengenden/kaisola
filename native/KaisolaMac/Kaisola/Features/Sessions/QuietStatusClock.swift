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
    /// The compact slot stops counting here. Beyond this point the exact day
    /// count belongs in the inspectable description, not in the title's lane.
    static let maxDays = 99

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
        case ..<(Double(maxDays + 1) * 86_400): return .days(Int(seconds / 86_400))
        default: return .moreThan99Days
        }
    }

    static func seconds(elapsed: Duration) -> Double {
        let components = elapsed.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Turns the clock reading into the sentence exposed by the tooltip and
/// VoiceOver. Every status has its own verb and transition meaning; all of them
/// use the same continuous elapsed clock.
enum QuietTimeSemantic {
    static let stampThreshold: TimeInterval = 86_400

    static func verb(for status: QuietSessionStatus) -> (word: String, ongoing: Bool) {
        switch status {
        case .working: ("Working", true)
        case .needsYou: ("Waiting for you", true)
        case .idle: ("Idle", true)
        case .doneUnseen: ("Finished", false)
        case .failed: ("Failed", false)
        case .ended: ("Ended", false)
        }
    }

    /// Spelled out rather than abbreviated so assistive technology reads a
    /// duration, while the compact lane remains capped at four glyphs.
    static func spelled(seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        switch seconds {
        case ..<60: return "less than a minute"
        case ..<3600: return count(Int(seconds / 60), "minute")
        case ..<86_400: return count(Int(seconds / 3600), "hour")
        default: return count(Int(seconds / 86_400), "day")
        }
    }

    static func observedPhrase(
        status: QuietSessionStatus,
        seconds: TimeInterval,
        observedAt: Date,
        wallClockChanged: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let verb = verb(for: status)
        let elapsed = spelled(seconds: seconds)
        let headline = verb.ongoing
            ? "\(verb.word) for \(elapsed)"
            : "\(verb.word) \(elapsed) ago"
        var sentence = "\(headline) (\(transitionQualifier(for: status)))."
        sentence += wallClockChanged
            ? " The system wall clock changed during this state, so the value uses continuous elapsed time "
                + "since Kaisola observed the transition. It includes time asleep."
            : " Measured with continuous elapsed time since Kaisola observed the transition, including time asleep; "
                + "wall-clock changes do not alter it."
        if seconds >= stampThreshold, !wallClockChanged {
            sentence += " Counting from \(stamp(observedAt, locale: locale, timeZone: timeZone))."
        }
        return sentence
    }

    /// A first observation is useful as a lower bound, but it is not a status
    /// transition. Keep the compact lane explicitly unknown and put the honest
    /// observation age here where the distinction can be explained.
    static func firstObservationPhrase(
        status: QuietSessionStatus,
        seconds: TimeInterval,
        observedAt: Date,
        wallClockChanged: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let verb = verb(for: status)
        let headline = verb.ongoing
            ? "\(verb.word) for an unknown duration"
            : "\(verb.word) at an unknown time"
        var sentence = "\(headline). Kaisola first observed this status \(spelled(seconds: seconds)) ago, "
            + "but the transition may be older."
        if status == .working {
            sentence += " This is not measured compute time."
        }
        sentence += wallClockChanged
            ? " The system wall clock changed, so the observation age uses continuous elapsed time and includes time asleep."
            : " The observation age uses continuous elapsed time, including time asleep; wall-clock changes do not alter it."
        if seconds >= stampThreshold, !wallClockChanged {
            sentence += " First observed at \(stamp(observedAt, locale: locale, timeZone: timeZone))."
        }
        return sentence
    }

    static func unavailablePhrase(status: QuietSessionStatus) -> String {
        let verb = verb(for: status)
        let headline = verb.ongoing
            ? "\(verb.word) for an unknown duration"
            : "\(verb.word) at an unknown time"
        let computeCaveat = status == .working ? " It is not measured compute time." : ""
        return "\(headline). Kaisola has no matching transition observation for this status; "
            + "the transition time is unknown.\(computeCaveat)"
    }

    static func transitionQualifier(for status: QuietSessionStatus) -> String {
        switch status {
        case .working: return "time since it started working, not measured compute time"
        case .needsYou: return "time since it began waiting for you"
        case .idle: return "time since it became idle"
        case .doneUnseen: return "time since it finished and began awaiting review"
        case .failed: return "time since it failed"
        case .ended: return "time since it ended"
        }
    }

    static func stamp(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func count(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
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
        now: QuietStatusClock.Reading,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> QuietTimeInStatePresentation {
        guard let entry, entry.status == status else {
            return QuietTimeInStatePresentation(
                compactLabel: "—",
                expandedDescription: QuietTimeSemantic.unavailablePhrase(status: status)
            )
        }

        let elapsed = entry.at.continuous.duration(to: now.continuous)
        let age = QuietTimeLabel.age(elapsed: elapsed)
        let seconds = QuietTimeLabel.seconds(elapsed: elapsed)
        guard seconds.isFinite, seconds >= 0 else {
            return QuietTimeInStatePresentation(
                compactLabel: "—",
                expandedDescription: QuietTimeSemantic.unavailablePhrase(status: status)
            )
        }

        let wallElapsed = now.wall.timeIntervalSince(entry.at.wall)
        let wallClockChanged = !wallElapsed.isFinite
            || abs(wallElapsed - seconds) >= 5

        if entry.origin == .firstObservation {
            return QuietTimeInStatePresentation(
                compactLabel: "—",
                expandedDescription: QuietTimeSemantic.firstObservationPhrase(
                    status: status,
                    seconds: seconds,
                    observedAt: entry.at.wall,
                    wallClockChanged: wallClockChanged,
                    locale: locale,
                    timeZone: timeZone
                )
            )
        }

        return QuietTimeInStatePresentation(
            compactLabel: age.compact,
            expandedDescription: QuietTimeSemantic.observedPhrase(
                status: status,
                seconds: seconds,
                observedAt: entry.at.wall,
                wallClockChanged: wallClockChanged,
                locale: locale,
                timeZone: timeZone
            )
        )
    }
}

/// Pure row strings keep the visible tooltip and accessibility contract in
/// lockstep. The compact bucket stays in the visual lane; assistive technology
/// receives the full meaning as AXValue rather than a bare `34m` in AXLabel.
enum QuietSurfaceRowSemantics {
    static func accessibilityLabel(title: String, status: QuietSessionStatus) -> String {
        "\(title), \(status.rowSpeechWord)"
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

    /// Preserve the row's existing spoken status vocabulary while fixing the
    /// old `ended` -> `idle` fallback. Richer time semantics live in AXValue.
    var rowSpeechWord: String {
        switch self {
        case .idle: return "idle"
        case .ended: return "ended"
        case .needsYou, .working, .doneUnseen, .failed:
            return accessibilityWord ?? timeInStateName
        }
    }
}
