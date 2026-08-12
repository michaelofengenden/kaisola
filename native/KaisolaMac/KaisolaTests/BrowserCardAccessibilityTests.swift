import Foundation
import XCTest
@testable import Kaisola

/// The browser card's reload and close controls are image-only, so the strings
/// pinned here are the only thing between a VoiceOver user and "arrow
/// clockwise, button" with no hint of which page it reloads. The card can also
/// sit on a dev server that never came up, so every load state has to be
/// reachable in the header's accessibility tree.
@MainActor
final class BrowserCardAccessibilityTests: XCTestCase {
    private func accessibility(
        _ string: String = "http://localhost:3000/dashboard?tab=logs",
        state: BrowserCardLoadState = .finished
    ) throws -> BrowserCardAccessibility {
        let url = try XCTUnwrap(URL(string: string), "Could not parse URL: \(string)")
        return BrowserCardAccessibility(url: url, state: state)
    }

    func testImageOnlyActionsNameBothTheActionAndTheAddress() throws {
        let header = try accessibility()
        XCTAssertEqual(header.reloadLabel, "Reload localhost:3000")
        XCTAssertEqual(header.closeLabel, "Close browser card for localhost:3000")
        // The visible title has to stay at the front of the label, otherwise
        // Voice Control can no longer address the button by what it reads.
        XCTAssertTrue(
            header.openExternallyLabel.hasPrefix("Open in Browser"),
            "a labelled button must keep its visible title: \(header.openExternallyLabel)"
        )
        XCTAssertTrue(header.openExternallyLabel.contains("localhost:3000"))
    }

    func testSpokenAddressIsTheHostAndPortNotTheWholeURL() throws {
        XCTAssertEqual(try accessibility("http://localhost:3000/a/b?c=d").address, "localhost:3000")
        XCTAssertEqual(try accessibility("http://127.0.0.1:5173/").address, "127.0.0.1:5173")
        // A default port is not in the URL, so it is not in the announcement.
        XCTAssertEqual(try accessibility("https://localhost").address, "localhost")
        // IPv6 keeps its brackets or the port runs into the address.
        XCTAssertEqual(try accessibility("http://[::1]:8080/").address, "[::1]:8080")
        // Nothing host-shaped to shorten: say the whole thing rather than nothing.
        XCTAssertEqual(try accessibility("about:blank").address, "about:blank")
    }

    func testEveryLoadStateIsReachableInTheHeader() throws {
        let provisional = try accessibility(state: .provisional)
        XCTAssertEqual(
            provisional.addressValue,
            "http://localhost:3000/dashboard?tab=logs, Connecting"
        )
        XCTAssertEqual(
            provisional.statusIndicatorLabel,
            "Connecting to localhost:3000"
        )

        let committed = try accessibility(state: .committed)
        XCTAssertEqual(
            committed.addressValue,
            "http://localhost:3000/dashboard?tab=logs, Loading"
        )
        XCTAssertEqual(committed.statusIndicatorLabel, "Loading localhost:3000")

        let finished = try accessibility(state: .finished)
        XCTAssertEqual(
            finished.addressValue,
            "http://localhost:3000/dashboard?tab=logs, Loaded"
        )
        XCTAssertNil(
            finished.statusIndicatorLabel,
            "a page that is up needs no status badge to swipe past"
        )

        let failed = try accessibility(state: .failed("Could not connect to the server."))
        XCTAssertEqual(
            failed.addressValue,
            "http://localhost:3000/dashboard?tab=logs, Failed to load: Could not connect to the server."
        )
        XCTAssertEqual(
            failed.statusIndicatorLabel,
            "localhost:3000 failed to load: Could not connect to the server."
        )
    }

    func testFailureKeepsDetailAndAnInCardRetryActionReachable() throws {
        let failed = try accessibility(
            "http://localhost:3000/dashboard",
            state: .failed("The server stopped accepting connections.")
        )

        XCTAssertEqual(failed.failureTitle, "Couldn’t load localhost:3000")
        XCTAssertEqual(failed.failureDetail, "The server stopped accepting connections.")
        XCTAssertEqual(failed.retryLabel, "Retry loading localhost:3000")
        XCTAssertTrue(failed.state.isFailure)

        let finished = try accessibility(state: .finished)
        XCTAssertNil(finished.failureTitle)
        XCTAssertNil(finished.failureDetail)
        XCTAssertFalse(finished.state.isFailure)
    }

    func testAddressValueCarriesTheFullURLTheLabelReplaces() throws {
        // The header labels the address element "Address", which drops its
        // visible text from the tree; the value has to carry the URL back.
        let header = try accessibility("http://localhost:4321/orders/42")
        XCTAssertTrue(
            header.addressValue.hasPrefix("http://localhost:4321/orders/42"),
            "address value lost the current address: \(header.addressValue)"
        )
    }

    func testActionNamesDoNotChangeWithLoadState() throws {
        for state in [
            BrowserCardLoadState.provisional,
            .committed,
            .finished,
            .failed("boom"),
        ] {
            let header = try accessibility(state: state)
            XCTAssertEqual(header.reloadLabel, "Reload localhost:3000", "state: \(state)")
            XCTAssertEqual(
                header.closeLabel,
                "Close browser card for localhost:3000",
                "state: \(state)"
            )
        }
    }

