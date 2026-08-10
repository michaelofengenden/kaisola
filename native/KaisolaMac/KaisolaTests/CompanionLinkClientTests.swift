import Darwin
import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

@MainActor
final class CompanionLinkClientTests: XCTestCase {
    func testMultiplexCodecMatchesRelayBoundsAndRejectsMalformedFrames() throws {
        let channelID = String(repeating: "a", count: CompanionRelayMux.channelIDBytes)
        let payload = Data([0, 1, 2, 127, 255])
        for kind in [CompanionRelayMux.Kind.open, .data, .close] {
            XCTAssertEqual(
                try CompanionRelayMux.decode(
                    CompanionRelayMux.encode(kind, channelID: channelID, payload: payload)
                ),
                CompanionRelayMux.Frame(kind: kind, channelID: channelID, payload: payload)
            )
        }
        XCTAssertThrowsError(try CompanionRelayMux.encode(.data, channelID: "short"))
        XCTAssertThrowsError(try CompanionRelayMux.decode(Data([1, 2, 22, 1])))
        XCTAssertThrowsError(try CompanionRelayMux.encode(
            .data,
            channelID: channelID,
            payload: Data(repeating: 0, count: CompanionRelayMux.maximumMessageBytes)
        ))
        XCTAssertEqual(CompanionRelayMux.maximumDevicePayloadBytes, 2 * 1_024 * 1_024 - 64)
        XCTAssertEqual(CompanionRelayMux.maximumChannels, 16)
    }

    func testRelayURLsStayOnTheConfiguredTLSOrigin() throws {
        let base = try XCTUnwrap(URL(string: "https://link.example/base/?ignored=true#fragment"))
        XCTAssertEqual(
            CompanionLinkClient.ticketURL(baseURL: base)?.absoluteString,
            "https://link.example/base/v1/ticket"
        )
        XCTAssertEqual(
            CompanionLinkClient.validatedWebSocketURL(
                "wss://link.example/v1/connect/abc?ticket=one",
                baseURL: base
            )?.absoluteString,
            "wss://link.example/v1/connect/abc?ticket=one"
        )
        XCTAssertNil(CompanionLinkClient.validatedWebSocketURL(
            "wss://evil.example/v1/connect/abc?ticket=one",
            baseURL: base
        ))
        XCTAssertNil(CompanionLinkClient.ticketURL(
            baseURL: try XCTUnwrap(URL(string: "http://link.example"))
        ))
    }

    func testTicketReadyOpenAndOpaqueChannelRoundTrip() async throws {
        let channelID = String(repeating: "c", count: CompanionRelayMux.channelIDBytes)
        let socket = FakeWebSocket()
        let accepted = SocketCapture()
        let requests = RequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayURLProtocol.self]
        RelayURLProtocol.handler = { request in
            requests.append(request, body: request.capturedBody())
            let expiresAt = Int64(1_900_000_100_000)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(
                #"{"ok":true,"websocketUrl":"wss://link.example/v1/connect/room?ticket=one","expiresAt":\#(expiresAt)}"#.utf8
            )
            return (response, body)
        }
        defer { RelayURLProtocol.handler = nil }
        let session = URLSession(configuration: configuration)
        let client = try XCTUnwrap(CompanionLinkClient(
            desktopID: "desktop-relay-test",
            baseURL: try XCTUnwrap(URL(string: "https://link.example")),
            tokenProvider: { "firebase-token-that-is-long-enough" },
            session: session,
            socketFactory: { _ in socket },
            acceptSocket: { accepted.append($0) },
            now: { 1_900_000_000_000 }
        ))

