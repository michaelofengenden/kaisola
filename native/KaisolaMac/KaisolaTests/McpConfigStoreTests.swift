import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

private enum TestMcpSecretError: Error {
    case refused
}

private final class TestMcpSecretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    var writeError: Error?

    var values: [String: String] {
        lock.withLock { storage }
    }

    var vault: McpSecretVault {
        McpSecretVault(
            read: { [weak self] reference in
                self?.lock.withLock { self?.storage[reference] }
            },
            write: { [weak self] reference, value in
                guard let self else { return }
                try self.lock.withLock {
                    if let writeError = self.writeError { throw writeError }
                    self.storage[reference] = value
                }
            },
            delete: { [weak self] reference in
                self?.lock.withLock { self?.storage[reference] = nil }
            }
        )
    }
}

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

    private func store(_ workspace: URL, secrets: TestMcpSecretBox) -> McpConfigStore {
        McpConfigStore(
            workspace: workspace,
            rootDirectory: root,
            secretVault: secrets.vault
        )
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

    // MARK: - OAuth secret references and consented migration

    func testOAuthSecretReferencesAreStableScopedAndOpaque() {
        let first = McpOAuthSecretReference.make(
            projectID: "project-a",
            serverName: "remote",
            location: .header,
            pairName: "Authorization"
        )
        let again = McpOAuthSecretReference.make(
            projectID: "project-a",
            serverName: "remote",
            location: .header,
            pairName: "Authorization"
        )
        let otherProject = McpOAuthSecretReference.make(
            projectID: "project-b",
            serverName: "remote",
            location: .header,
            pairName: "Authorization"
        )

        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, otherProject)
        XCTAssertTrue(first.hasPrefix("mcp-oauth-v1:"))
        XCTAssertFalse(first.contains("project-a"))
        XCTAssertFalse(first.localizedCaseInsensitiveContains("authorization"))
    }

    func testSecretPolicyCoversOAuthTokensAndKeysWithoutCapturingPlaceholders() {
        for name in ["Authorization", "OAUTH_CLIENT_SECRET", "GITHUB_TOKEN", "X-API-Key"] {
            XCTAssertTrue(
                McpOAuthSecretPolicy.requiresKeychain(.init(name: name, value: "credential")),
                name
            )
        }
        XCTAssertFalse(
            McpOAuthSecretPolicy.requiresKeychain(
                .init(name: "Authorization", value: "Bearer ${MCP_TOKEN}")
            )
        )
        XCTAssertFalse(McpOAuthSecretPolicy.requiresKeychain(.init(name: "REGION", value: "us-east-1")))
    }

    func testPlaintextOAuthMigrationRequiresConsentThenPersistsOnlyAReference() throws {
        let secrets = TestMcpSecretBox()
        let configured = store(workspace, secrets: secrets)
        let plaintext = "never-write-this-to-json-again"
        configured.save([
            McpServerConfig(
                name: "remote",
                kind: .http,
                url: "https://example.test/mcp",
                headerPairs: [.init(name: "Authorization", value: "Bearer \(plaintext)")]
            ),
        ])
        XCTAssertEqual(configured.pendingPlaintextOAuthSecretCount(), 1)
        let before = try Data(contentsOf: configured.fileURL)
        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains(plaintext))
        XCTAssertFalse(String(decoding: try configured.exportData(), as: UTF8.self).contains(plaintext))

        XCTAssertThrowsError(try configured.migratePlaintextOAuthSecrets(consent: false)) { error in
            XCTAssertEqual(error as? McpOAuthSecretMigrationError, .consentRequired)
        }
        XCTAssertEqual(try Data(contentsOf: configured.fileURL), before)
        XCTAssertTrue(secrets.values.isEmpty)

        let receipt = try configured.migratePlaintextOAuthSecrets(consent: true)
        XCTAssertEqual(receipt.migratedCount, 1)
        let migrated = try XCTUnwrap(receipt.servers.first?.headerPairs.first)
        let reference = try XCTUnwrap(migrated.secretReference)
        XCTAssertEqual(migrated.value, "")
        XCTAssertEqual(secrets.values[reference], "Bearer \(plaintext)")

        let persisted = try Data(contentsOf: configured.fileURL)
        let persistedText = String(decoding: persisted, as: UTF8.self)
        XCTAssertFalse(persistedText.contains(plaintext))
        XCTAssertTrue(persistedText.contains(reference))
        XCTAssertFalse(String(decoding: try configured.exportData(), as: UTF8.self).contains(plaintext))

        let wire = try XCTUnwrap(configured.sessionJSONValues().first?.objectValue)
        XCTAssertEqual(
            wire["headers"],
            .array([.object([
                "name": .string("Authorization"),
                "value": .string("Bearer \(plaintext)"),
            ])])
        )
    }

    func testFailedKeychainMigrationLeavesTheOriginalConfigurationByteExact() throws {
        let secrets = TestMcpSecretBox()
        secrets.writeError = TestMcpSecretError.refused
        let configured = store(workspace, secrets: secrets)
        configured.save([
            McpServerConfig(
                name: "local",
                kind: .stdio,
                command: "server",
                envPairs: [.init(name: "OAUTH_REFRESH_TOKEN", value: "refresh-plaintext")]
            ),
        ])
        let before = try Data(contentsOf: configured.fileURL)

        XCTAssertThrowsError(try configured.migratePlaintextOAuthSecrets(consent: true))
        XCTAssertEqual(try Data(contentsOf: configured.fileURL), before)
        XCTAssertEqual(configured.pendingPlaintextOAuthSecretCount(), 1)
        XCTAssertTrue(secrets.values.isEmpty)
    }

    func testConfigurationFailureRollsBackTheNewKeychainItem() throws {
        try Data("not-a-directory".utf8).write(to: root.appendingPathComponent("mcp"))
        let secrets = TestMcpSecretBox()
        let configured = store(workspace, secrets: secrets)

        XCTAssertThrowsError(try configured.saveSecuringOAuthSecrets([
            McpServerConfig(
                name: "local",
                kind: .stdio,
                command: "server",
                envPairs: [.init(name: "ACCESS_TOKEN", value: "new-access-token")]
            ),
        ], consent: true)) { error in
            XCTAssertEqual(error as? McpOAuthSecretMigrationError, .configurationWriteFailed)
        }
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configured.fileURL.path))
    }

    func testNewOAuthSecretIsInKeychainBeforeConfigurationIsPersisted() throws {
        let secrets = TestMcpSecretBox()
        let configured = store(workspace, secrets: secrets)
        let plaintext = "new-client-secret"

        let receipt = try configured.appendSecuringOAuthServer(
            McpServerConfig(
                name: "local",
                kind: .stdio,
                command: "server",
                envPairs: [.init(name: "OAUTH_CLIENT_SECRET", value: plaintext)]
            ),
            to: [],
            consent: true
        )

        XCTAssertEqual(receipt.migratedCount, 1)
        let reference = try XCTUnwrap(receipt.servers.first?.envPairs.first?.secretReference)
        XCTAssertEqual(secrets.values[reference], plaintext)
        let persisted = String(decoding: try Data(contentsOf: configured.fileURL), as: UTF8.self)
        XCTAssertTrue(persisted.contains(reference))
        XCTAssertFalse(persisted.contains(plaintext))
    }

    func testAddingANewServerDoesNotImplicitlyMigrateOlderPlaintext() throws {
        let secrets = TestMcpSecretBox()
        let configured = store(workspace, secrets: secrets)
        let legacy = McpServerConfig(
            name: "legacy",
            kind: .http,
            url: "https://legacy.example/mcp",
            headerPairs: [.init(name: "Authorization", value: "Bearer legacy-token")]
        )
        configured.save([legacy])

        let receipt = try configured.appendSecuringOAuthServer(
            McpServerConfig(name: "new", kind: .stdio, command: "server"),
            to: configured.servers(),
            consent: true
        )

        XCTAssertEqual(receipt.migratedCount, 0)
        XCTAssertEqual(configured.pendingPlaintextOAuthSecretCount(), 1)
        XCTAssertTrue(String(decoding: try Data(contentsOf: configured.fileURL), as: UTF8.self).contains("legacy-token"))
        XCTAssertTrue(secrets.values.isEmpty)
    }

    func testMissingReferencedSecretFailsClosedBeforeSessionLaunch() throws {
        let secrets = TestMcpSecretBox()
        let configured = store(workspace, secrets: secrets)
        configured.save([
            McpServerConfig(
                name: "remote",
                kind: .http,
                url: "https://example.test/mcp",
                headerPairs: [
                    .init(
                        name: "Authorization",
                        value: "",
                        secretReference: "mcp-oauth-v1:missing"
                    ),
                ]
            ),
        ])

        XCTAssertTrue(configured.sessionJSONValues().isEmpty)
        XCTAssertFalse(String(decoding: try configured.exportData(), as: UTF8.self).contains("Authorization\":\"Bearer"))
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

    func testSettingsChangeScopeNamesEveryMutationAndOffersANewChatOnlyWhenUseful() {
        XCTAssertEqual(McpSettingsPolicy.changeScopeTitle, "New chats only")
        XCTAssertEqual(
            McpSettingsPolicy.changeScopeDetail(openChatCount: 0),
            "Enable, disable, add, edit, delete, and import changes apply when you start a new chat."
        )
        XCTAssertEqual(
            McpSettingsPolicy.changeScopeDetail(openChatCount: 2),
            "2 open chats keep their current MCP tools. Start a new chat to use enable, disable, add, edit, delete, or import changes."
        )
        XCTAssertFalse(McpSettingsPolicy.offersNewChatAction(
            openChatCount: 0,
            canStartNewChat: true
        ))
        XCTAssertFalse(McpSettingsPolicy.offersNewChatAction(
            openChatCount: 1,
            canStartNewChat: false
        ))
        XCTAssertTrue(McpSettingsPolicy.offersNewChatAction(
            openChatCount: 1,
            canStartNewChat: true
        ))
    }

    func testSettingsAddPolicyUsesOneCaseInsensitiveTrimmedNameForValidationAndPersistence() {
        let servers = [
            McpServerConfig(name: "Project Files", kind: .stdio, command: "server"),
        ]

        XCTAssertEqual(
            McpSettingsPolicy.normalizedName("  PROJECT FILES \n"),
            "PROJECT FILES"
        )
        XCTAssertEqual(
            McpSettingsPolicy.duplicateName("  PROJECT FILES \n", servers: servers),
            "PROJECT FILES"
        )
        XCTAssertFalse(McpSettingsPolicy.canAddServer(
            rawName: "  PROJECT FILES \n",
            servers: servers,
            hasRequiredFields: true,
            remainingCapacity: 1
        ))
        XCTAssertTrue(McpSettingsPolicy.canAddServer(
            rawName: "  Other Server \n",
            servers: servers,
            hasRequiredFields: true,
            remainingCapacity: 1
        ))
        XCTAssertFalse(McpSettingsPolicy.canAddServer(
            rawName: "Other Server",
            servers: servers,
            hasRequiredFields: true,
            remainingCapacity: 0
        ))
        XCTAssertFalse(McpSettingsPolicy.canAddServer(
            rawName: " \n ",
            servers: servers,
            hasRequiredFields: true,
            remainingCapacity: 1
        ))
        XCTAssertFalse(McpSettingsPolicy.canAddServer(
            rawName: "Other Server",
            servers: servers,
            hasRequiredFields: false,
            remainingCapacity: 1
        ))
        XCTAssertFalse(McpSettingsPolicy.canAddServer(
            rawName: "Other Server",
            servers: servers,
            hasRequiredFields: true,
            remainingCapacity: 1,
            pairText: "MISSING_SEPARATOR"
        ))
        XCTAssertTrue(McpSettingsPolicy.canAddServer(
            rawName: "Other Server",
            servers: servers,
            hasRequiredFields: true,
            remainingCapacity: 1,
            pairText: "EMPTY="
        ))

        let persisted = McpServerConfig(
            name: McpSettingsPolicy.normalizedName("  Other Server \n"),
            kind: .stdio,
            command: "server"
        )
        store(workspace).save(servers + [persisted])
        XCTAssertEqual(store(workspace).servers().map(\.name), ["Project Files", "Other Server"])
    }

    func testSettingsDuplicateMessageIsContentSpecificAndSafeForFieldAndButtonHints() {
        XCTAssertEqual(
            McpSettingsPolicy.duplicateMessage("Project Files"),
            "A server named \"Project Files\" already exists in this project."
        )
    }

    // MARK: - Environment / header line validation

    /// Every non-blank line either becomes a pair or is reported by number. A
    /// line that is neither must never exist: that is how a header used to
    /// vanish while Add reported success.
    func testEveryMalformedPairLineIsReportedWithItsLineNumber() {
        let parse = McpSettingsPolicy.parsePairs("""
        TOKEN=abc

        MISSING_SEPARATOR
        =orphan-value
        EMPTY=
        """)

        XCTAssertEqual(parse.pairs, [
            .init(name: "TOKEN", value: "abc"),
            .init(name: "EMPTY", value: ""),
        ])
        XCTAssertEqual(parse.problems.map(\.line), [3, 4])
        XCTAssertTrue(parse.problems[0].reason.contains("\"=\""))
        XCTAssertTrue(parse.problems[1].reason.contains("name"))
    }

    /// Blank lines are still counted, and CRLF must not shift the number the
    /// user is pointed at.
    func testPairLineNumbersFollowTheEditorIncludingBlankAndCRLFLines() {
        XCTAssertEqual(
            McpSettingsPolicy.parsePairs("A=1\r\n\r\nBROKEN").problems.map(\.line),
            [3]
        )
        XCTAssertEqual(
            McpSettingsPolicy.parsePairs("\n\n\n  \nBROKEN").problems.map(\.line),
            [5]
        )
    }

    /// `NAME=` is a real setting (an explicitly empty variable or header), so it
    /// must parse and keep its empty value rather than be reported or dropped.
    func testEmptyValuesParseAndKeepTheirEmptyString() {
        let parse = McpSettingsPolicy.parsePairs("TOKEN=\n  SPACED  =   ")
        XCTAssertTrue(parse.problems.isEmpty)
        XCTAssertEqual(parse.pairs, [
            .init(name: "TOKEN", value: ""),
            .init(name: "SPACED", value: ""),
        ])
    }

    /// Bounds that `McpServerConfig.safePair` would only reject for the whole
    /// server are reported against the line that broke them.
    func testOversizedAndControlCharacterLinesAreReportedPerLine() {
        let longName = String(repeating: "N", count: 129)
        let longValue = String(repeating: "v", count: 4_097)
        let parse = McpSettingsPolicy.parsePairs("""
        \(longName)=fine
        NAME=\(longValue)
        BE\u{7}LL=fine
        """)

        XCTAssertTrue(parse.pairs.isEmpty)
        XCTAssertEqual(parse.problems.map(\.line), [1, 2, 3])
        XCTAssertTrue(parse.problems[0].reason.contains("128"))
        XCTAssertTrue(parse.problems[1].reason.contains("4096"))
        XCTAssertTrue(parse.problems[2].reason.contains("control"))
    }

    /// The Add gate the button binds to: a malformed line blocks the save while
    /// the draft text stays exactly as typed, and the existing capacity and
    /// duplicate rules keep applying.
    func testAddIsBlockedUntilEveryPairLineParses() {
        let draft = "TOKEN=abc\nMISSING_SEPARATOR"
        XCTAssertFalse(McpSettingsPolicy.canAdd(
            hasRequiredFields: true, serverCount: 0, duplicateName: nil, pairText: draft
        ))
        XCTAssertTrue(McpSettingsPolicy.canAdd(
            hasRequiredFields: true, serverCount: 0, duplicateName: nil, pairText: "TOKEN=abc\n\nEMPTY="
        ))
        XCTAssertFalse(McpSettingsPolicy.canAdd(
            hasRequiredFields: false, serverCount: 0, duplicateName: nil, pairText: ""
        ))
        XCTAssertFalse(McpSettingsPolicy.canAdd(
            hasRequiredFields: true, serverCount: 0, duplicateName: "files", pairText: ""
        ))
        XCTAssertFalse(McpSettingsPolicy.canAdd(
            hasRequiredFields: true,
            serverCount: McpConfigStore.maximumServerCount,
            duplicateName: nil,
            pairText: ""
        ))
    }

    /// The message shown when a save is attempted names every bad line, not
    /// just the first, and says nothing was saved.
    func testMalformedPairMessageNamesEveryBadLine() {
        let problems = McpSettingsPolicy.parsePairs("BROKEN\n=orphan\nOK=1").problems
        let message = McpSettingsPolicy.malformedPairMessage(field: "Headers", problems: problems)
        XCTAssertEqual(
            message?.contains("Headers could not be read, so nothing was saved:"), true
        )
        XCTAssertEqual(message?.contains("Line 1:"), true)
        XCTAssertEqual(message?.contains("Line 2:"), true)
        XCTAssertNil(McpSettingsPolicy.malformedPairMessage(field: "Headers", problems: []))
    }
    // MARK: - Session wire shapes

    func testStdioJsonValueMatchesNodeShape() {
        let server = McpServerConfig(
            name: "files",
            kind: .stdio,
            command: "npx",
            args: ["-y", "server-filesystem"],
            envPairs: [.init(name: "REGION", value: "us-east-1")],
            enabled: true
        )
        // Hand-built to the exact key set buildSessionServers emits for stdio:
        // {name, command, args, env:[{name,value}]} — no `type`.
        let expected: JSONValue = .object([
            "name": .string("files"),
            "command": .string("npx"),
            "args": .array([.string("-y"), .string("server-filesystem")]),
            "env": .array([.object(["name": .string("REGION"), "value": .string("us-east-1")])]),
        ])
        XCTAssertEqual(McpConfigStore.jsonValues([server]), [expected])
    }

    func testHttpJsonValueMatchesNodeShape() {
        let reference = McpOAuthSecretReference.make(
            projectID: "project",
            serverName: "remote",
            location: .header,
            pairName: "Authorization"
        )
        let server = McpServerConfig(
            name: "remote",
            kind: .http,
            url: "https://example.com/mcp",
            headerPairs: [.init(name: "Authorization", value: "", secretReference: reference)],
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
        XCTAssertEqual(
            McpConfigStore.jsonValues([server]) { $0 == reference ? "Bearer xyz" : nil },
            [expected]
        )
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

    /// GHSA-7p8r-x3mc-p8w7. A stored URL is read back by `URLComponents` here,
    /// by WHATWG `new URL` in `scripts/native-mcp-registry.cjs`, and by whatever
    /// RFC 3986 parser the agent links. These spellings name a different host to
    /// each of them, so none of them may be allowed to pick one.
    func testAmbiguousRemoteURLsNeverReachSessionWire() {
        let ambiguous = [
            "https:\\\\evil.test/mcp",
            "https:/\\evil.test/mcp",
            "https:\\/evil.test/mcp",
            "https://good.test\\@evil.test/mcp",
            "https://good.test\\.evil.test/mcp",
            "https://good.test/schema\\..\\evil.test",
            "https://good.test%09.evil.test/mcp",
        ]
        let servers = ambiguous.enumerated().map { index, url in
            McpServerConfig(name: "probe\(index)", kind: .http, url: url)
        }
        for (url, server) in zip(ambiguous, servers) {
            XCTAssertEqual(
                server.validationError,
                "Remote MCP servers must use a valid HTTPS URL.",
                "accepted \(url)"
            )
        }
        XCTAssertTrue(McpConfigStore.jsonValues(servers).isEmpty)
    }

    /// The guard above rejects a spelling, not a destination: ordinary public
    /// hosts, loopback, IPv6 literals, a private-CA endpoint on its own port,
    /// and a percent-encoded backslash in the path all stay usable.
    func testOrdinaryRemoteURLsStillReachSessionWire() {
        let ordinary = [
            "https://api.example.test/v1",
            "https://localhost:8443/mcp",
            "https://127.0.0.1:8443/mcp",
            "https://[::1]:8443/mcp",
            "https://mcp.internal.corp.test:8443/mcp",
            "https://good.test/a%5Cb",
        ]
        let servers = ordinary.enumerated().map { index, url in
            McpServerConfig(name: "ok\(index)", kind: .http, url: url)
        }
        for (url, server) in zip(ordinary, servers) {
            XCTAssertNil(server.validationError, "rejected \(url)")
        }
        XCTAssertEqual(McpConfigStore.jsonValues(servers).count, ordinary.count)
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

    func testDiscoveryReadsKnownJSONAndCodexTOMLWithoutExpandingPlaceholders() throws {
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
        XCTAssertEqual(Set(found.map { $0.config.name }), ["cursor-safe", "docs", "local", "literal-secret"])
        XCTAssertTrue(found.allSatisfy { !$0.config.enabled })
        let literal = try XCTUnwrap(found.first { $0.config.name == "literal-secret" })
        XCTAssertEqual(literal.plaintextSecretCount, 1)
        XCTAssertEqual(literal.config.envPairs, [.init(name: "API_KEY", value: "plaintext")])
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

    func testDiscoveryDropsAmbiguousRemoteURLs() throws {
        let home = root.appendingPathComponent("confused-home", isDirectory: true)
        try write(
            #"{"mcpServers":{"trap":{"url":"https://good.test%09.evil.test/mcp"},"keep":{"url":"https://mcp.internal.corp.test:8443/mcp"}}}"#,
            relativePath: ".cursor/mcp.json",
            home: home
        )

        XCTAssertEqual(McpConfigDiscovery.scan(homeDirectory: home).map { $0.config.name }, ["keep"])
    }

    func testImportIsExplicitDisabledCollisionSafeAndBounded() throws {
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

        let receipt = try store(workspace).importDiscovered(
            discoveries,
            consentToMigrateSecrets: false
        )
        XCTAssertEqual(receipt.importedCount, 1)
        XCTAssertEqual(receipt.migratedSecretCount, 0)
        let saved = store(workspace).servers()
        XCTAssertEqual(saved.first { $0.name == "existing" }?.command, "keep")
        XCTAssertEqual(saved.first { $0.name == "new" }?.enabled, false)
    }

    func testImportMigratesLiteralCredentialOnlyAfterConsent() throws {
        let secrets = TestMcpSecretBox()
        let configured = store(workspace, secrets: secrets)
        let plaintext = "imported-access-token"
        let discovery = McpDiscoveredServer(
            origin: "Cursor",
            config: McpServerConfig(
                name: "remote",
                kind: .http,
                url: "https://example.test/mcp",
                headerPairs: [.init(name: "Authorization", value: "Bearer \(plaintext)")],
                enabled: false
            )
        )

        XCTAssertThrowsError(try configured.importDiscovered(
            [discovery],
            consentToMigrateSecrets: false
        )) { error in
            XCTAssertEqual(error as? McpOAuthSecretMigrationError, .consentRequired)
        }
        XCTAssertTrue(configured.servers().isEmpty)
        XCTAssertTrue(secrets.values.isEmpty)

        let receipt = try configured.importDiscovered(
            [discovery],
            consentToMigrateSecrets: true
        )
        XCTAssertEqual(receipt.importedCount, 1)
        XCTAssertEqual(receipt.migratedSecretCount, 1)
        let imported = try XCTUnwrap(receipt.servers.first)
        XCTAssertFalse(imported.enabled)
        let reference = try XCTUnwrap(imported.headerPairs.first?.secretReference)
        XCTAssertEqual(secrets.values[reference], "Bearer \(plaintext)")
        let persisted = String(decoding: try Data(contentsOf: configured.fileURL), as: UTF8.self)
        XCTAssertTrue(persisted.contains(reference))
        XCTAssertFalse(persisted.contains(plaintext))
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

    // MARK: - Authentication state policy

    func testAuthenticationStatesHaveDistinctCopyAndSafeFollowUpActions() {
        let expectations: [(McpAuthenticationState, String, McpAuthenticationAction)] = [
            (.probing, "Checking authentication", .none),
            (.signedIn, "Signed in", .none),
            (.signedOut, "Signed out", .reviewCredentialSetup),
            (.expired, "Credentials expired", .replaceExpiredCredential),
            (.unknown(.timeout), "Authentication unknown · server timed out", .retryProbe),
            (.unknown(.keychainDenied), "Authentication unknown · Keychain access denied", .reviewKeychainAccess),
            (.unknown(.unsupported), "Authentication unknown · status unsupported", .reviewCompatibility),
        ]

        for (state, copy, action) in expectations {
            let presentation = state.presentation
            XCTAssertEqual(presentation.copy, copy)
            XCTAssertEqual(presentation.action, action)
        }
        XCTAssertNotEqual(
            McpAuthenticationState.signedOut.presentation,
            McpAuthenticationState.unknown(.timeout).presentation
        )
    }

    func testEmptyAuthenticationHeaderIsNotEvidenceOfConfiguredCredentials() {
        XCTAssertFalse(McpAuthenticationPolicy.hasConfiguredCredential([
            .init(name: "Authorization", value: "   "),
        ]))
        XCTAssertTrue(McpAuthenticationPolicy.hasConfiguredCredential([
            .init(name: "Authorization", value: "Bearer ${TOKEN}"),
        ]))
    }

    func testUnknownAuthenticationActionsNeverLaunchOAuthOrClearCredentials() {
        for reason in McpAuthenticationState.UnknownReason.allCases {
            let action = McpAuthenticationState.unknown(reason).presentation.action
            XCTAssertFalse(action.launchesOAuth)
            XCTAssertFalse(action.clearsCredentials)
        }
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
        XCTAssertEqual(stdio.authentication, .unknown(.unsupported))
        XCTAssertEqual(sse.status, .configured)
        XCTAssertFalse(sse.verified)
        XCTAssertEqual(sse.authentication, .unknown(.unsupported))
    }

    func testHTTPProbeReportsSignedInWhenConfiguredCredentialsAreAccepted() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpProbeURLProtocol.self]
        McpProbeURLProtocol.handler = { request in
            let request = try request.materializingBody()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            let method = try XCTUnwrap(object["method"] as? String)
            let data = method == "initialize"
                ? Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{}}}"#.utf8)
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
            url: "https://example.com/mcp",
            headerPairs: [.init(name: "Authorization", value: "Bearer ${TOKEN}")]
        ))

        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.authentication, .signedIn)
    }

    func testHTTPProbeKeepsSignedOutSeparateFromExpiredCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpProbeURLProtocol.self]
        McpProbeURLProtocol.handler = { request in
            let request = try request.materializingBody()
            let hasCredentials = request.value(forHTTPHeaderField: "Authorization") != nil
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: hasCredentials
                        ? ["WWW-Authenticate": #"Bearer error="invalid_token", error_description="token expired""#]
                        : ["WWW-Authenticate": "Bearer"]
                )!,
                Data()
            )
        }
        defer { McpProbeURLProtocol.handler = nil }
        let service = McpProbeService(session: URLSession(configuration: configuration))

        let signedOutServer = McpServerConfig(
            name: "signed-out",
            kind: .http,
            url: "https://example.com/mcp"
        )
        let expiredServer = McpServerConfig(
            name: "expired",
            kind: .http,
            url: "https://example.com/mcp",
            headerPairs: [.init(name: "Authorization", value: "Bearer ${TOKEN}")]
        )
        store(workspace).save([signedOutServer, expiredServer])
        let persistedBefore = try Data(contentsOf: store(workspace).fileURL)

        let signedOut = await service.probe(signedOutServer)
        let expired = await service.probe(expiredServer)

        XCTAssertEqual(signedOut.authentication, .signedOut)
        XCTAssertEqual(expired.authentication, .expired)
        XCTAssertEqual(try Data(contentsOf: store(workspace).fileURL), persistedBefore)
    }

    func testHTTPProbeTimeoutLeavesStoredCredentialsUntouched() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpProbeURLProtocol.self]
        McpProbeURLProtocol.handler = { _ in throw URLError(.timedOut) }
        defer { McpProbeURLProtocol.handler = nil }
        let service = McpProbeService(session: URLSession(configuration: configuration))
        let server = McpServerConfig(
            name: "remote",
            kind: .http,
            url: "https://example.com/mcp",
            headerPairs: [.init(name: "Authorization", value: "Bearer ${TOKEN}")]
        )
        store(workspace).save([server])
        let persistedBefore = try Data(contentsOf: store(workspace).fileURL)

        let result = await service.probe(server)

        XCTAssertEqual(result.authentication, .unknown(.timeout))
        XCTAssertEqual(try Data(contentsOf: store(workspace).fileURL), persistedBefore)
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
                data = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"one\",\"inputSchema\":{\"type\":\"object\"}}],\"nextCursor\":\"more\"}}\n\n".utf8)
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
        XCTAssertEqual(result.authentication, .signedIn)
        XCTAssertTrue(result.disabledTools.isEmpty)
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
        let server = McpServerConfig(name: "remote", kind: .http, url: "https://example.com/mcp")
        store(workspace).save([server])
        let persistedBefore = try Data(contentsOf: store(workspace).fileURL)

        let result = await service.probe(server)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(result.message.contains("Unsupported protocol version"))
        XCTAssertEqual(result.authentication, .unknown(.unsupported))
        XCTAssertEqual(try Data(contentsOf: store(workspace).fileURL), persistedBefore)
    }

    // MARK: - Provider-facing tool schema normalization

    func testToolSchemaNormalizerResolvesNestedDefinitionsArraysUnionsAndEscapedPointers() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "payload": ["$ref": "#/$defs/envelope"],
                "legacy": ["$ref": "#/definitions/a~1b~0c"],
            ],
            "$defs": [
                "envelope": [
                    "type": "object",
                    "properties": [
                        "values": [
                            "type": "array",
                            "items": [
                                "anyOf": [
                                    ["$ref": "#/$defs/scalar"],
                                    ["type": "null"],
                                ],
                            ],
                        ],
                    ],
                    "required": ["values"],
                ],
                "scalar": ["oneOf": [["type": "string"], ["type": "integer"]]],
            ],
            "definitions": [
                "a/b~c": ["type": "string", "minLength": 2],
            ],
        ]

        let first = McpToolSchemaNormalizer.normalizeTools([
            ["name": "nested", "description": "fixture", "inputSchema": schema],
        ])
        let second = McpToolSchemaNormalizer.normalizeTools([
            ["inputSchema": schema, "description": "fixture", "name": "nested"],
        ])

        XCTAssertEqual(first.usable.count, 1)
        XCTAssertTrue(first.disabled.isEmpty)
        let normalized = try XCTUnwrap(first.usable[0]["inputSchema"] as? [String: Any])
        XCTAssertNil(normalized["$defs"])
        XCTAssertNil(normalized["definitions"])
        let properties = try XCTUnwrap(normalized["properties"] as? [String: Any])
        let legacy = try XCTUnwrap(properties["legacy"] as? [String: Any])
        XCTAssertEqual(legacy["type"] as? String, "string")
        XCTAssertEqual(legacy["minLength"] as? Int, 2)
        XCTAssertFalse(try McpToolSchemaNormalizer.stableData(normalized).isEmpty)
        XCTAssertEqual(
            try McpToolSchemaNormalizer.stableData(normalized),
            try McpToolSchemaNormalizer.stableData(
                XCTUnwrap(second.usable[0]["inputSchema"] as? [String: Any])
            )
        )
    }

    func testToolSchemaNormalizerDisablesOnlyInvalidToolsWithBoundedVisibleReasons() throws {
        let cycle: [String: Any] = [
            "type": "object",
            "properties": ["node": ["$ref": "#/$defs/node"]],
            "$defs": ["node": ["$ref": "#/$defs/node"]],
        ]
        let result = McpToolSchemaNormalizer.normalizeTools([
            ["name": "healthy", "inputSchema": ["type": "object", "additionalProperties": false]],
            ["name": "missing", "inputSchema": ["$ref": "#/$defs/absent", "$defs": [:]]],
            ["name": "cycle", "inputSchema": cycle],
            ["name": "remote", "inputSchema": ["$ref": "https://example.test/schema.json"]],
            ["name": "unsupported", "inputSchema": ["type": "object", "unevaluatedProperties": false]],
        ])

        XCTAssertEqual(result.usable.compactMap { $0["name"] as? String }, ["healthy"])
        XCTAssertEqual(result.disabled.map(\.name), ["missing", "cycle", "remote", "unsupported"])
        XCTAssertTrue(result.disabled[0].reason.localizedCaseInsensitiveContains("missing"))
        XCTAssertTrue(result.disabled[1].reason.localizedCaseInsensitiveContains("cycle"))
        XCTAssertTrue(result.disabled[2].reason.localizedCaseInsensitiveContains("local"))
        XCTAssertTrue(result.disabled[3].reason.localizedCaseInsensitiveContains("unsupported"))
        XCTAssertTrue(result.disabled.allSatisfy { !$0.reason.isEmpty && $0.reason.count <= 160 })
    }

    func testToolSchemaNormalizerStopsAtDepthNodeAndByteBudgets() {
        var deep: [String: Any] = ["type": "string"]
        for _ in 0..<8 { deep = ["type": "array", "items": deep] }
        let manyProperties = Dictionary(uniqueKeysWithValues: (0..<20).map {
            ("p\($0)", ["type": "string"] as [String: Any])
        })
        let oversizedDescription = String(repeating: "x", count: 1_024)
        let limits = McpToolSchemaNormalizer.Limits(
            maximumInputBytes: 800,
            maximumOutputBytes: 800,
            maximumDepth: 4,
            maximumNodes: 12
        )

        let result = McpToolSchemaNormalizer.normalizeTools([
            ["name": "deep", "inputSchema": deep],
            ["name": "nodes", "inputSchema": ["type": "object", "properties": manyProperties]],
            ["name": "bytes", "inputSchema": ["type": "string", "description": oversizedDescription]],
            ["name": "healthy", "inputSchema": ["type": "boolean"]],
        ], limits: limits)

        XCTAssertEqual(result.usable.compactMap { $0["name"] as? String }, ["healthy"])
        XCTAssertEqual(result.disabled.map(\.name), ["deep", "nodes", "bytes"])
        XCTAssertTrue(result.disabled[0].reason.localizedCaseInsensitiveContains("depth"))
        XCTAssertTrue(result.disabled[1].reason.localizedCaseInsensitiveContains("node"))
        XCTAssertTrue(result.disabled[2].reason.localizedCaseInsensitiveContains("byte"))
    }

    func testHTTPProbeReportsUsableAndDisabledToolsWithoutFailingHealthySibling() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpProbeURLProtocol.self]
        McpProbeURLProtocol.handler = { request in
            let request = try request.materializingBody()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            let method = try XCTUnwrap(object["method"] as? String)
            let data: Data
            switch method {
            case "initialize":
                data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}"#.utf8)
            case "notifications/initialized":
                data = Data()
            case "tools/list":
                data = Data(##"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"healthy","inputSchema":{"type":"object","properties":{"value":{"$ref":"#/$defs/value"}},"$defs":{"value":{"type":"string"}}}},{"name":"broken","inputSchema":{"$ref":"#/$defs/missing"}}]}}"##.utf8)
            default:
                throw URLError(.badServerResponse)
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: method == "notifications/initialized" ? 202 : 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: data.isEmpty ? [:] : ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        defer { McpProbeURLProtocol.handler = nil }

        let result = await McpProbeService(session: URLSession(configuration: configuration)).probe(
            McpServerConfig(name: "remote", kind: .http, url: "https://example.com/mcp")
        )

        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.toolCount, 1)
        XCTAssertEqual(result.authentication, .unknown(.unsupported))
        XCTAssertEqual(result.disabledTools.map(\.name), ["broken"])
        XCTAssertTrue(result.message.contains("1 usable"))
        XCTAssertTrue(result.message.contains("1 disabled"))
        XCTAssertTrue(result.message.contains("broken"))
        XCTAssertLessThanOrEqual(result.message.count, 240)
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
