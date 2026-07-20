import Foundation
import XCTest
@testable import KaisolaCompanion

final class CompanionAccountRendezvousTests: XCTestCase {
    func testEndpointIsSiblingOfSessionAndDropsQuery() throws {
        let session = try XCTUnwrap(URL(
            string: "https://us-central1-kaisola-a9ab7.cloudfunctions.net/session?private=no"
        ))
        XCTAssertEqual(
            CompanionAccountRendezvousService.endpoint(from: session),
            URL(string: "https://us-central1-kaisola-a9ab7.cloudfunctions.net/companionRendezvous")
        )
        XCTAssertNil(CompanionAccountRendezvousService.endpoint(
            from: try XCTUnwrap(URL(string: "http://localhost/session"))
        ))
    }

    func testListUsesBearerAuthAndDecodesAnEmptyOfferSet() async throws {
        let client = RecordingAuthHTTPClient(
            body: Data(#"{"ok":true,"offers":[]}"#.utf8),
            status: 200
        )
        let service = CompanionAccountRendezvousService(
            configuration: FirebaseAuthConfiguration(
                projectId: "kaisola-a9ab7",
                apiKey: "AIzaSyAiqyY5bzsa7j5E1rP-iKYXaQFH8iFUJwY",
                serverURL: try XCTUnwrap(URL(string: "https://region.example.test/session"))
            ),
            httpClient: client
        )

        let offers = try await service.listOffers(idToken: "firebase-token")
        XCTAssertTrue(offers.isEmpty)
        let captured = await client.firstRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url, URL(string: "https://region.example.test/companionRendezvous"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-token")
        XCTAssertEqual(request.httpBody, Data(#"{"action":"list"}"#.utf8))
    }
}

private actor RecordingAuthHTTPClient: AuthHTTPClient {
    private let body: Data
    private let status: Int
    private var requests: [URLRequest] = []

    init(body: Data, status: Int) {
        self.body = body
        self.status = status
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (body, response)
    }

    func firstRequest() -> URLRequest? { requests.first }
}
