import Foundation
import WebKit
import XCTest
@testable import Kaisola

/// Storage isolation between the app's two ephemeral content surfaces. An
/// approved project HTML preview and a browser card pointed at an
/// authenticated local dev server are different trust classes, so neither may
/// read the other's cookies or website data.
@MainActor
final class SharedWebKitTests: XCTestCase {

    // MARK: - Store identity

    func testEveryContentSurfaceGetsItsOwnNonPersistentStore() {
        let surfaces = SharedWebKit.ContentSurface.allCases
        XCTAssertEqual(surfaces.count, 2)
        for surface in surfaces {
            XCTAssertFalse(
                SharedWebKit.ephemeralStore(for: surface).isPersistent,
                "\(surface) must not touch on-disk website data"
            )
        }
        for (index, surface) in surfaces.enumerated() {
            for other in surfaces[surfaces.index(after: index)...] {
                XCTAssertFalse(
                    SharedWebKit.ephemeralStore(for: surface) === SharedWebKit.ephemeralStore(for: other),
                    "\(surface) and \(other) share one website data store"
                )
            }
        }
    }

    func testEachSurfaceKeepsOneStoreAcrossViews() {
        // Views on the SAME surface still pool: that is the caching/process
        // affinity the shared store existed for in the first place.
        XCTAssertTrue(
            SharedWebKit.ephemeralStore(for: .filePreview) === SharedWebKit.ephemeralStore(for: .filePreview)
        )
        XCTAssertTrue(
            SharedWebKit.ephemeralStore(for: .browserCard) === SharedWebKit.ephemeralStore(for: .browserCard)
        )
    }

    func testWebViewsBuiltForTheTwoSurfacesDoNotShareAStore() {
        let previewConfiguration = SharedWebKit.contentConfiguration(for: .filePreview)
        let cardConfiguration = SharedWebKit.contentConfiguration(for: .browserCard)
        XCTAssertTrue(
            previewConfiguration.websiteDataStore === SharedWebKit.ephemeralStore(for: .filePreview)
        )
        XCTAssertTrue(
            cardConfiguration.websiteDataStore === SharedWebKit.ephemeralStore(for: .browserCard)
        )

        // Through the live web views the two surfaces actually build.
        let preview = WKWebView(frame: .zero, configuration: previewConfiguration)
        let card = WKWebView(frame: .zero, configuration: cardConfiguration)
        XCTAssertFalse(
            preview.configuration.websiteDataStore === card.configuration.websiteDataStore,
            "the HTML preview and the browser card share one website data store"
        )
    }

    // MARK: - Live cookie isolation

    func testBrowserCardCookieNeverReachesTheFilePreviewStore() async throws {
        let name = "kaisola-dev-session-\(UUID().uuidString)"
        let cookie = try XCTUnwrap(Self.probeCookie(named: name))
        let card = SharedWebKit.ephemeralStore(for: .browserCard).httpCookieStore
        let preview = SharedWebKit.ephemeralStore(for: .filePreview).httpCookieStore

        await card.setCookie(cookie)
        let cardCookies = await card.allCookies()
        XCTAssertTrue(
            cardCookies.contains { $0.name == name },
            "the probe cookie never landed in the browser-card store, so isolation was not exercised"
        )

        let previewCookies = await preview.allCookies()
        XCTAssertFalse(
            previewCookies.contains { $0.name == name },
            "a local dev server cookie leaked into the untrusted file preview"
        )
        await card.deleteCookie(cookie)
    }

    func testFilePreviewCookieNeverReachesTheBrowserCardStore() async throws {
        let name = "kaisola-project-html-\(UUID().uuidString)"
        let cookie = try XCTUnwrap(Self.probeCookie(named: name))
        let card = SharedWebKit.ephemeralStore(for: .browserCard).httpCookieStore
        let preview = SharedWebKit.ephemeralStore(for: .filePreview).httpCookieStore

        await preview.setCookie(cookie)
        let previewCookies = await preview.allCookies()
        XCTAssertTrue(
            previewCookies.contains { $0.name == name },
            "the probe cookie never landed in the file-preview store, so isolation was not exercised"
        )

        let cardCookies = await card.allCookies()
        XCTAssertFalse(
            cardCookies.contains { $0.name == name },
            "approved project JavaScript could write into the local dev server's session"
        )
        await preview.deleteCookie(cookie)
    }

    private static func probeCookie(named name: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .name: name,
            .value: "isolation-probe",
            .domain: "localhost",
            .path: "/",
        ])
    }
}
