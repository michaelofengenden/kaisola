import Foundation
import XCTest
@testable import KaisolaCompanion

final class RememberedSessionCatalogTests: XCTestCase {
    func testEndpointRequiresHTTPSWithoutCredentialsAndDropsURLSecrets() throws {
        XCTAssertEqual(
            RememberedSessionCatalogEndpoint.derive(from: try XCTUnwrap(URL(
                string: "https://region.example.test/session?private=value#fragment"
            ))),
            URL(string: "https://region.example.test/sessionCatalog")
        )
        XCTAssertNil(RememberedSessionCatalogEndpoint.derive(
            from: try XCTUnwrap(URL(string: "http://region.example.test/session"))
        ))
        XCTAssertNil(RememberedSessionCatalogEndpoint.derive(
            from: try XCTUnwrap(URL(string: "https://user:secret@region.example.test/session"))
        ))
    }

    func testPortableCloudProjectionBoundsIdentifiersAndOneLineLabels() {
        let privateID = RememberedSessionCatalogPortable.id(
            "/Users/example/private/project",
            domain: "project",
            maximumUTF8Bytes: 160
        )
        XCTAssertTrue(privateID.hasPrefix("project-"))
        XCTAssertFalse(privateID.contains("Users"))
        XCTAssertEqual(
            RememberedSessionCatalogPortable.id(
                "session:portable-1",
                domain: "session",
                maximumUTF8Bytes: 240
            ),
            "session:portable-1"
        )
        let label = RememberedSessionCatalogPortable.text(
            "  first\nsecond\0  ",
            maximumUTF8Bytes: 12,
            fallback: "Session"
        )
        XCTAssertEqual(label, "first second")
        XCTAssertLessThanOrEqual(label.utf8.count, 12)
    }

    func testListUsesSiblingEndpointBearerAndDecodesPortableMetadata() async throws {
        let http = MobileCatalogHTTPClient(body: """
        {"ok":true,"schema":1,"devices":[{
          "deviceId":"studio-mac","deviceName":"Studio Mac","revision":3,
          "updatedAt":1785250000000,"presence":"offline","sessions":[{
            "id":"session-1","projectId":"kaisola","projectName":"Kaisola",
            "title":"Codex · release review","kind":"terminal","agentId":"codex",
            "activity":"needs-attention","resumeKind":"live-pty",
            "createdAt":1785240000000,"lastActivityAt":1785250000000,
            "hasLocalTranscript":true
          }]
        }]}
        """)
        let client = try RememberedSessionCatalogClient(
            sessionURL: try XCTUnwrap(URL(string: "https://region.example.test/session?ignored=1")),
            httpClient: http
        )

        let devices = try await client.list(
            idToken: "firebase-token",
            accountID: "account-a"
        )

        XCTAssertEqual(devices.map(\.deviceName), ["Studio Mac"])
        XCTAssertEqual(devices.first?.sessions.first?.activity, .needsAttention)
        let capturedRequest = await http.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, URL(string: "https://region.example.test/sessionCatalog"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-token")
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(requestObject["action"] as? String, "list")
    }

    func testSignOutInvalidatesSuspendedCatalogResultWithoutReplacementAccount() async throws {
        let http = MobileSuspendedCatalogHTTPClient()
        let client = try RememberedSessionCatalogClient(
            sessionURL: try XCTUnwrap(URL(string: "https://region.example.test/session")),
            httpClient: http
        )
        let request = Task {
            try await client.list(idToken: "token-a", accountID: "account-a")
        }

        await http.waitUntilRequested()
        await client.deactivate()
        await http.respond(with: #"{"ok":true,"schema":1,"devices":[]}"#)

        do {
            _ = try await request.value
            XCTFail("A suspended Account A result must not survive sign-out")
        } catch is CancellationError {
            // Expected: explicit deactivation advances the account epoch even
            // when the signed-out state never starts another catalog request.
        }
    }

    @MainActor
    func testViewerTreatsEveryMacAsRemoteAndClearsAccountState() {
        let center = RememberedSessionCatalogCenter(localDeviceID: "companion-viewer")
        center.beginRefresh()
        center.apply([
            RememberedDeviceCatalog(
                deviceId: "studio-mac",
                deviceName: "Studio Mac",
                revision: 1,
                updatedAt: 100,
                presence: .online,
                sessions: []
            ),
            RememberedDeviceCatalog(
                deviceId: "travel-mac",
                deviceName: "Travel Mac",
                revision: 2,
                updatedAt: 90,
                presence: .offline,
                sessions: []
            ),
        ], now: 200)

        XCTAssertEqual(center.remoteDevices.map(\.deviceId), ["studio-mac", "travel-mac"])
        XCTAssertEqual(center.lastUpdatedAt, 200)
        XCTAssertFalse(center.isRefreshing)

        center.clear()
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertNil(center.lastUpdatedAt)
    }
}

private actor MobileCatalogHTTPClient: AuthHTTPClient {
    private let body: String
    private var request: URLRequest?

    init(body: String) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (Data(body.utf8), response)
    }

    func lastRequest() -> URLRequest? { request }
}

private actor MobileSuspendedCatalogHTTPClient: AuthHTTPClient {
    private var responseContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var responseURL: URL?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { continuation in
            responseURL = request.url
            responseContinuation = continuation
            let waiters = requestWaiters
            requestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        if responseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func respond(with body: String) {
        guard let continuation = responseContinuation,
              let url = responseURL,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [:]
              ) else { return }
        responseContinuation = nil
        responseURL = nil
        continuation.resume(returning: (Data(body.utf8), response))
    }
}