        client.enable()
        try await eventually { socket.resumed }
        let request = try XCTUnwrap(requests.snapshot().first)
        XCTAssertEqual(request.request.url?.path, "/v1/ticket")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-token-that-is-long-enough")
        let requestBody = try XCTUnwrap(request.body)
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody) as? [String: String]
        )
        XCTAssertEqual(requestObject, ["role": "desktop", "desktopId": "desktop-relay-test"])

        socket.push(.string(#"{"type":"relay.desktop-ready"}"#))
        try await eventually { client.phase == .ready }
        XCTAssertEqual(client.channelCount, 0)

        let open = try CompanionRelayMux.encode(
            .open,
            channelID: channelID,
            payload: Data(#"{"deviceId":"device-relay-test"}"#.utf8)
        )
        socket.push(.data(open))
        try await eventually { accepted.snapshot().count == 1 }
        let channel = try XCTUnwrap(accepted.snapshot().first)
        let received = DataCapture()
        let closed = BoolCapture()
        await channel.install(
            receiver: { data in
                if data == Data("slow-first".utf8) {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                received.append(data)
            },
            onClose: { closed.setTrue() }
        )

        socket.push(.data(try CompanionRelayMux.encode(
            .data,
            channelID: channelID,
            payload: Data("phone-to-mac".utf8)
        )))
        try await eventually { received.snapshot() == [Data("phone-to-mac".utf8)] }

        socket.push(.data(try CompanionRelayMux.encode(
            .data,
            channelID: channelID,
            payload: Data("slow-first".utf8)
        )))
        socket.push(.data(try CompanionRelayMux.encode(
            .data,
            channelID: channelID,
            payload: Data("immediate-second".utf8)
        )))
        try await eventually {
            received.snapshot() == [
                Data("phone-to-mac".utf8),
                Data("slow-first".utf8),
                Data("immediate-second".utf8),
            ]
        }

        try await channel.write(Data("mac-to-phone".utf8))
        try await eventually {
            socket.sentMessages.contains { message in
                guard case let .data(data) = message,
                      let frame = try? CompanionRelayMux.decode(data) else { return false }
                return frame.kind == .data && frame.channelID == channelID
                    && frame.payload == Data("mac-to-phone".utf8)
            }
        }

        socket.push(.data(try CompanionRelayMux.encode(.close, channelID: channelID)))
        try await eventually { closed.value }
        XCTAssertEqual(client.channelCount, 0)

        let signOutChannelID = String(repeating: "s", count: CompanionRelayMux.channelIDBytes)
        socket.push(.data(try CompanionRelayMux.encode(
            .open,
            channelID: signOutChannelID,
            payload: Data(#"{"deviceId":"device-signout-test"}"#.utf8)
        )))
        try await eventually { accepted.snapshot().count == 2 }
        let signOutClosed = BoolCapture()
        await accepted.snapshot()[1].install(receiver: { _ in }, onClose: { signOutClosed.setTrue() })
        client.disable()
        XCTAssertEqual(client.phase, .off)
        XCTAssertEqual(client.channelCount, 0)
        try await eventually { signOutClosed.value }
        XCTAssertEqual(socket.cancelCode, .normalClosure)
    }

    func testAuthenticationRefreshRecoversWithoutWaitingForBackoff() async throws {
        let socket = FakeWebSocket()
        let requests = RequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayURLProtocol.self]
        let attempts = IntCapture()
        RelayURLProtocol.handler = { request in
            requests.append(request, body: request.capturedBody())
            let attempt = attempts.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: attempt == 1 ? 401 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = attempt == 1
                ? Data(#"{"ok":false}"#.utf8)
                : Data(#"{"ok":true,"websocketUrl":"wss://link.example/v1/connect/room?ticket=fresh","expiresAt":1900000100000}"#.utf8)
            return (response, body)
        }
        defer { RelayURLProtocol.handler = nil }
        let client = try XCTUnwrap(CompanionLinkClient(
            desktopID: "desktop-auth-refresh",
            baseURL: try XCTUnwrap(URL(string: "https://link.example")),
            tokenProvider: { "fresh-firebase-token-that-is-long-enough" },
            session: URLSession(configuration: configuration),
            socketFactory: { _ in socket },
            acceptSocket: { _ in },
            now: { 1_900_000_000_000 }
        ))

        client.enable()
        try await eventually { client.phase == .authenticationRequired }
        XCTAssertEqual(requests.snapshot().count, 1)
        client.refresh()
        try await eventually { socket.resumed && requests.snapshot().count == 2 }
        socket.push(.string(#"{"type":"relay.desktop-ready"}"#))
        try await eventually { client.phase == .ready }
        client.disable()
    }

    func testVirtualSocketBoundsBytesArrivingBeforeHostInstallation() async throws {
        let sent = DataCapture()
        let socket = CompanionRelayVirtualSocket(
            id: String(repeating: "v", count: CompanionRelayMux.channelIDBytes),
            writer: { sent.append($0) },
            closer: {}
        )
        await socket.receive(Data("early".utf8))
        let received = DataCapture()
        let closed = BoolCapture()
        await socket.install(
            receiver: { received.append($0) },
            onClose: { closed.setTrue() }
        )
        XCTAssertEqual(received.snapshot(), [Data("early".utf8)])
        try await socket.write(Data("out".utf8))
        XCTAssertEqual(sent.snapshot(), [Data("out".utf8)])
        await socket.remoteClose()
        XCTAssertTrue(closed.value)
        do {
            try await socket.write(Data("late".utf8))
            XCTFail("Expected a closed relay channel to reject writes")
        } catch {}
    }

    func testVirtualSocketOverflowClosesPeerAndHostInsteadOfLeavingAZombie() async {
        let peerClosed = BoolCapture()
        let hostClosed = BoolCapture()
        let socket = CompanionRelayVirtualSocket(
            id: String(repeating: "z", count: CompanionRelayMux.channelIDBytes),
            writer: { _ in },
            closer: { peerClosed.setTrue() }
        )
        let maximum = CompanionRelayMux.maximumDevicePayloadBytes
        await socket.receive(Data(repeating: 1, count: maximum))
        await socket.receive(Data(repeating: 2, count: maximum))
        await socket.receive(Data(repeating: 3, count: 256))
        XCTAssertTrue(peerClosed.value)
        await socket.install(receiver: { _ in }, onClose: { hostClosed.setTrue() })
        XCTAssertTrue(hostClosed.value)
    }

    func testRelayVirtualStreamRunsTheRealNoiseResumeAndDesktopHello() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-relay-resume-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let desktop = try CompanionIdentity(
            id: "desktop-relay-resume",
            role: .desktop,
            displayName: "Relay Mac"
        )
        let device = try CompanionIdentity(
            id: "device-relay-resume",
            role: .device,
            displayName: "Relay iPhone"
        )
        let roster = try CompanionDeviceRosterStore(
            fileURL: directory.appendingPathComponent("devices-v3.json"),
            accountScope: try CompanionAccountScope(accountID: "link-client-test-account")
        )
        _ = try await roster.pair(
            peer: CompanionIdentityPin(
                id: device.id,
                identityPublic: device.identityPublic,
                x25519StaticPublic: device.x25519StaticPublic
            ),
            displayName: device.displayName,
            capabilities: [.observe, .terminalControl],
            now: 1_900_000_000_000
        )
        let coordinator = try CompanionPairingCoordinator(identity: desktop, roster: roster)
        let wire = DataCapture()
        let events = RelayEventCapture()
        let socket = CompanionRelayVirtualSocket(
            id: String(repeating: "r", count: CompanionRelayMux.channelIDBytes),
            writer: { wire.append($0) },
            closer: {}
        )
        let connectionID = "relay-resume-connection"
        let connection = CompanionRelayConnection(
            id: connectionID,
            socket: socket,
            coordinator: coordinator,
            epoch: "epoch-relay-resume",
            eventSink: { events.append($0) }
        )
        try await connection.start()

        let context = CompanionConnectionContext(
            desktopId: desktop.id,
            deviceId: device.id,
            connectionId: connectionID
        )
        let resumeContext: JSONValue = .object([
            "v": .integer(1),
            "mode": .string("resume"),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(desktop.id),
            "deviceId": .string(device.id),
            "connectionId": .string(connectionID),
            "accountScope": .string(roster.accountScope.rawValue),
        ])
        let initiator = try NoiseXXInitiator(
            identity: device,
            prologue: createNoisePrologue(resumeContext),
            peerPin: CompanionIdentityPin(
                id: desktop.id,
                identityPublic: desktop.identityPublic,
                x25519StaticPublic: desktop.x25519StaticPublic
            )
        )
        let start = try relayFrame(JSONValue.object([
            "v": .integer(1),
            "type": .string("resume.start"),
            "deviceId": .string(device.id),
            "connectionId": .string(connectionID),
            "accountScope": .string(roster.accountScope.rawValue),
            "message1": .string(try initiator.writeMessage1().base64URLEncodedString()),
        ]))
        await socket.receive(Data(start.prefix(5)))
        XCTAssertTrue(wire.snapshot().isEmpty)
        await socket.receive(Data(start.dropFirst(5)))
        try await eventually { wire.snapshot().count == 1 }

        let message2 = try relayObject(relayPayload(from: wire.snapshot()[0]))
        let sessionID = try XCTUnwrap(message2["sessionId"]?.stringValue)
        let message2Data = try XCTUnwrap(
            message2["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        _ = try initiator.readMessage2(message2Data)
        await socket.receive(try relayFrame(JSONValue.object([
            "v": .integer(1),
            "type": .string("resume.message3"),
            "sessionId": .string(sessionID),
            "message3": .string(try initiator.writeMessage3().base64URLEncodedString()),
        ])))
        try await eventually { wire.snapshot().count == 2 }

        let result = try initiator.result()
        let phoneChannel = try SecureFrameChannel(result: result, context: context, role: .device)
        let confirmation = try relayObject(relayPayload(from: wire.snapshot()[1]))
        let desktopConfirmation = try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: CanonicalJSON.data(from: try XCTUnwrap(confirmation["confirmationFrame"]))
        )
        try CompanionKeyConfirmation.verify(
            channel: phoneChannel,
            frame: desktopConfirmation,
            expectedRole: .desktop,
            handshakeHash: result.handshakeHash
        )
        await socket.receive(try relayFrame(CompanionKeyConfirmation.make(
            channel: phoneChannel,
            role: .device,
            handshakeHash: result.handshakeHash
        )))
        try await eventually { wire.snapshot().count == 3 }

        let desktopHelloFrame = try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: relayPayload(from: wire.snapshot()[2])
        )
        let desktopHello = try CompanionProtocolCodec.decode(
            phoneChannel.decrypt(desktopHelloFrame)
        )
        XCTAssertEqual(desktopHello.kind, .hello)
        XCTAssertEqual(desktopHello.connectionId, connectionID)
        XCTAssertEqual(desktopHello.epoch, "epoch-relay-resume")
        XCTAssertEqual(
            try desktopHello.body.decode(CompanionHelloBody.self).capabilities,
            [.observe, .terminalControl]
        )
        XCTAssertEqual(events.snapshot(), ["authenticated:device-relay-resume:true"])
        await connection.close(reason: "test_complete")
        XCTAssertEqual(events.snapshot().last, "closed:test_complete")
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for relay condition")
    }
}

private func relayFrame<T: Encodable>(_ value: T) throws -> Data {
    try CompanionLengthFrameDecoder.encode(CanonicalJSON.data(from: value))
}

private func relayPayload(from wire: Data) throws -> Data {
    var decoder = CompanionLengthFrameDecoder()
    let values = try decoder.push(wire)
    guard decoder.buffer.isEmpty, values.count == 1, let value = values.first else {
        throw CompanionRelayError.invalidResponse
    }
    return value
}

private func relayObject(_ data: Data) throws -> [String: JSONValue] {
    guard let value = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
        throw CompanionRelayError.invalidResponse
    }
    return value
}

@MainActor
private final class FakeWebSocket: CompanionLinkWebSocket {
    private(set) var resumed = false
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private(set) var cancelCode: URLSessionWebSocketTask.CloseCode?
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?

    func resume() { resumed = true }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { sentMessages.append(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCode = closeCode
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
    func push(_ message: URLSessionWebSocketTask.Message) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else { queued.append(message) }
    }
}

private final class RelayURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw CompanionRelayError.unavailable }
            let (response, data) = try handler(try materializedRequest())
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    /// URLSession converts an upload `httpBody` to a stream before handing the
    /// request to URLProtocol. Materialize only the tiny relay ticket body so
    /// the test can assert its exact fail-closed schema.
    private func materializedRequest() throws -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CompanionRelayError.invalidResponse }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
            guard body.count <= 8 * 1_024 else { throw CompanionRelayError.invalidResponse }
        }
        var value = request
        value.httpBody = body
        return value
    }
}

