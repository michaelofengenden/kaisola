import XCTest
@testable import KaisolaMacPreview

final class BrokerReconnectBackoffTests: XCTestCase {
    func testExponentialScheduleCapsAtTheConfiguredMaximum() {
        let policy = BrokerReconnectBackoff(
            baseNanoseconds: 100,
            maximumNanoseconds: 800,
            jitterFraction: 0
        )

        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 0, jitterUnit: 0), 100)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 1, jitterUnit: 0), 200)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 2, jitterUnit: 0), 400)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 3, jitterUnit: 0), 800)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 30, jitterUnit: 0), 800)
    }

    func testJitterIsBoundedAndNeverExceedsTheMaximum() {
        let policy = BrokerReconnectBackoff(
            baseNanoseconds: 1_000,
            maximumNanoseconds: 10_000,
            jitterFraction: 0.2
        )

        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 0, jitterUnit: -1), 800)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 0, jitterUnit: 1), 1_200)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 10, jitterUnit: 1), 10_000)
    }
}
