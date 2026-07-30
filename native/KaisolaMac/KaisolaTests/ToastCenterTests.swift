import XCTest
@testable import Kaisola

/// The toast queue: appending, the 3-visible FIFO cap, explicit dismissal, and
/// duration-driven auto-expiry. `ToastCenter.shared` is a singleton, so each
/// test starts from a cleared queue; the non-expiry cases use a long duration
/// so their timers can never fire mid-suite.
@MainActor
final class ToastCenterTests: XCTestCase {
    override func setUp() async throws {
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
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
}
