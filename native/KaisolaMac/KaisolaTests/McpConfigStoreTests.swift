import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

/// Per-workspace MCP configuration: round-trip persistence in the USER-GLOBAL
/// store (keyed by workspace digest — a cloned repo must never be able to seed
/// auto-run commands), corrupt-file → empty, and `jsonValues` session shapes
/// that mirror `scripts/native-mcp-registry.cjs` `buildSessionServers`
/// byte-for-byte (stdio omits `type`; http/sse carry it; env/headers are
/// arrays of `{name,value}`; disabled servers are dropped).
final class McpConfigStoreTests: XCTestCase {
    private var workspace: URL!
    private var root: URL!

    private func store(_ workspace: URL) -> McpConfigStore {
        McpConfigStore(workspace: workspace, rootDirectory: root)
    }

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mcp-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Persistence

    func testRoundTripAcrossInstances() {
        let servers = [
            McpServerConfig(
                name: "files",
                kind: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                envPairs: [.init(name: "TOKEN", value: "abc")],
                enabled: true
            ),
            McpServerConfig(
                name: "remote",
                kind: .http,
                url: "https://example.com/mcp",
                headerPairs: [.init(name: "Authorization", value: "Bearer xyz")],
                enabled: false
            ),
        ]
        store(workspace).save(servers)

        let reopened = store(workspace)
        XCTAssertEqual(reopened.servers(), servers)
    }

    func testConfigLivesOutsideTheWorkspace() throws {
        store(workspace).save([
            McpServerConfig(name: "x", kind: .stdio, command: "echo"),
        ])
        // The store must be user-global (workspace-digest-keyed), never a file
        // the repository itself could carry.
        let inWorkspace = workspace
            .appendingPathComponent(".kaisola")
            .appendingPathComponent("mcp.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inWorkspace.path))
        XCTAssertTrue(store(workspace).fileURL.path.hasPrefix(root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store(workspace).fileURL.path))
    }

    func testRepoLocalConfigIsIgnored() throws {
        // A malicious clone shipping .kaisola/mcp.json must not be read.
        let directory = workspace.appendingPathComponent(".kaisola")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostile = """
        {"servers":[{"name":"x","kind":"stdio","command":"bash","args":["-c","true"],\
        "envPairs":[],"headerPairs":[],"enabled":true}]}
        """
        try Data(hostile.utf8).write(to: directory.appendingPathComponent("mcp.json"))
        XCTAssertTrue(store(workspace).servers().isEmpty)
    }

    func testDistinctWorkspacesUseDistinctFiles() throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mcp-other-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        store(workspace).save([McpServerConfig(name: "a", kind: .stdio, command: "echo")])
        XCTAssertTrue(store(other).servers().isEmpty)
        XCTAssertNotEqual(store(workspace).fileURL, store(other).fileURL)
    }

    func testMissingFileIsEmpty() {
        XCTAssertTrue(store(workspace).servers().isEmpty)
    }

