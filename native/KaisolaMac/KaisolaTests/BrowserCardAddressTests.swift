import Foundation
import WebKit
import XCTest
@testable import Kaisola

/// The browser card header must name the page on screen, not the link that
/// opened the card. `BrowserCardAddress` holds that decision and the confined
/// web view's coordinator feeds it, so these cover the three ways the document
/// moves out from under a request — a redirect, a history step, and the shell
/// retargeting the card — plus the coordinator wiring that reports them.
@MainActor
final class BrowserCardAddressTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Could not parse URL: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    // MARK: - What the header renders

    func testRequestIsShownUntilADocumentCommits() {
        let address = BrowserCardAddress(requested: url("http://localhost:3000/"))
        XCTAssertEqual(address.displayed, url("http://localhost:3000/"))
    }

    func testRedirectTargetReplacesTheRequestedAddress() {
        var address = BrowserCardAddress(requested: url("http://localhost:3000/"))
        // The dev server bounced / to the sign-in route; the header must not
        // keep claiming /.
        address.commit(url("http://localhost:3000/login?next=%2F"))
        XCTAssertEqual(address.displayed, url("http://localhost:3000/login?next=%2F"))
    }

    func testEveryHistoryStepMovesTheAddress() {
        var address = BrowserCardAddress(requested: url("http://localhost:3000/"))
        address.commit(url("http://localhost:3000/docs"))
        address.commit(url("http://localhost:3000/docs/install"))
        // Back to /docs: a history navigation commits like any other document.
        address.commit(url("http://localhost:3000/docs"))
        XCTAssertEqual(address.displayed, url("http://localhost:3000/docs"))
    }

    func testCommitWithoutAURLKeepsTheAddressOnScreen() {
        var address = BrowserCardAddress(requested: url("http://localhost:3000/"))
        address.commit(url("http://localhost:3000/docs"))
        address.commit(nil)
        XCTAssertEqual(address.displayed, url("http://localhost:3000/docs"))
    }

    func testRetargetShowsTheNewRequestAndDropsTheOldDocument() {
        var address = BrowserCardAddress(requested: url("http://localhost:3000/"))
        address.commit(url("http://localhost:3000/docs"))
        // The user clicked a different localhost link while the card was up.
        address.retarget(to: url("http://localhost:5173/"))
        XCTAssertEqual(address.displayed, url("http://localhost:5173/"))
        // And the retargeted card follows its own navigation from there.
        address.commit(url("http://localhost:5173/board"))
        XCTAssertEqual(address.displayed, url("http://localhost:5173/board"))
    }

    // MARK: - What the web view reports

    /// A coordinator wired to a header address the way `BrowserCardView` wires
    /// it, plus a reader for what the header would render.
    private func wiredCoordinator(
        requested: String
    ) -> (ConfinedWebView.Coordinator, () -> URL) {
        let box = AddressBox(address: BrowserCardAddress(requested: url(requested)))
        let coordinator = ConfinedWebView.Coordinator()
        coordinator.onCommit = { committed in box.address.commit(committed) }
        return (coordinator, { box.address.displayed })
    }

    func testCommittedNavigationReachesTheHeader() {
        let (coordinator, displayed) = wiredCoordinator(requested: "http://localhost:3000/")
        coordinator.navigationCommitted(to: url("http://localhost:3000/login"))
        XCTAssertEqual(displayed(), url("http://localhost:3000/login"))
    }

    func testSameDocumentNavigationReachesTheHeader() {
        let (coordinator, displayed) = wiredCoordinator(requested: "http://localhost:3000/")
        // A router `pushState`: nothing loads, and no navigation callback fires.
        coordinator.addressChangedOutsideNavigation(
            to: url("http://localhost:3000/settings"),
            isLoading: false
        )
        XCTAssertEqual(displayed(), url("http://localhost:3000/settings"))
    }

    func testProvisionalAddressIsNotShownBeforeItCommits() {
        let (coordinator, displayed) = wiredCoordinator(requested: "http://localhost:3000/")
        // `url` moves as soon as a cross-document load goes provisional, and
        // that load can still fail. Only a commit may move the header.
        coordinator.addressChangedOutsideNavigation(
            to: url("http://localhost:3000/report"),
            isLoading: true
        )
        XCTAssertEqual(displayed(), url("http://localhost:3000/"))
    }

    /// WebKit looks its delegate methods up by ObjC selector, and Swift accepts
    /// a near-miss signature as an unrelated method — the policy callback in
    /// `BrowserCardView.swift` carries a comment about exactly that trap. If the
    /// commit callback ever drifts the same way the header silently stops
    /// following navigation, with nothing else to catch it.
    func testCoordinatorAnswersTheSelectorsWebKitCalls() {
        let coordinator = ConfinedWebView.Coordinator()
        XCTAssertTrue(
            coordinator.responds(to: NSSelectorFromString("webView:didCommitNavigation:")),
            "WebKit reports committed navigations through this selector"
        )
        XCTAssertTrue(
            coordinator.responds(
                to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
            ),
            "navigation confinement depends on this selector"
        )
    }
}

/// Reference holder so a test can watch a value-type address the way SwiftUI's
/// `@State` does, without a closure capturing a `var` that outlives the call.
private final class AddressBox {
    var address: BrowserCardAddress

    init(address: BrowserCardAddress) {
        self.address = address
    }
}
