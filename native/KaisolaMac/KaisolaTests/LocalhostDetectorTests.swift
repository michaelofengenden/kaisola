import Foundation
import XCTest
@testable import Kaisola

/// `LocalhostDetector.isLocalDevURL` — the pure gate that decides whether a
/// clicked terminal/agent link opens an in-app browser card instead of Safari.
/// Security-sensitive: a false positive would let a real host masquerade as a
/// dev server, so the suffix-spoof and non-http rejections are load-bearing.
final class LocalhostDetectorTests: XCTestCase {
    private func isLocal(_ string: String) -> Bool {
        guard let url = URL(string: string) else {
            XCTFail("Could not parse URL: \(string)")
            return false
        }
        return LocalhostDetector.isLocalDevURL(url)
    }

    func testLocalDevURLsAreAccepted() {
        XCTAssertTrue(isLocal("http://localhost:3000"))
        XCTAssertTrue(isLocal("http://127.0.0.1"))
        XCTAssertTrue(isLocal("http://[::1]:8080"))
        XCTAssertTrue(isLocal("http://foo.localhost"))
        XCTAssertTrue(isLocal("https://localhost"))
        // Extra loopback / normalization coverage.
        XCTAssertTrue(isLocal("http://0.0.0.0:5173"))
        XCTAssertTrue(isLocal("http://LOCALHOST:3000"), "host match must be case-insensitive")
    }

    func testRealHostsAreRejected() {
        XCTAssertFalse(isLocal("https://example.com"))
        XCTAssertFalse(isLocal("http://notlocalhost:3000"))
        // Suffix spoof: a real host that merely ends up next to "localhost".
        XCTAssertFalse(isLocal("http://localhost.evil.com"))
        // A query string that mentions localhost must not fool the host check.
        XCTAssertFalse(isLocal("http://evil.com/path?next=http://localhost"))
    }

    func testNonHTTPSchemesAreRejected() {
        XCTAssertFalse(isLocal("file:///Users/x/index.html"))
        XCTAssertFalse(isLocal("ftp://localhost/pub"))
        XCTAssertFalse(isLocal("ssh://localhost"))
    }
}
