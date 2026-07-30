import KaisolaCore
import XCTest
@testable import KaisolaCompanion

@MainActor
final class KaisolaLinkConnectionTests: XCTestCase {
    func testTicketAndWebSocketURLsStayOnConfiguredTLSHost() throws {
        let base = try XCTUnwrap(URL(string: "https://link.example/base"))
        XCTAssertEqual(
            KaisolaLinkConnection.ticketURL(baseURL: base)?.absoluteString,
            "https://link.example/base/v1/ticket"
        )
        XCTAssertEqual(
            KaisolaLinkConnection.validatedWebSocketURL(
                "wss://link.example/v1/connect/abc?ticket=one",
                baseURL: base
            )?.absoluteString,
            "wss://link.example/v1/connect/abc?ticket=one"
        )
        XCTAssertNil(KaisolaLinkConnection.validatedWebSocketURL(
            "wss://evil.example/v1/connect/abc?ticket=one",
            baseURL: base
        ))
        XCTAssertNil(KaisolaLinkConnection.ticketURL(baseURL: try XCTUnwrap(URL(string: "http://link.example"))))
    }
}
