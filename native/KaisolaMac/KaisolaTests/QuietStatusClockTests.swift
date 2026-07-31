import XCTest
@testable import Kaisola

final class QuietStatusClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLabelBuckets() {
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(30)), "now")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(90)), "1m")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(34 * 60)), "34m")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(2 * 3600 + 300)), "2h")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(3 * 86_400)), "3d")
        // clock skew must never render a negative time
        XCTAssertEqual(QuietTimeLabel.label(since: t0.addingTimeInterval(60), now: t0), "now")
    }

    func testClockTracksTransitionsOnly() {
        var clock = QuietStatusClock()
        clock.note(id: "a", status: .working, at: t0)
        clock.note(id: "a", status: .working, at: t0.addingTimeInterval(60)) // same state: no reset
        XCTAssertEqual(clock.since(id: "a"), t0)
        clock.note(id: "a", status: .doneUnseen, at: t0.addingTimeInterval(120)) // transition: reset
        XCTAssertEqual(clock.since(id: "a"), t0.addingTimeInterval(120))
        XCTAssertNil(clock.since(id: "unknown"))
    }
}