private final class RequestCapture: @unchecked Sendable {
    struct Value {
        let request: URLRequest
        let body: Data?
    }
    private let lock = NSLock()
    private var values: [Value] = []
    func append(_ request: URLRequest, body: Data?) {
        lock.withLock { values.append(Value(request: request, body: body)) }
    }
    func snapshot() -> [Value] { lock.withLock { values } }
}

private final class SocketCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CompanionRelayVirtualSocket] = []
    func append(_ value: CompanionRelayVirtualSocket) { lock.withLock { values.append(value) } }
    func snapshot() -> [CompanionRelayVirtualSocket] { lock.withLock { values } }
}

private final class DataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ value: Data) { lock.withLock { values.append(value) } }
    func snapshot() -> [Data] { lock.withLock { values } }
}

private final class BoolCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func setTrue() { lock.withLock { stored = true } }
}

private final class RelayEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ event: CompanionConnectionEvent) {
        let value: String
        switch event {
        case let .authenticated(device, resumed): value = "authenticated:\(device.deviceId):\(resumed)"
        case let .closed(reason): value = "closed:\(reason)"
        case .pairingPhrase: value = "pairing"
        case .live: value = "live"
        case .envelope: value = "envelope"
        }
        lock.withLock { values.append(value) }
    }
    func snapshot() -> [String] { lock.withLock { values } }
}

private final class IntCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() -> Int { lock.withLock { stored += 1; return stored } }
}

private extension URLRequest {
    func capturedBody() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
