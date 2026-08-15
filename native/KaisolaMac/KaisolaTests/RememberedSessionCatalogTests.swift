import Foundation
import XCTest
@testable import Kaisola

final class RememberedSessionCatalogTests: XCTestCase {
    func testEndpointIsHTTPSiblingAndDropsQueryAndFragment() throws {
        let source = try XCTUnwrap(URL(
            string: "https://us-central1-kaisola-a9ab7.cloudfunctions.net/session?private=no#fragment"
        ))
        XCTAssertEqual(
            RememberedSessionCatalogEndpoint.derive(from: source),
            URL(string: "https://us-central1-kaisola-a9ab7.cloudfunctions.net/sessionCatalog")
        )
        XCTAssertNil(RememberedSessionCatalogEndpoint.derive(
            from: try XCTUnwrap(URL(string: "http://localhost/session"))
        ))
        XCTAssertNil(RememberedSessionCatalogEndpoint.derive(
            from: try XCTUnwrap(URL(string: "https://user:secret@example.test/session"))
        ))
    }

    func testPortableIdentifiersAndLabelsAreStableBoundedAndOneLine() {
        let first = RememberedSessionCatalogDevice.id(from: "private-broker-owner")
        XCTAssertEqual(first, RememberedSessionCatalogDevice.id(from: "private-broker-owner"))
        XCTAssertEqual(first.utf8.count, 43)
        XCTAssertFalse(first.contains("owner"))

        let opaque = RememberedSessionCatalogPortable.id(
            "/Users/michael/private/project", domain: "project", maximumUTF8Bytes: 160
        )
        XCTAssertTrue(opaque.hasPrefix("project-"))
        XCTAssertFalse(opaque.contains("Users"))
        XCTAssertEqual(
            RememberedSessionCatalogPortable.id(
                "session:portable-1", domain: "session", maximumUTF8Bytes: 240
            ),
            "session:portable-1"
        )
        let label = RememberedSessionCatalogPortable.text(
            "  first\nsecond\0  ", maximumUTF8Bytes: 12, fallback: "Session"
        )
        XCTAssertEqual(label, "first second")
        XCTAssertLessThanOrEqual(label.utf8.count, 12)
    }