    func testCorruptFileDegradesToEmpty() throws {
        let target = store(workspace).fileURL
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: target)
        XCTAssertTrue(store(workspace).servers().isEmpty)
    }

    func testSettingsAddPolicyMatchesBoundedStoreAndSurfacesDuplicates() {
        let servers = [
            McpServerConfig(name: "files", kind: .stdio, command: "server"),
        ]
        XCTAssertEqual(
            McpSettingsPolicy.remainingCapacity(serverCount: servers.count),
            McpConfigStore.maximumServerCount - 1
        )
        XCTAssertEqual(
            McpSettingsPolicy.remainingCapacity(serverCount: McpConfigStore.maximumServerCount),
            0
        )
        XCTAssertEqual(
            McpSettingsPolicy.duplicateName("  files  ", servers: servers),
            "files"
        )
        XCTAssertNil(McpSettingsPolicy.duplicateName("other", servers: servers))
    }

    // MARK: - Session wire shapes

    func testStdioJsonValueMatchesNodeShape() {
        let server = McpServerConfig(
            name: "files",
            kind: .stdio,
            command: "npx",
            args: ["-y", "server-filesystem"],
            envPairs: [.init(name: "TOKEN", value: "abc")],
            enabled: true
        )
        // Hand-built to the exact key set buildSessionServers emits for stdio:
        // {name, command, args, env:[{name,value}]} — no `type`.
        let expected: JSONValue = .object([
            "name": .string("files"),
            "command": .string("npx"),
            "args": .array([.string("-y"), .string("server-filesystem")]),
            "env": .array([.object(["name": .string("TOKEN"), "value": .string("abc")])]),
        ])
        XCTAssertEqual(McpConfigStore.jsonValues([server]), [expected])
    }

    func testHttpJsonValueMatchesNodeShape() {
        let server = McpServerConfig(
            name: "remote",
            kind: .http,
            url: "https://example.com/mcp",
            headerPairs: [.init(name: "Authorization", value: "Bearer xyz")],
            enabled: true
        )
        // Hand-built to the exact key set buildSessionServers emits for http/sse:
        // {type, name, url, headers:[{name,value}]}.
        let expected: JSONValue = .object([
            "type": .string("http"),
            "name": .string("remote"),
            "url": .string("https://example.com/mcp"),
            "headers": .array([.object(["name": .string("Authorization"), "value": .string("Bearer xyz")])]),
        ])
        XCTAssertEqual(McpConfigStore.jsonValues([server]), [expected])
    }

    func testStdioOmitsTypeAndAlwaysCarriesEmptyArgsAndEnv() {
        let server = McpServerConfig(name: "bare", kind: .stdio, command: "run", enabled: true)
        let object = McpConfigStore.jsonValues([server]).first?.objectValue
        XCTAssertNil(object?["type"])
        XCTAssertEqual(object?["args"], .array([]))
        XCTAssertEqual(object?["env"], .array([]))
    }

    func testSseCarriesTypeAndAlwaysCarriesEmptyHeaders() {
        let server = McpServerConfig(name: "stream", kind: .sse, url: "https://example.com/sse", enabled: true)
        let object = McpConfigStore.jsonValues([server]).first?.objectValue
        XCTAssertEqual(object?["type"], .string("sse"))
        XCTAssertEqual(object?["headers"], .array([]))
    }

    func testDisabledServersExcluded() {
        let servers = [
            McpServerConfig(name: "on", kind: .stdio, command: "a", enabled: true),
            McpServerConfig(name: "off", kind: .stdio, command: "b", enabled: false),
        ]
        let values = McpConfigStore.jsonValues(servers)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.objectValue?["name"], .string("on"))
    }

    func testInvalidRemoteServersNeverReachSessionWire() {
        let insecure = McpServerConfig(name: "remote", kind: .http, url: "http://example.com/mcp")
        let credentialed = McpServerConfig(
            name: "secret", kind: .sse, url: "https://user:password@example.com/sse"
        )
        XCTAssertNotNil(insecure.validationError)
        XCTAssertNotNil(credentialed.validationError)
        XCTAssertTrue(McpConfigStore.jsonValues([insecure, credentialed]).isEmpty)
    }

    func testInvalidStdioCommandNeverReachesSessionWire() {
        let empty = McpServerConfig(name: "bad", kind: .stdio, command: "  ")
        let multiline = McpServerConfig(name: "bad2", kind: .stdio, command: "sh\necho")
        XCTAssertTrue(McpConfigStore.jsonValues([empty, multiline]).isEmpty)
    }

    func testManualCatalogEntriesAreStrictlyBounded() {
        let tooManyArguments = McpServerConfig(
            name: "args",
            kind: .stdio,
            command: "server",
            args: Array(repeating: "value", count: 65)
        )
        let tooManyPairs = McpServerConfig(
            name: "pairs",
            kind: .stdio,
            command: "server",
            envPairs: (0..<33).map { .init(name: "KEY_\($0)", value: "value") }
        )
        let oversized = McpServerConfig(
            name: String(repeating: "n", count: 129),
            kind: .http,
            url: "https://example.com/mcp",
            headerPairs: [.init(name: "X-Test", value: String(repeating: "v", count: 4_097))]
        )
        let controlCharacter = McpServerConfig(
            name: "unsafe\u{7}",
            kind: .stdio,
            command: "server"
        )

        XCTAssertNotNil(tooManyArguments.validationError)
        XCTAssertNotNil(tooManyPairs.validationError)
        XCTAssertNotNil(oversized.validationError)
        XCTAssertNotNil(controlCharacter.validationError)
        XCTAssertTrue(McpConfigStore.jsonValues([
            tooManyArguments, tooManyPairs, oversized, controlCharacter,
        ]).isEmpty)
    }

    // MARK: - Sibling discovery and disabled import

    func testDiscoveryReadsKnownJSONAndCodexTOMLWithoutMaterializingSecrets() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try write(
            #"{"mcpServers":{"cursor-safe":{"command":"npx","args":["-y","safe-server"],"env":{"TOKEN":"${CURSOR_TOKEN}"}},"literal-secret":{"command":"unsafe","env":{"API_KEY":"plaintext"}}}}"#,
            relativePath: ".cursor/mcp.json",
            home: home
        )
        try write(
            """
            [mcp_servers.docs]
            url = "https://docs.example/mcp"
            bearer_token_env_var = "DOCS_TOKEN"

            [mcp_servers.local.env]
            MODE = "read-only"
            [mcp_servers.local]
            command = "local-mcp"
            args = ["--stdio"]
            """,
            relativePath: ".codex/config.toml",
            home: home
        )

        let found = McpConfigDiscovery.scan(homeDirectory: home)
        XCTAssertEqual(Set(found.map { $0.config.name }), ["cursor-safe", "docs", "local"])
        XCTAssertFalse(found.contains { $0.config.name == "literal-secret" })
        XCTAssertTrue(found.allSatisfy { !$0.config.enabled })
        let docs = try XCTUnwrap(found.first { $0.config.name == "docs" })
        XCTAssertEqual(docs.origin, "Codex CLI")
        XCTAssertEqual(
            docs.config.headerPairs,
            [.init(name: "Authorization", value: "Bearer ${DOCS_TOKEN}")]
        )
        let cursor = try XCTUnwrap(found.first { $0.config.name == "cursor-safe" })
        XCTAssertEqual(cursor.config.envPairs, [.init(name: "TOKEN", value: "${CURSOR_TOKEN}")])
    }

    func testDiscoveryRejectsSymlinkedAndOversizedInputs() throws {
        let home = root.appendingPathComponent("bounded-home", isDirectory: true)
        let external = root.appendingPathComponent("external.json")
        try Data(#"{"mcpServers":{"linked":{"command":"do-not-read"}}}"#.utf8).write(to: external)
        let cursorDirectory = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cursorDirectory.appendingPathComponent("mcp.json"),
            withDestinationURL: external
        )
        try write(
            String(repeating: "x", count: 1_000_001),
            relativePath: ".gemini/settings.json",
            home: home
        )

        XCTAssertTrue(McpConfigDiscovery.scan(homeDirectory: home).isEmpty)
    }

    func testImportIsExplicitDisabledCollisionSafeAndBounded() {
        store(workspace).save([McpServerConfig(name: "existing", kind: .stdio, command: "keep")])
        let discoveries = [
            McpDiscoveredServer(
                origin: "Cursor",
                config: McpServerConfig(name: "existing", kind: .stdio, command: "replace")
            ),
            McpDiscoveredServer(
                origin: "Codex CLI",
                config: McpServerConfig(name: "new", kind: .http, url: "https://example.com/mcp")
            ),
        ]

        XCTAssertEqual(store(workspace).importDiscovered(discoveries), 1)
        let saved = store(workspace).servers()
        XCTAssertEqual(saved.first { $0.name == "existing" }?.command, "keep")
        XCTAssertEqual(saved.first { $0.name == "new" }?.enabled, false)
    }

    // MARK: - Protocol revision negotiation (pure)

    func testProtocolRevisionRequestsTheNewestKnownRevision() {
        XCTAssertEqual(McpProtocolRevision.requested, "2025-11-25")
    }

    func testProtocolRevisionAcceptsAnExactMatch() {
        XCTAssertTrue(McpProtocolRevision.isAccepted("2025-11-25"))
    }

    func testProtocolRevisionAcceptsAServerDowngradeToAKnownOlderRevision() {
        XCTAssertTrue(McpProtocolRevision.isAccepted("2025-06-18"))
    }

    func testProtocolRevisionRejectsAnUnknownOrFutureRevision() {
        XCTAssertFalse(McpProtocolRevision.isAccepted("2024-11-05"))
        XCTAssertFalse(McpProtocolRevision.isAccepted("2099-01-01"))
    }

    func testProtocolRevisionRejectsMalformedOrMissingVersions() {
        XCTAssertFalse(McpProtocolRevision.isAccepted(nil))
        XCTAssertFalse(McpProtocolRevision.isAccepted(""))
        XCTAssertFalse(McpProtocolRevision.isAccepted("not-a-revision"))
    }

    // MARK: - MCP lifecycle probe

    func testStdioAndLegacySSEProbesNeverOpenANetworkConnection() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpProbeURLProtocol.self]
        McpProbeURLProtocol.handler = { _ in XCTFail("Probe unexpectedly used the network"); throw URLError(.badURL) }
        defer { McpProbeURLProtocol.handler = nil }
        let service = McpProbeService(session: URLSession(configuration: configuration))

        let stdio = await service.probe(McpServerConfig(name: "local", kind: .stdio, command: "server"))
        let sse = await service.probe(McpServerConfig(name: "legacy", kind: .sse, url: "https://example.com/sse"))
        XCTAssertEqual(stdio.status, .configured)
        XCTAssertFalse(stdio.verified)
        XCTAssertEqual(sse.status, .configured)
        XCTAssertFalse(sse.verified)
    }

    func testHTTPProbeNegotiatesSessionHeadersAndListsTools() async throws {
        let capture = McpProbeRequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpProbeURLProtocol.self]
        McpProbeURLProtocol.handler = { request in
            let request = try request.materializingBody()
            capture.append(request)
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let method = try XCTUnwrap(object["method"] as? String)
            let headers: [String: String]
            let data: Data
            switch method {
            case "initialize":
                XCTAssertNil(request.value(forHTTPHeaderField: "MCP-Protocol-Version"))
                let params = object["params"] as? [String: Any]
                XCTAssertEqual(params?["protocolVersion"] as? String, "2025-11-25")
                headers = ["Content-Type": "application/json", "Mcp-Session-Id": "probe-session"]
                // Server legitimately downgrades to the older revision it
                // supports; the probe must accept it, not demand an exact echo.
                data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1.2"}}}"#.utf8)
            case "notifications/initialized":
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "probe-session")
                headers = [:]
                data = Data()
            case "tools/list":
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "probe-session")
                headers = ["Content-Type": "text/event-stream"]
                data = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"one\"}],\"nextCursor\":\"more\"}}\n\n".utf8)
            default:
                XCTFail("Unexpected MCP method \(method)")
                headers = [:]
                data = Data()
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: method == "notifications/initialized" ? 202 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, data)
        }
        defer { McpProbeURLProtocol.handler = nil }
        let service = McpProbeService(session: URLSession(configuration: configuration))
        let result = await service.probe(McpServerConfig(
            name: "remote",
            kind: .http,
            url: "https://example.com/mcp",
            headerPairs: [
                .init(name: "Authorization", value: "Bearer ${TOKEN}"),
                .init(name: "MCP-Protocol-Version", value: "wrong"),
            ]
        ))

        XCTAssertEqual(result.status, .ready)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.serverName, "fixture")
        XCTAssertEqual(result.serverVersion, "1.2")
        XCTAssertEqual(result.toolCount, 1)
        XCTAssertTrue(result.hasMoreTools)
        XCTAssertEqual(capture.snapshot().count, 3)
        XCTAssertTrue(capture.snapshot().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer ${TOKEN}"
        })
    }

    func testHTTPProbeRespectsMissingToolsCapability() async throws {
        let capture = McpProbeRequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpProbeURLProtocol.self]
        McpProbeURLProtocol.handler = { request in
            let request = try request.materializingBody()
            capture.append(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            let method = try XCTUnwrap(object["method"] as? String)
            let data = method == "initialize"
                ? Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"no-tools","version":"1"}}}"#.utf8)
                : Data()
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: method == "initialize" ? 200 : 202,
                    httpVersion: "HTTP/1.1",
                    headerFields: method == "initialize" ? ["Content-Type": "application/json"] : [:]
                )!,
                data
            )
        }
        defer { McpProbeURLProtocol.handler = nil }
        let service = McpProbeService(session: URLSession(configuration: configuration))

        let result = await service.probe(McpServerConfig(
            name: "remote",
            kind: .http,
            url: "https://example.com/mcp"
        ))
        XCTAssertEqual(result.status, .ready)
        XCTAssertNil(result.toolCount)
        XCTAssertEqual(capture.snapshot().count, 2)
    }

    func testHTTPProbeFailsOnAGenuinelyUnsupportedProtocolVersion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpProbeURLProtocol.self]
        McpProbeURLProtocol.handler = { request in
            let request = try request.materializingBody()
            let data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2099-01-01","capabilities":{},"serverInfo":{"name":"future","version":"1"}}}"#.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { McpProbeURLProtocol.handler = nil }
        let service = McpProbeService(session: URLSession(configuration: configuration))

        let result = await service.probe(McpServerConfig(name: "remote", kind: .http, url: "https://example.com/mcp"))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(result.message.contains("Unsupported protocol version"))
    }

    private func write(_ value: String, relativePath: String, home: URL) throws {
        let target = home.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: target)
    }
}

private final class McpProbeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.resourceUnavailable) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class McpProbeRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func snapshot() -> [URLRequest] { lock.withLock { requests } }
}

private extension URLRequest {
    func materializingBody() throws -> URLRequest {
        guard httpBody == nil, let stream = httpBodyStream else { return self }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
            guard body.count <= 64 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        }
        var result = self
        result.httpBody = body
        return result
    }
}
