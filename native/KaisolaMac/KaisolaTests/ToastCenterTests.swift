import XCTest
@testable import Kaisola

/// The toast queue: appending, the 3-visible severity-aware cap, coalescing,
/// explicit dismissal, and duration-driven auto-expiry. `ToastCenter.shared`
/// is a singleton, so each test starts from a cleared queue; the non-expiry
/// cases use a long duration so their timers can never fire mid-suite.
@MainActor
final class ToastCenterTests: XCTestCase {
    override func setUp() async throws {
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        ToastCenter.shared.clearRecent()
    }

    func testShowAppendsToast() {
        let center = ToastCenter.shared
        center.show("Hello", duration: 100)
        XCTAssertEqual(center.toasts.count, 1)
        XCTAssertEqual(center.toasts.first?.message, "Hello")
        XCTAssertEqual(center.toasts.first?.style, .info)
    }

    func testMaxThreeEvictsOldest() {
        let center = ToastCenter.shared
        center.show("one", duration: 100)
        center.show("two", duration: 100)
        center.show("three", duration: 100)
        center.show("four", duration: 100)
        XCTAssertEqual(center.toasts.count, 3)
        XCTAssertEqual(center.toasts.map(\.message), ["two", "three", "four"])
    }

    func testDismissRemovesToast() {
        let center = ToastCenter.shared
        center.show("bye", duration: 100)
        guard let id = center.toasts.first?.id else {
            return XCTFail("expected a toast to have been appended")
        }
        center.dismiss(id)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testAutoExpiryRemovesAfterDuration() async throws {
        let center = ToastCenter.shared
        center.show("temporary", style: .success, duration: 0.05)
        XCTAssertEqual(center.toasts.count, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testRepeatedIdenticalEventsCoalesceByDefaultStableKey() {
        let center = ToastCenter.shared

        center.show("Build finished", style: .success, duration: 100)
        let firstAnnouncement = center.toasts.first?.announcementToken
        center.show("Build finished", style: .success, duration: 100)

        XCTAssertEqual(center.toasts.count, 1)
        XCTAssertEqual(center.toasts.first?.message, "Build finished")
        XCTAssertEqual(center.toasts.first?.occurrenceCount, 2)
        XCTAssertEqual(center.toasts.first?.announcementToken, firstAnnouncement)
        XCTAssertEqual(center.recentToasts.count, 1)
        XCTAssertEqual(center.recentToasts.first?.occurrenceCount, 2)
    }

    func testExplicitStableKeyUpdatesContentAndNeverDowngradesCriticalStyle() {
        let center = ToastCenter.shared

        center.show("Reconnect pending", style: .error, duration: 100, key: "broker-reconnect")
        let originalID = center.toasts.first?.id
        let originalAnnouncement = center.toasts.first?.announcementToken
        center.show("Reconnect retrying", style: .info, duration: 100, key: "broker-reconnect")

        XCTAssertEqual(center.toasts.count, 1)
        XCTAssertEqual(center.toasts.first?.id, originalID)
        XCTAssertEqual(center.toasts.first?.message, "Reconnect retrying")
        XCTAssertEqual(center.toasts.first?.style, .error)
        XCTAssertEqual(center.toasts.first?.occurrenceCount, 2)
        XCTAssertNotEqual(center.toasts.first?.announcementToken, originalAnnouncement)
    }

    func testMixedSeverityBurstEvictsNoncriticalBeforeCritical() {
        let center = ToastCenter.shared
        center.show("first info", duration: 100)
        center.show("permission failed", style: .error, duration: 100)
        center.show("saved", style: .success, duration: 100)

        center.show("new info", duration: 100)

        XCTAssertEqual(
            center.toasts.map(\.message),
            ["permission failed", "saved", "new info"]
        )
        XCTAssertTrue(center.toasts.contains { $0.message == "permission failed" })
    }

    func testNoncriticalBurstCannotDisplaceAnAllCriticalStack() {
        let center = ToastCenter.shared
        center.show("critical one", style: .error, duration: 100)
        center.show("critical two", style: .error, duration: 100)
        center.show("critical three", style: .error, duration: 100)

        center.show("routine update", duration: 100)

        XCTAssertEqual(
            center.toasts.map(\.message),
            ["critical one", "critical two", "critical three"]
        )
        XCTAssertEqual(center.recentToasts.last?.message, "routine update")
    }

    func testCriticalBurstStaysBoundedByEvictingTheOldestCriticalNotice() {
        let center = ToastCenter.shared
        center.show("critical one", style: .error, duration: 100)
        center.show("critical two", style: .error, duration: 100)
        center.show("critical three", style: .error, duration: 100)

        center.show("critical four", style: .error, duration: 100)

        XCTAssertEqual(
            center.toasts.map(\.message),
            ["critical two", "critical three", "critical four"]
        )
        XCTAssertEqual(center.toasts.count, ToastCenter.maxVisible)
    }

    func testRenewedToastRejectsItsStaleExpiryToken() {
        let center = ToastCenter.shared
        center.show("first state", duration: 100, key: "stable-operation")
        let first = center.toasts[0]

        center.show("renewed state", duration: 100, key: "stable-operation")
        let renewed = center.toasts[0]
        XCTAssertEqual(renewed.id, first.id)
        XCTAssertNotEqual(renewed.expiryToken, first.expiryToken)

        center.expire(first.id, token: first.expiryToken)
        XCTAssertEqual(center.toasts.map(\.message), ["renewed state"])

        center.expire(renewed.id, token: renewed.expiryToken)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testRecentNoticeLogIsBoundedAndSurvivesDismissal() {
        let center = ToastCenter(maxVisible: 2, recentLimit: 2)
        center.show("one", duration: 100)
        center.show("two", duration: 100)
        center.show("three", duration: 100)

        XCTAssertEqual(center.recentToasts.map(\.message), ["two", "three"])
        XCTAssertEqual(center.toasts.map(\.message), ["two", "three"])

        for toast in center.toasts { center.dismiss(toast.id) }
        XCTAssertTrue(center.toasts.isEmpty)
        XCTAssertEqual(center.recentToasts.map(\.message), ["two", "three"])
    }

    func testAccessibilityNamesRepeatCountAndDismissalAction() {
        let center = ToastCenter.shared
        center.show("Build failed", style: .error, duration: 100)
        center.show("Build failed", style: .error, duration: 100)
        let toast = center.toasts[0]

        XCTAssertEqual(
            ToastAccessibility.label(for: toast),
            "Build failed, repeated 2 times"
        )
        XCTAssertEqual(ToastAccessibility.dismissActionName, "Dismiss notification")
    }
}
