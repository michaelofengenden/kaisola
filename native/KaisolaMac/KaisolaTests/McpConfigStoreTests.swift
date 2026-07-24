import Foundation
import KaisolaCore
import XCTest
@testable import KaisolaMacPreview

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
}
