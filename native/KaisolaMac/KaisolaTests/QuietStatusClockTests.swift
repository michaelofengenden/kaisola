import XCTest
@testable import Kaisola

final class QuietStatusClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let posix = Locale(identifier: "en_US_POSIX")
    private let gmt = TimeZone(secondsFromGMT: 0)!

    func testLabelBuckets() {
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(30)), "now")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(90)), "1m")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(34 * 60)), "34m")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(2 * 3600 + 300)), "2h")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(3 * 86_400)), "3d")
        // clock skew must never render a negative time
        XCTAssertEqual(QuietTimeLabel.label(since: t0.addingTimeInterval(60), now: t0), "now")
    }

    /// A state nobody has touched in years must not widen the time lane past
    /// the title it shares a row with.
    func testVeryOldStatesCapTheCompactLabel() {
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(99 * 86_400)), "99d")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(100 * 86_400)), "99d+")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(4_000 * 86_400)), "99d+")
        XCTAssertLessThanOrEqual(
            QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(9_999 * 86_400)).count,
            4
        )
    }

    func testClockTracksTransitionsOnly() {
        var clock = QuietStatusClock()
        clock.note(id: "a", status: .working, at: t0)
        clock.note(id: "a", status: .working, at: t0.addingTimeInterval(60)) // same state: no reset
        XCTAssertEqual(clock.reading(id: "a")?.at, t0)
        clock.note(id: "a", status: .doneUnseen, at: t0.addingTimeInterval(120)) // transition: reset
        XCTAssertEqual(clock.reading(id: "a")?.at, t0.addingTimeInterval(120))
        XCTAssertNil(clock.reading(id: "unknown"))
    }

    // MARK: Origin

    /// A restored workspace hands the rail sessions that were already idle. The
    /// first sighting is when we started counting, never a transition we saw.
    func testFirstSightingIsNotAnObservedTransition() {
        var clock = QuietStatusClock()
        clock.note(id: "restored", status: .idle, at: t0)
        XCTAssertEqual(clock.reading(id: "restored")?.origin, .firstSeen)
        // Re-notes of the same state must not promote it to observed.
        clock.note(id: "restored", status: .idle, at: t0.addingTimeInterval(600))
        XCTAssertEqual(clock.reading(id: "restored")?.origin, .firstSeen)
        XCTAssertEqual(clock.reading(id: "restored")?.at, t0)
        // Only a real edge is observed.
        clock.note(id: "restored", status: .working, at: t0.addingTimeInterval(900))
        XCTAssertEqual(clock.reading(id: "restored")?.origin, .observed)
    }

    // MARK: Clock changes

    /// A wall clock that moves backwards leaves a stamp in the future, and the
    /// negative-interval clamp then pins the row at "now" until its next
    /// transition. Reconciling re-bases it, and forgets a start we can no
    /// longer name.
    func testReconcilePullsFutureStampsBack() {
        var clock = QuietStatusClock()
        clock.note(id: "a", status: .working, at: t0)
        let rewound = t0.addingTimeInterval(-7200)

        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: rewound), "now")
        XCTAssertTrue(clock.reconcile(now: rewound))
        XCTAssertEqual(clock.reading(id: "a")?.at, rewound)
        XCTAssertEqual(clock.reading(id: "a")?.origin, .firstSeen)
        // The row now counts again from the corrected clock.
        XCTAssertEqual(
            QuietTimeLabel.label(since: clock.reading(id: "a")!.at, now: rewound.addingTimeInterval(300)),
            "5m"
        )
    }

    /// The rail stamps with a live `Date()` and reconciles on a 30s tick, so an
    /// honest entry sits slightly ahead of the tick's instant. That is skew,
    /// not a clock change, and must not reset anybody's timer.
    func testReconcileLeavesOrdinarySkewAlone() {
        var clock = QuietStatusClock()
        clock.note(id: "a", status: .working, at: t0.addingTimeInterval(30))
        XCTAssertFalse(clock.reconcile(now: t0))
        XCTAssertEqual(clock.reading(id: "a")?.at, t0.addingTimeInterval(30))
        XCTAssertEqual(clock.reading(id: "a")?.origin, .firstSeen)
    }

    // MARK: Semantics

    /// One exact meaning per status, and the number behind every one of them is
    /// the same clock: time since the status last changed.
    func testEveryStatusNamesItsOwnTimeSemantic() {
        let cases: [(QuietSessionStatus, String)] = [
            (.working, "Working for 34 minutes"),
            (.needsYou, "Waiting for you for 34 minutes"),
            (.idle, "Idle for 34 minutes"),
            (.doneUnseen, "Finished 34 minutes ago"),
            (.failed, "Failed 34 minutes ago"),
            (.ended, "Ended 34 minutes ago"),
        ]
        for (status, headline) in cases {
            let phrase = QuietTimeSemantic.phrase(
                status: status,
                since: t0,
                now: t0.addingTimeInterval(34 * 60),
                origin: .observed,
                locale: posix,
                timeZone: gmt
            )
            XCTAssertTrue(phrase.hasPrefix(headline), "\(status) said: \(phrase)")
            XCTAssertTrue(
                phrase.contains("time since it started working") || phrase.contains("time since the status last changed"),
                "\(status) never says which clock it read: \(phrase)"
            )
        }
    }

    /// The one status whose number could be mistaken for work done says
    /// outright that it is not. A Mac that slept for two of those hours still
    /// reports them, so this can never be sold as compute.
    func testWorkingDoesNotClaimComputeTime() {
        let phrase = QuietTimeSemantic.phrase(
            status: .working,
            since: t0,
            now: t0.addingTimeInterval(3 * 3600),
            origin: .observed,
            locale: posix,
            timeZone: gmt
        )
        XCTAssertTrue(phrase.contains("not measured compute time"), phrase)
        XCTAssertFalse(phrase.lowercased().contains("spent"), phrase)
    }

    /// A state we never saw begin is a lower bound, and says so.
    func testFirstSeenStatesReadAsALowerBound() {
        let phrase = QuietTimeSemantic.phrase(
            status: .idle,
            since: t0,
            now: t0.addingTimeInterval(2 * 3600),
            origin: .firstSeen,
            locale: posix,
            timeZone: gmt
        )
        XCTAssertTrue(phrase.hasPrefix("Idle for at least 2 hours"), phrase)
        XCTAssertTrue(phrase.contains("Kaisola first saw this session"), phrase)

        // "at least less than a minute" is not a sentence.
        let fresh = QuietTimeSemantic.phrase(
            status: .idle,
            since: t0,
            now: t0.addingTimeInterval(5),
            origin: .firstSeen,
            locale: posix,
            timeZone: gmt
        )
        XCTAssertEqual(fresh, "Idle for less than a minute (counted from when Kaisola first saw this session, so the state may be older).")
    }

    /// Past a day the relative phrase stops being inspectable, so the sentence
    /// names the moment it is counting from.
    func testOldStatesNameTheMomentTheyCountFrom() {
        let recent = QuietTimeSemantic.phrase(
            status: .idle,
            since: t0,
            now: t0.addingTimeInterval(6 * 3600),
            origin: .observed,
            locale: posix,
            timeZone: gmt
        )
        XCTAssertFalse(recent.contains("Counting from"), recent)

        let old = QuietTimeSemantic.phrase(
            status: .idle,
            since: t0,
            now: t0.addingTimeInterval(9 * 86_400),
            origin: .observed,
            locale: posix,
            timeZone: gmt
        )
        XCTAssertTrue(old.hasPrefix("Idle for 9 days"), old)
        XCTAssertTrue(old.contains("Counting from"), old)
        // 1970-01-12 13:46:40 GMT
        XCTAssertTrue(old.contains("1970"), old)
        XCTAssertTrue(old.contains("12"), old)
    }

    func testSpelledElapsedIsReadableAloud() {
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 5), "less than a minute")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 60), "1 minute")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 34 * 60), "34 minutes")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 3600), "1 hour")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 5 * 3600), "5 hours")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 86_400), "1 day")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 400 * 86_400), "400 days")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: -90), "less than a minute")
    }

    // MARK: Row speech

    /// The bare time left the row's NAME for its VALUE, spelled out. An ended
    /// session also stopped introducing itself as merely idle.
    func testRowLabelCarriesNameAndStateOnly() {
        XCTAssertEqual(QuietRowSpeech.label(title: "api", status: .working), "api, working")
        XCTAssertEqual(QuietRowSpeech.label(title: "api", status: .idle), "api, idle")
        XCTAssertEqual(QuietRowSpeech.label(title: "api", status: .ended), "api, ended")
        XCTAssertEqual(QuietRowSpeech.label(title: "api", status: .doneUnseen), "api, done")
        XCTAssertEqual(QuietRowSpeech.label(title: "api", status: .needsYou), "api, needs you")
        XCTAssertEqual(QuietRowSpeech.label(title: "api", status: .failed), "api, failed")
        // Name and state, and nothing else: no third component, and no status
        // left to speak as an empty string.
        for status: QuietSessionStatus in [.needsYou, .working, .doneUnseen, .failed, .idle, .ended] {
            let parts = QuietRowSpeech.label(title: "api", status: status).components(separatedBy: ", ")
            XCTAssertEqual(parts.count, 2, "\(status)")
            XCTAssertFalse(parts[1].isEmpty, "\(status)")
        }
    }

    func testTooltipKeepsDetailsAndAddsTheTimeSentence() {
        let time = QuietTimeSemantic.phrase(
            status: .doneUnseen,
            since: t0,
            now: t0.addingTimeInterval(15 * 60),
            origin: .observed,
            locale: posix,
            timeZone: gmt
        )
        let tooltip = QuietRowSpeech.tooltip(details: "PID 42 · ⎇ main", time: time)
        XCTAssertEqual(tooltip, "PID 42 · ⎇ main\nFinished 15 minutes ago (time since the status last changed).")
        // A surface the clock has not stamped yet leaves no dangling separator.
        XCTAssertEqual(QuietRowSpeech.tooltip(details: "PID 42", time: ""), "PID 42")
        XCTAssertEqual(QuietRowSpeech.tooltip(details: "", time: time), time)
    }
}
