import Foundation

/// Remembers when each surface last CHANGED status, so rows can show
/// time-in-state ("working for 34m"), not time-since-creation.
///
/// Every number the rail prints in a row's time slot comes from here and means
/// exactly one thing: how long ago that surface's *status* last changed. It is
/// never a measurement of how long an agent has been computing — the rail has
/// no compute clock, and a row that sat through a sleep, a reconnect or a
/// relaunch would overstate one badly. `QuietTimeSemantic` turns that single
/// rule into the words the tooltip and VoiceOver read out.
struct QuietStatusClock {
    /// Where a stamp came from, which is the difference between "this went idle
    /// two hours ago" and "it was already idle when we first looked two hours
    /// ago". Only the first is a fact about the session.
    enum Origin: Equatable {
        /// Kaisola watched this surface leave one status and enter another, so
        /// the stamp is the transition itself.
        case observed
        /// The status was already in place the first time Kaisola saw the
        /// surface: app launch, a restored workspace, an adopted terminal, or a
        /// project expanded for the first time. The real transition happened at
        /// some unknown earlier moment, so the elapsed time is a lower bound.
        case firstSeen
    }

    struct Reading: Equatable {
        let status: QuietSessionStatus
        let at: Date
        let origin: Origin
    }

    /// A stamp further ahead of `now` than this is not skew, it is a clock that
    /// moved. Comfortably above the rail's 30s tick, because `note` stamps with
    /// the live `Date()` while `reconcile` is handed the tick's older instant,
    /// so an honest entry can legitimately sit a tick in the "future".
    static let futureTolerance: TimeInterval = 120

    private var entries: [String: Reading] = [:]

    mutating func note(id: String, status: QuietSessionStatus, at: Date) {
        guard let existing = entries[id] else {
            // First sighting. We did not see the transition, so this is when we
            // started counting rather than when the state began.
            entries[id] = Reading(status: status, at: at, origin: .firstSeen)
            return
        }
        guard existing.status != status else { return }
        entries[id] = Reading(status: status, at: at, origin: .observed)
    }

    func reading(id: String) -> Reading? { entries[id] }

    /// Pulls stamps that sit in the future back to `now`.
    ///
    /// A wall clock can move backwards — a manual change, an NTP correction, a
    /// Mac waking with a stale RTC — and `QuietTimeLabel` clamps the negative
    /// interval that produces to "now". Without this the clamp is permanent:
    /// the row reads "now" until its next transition, however long that takes.
    /// The re-stamped entry drops to `.firstSeen`, because whatever the true
    /// transition time was, it is no longer something we can name.
    ///
    /// - Returns: whether anything was re-stamped.
    @discardableResult
    mutating func reconcile(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(Self.futureTolerance)
        var changed = false
        for (id, reading) in entries where reading.at > cutoff {
            entries[id] = Reading(status: reading.status, at: now, origin: .firstSeen)
            changed = true
        }
        return changed
    }
}

enum QuietTimeLabel {
    /// The compact slot stops counting here. Past three months the exact day
    /// count is noise, and a five-glyph "1024d" eats the width the title needs;
    /// the tooltip carries the real date for anyone who wants it.
    static let maxDays = 99

    static func label(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default:
            let days = Int(seconds / 86_400)
            return days > maxDays ? "\(maxDays)d+" : "\(days)d"
        }
    }
}