    func testSupersededNavigationIsNotAnnouncedAsAFailure() {
        // WebKit cancels the load in flight on every reload and retarget.
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertNil(BrowserCardLoadState.failure(for: cancelled))

        let refused = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."]
        )
        XCTAssertEqual(
            BrowserCardLoadState.failure(for: refused),
            .failed("Could not connect to the server.")
        )
    }

    // MARK: - Current address

    func testCommittedRedirectReplacesTheRequestedAddressEverywhere() throws {
        var address = BrowserCardAddressState(
            requestedURL: try url("http://localhost:3000/start")
        )

        address.commit(try url("http://localhost:3000/dashboard?from=redirect"))

        XCTAssertEqual(
            address.currentURL,
            try url("http://localhost:3000/dashboard?from=redirect")
        )
        let accessibility = BrowserCardAccessibility(url: address.currentURL, state: .finished)
        XCTAssertEqual(
            accessibility.addressValue,
            "http://localhost:3000/dashboard?from=redirect, Loaded"
        )
        XCTAssertEqual(accessibility.openExternallyLabel, "Open in Browser, localhost:3000")
    }

    func testCommittedHistoryNavigationTracksBothDirections() throws {
        var address = BrowserCardAddressState(
            requestedURL: try url("http://localhost:3000/first")
        )

        address.commit(try url("http://localhost:3000/second"))
        XCTAssertEqual(address.currentURL, try url("http://localhost:3000/second"))

        address.commit(try url("http://localhost:3000/first"))
        XCTAssertEqual(address.currentURL, try url("http://localhost:3000/first"))
    }

    func testRetargetReplacesPriorNavigationAndMissingCommitCannotRollItBack() throws {
        var address = BrowserCardAddressState(
            requestedURL: try url("http://localhost:3000/first")
        )
        address.commit(try url("http://localhost:3000/first/deep-link"))

        let retargeted = try url("http://admin.localhost:4400/new-root")
        address.retarget(to: retargeted)
        address.commit(nil)

        XCTAssertEqual(address.currentURL, retargeted)
    }

    func testSameDocumentObserverAcceptsOnlyIdleExactOriginAddresses() throws {
        let coordinator = ConfinedWebView.Coordinator()
        coordinator.origin = try origin("http://localhost:3000/start")
        var reported: [URL] = []
        coordinator.reportCommittedURL = { url in
            if let url { reported.append(url) }
        }

        let sameDocument = try url("http://localhost:3000/dashboard#activity")
        coordinator.addressChangedOutsideNavigation(to: sameDocument, isLoading: true)
        coordinator.addressChangedOutsideNavigation(
            to: try url("http://localhost:3001/dashboard"),
            isLoading: false
        )
        coordinator.addressChangedOutsideNavigation(to: nil, isLoading: false)
        coordinator.addressChangedOutsideNavigation(to: sameDocument, isLoading: false)

        XCTAssertEqual(reported, [sameDocument])
    }

    func testCoordinatorAnswersTheWebKitNavigationSelectors() {
        let coordinator = ConfinedWebView.Coordinator()
        XCTAssertTrue(
            coordinator.responds(to: NSSelectorFromString("webView:didCommitNavigation:"))
        )
        XCTAssertTrue(
            coordinator.responds(
                to: NSSelectorFromString(
                    "webView:decidePolicyForNavigationAction:decisionHandler:"
                )
            )
        )
    }

    // MARK: - Origin confinement

    /// Browser-card navigations stay inside the exact local web origin that
    /// opened the card. A host-only comparison would let one localhost service
    /// navigate into another service, or even into a non-web scheme, without
    /// leaving the embedded browser boundary.
    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string), "Could not parse URL: \(string)")
    }

    private func origin(_ string: String) throws -> BrowserCardOrigin {
        try XCTUnwrap(BrowserCardOrigin(url: url(string)))
    }

    func testPathsQueriesAndDefaultPortSpellingStayInsideTheOrigin() throws {
        let http = try origin("http://LOCALHOST/start")
        XCTAssertTrue(http.allows(try url("http://localhost:80/next?tab=logs")))
        XCTAssertTrue(http.allows(try url("http://localhost/final#status")))

        let https = try origin("https://localhost:443/start")
        XCTAssertTrue(https.allows(try url("https://LOCALHOST/next")))
    }

    func testHTTPAndHTTPSNeverShareAnOrigin() throws {
        XCTAssertFalse(
            try origin("http://localhost:3000").allows(url("https://localhost:3000"))
        )
        XCTAssertFalse(
            try origin("https://localhost").allows(url("http://localhost"))
        )
    }

    func testDifferentEffectivePortsNeverShareAnOrigin() throws {
        XCTAssertFalse(
            try origin("http://localhost:3000").allows(url("http://localhost:3001"))
        )
        XCTAssertFalse(
            try origin("http://localhost").allows(url("http://localhost:8080"))
        )
    }

    func testCredentialsCannotHideInsideAnOtherwiseMatchingOrigin() throws {
        let clean = try origin("http://localhost:3000")
        let credentialed = try url("http://user:secret@localhost:3000/private")
        XCTAssertFalse(clean.allows(credentialed))
        XCTAssertFalse(LocalhostDetector.isLocalDevURL(credentialed))
        XCTAssertNil(BrowserCardOrigin(url: try url("http://user@localhost:3000")))
        XCTAssertNil(BrowserCardOrigin(url: try url("http://:secret@localhost:3000")))
    }

    func testNonWebAndHostlessURLsHaveNoBrowserCardOrigin() throws {
        let local = try origin("http://localhost:3000")
        for candidate in [
            "ftp://localhost:3000/archive",
            "file://localhost/tmp/index.html",
            "javascript:alert(1)",
            "about:blank",
        ] {
            let candidateURL = try url(candidate)
            XCTAssertNil(BrowserCardOrigin(url: candidateURL), candidate)
            XCTAssertFalse(local.allows(candidateURL), candidate)
        }
    }

    func testAnotherLocalhostNameIsStillAnotherOrigin() throws {
        XCTAssertFalse(
            try origin("http://localhost:3000").allows(url("http://admin.localhost:3000"))
        )
    }
}
