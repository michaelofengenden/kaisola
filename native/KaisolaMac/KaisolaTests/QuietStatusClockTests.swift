import XCTest
@testable import Kaisola

final class QuietStatusClockTests: XCTestCase {
    private let wall0 = Date(timeIntervalSince1970: 1_000_000)
    private let continuous0 = ContinuousClock.now

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
        let cases: [(QuietSessionStatus, String)] = [
            (.needsYou, "needs your attention"),
            (.working, "working"),
            (.doneUnseen, "done, awaiting review"),
            (.failed, "failed"),
            (.idle, "idle"),
            (.ended, "ended"),
        ]

        for (status, name) in cases {
            let entry = QuietStatusClock.Entry(
                status: status,
                at: reading(),
                origin: .observedTransition
            )
            let presentation = QuietTimeInStatePresentation.make(
                status: status,
                entry: entry,
                now: reading(wallOffset: 34 * 60, continuousOffset: 34 * 60)
            )

            XCTAssertEqual(presentation.compactLabel, "34m", "status: \(status)")
            XCTAssertEqual(
                presentation.expandedDescription,
                "Current status: \(name). Kaisola observed the status change 34 minutes ago. "
                    + "The value uses continuous elapsed time since that observation, including time asleep; "
                    + "wall-clock changes do not alter it, and it is not active compute time.",
                "status: \(status)"
            )
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
            now: reading(wallOffset: 8 * 3600, continuousOffset: 8 * 3600)
        )

        XCTAssertEqual(presentation.compactLabel, "—")
        XCTAssertEqual(
            presentation.expandedDescription,
            "Current status: working. Kaisola first observed this status when this window began tracking "
                + "the surface, so the transition time is unknown."
        )
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
            "Current status: done, awaiting review. Kaisola first observed this status when this window "
                + "began tracking the surface, so the transition time is unknown."
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
        XCTAssertTrue(presentation.expandedDescription.contains("8 hours ago"))
        XCTAssertTrue(presentation.expandedDescription.contains("including time asleep"))
        XCTAssertTrue(presentation.expandedDescription.contains("continuous elapsed time"))
        XCTAssertTrue(presentation.expandedDescription.contains("not active compute time"))
    }

    func testVeryOldTransitionStaysBoundedAndExpanded() {
        let presentation = transitionPresentation(
            status: .ended,
            wallOffset: 365 * 86_400,
            continuousOffset: 365 * 86_400
        )

        XCTAssertEqual(presentation.compactLabel, "99d+")
        XCTAssertTrue(presentation.expandedDescription.contains("more than 99 days ago"))
    }

    func testRowSemanticsPutExpandedMeaningInTooltipAndAccessibilityValue() {
        let presentation = transitionPresentation(
            status: .working,
            wallOffset: 34 * 60,
            continuousOffset: 34 * 60
        )

        XCTAssertEqual(QuietSurfaceRowSemantics.accessibilityLabel(title: "Build", status: .working), "Build, working")
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
            now: reading(wallOffset: wallOffset, continuousOffset: continuousOffset)
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
