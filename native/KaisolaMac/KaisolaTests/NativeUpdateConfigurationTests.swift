import Foundation
import XCTest
@testable import KaisolaMacPreview

final class NativeUpdateConfigurationTests: XCTestCase {
    private let validKey = Data(repeating: 0xA5, count: 32).base64EncodedString()

    func testValidSignedHTTPSFeedIsAccepted() throws {
        let configuration = try NativeUpdateConfiguration.parse([
            "SUFeedURL": "https://updates.kaisola.app/native-preview/appcast.xml",
            "SUPublicEDKey": validKey,
        ])
        XCTAssertEqual(configuration.feedURL.absoluteString, "https://updates.kaisola.app/native-preview/appcast.xml")
        XCTAssertEqual(configuration.publicEDKey, validKey)
    }

    func testMissingReleaseConfigurationFailsClosed() {
        XCTAssertThrowsError(try NativeUpdateConfiguration.parse([:])) {
            XCTAssertEqual($0 as? NativeUpdateConfigurationError, .notConfigured)
        }
    }

    func testInsecureOrCredentialedFeedIsRejected() {
        for feed in [
            "http://updates.kaisola.app/appcast.xml",
            "https://user:secret@updates.kaisola.app/appcast.xml",
            "https://updates.kaisola.app/appcast.xml#replacement",
        ] {
            XCTAssertThrowsError(try NativeUpdateConfiguration.parse([
                "SUFeedURL": feed,
                "SUPublicEDKey": validKey,
            ])) {
                XCTAssertEqual($0 as? NativeUpdateConfigurationError, .unsafeFeedURL)
            }
        }
    }

    func testSigningKeyMustBeExactlyOneEd25519PublicKey() {
        for key in ["not-base64", Data(repeating: 1, count: 31).base64EncodedString()] {
            XCTAssertThrowsError(try NativeUpdateConfiguration.parse([
                "SUFeedURL": "https://updates.kaisola.app/appcast.xml",
                "SUPublicEDKey": key,
            ])) {
                XCTAssertEqual($0 as? NativeUpdateConfigurationError, .invalidPublicKey)
            }
        }
    }
}