    func testPublishListsFirstUsesBearerRevisionAndExistingCreationTime() async throws {
        let deviceID = "mac-test"
        let createdAt: Int64 = 1_784_250_000_000
        let client = CatalogRecordingHTTPClient(responses: [
            .init(status: 200, body: """
            {"ok":true,"schema":1,"devices":[{
              "deviceId":"mac-test","deviceName":"Existing Mac","revision":4,
              "updatedAt":1784250010000,"presence":"online","sessions":[{
                "id":"session-1","projectId":"project-1","projectName":"Kaisola",
                "title":"Existing","kind":"terminal","agentId":"codex","activity":"idle",
                "resumeKind":"live-pty","createdAt":1784250000000,
                "lastActivityAt":1784250010000,"hasLocalTranscript":true
              }]}
            ]}
            """),
            .init(status: 200, body: #"{"ok":true,"schema":1,"revision":5}"#),
        ])
        let catalog = try RememberedSessionCatalogClient(
            sessionURL: try XCTUnwrap(URL(string: "https://region.example.test/session")),
            httpClient: client
        )
        let revision = try await catalog.publish(
            idToken: "firebase-token",
            accountID: "account-a",
            deviceID: deviceID,
            deviceName: "Michael\nMac",
            drafts: [draft(createdAt: nil, lastActivityAt: createdAt + 20_000)],
            now: createdAt + 30_000
        )
        XCTAssertEqual(revision, 5)

        let requests = await client.allRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer firebase-token")
        XCTAssertEqual(requests[0].url, URL(string: "https://region.example.test/sessionCatalog"))
        let listBody = try XCTUnwrap(requests[0].httpBody)
        XCTAssertEqual(try object(listBody)["action"] as? String, "list")

        let publishBody = try object(try XCTUnwrap(requests[1].httpBody))
        XCTAssertEqual(publishBody["action"] as? String, "publish")
        XCTAssertEqual(publishBody["expectedRevision"] as? Int, 4)
        XCTAssertEqual(publishBody["deviceName"] as? String, "Michael Mac")
        let sessions = try XCTUnwrap(publishBody["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["createdAt"] as? Int64, createdAt)
        XCTAssertEqual(sessions.first?["lastActivityAt"] as? Int64, createdAt + 20_000)
    }

    func testRevisionConflictRetriesExactlyOnceWithServerRevision() async throws {
        let client = CatalogRecordingHTTPClient(responses: [
            .init(status: 200, body: #"{"ok":true,"schema":1,"devices":[]}"#),
            .init(status: 409, body: #"{"ok":false,"currentRevision":7,"message":"conflict"}"#),
            .init(status: 200, body: #"{"ok":true,"schema":1,"revision":8}"#),
        ])
        let catalog = try RememberedSessionCatalogClient(
            sessionURL: try XCTUnwrap(URL(string: "https://region.example.test/session")),
            httpClient: client
        )
        let revision = try await catalog.publish(
            idToken: "firebase-token",
            accountID: "account-a",
            deviceID: "mac-test",
            deviceName: "Mac",
            drafts: [draft(createdAt: 100, lastActivityAt: 200)],
            now: 300
        )
        XCTAssertEqual(revision, 8)
        let requests = await client.allRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            try object(try XCTUnwrap(requests[1].httpBody))["expectedRevision"] as? Int,
            0
        )
        XCTAssertEqual(
            try object(try XCTUnwrap(requests[2].httpBody))["expectedRevision"] as? Int,
            7
        )
    }

    func testRemoveUsesBearerAndClearsOnlyThatDevicesLocalCaches() async throws {
        let client = CatalogRecordingHTTPClient(responses: [
            .init(status: 200, body: """
            {"ok":true,"schema":1,"devices":[{
              "deviceId":"mac-test","deviceName":"Existing Mac","revision":4,
              "updatedAt":500,"presence":"online","sessions":[{
                "id":"session-1","projectId":"project-1","projectName":"Kaisola",
                "title":"Existing","kind":"terminal","agentId":"codex","activity":"idle",
                "resumeKind":"live-pty","createdAt":100,"lastActivityAt":200,
                "hasLocalTranscript":true
              }]
            }]}
            """),
            .init(status: 200, body: #"{"ok":true,"schema":1,"revision":5}"#),
            .init(status: 200, body: #"{"ok":true}"#),
            .init(status: 200, body: #"{"ok":true,"schema":1,"devices":[]}"#),
            .init(status: 200, body: #"{"ok":true,"schema":1,"revision":1}"#),
        ])
        let catalog = try RememberedSessionCatalogClient(
            sessionURL: try XCTUnwrap(URL(string: "https://region.example.test/session")),
            httpClient: client
        )

        _ = try await catalog.publish(
            idToken: "token-a",
            accountID: "account-a",
            deviceID: "mac-test",
            deviceName: "Mac",
            drafts: [draft(createdAt: nil, lastActivityAt: 400)],
            now: 500
        )
        try await catalog.removeDevice(
            idToken: "token-a",
            accountID: "account-a",
            deviceID: "mac-test"
        )
        let nextRevision = try await catalog.publish(
            idToken: "token-a",
            accountID: "account-a",
            deviceID: "mac-test",
            deviceName: "Mac",
            drafts: [draft(createdAt: nil, lastActivityAt: 900)],
            now: 1_000
        )
        XCTAssertEqual(nextRevision, 1)

        let requests = await client.allRequests()
        XCTAssertEqual(requests.count, 5)
        let remove = try object(try XCTUnwrap(requests[2].httpBody))
        XCTAssertEqual(remove["action"] as? String, "remove-device")
        XCTAssertEqual(remove["deviceId"] as? String, "mac-test")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Authorization"),
            "Bearer token-a"
        )
        let republish = try object(try XCTUnwrap(requests[4].httpBody))
        XCTAssertEqual(republish["expectedRevision"] as? Int, 0)
        XCTAssertEqual(
            (republish["sessions"] as? [[String: Any]])?.first?["createdAt"] as? Int64,
            1_000
        )
    }

    func testAccountSwitchClearsRevisionAndCreationTimeCaches() async throws {
        let client = CatalogRecordingHTTPClient(responses: [
            .init(status: 200, body: """
            {"ok":true,"schema":1,"devices":[{
              "deviceId":"mac-test","deviceName":"Account A Mac","revision":4,
              "updatedAt":500,"presence":"online","sessions":[{
                "id":"session-1","projectId":"project-1","projectName":"Kaisola",
                "title":"Account A","kind":"terminal","agentId":"codex","activity":"idle",
                "resumeKind":"live-pty","createdAt":100,"lastActivityAt":200,
                "hasLocalTranscript":true
              }]
            }]}
            """),
            .init(status: 200, body: #"{"ok":true,"schema":1,"revision":5}"#),
            .init(status: 200, body: #"{"ok":true,"schema":1,"devices":[]}"#),
            .init(status: 200, body: #"{"ok":true,"schema":1,"revision":1}"#),
        ])
        let catalog = try RememberedSessionCatalogClient(
            sessionURL: try XCTUnwrap(URL(string: "https://region.example.test/session")),
            httpClient: client
        )

        let accountARevision = try await catalog.publish(
            idToken: "token-a",
            accountID: "account-a",
            deviceID: "mac-test",
            deviceName: "Mac",
            drafts: [draft(createdAt: nil, lastActivityAt: 400)],
            now: 500
        )
        XCTAssertEqual(accountARevision, 5)
        let accountBRevision = try await catalog.publish(
            idToken: "token-b",
            accountID: "account-b",
            deviceID: "mac-test",
            deviceName: "Mac",
            drafts: [draft(createdAt: nil, lastActivityAt: 900)],
            now: 1_000
        )
        XCTAssertEqual(accountBRevision, 1)

        let requests = await client.allRequests()
        XCTAssertEqual(requests.count, 4)
        let accountAPublish = try object(try XCTUnwrap(requests[1].httpBody))
        let accountBPublish = try object(try XCTUnwrap(requests[3].httpBody))
        XCTAssertEqual(accountAPublish["expectedRevision"] as? Int, 4)
        XCTAssertEqual(accountBPublish["expectedRevision"] as? Int, 0)
        XCTAssertEqual(
            (accountAPublish["sessions"] as? [[String: Any]])?.first?["createdAt"] as? Int64,
            100
        )
        XCTAssertEqual(
            (accountBPublish["sessions"] as? [[String: Any]])?.first?["createdAt"] as? Int64,
            1_000
        )
        XCTAssertEqual(
            requests[3].value(forHTTPHeaderField: "Authorization"),
            "Bearer token-b"
        )
    }

    func testSignOutInvalidatesSuspendedCatalogResult() async throws {
        let client = CatalogSuspendedHTTPClient()
        let catalog = try RememberedSessionCatalogClient(
            sessionURL: try XCTUnwrap(URL(string: "https://region.example.test/session")),
            httpClient: client
        )
        let request = Task {
            try await catalog.list(idToken: "token-a", accountID: "account-a")
        }

        await client.waitUntilRequested()
        await catalog.deactivate()
        await client.respond(with: #"{"ok":true,"schema":1,"devices":[]}"#)

        do {
            _ = try await request.value
            XCTFail("A suspended Account A result must not survive sign-out")
        } catch is CancellationError {
            // Expected: deactivation advances the account epoch.
        }
    }

    func testSignOutStopsASuspendedRevisionConflictRetry() async throws {
        let client = CatalogSuspendedHTTPClient()
        let catalog = try RememberedSessionCatalogClient(
            sessionURL: try XCTUnwrap(URL(string: "https://region.example.test/session")),
            httpClient: client
        )
        let pendingDraft = draft(createdAt: 100, lastActivityAt: 200)
        let request = Task {
            try await catalog.publish(
                idToken: "token-a",
                accountID: "account-a",
                deviceID: "mac-test",
                deviceName: "Mac",
                drafts: [pendingDraft],
                now: 300
            )
        }

        await client.waitUntilRequested()
        await client.respond(with: #"{"ok":true,"schema":1,"devices":[]}"#)
        await client.waitUntilRequested()
        await catalog.deactivate()
        await client.respond(
            with: #"{"ok":false,"currentRevision":7,"message":"conflict"}"#,
            status: 409
        )

        do {
            _ = try await request.value
            XCTFail("A signed-out request must not retry a revision conflict")
        } catch is CancellationError {
            // Expected: no third request is made after the account epoch moves.
        }
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testSnapshotStoreIsAccountHashedPrivateAndCorruptionBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-catalog-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RememberedSessionCatalogSnapshotStore(directory: root)
        let accountID = "firebase-account-a-private"
        let devices = [device(id: "studio-mac", name: "Studio Mac", presence: .offline)]

        try await store.save(
            accountID: accountID,
            devices: devices,
            savedAt: 1_785_250_001_000
        )
        let restored = try await store.load(accountID: accountID)
        XCTAssertEqual(
            restored,
            RememberedSessionCatalogSnapshot(
                schema: 1,
                savedAt: 1_785_250_001_000,
                devices: devices
            )
        )
        let otherAccount = try await store.load(accountID: "firebase-account-b-private")
        XCTAssertNil(otherAccount)

        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(file.lastPathComponent.contains(accountID))
        let payload = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(payload.contains(accountID))
        XCTAssertFalse(payload.contains("firebase"))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o600
        )

        try Data("{\"schema\":1,\"savedAt\":0,\"devices\":\"corrupt\"}".utf8)
            .write(to: file, options: [.atomic])
        do {
            _ = try await store.load(accountID: accountID)
            XCTFail("A corrupt snapshot must fail closed")
        } catch RememberedSessionCatalogSnapshotError.invalidSnapshot {
            // Expected.
        }
    }

    func testSnapshotStoreRejectsInvalidAccountAndNonPortableMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-catalog-snapshot-invalid-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RememberedSessionCatalogSnapshotStore(directory: root)

        do {
            try await store.save(accountID: "bad\naccount", devices: [])
            XCTFail("A control-bearing account ID must be rejected")
        } catch RememberedSessionCatalogSnapshotError.invalidAccount {
            // Expected.
        }

        let invalid = RememberedDeviceCatalog(
            deviceId: "bad/device/path",
            deviceName: "Private Mac",
            revision: 1,
            updatedAt: 100,
            presence: .offline,
            sessions: []
        )
        do {
            try await store.save(accountID: "account-a", devices: [invalid])
            XCTFail("A non-portable device identifier must be rejected")
        } catch RememberedSessionCatalogSnapshotError.invalidSnapshot {
            // Expected.
        }

        let redirected = root.appendingPathComponent("redirected", isDirectory: true)
        let symlink = root.appendingPathComponent("symlink-cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: redirected,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: redirected
        )
        let redirectedStore = RememberedSessionCatalogSnapshotStore(directory: symlink)
        do {
            try await redirectedStore.save(accountID: "account-a", devices: [])
            XCTFail("A symlinked cache root must be rejected")
        } catch RememberedSessionCatalogSnapshotError.unsafeStorage {
            // Expected.
        }
    }

    @MainActor
    func testCatalogCenterSeparatesLocalFromOrderedRemoteDevicesAndClearsOnSignOut() {
        let center = RememberedSessionCatalogCenter(localDeviceID: "local")
        let remoteOffline = device(id: "z", name: "Zulu", presence: .offline)
        let local = device(id: "local", name: "Local", presence: .online)
        let remoteOnline = device(id: "a", name: "Alpha", presence: .online)

        center.beginRefresh()
        center.apply(
            [remoteOffline, local, remoteOnline],
            now: 500,
            source: .savedSnapshot
        )

        XCTAssertEqual(center.devices.map(\.deviceId), ["local", "a", "z"])
        XCTAssertEqual(center.remoteDevices.map(\.deviceId), ["a", "z"])
        XCTAssertEqual(center.lastUpdatedAt, 500)
        XCTAssertEqual(center.source, .savedSnapshot)
        XCTAssertTrue(center.freshnessTitle?.hasPrefix("Saved ") == true)
        XCTAssertFalse(center.isRefreshing)

        center.fail(RememberedSessionCatalogError.invalidResponse)
        XCTAssertTrue(center.freshnessTitle?.hasPrefix("Saved · refresh failed · ") == true)

        center.apply([local], now: 1_000)
        XCTAssertEqual(center.source, .live)
        XCTAssertTrue(center.freshnessTitle?.hasPrefix("Updated ") == true)
        // The fleet latch flipped on the earlier remote-bearing apply and a
        // later local-only list must not lower it: a transient empty live
        // catalog would otherwise re-hide the section mid-session.
        XCTAssertTrue(center.hasEverSeenRemoteDevice)

        center.clear()
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertNil(center.source)
        XCTAssertNil(center.freshnessTitle)
        XCTAssertNil(center.lastUpdatedAt)
        XCTAssertFalse(center.hasEverSeenRemoteDevice)
    }

    @MainActor
    func testFleetLatchStaysDownForALocalOnlyCatalog() {
        let center = RememberedSessionCatalogCenter(localDeviceID: "local")
        XCTAssertFalse(center.hasEverSeenRemoteDevice)
        center.apply([device(id: "local", name: "Local", presence: .online)], now: 10)
        XCTAssertFalse(center.hasEverSeenRemoteDevice)
        center.fail(RememberedSessionCatalogError.invalidResponse)
        XCTAssertFalse(center.hasEverSeenRemoteDevice)
    }

    private func draft(createdAt: Int64?, lastActivityAt: Int64?) -> RememberedSessionDraft {
        RememberedSessionDraft(
            id: "session-1",
            projectID: "project-1",
            projectName: "Kaisola",
            title: "Codex session",
            kind: .terminal,
            agentID: "codex",
            activity: .working,
            resumeKind: .livePTY,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            hasLocalTranscript: true
        )
    }

    private func device(
        id: String,
        name: String,
        presence: RememberedDeviceCatalog.Presence
    ) -> RememberedDeviceCatalog {
        RememberedDeviceCatalog(
            deviceId: id,
            deviceName: name,
            revision: 1,
            updatedAt: 100,
            presence: presence,
            sessions: []
        )
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor CatalogRecordingHTTPClient: AuthHTTPClient {
    struct Response: Sendable {
        let status: Int
        let body: String
    }

    private var responses: [Response]
    private var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw CatalogRecordingError.missingResponse }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (Data(next.body.utf8), response)
    }

    func allRequests() -> [URLRequest] { requests }
}

private enum CatalogRecordingError: Error {
    case missingResponse
}

private actor CatalogSuspendedHTTPClient: AuthHTTPClient {
    private var responseContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var responseURL: URL?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var requests = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { continuation in
            requests += 1
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

    func requestCount() -> Int { requests }

    func respond(with body: String, status: Int = 200) {
        guard let continuation = responseContinuation,
              let url = responseURL,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: [:]
              ) else { return }
        responseContinuation = nil
        responseURL = nil
        continuation.resume(returning: (Data(body.utf8), response))
    }
}
