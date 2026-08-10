import XCTest
@testable import Kaisola

final class QuietStatusClockTests: XCTestCase {
    private let wall0 = Date(timeIntervalSince1970: 1_000_000)
    private let continuous0 = ContinuousClock.now
    private let posix = Locale(identifier: "en_US_POSIX")
    private let gmt = TimeZone(secondsFromGMT: 0)!

    func testLabelBuckets() {
        XCTAssertEqual(QuietTimeLabel.label(elapsed: .seconds(30)), "now")
        XCTAssertEqual(QuietTimeLabel.label(elapsed: .seconds(90)), "1m")
        XCTAssertEqual(QuietTimeLabel.label(elapsed: .seconds(34 * 60)), "34m")
        XCTAssertEqual(QuietTimeLabel.label(elapsed: .seconds(2 * 3600 + 300)), "2h")
        XCTAssertEqual(QuietTimeLabel.label(elapsed: .seconds(3 * 86_400)), "3d")
        XCTAssertEqual(QuietTimeLabel.label(elapsed: .seconds(-60)), "—")
        // Keep the compact lane bounded even after a machine wakes from a long
        // sleep or restores a very old session.
        XCTAssertEqual(QuietTimeLabel.label(elapsed: .seconds(365 * 86_400)), "99d+")
    }

    func testClockTracksTransitionsOnly() {
        var clock = QuietStatusClock()
        clock.note(id: "a", status: .working, at: reading())
        clock.note(id: "a", status: .working, at: reading(wallOffset: 60, continuousOffset: 60))
        XCTAssertEqual(clock.entry(id: "a")?.at, reading())
        XCTAssertEqual(clock.entry(id: "a")?.origin, .firstObservation)
        clock.note(id: "a", status: .doneUnseen, at: reading(wallOffset: 120, continuousOffset: 120))
        XCTAssertEqual(clock.entry(id: "a")?.at, reading(wallOffset: 120, continuousOffset: 120))
        XCTAssertEqual(clock.entry(id: "a")?.origin, .observedTransition)
        XCTAssertNil(clock.entry(id: "unknown"))
    }

    func testEveryStatusHasAnExactObservedTransitionSemantic() {
        let cases: [(QuietSessionStatus, String, String)] = [
            (.needsYou, "Waiting for you for 34 minutes", "time since it began waiting for you"),
            (.working, "Working for 34 minutes", "time since it started working"),
            (.doneUnseen, "Finished 34 minutes ago", "time since it finished and began awaiting review"),
            (.failed, "Failed 34 minutes ago", "time since it failed"),
            (.idle, "Idle for 34 minutes", "time since it became idle"),
            (.ended, "Ended 34 minutes ago", "time since it ended"),
        ]

        for (status, headline, qualifier) in cases {
            let entry = QuietStatusClock.Entry(
                status: status,
                at: reading(),
                origin: .observedTransition
            )
            let presentation = QuietTimeInStatePresentation.make(
                status: status,
                entry: entry,
                now: reading(wallOffset: 34 * 60, continuousOffset: 34 * 60),
                locale: posix,
                timeZone: gmt
            )

            XCTAssertEqual(presentation.compactLabel, "34m", "status: \(status)")
            XCTAssertTrue(presentation.expandedDescription.hasPrefix(headline), "status: \(status)")
            XCTAssertTrue(presentation.expandedDescription.contains(qualifier), "status: \(status)")
            XCTAssertTrue(presentation.expandedDescription.contains("continuous elapsed time"), "status: \(status)")
            XCTAssertTrue(presentation.expandedDescription.contains("including time asleep"), "status: \(status)")
        }
    }

    func testFirstObservationAfterRestoreDoesNotInventATransitionTime() {
        let entry = QuietStatusClock.Entry(
            status: .working,
            at: reading(),
            origin: .firstObservation
        )
        let presentation = QuietTimeInStatePresentation.make(
            status: .working,
            entry: entry,
            now: reading(wallOffset: 8 * 3600, continuousOffset: 8 * 3600),
            locale: posix,
            timeZone: gmt
        )

        XCTAssertEqual(presentation.compactLabel, "—")
        XCTAssertTrue(presentation.expandedDescription.hasPrefix("Working for an unknown duration"))
        XCTAssertTrue(presentation.expandedDescription.contains("first observed this status 8 hours ago"))
        XCTAssertTrue(presentation.expandedDescription.contains("transition may be older"))
        XCTAssertTrue(presentation.expandedDescription.contains("not measured compute time"))
        XCTAssertTrue(presentation.expandedDescription.contains("continuous elapsed time"))
    }

    func testStatusChangingBeforeTheClockCallbackDoesNotReuseThePriorStatusAge() {
        let staleEntry = QuietStatusClock.Entry(
            status: .working,
            at: reading(),
            origin: .observedTransition
        )
        let presentation = QuietTimeInStatePresentation.make(
            status: .doneUnseen,
            entry: staleEntry,
            now: reading(wallOffset: 8 * 3600, continuousOffset: 8 * 3600)
        )

        XCTAssertEqual(presentation.compactLabel, "—")
        XCTAssertEqual(
            presentation.expandedDescription,
            "Finished at an unknown time. Kaisola has no matching transition observation for this status; "
                + "the transition time is unknown."
        )
    }