/// What a row's time value MEANS, in words.
///
/// The compact label is four characters wide, so it can only ever be a number.
/// Which of several plausible clocks it is a number from — the session's age,
/// the last output, the last status change, the length of the current task —
/// was not written down anywhere the user could reach. It is the last of those,
/// always, for every status; this is where that gets said out loud.
///
/// The verb changes per status, the clock does not:
///
/// | status     | reads as                | means                          |
/// |------------|-------------------------|--------------------------------|
/// | working    | "Working for 34m"       | entered `working` 34m ago      |
/// | needsYou   | "Waiting for you for …" | asked for you then             |
/// | doneUnseen | "Finished 34m ago"      | finished then, still unseen    |
/// | failed     | "Failed 34m ago"        | failed then                    |
/// | idle       | "Idle for 34m"          | went quiet then                |
/// | ended      | "Ended 34m ago"         | the process ended then         |
///
/// Two qualifiers ride along. A `.firstSeen` stamp says "at least", because the
/// state predates our watching it. And `working` names what it is not: a
/// 34-minute-old `working` stamp is 34 minutes of wall clock, which includes
/// any time the Mac spent asleep, so it must never be read as 34 minutes of
/// compute.
enum QuietTimeSemantic {
    /// Beyond a day the relative phrase alone stops being inspectable ("3d"
    /// could be any of 72 hours), so the phrase names the moment outright.
    static let stampThreshold: TimeInterval = 86_400

    /// The verb, and whether the state is a condition you are still in ("for
    /// 34m") or an event that happened ("34m ago").
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

    /// Elapsed time spelled out. VoiceOver reads "34m" as a letter; it reads
    /// "34 minutes" as a duration, and the tooltip is prose either way.
    static func spelled(seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        switch seconds {
        case ..<60: return "less than a minute"
        case ..<3600: return count(Int(seconds / 60), "minute")
        case ..<86_400: return count(Int(seconds / 3600), "hour")
        default: return count(Int(seconds / 86_400), "day")
        }
    }

    /// The whole sentence: state, elapsed time, and what that time is measured
    /// from. Old states also name the moment they are counted from.
    static func phrase(
        status: QuietSessionStatus,
        since: Date,
        now: Date,
        origin: QuietStatusClock.Origin,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        let verb = verb(for: status)
        let elapsed = spelled(seconds: seconds)
        // "at least less than a minute" is not a sentence, and a sub-minute
        // state is not one anybody needs hedged.
        let hedge = origin == .firstSeen && seconds >= 60 ? "at least " : ""
        let headline = verb.ongoing
            ? "\(verb.word) for \(hedge)\(elapsed)"
            : "\(verb.word) \(hedge)\(elapsed) ago"
        var sentence = "\(headline) (\(qualifier(status: status, origin: origin)))."
        if seconds >= stampThreshold {
            sentence += " Counting from \(stamp(since, locale: locale, timeZone: timeZone))."
        }
        return sentence
    }

    /// The parenthetical that answers "which clock is this?".
    static func qualifier(status: QuietSessionStatus, origin: QuietStatusClock.Origin) -> String {
        switch origin {
        case .firstSeen:
            return "counted from when Kaisola first saw this session, so the state may be older"
        case .observed:
            // The only status whose number could be mistaken for a measurement
            // of work done says plainly that it is not one.
            return status == .working
                ? "time since it started working, not measured compute time"
                : "time since the status last changed"
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

/// What a surface row says when it is asked, rather than looked at: its
/// VoiceOver label, and the tooltip under the pointer.
///
/// Pure and separate from the row view so both are testable — the row itself is
/// a private SwiftUI struct, and a label no test can reach is a label that
/// quietly rots.
enum QuietRowSpeech {
    /// Name and state. The bare "34m" used to ride here as a third component,
    /// which spoke a number with no unit and no meaning; it moved to the value,
    /// spelled out, as a full sentence.
    static func label(title: String, status: QuietSessionStatus) -> String {
        [title, word(for: status)].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Every status has a word here, including the two that draw no dot.
    /// `accessibilityWord` returns nil for idle and ended because the *rollup*
    /// must not count silent states, and the row used to spend that nil as
    /// `?? "idle"` — which announced a dead session as merely quiet.
    static func word(for status: QuietSessionStatus) -> String {
        switch status {
        case .idle: "idle"
        case .ended: "ended"
        case .needsYou, .working, .doneUnseen, .failed: status.accessibilityWord ?? ""
        }
    }

    /// The row's tooltip: the surface's own details (PID, branch, process),
    /// then the time sentence on its own line so the chips stay chips.
    static func tooltip(details: String, time: String) -> String {
        [details, time].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