    func testForwardAndBackwardWallClockChangesCannotDistortContinuousAge() {
        let backward = transitionPresentation(
            status: .working,
            wallOffset: -365 * 86_400,
            continuousOffset: 90
        )
        let forward = transitionPresentation(
            status: .working,
            wallOffset: 365 * 86_400,
            continuousOffset: 90
        )

        XCTAssertEqual(backward, forward)
        XCTAssertEqual(backward.compactLabel, "1m")
        XCTAssertTrue(backward.expandedDescription.contains("system wall clock changed"))
        XCTAssertTrue(backward.expandedDescription.contains("uses continuous elapsed time"))
    }

    func testSleepWakeCountsWallClockTimeWithoutClaimingComputeTime() {
        let presentation = transitionPresentation(
            status: .working,
            wallOffset: 8 * 3600,
            continuousOffset: 8 * 3600
        )

        XCTAssertEqual(presentation.compactLabel, "8h")
        XCTAssertTrue(presentation.expandedDescription.contains("Working for 8 hours"))
        XCTAssertTrue(presentation.expandedDescription.contains("including time asleep"))
        XCTAssertTrue(presentation.expandedDescription.contains("continuous elapsed time"))
        XCTAssertTrue(presentation.expandedDescription.contains("not measured compute time"))
    }

    func testVeryOldTransitionStaysBoundedAndExpanded() {
        let presentation = transitionPresentation(
            status: .ended,
            wallOffset: 365 * 86_400,
            continuousOffset: 365 * 86_400
        )

        XCTAssertEqual(presentation.compactLabel, "99d+")
        XCTAssertTrue(presentation.expandedDescription.contains("Ended 365 days ago"))
        XCTAssertTrue(presentation.expandedDescription.contains("Counting from"))
        XCTAssertTrue(presentation.expandedDescription.contains("1970"))
    }

    func testFirstObservationOldStateNamesOnlyTheObservationMoment() {
        let entry = QuietStatusClock.Entry(
            status: .idle,
            at: reading(),
            origin: .firstObservation
        )
        let presentation = QuietTimeInStatePresentation.make(
            status: .idle,
            entry: entry,
            now: reading(wallOffset: 9 * 86_400, continuousOffset: 9 * 86_400),
            locale: posix,
            timeZone: gmt
        )

        XCTAssertEqual(presentation.compactLabel, "—")
        XCTAssertTrue(presentation.expandedDescription.hasPrefix("Idle for an unknown duration"))
        XCTAssertTrue(presentation.expandedDescription.contains("first observed this status 9 days ago"))
        XCTAssertTrue(presentation.expandedDescription.contains("First observed at"))
        XCTAssertFalse(presentation.expandedDescription.contains("Counting from"))
    }

    func testSpelledElapsedIsReadableAloudWithoutCompactCap() {
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 5), "less than a minute")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 60), "1 minute")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 34 * 60), "34 minutes")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 3600), "1 hour")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 5 * 3600), "5 hours")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 86_400), "1 day")
        XCTAssertEqual(QuietTimeSemantic.spelled(seconds: 400 * 86_400), "400 days")
    }

    func testRowSemanticsPutExpandedMeaningInTooltipAndAccessibilityValue() {
        let presentation = transitionPresentation(
            status: .working,
            wallOffset: 34 * 60,
            continuousOffset: 34 * 60
        )

        XCTAssertEqual(QuietSurfaceRowSemantics.accessibilityLabel(title: "Build", status: .working), "Build, working")
        XCTAssertEqual(QuietSurfaceRowSemantics.accessibilityLabel(title: "Build", status: .needsYou), "Build, needs you")
        XCTAssertEqual(QuietSurfaceRowSemantics.accessibilityLabel(title: "Build", status: .doneUnseen), "Build, done")
        XCTAssertEqual(QuietSurfaceRowSemantics.accessibilityLabel(title: "Build", status: .idle), "Build, idle")
        XCTAssertEqual(QuietSurfaceRowSemantics.accessibilityLabel(title: "Build", status: .ended), "Build, ended")
        XCTAssertEqual(QuietSurfaceRowSemantics.accessibilityValue(time: presentation), presentation.expandedDescription)
        XCTAssertEqual(
            QuietSurfaceRowSemantics.tooltip(base: "PID 42 · swift", time: presentation),
            "PID 42 · swift\n\(presentation.expandedDescription)"
        )
        XCTAssertFalse(QuietSurfaceRowSemantics.accessibilityLabel(title: "Build", status: .working).contains("34m"))
    }

    private func transitionPresentation(
        status: QuietSessionStatus,
        wallOffset: TimeInterval,
        continuousOffset: Int64
    ) -> QuietTimeInStatePresentation {
        QuietTimeInStatePresentation.make(
            status: status,
            entry: QuietStatusClock.Entry(
                status: status,
                at: reading(),
                origin: .observedTransition
            ),
            now: reading(wallOffset: wallOffset, continuousOffset: continuousOffset),
            locale: posix,
            timeZone: gmt
        )
    }

    private func reading(
        wallOffset: TimeInterval = 0,
        continuousOffset: Int64 = 0
    ) -> QuietStatusClock.Reading {
        QuietStatusClock.Reading(
            wall: wall0.addingTimeInterval(wallOffset),
            continuous: continuous0.advanced(by: .seconds(continuousOffset))
        )
    }
}
