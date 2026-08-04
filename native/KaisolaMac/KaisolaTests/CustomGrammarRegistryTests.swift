import XCTest
@testable import Kaisola

/// Custom grammars: validated with named reasons, scanned by the same
/// never-crash pass as shipped languages, and never able to take over a
/// shipped extension.
final class CustomGrammarRegistryTests: XCTestCase {
    private func temporaryStore() throws -> CustomGrammarStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-grammars-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CustomGrammarStore(fileURL: directory.appending(path: "custom-grammars.json"))
    }

    private func tomlGrammar() -> CustomGrammarSpec {
        CustomGrammarSpec(
            id: "toml",
            title: "TOML",
            extensions: ["toml"],
            fences: ["toml"],
            rules: [
                .init(pattern: "#[^\\n]*", role: "comment", context: true),
                .init(pattern: "\"(?:\\\\.|[^\"\\\\\\n])*\"", role: "string", context: true),
                .init(pattern: "^\\s*\\[[^\\]\\n]*\\]", role: "tag", anchorsMatchLines: true),
                .init(pattern: "^[A-Za-z0-9_.-]+(?=\\s*=)", role: "keyword", anchorsMatchLines: true),
                .init(pattern: "\\b\\d[\\d_]*(?:\\.\\d+)?\\b", role: "number"),
            ]
        )
    }

    /// The guard that keeps `shippedExtensions` honest: it must contain
    /// exactly the extensions the shipped table answers for.
    func testShippedExtensionsMatchTheShippedTable() {
        for ext in SyntaxHighlighter.shippedExtensions {
            XCTAssertNotNil(
                SyntaxHighlighter.language(forExtension: ext),
                "\(ext) is declared shipped but the table does not answer for it"
            )
        }
        for probe in ["toml", "rs", "go", "rb", "unknown"] {
            XCTAssertNil(SyntaxHighlighter.language(forExtension: probe))
            XCTAssertFalse(SyntaxHighlighter.shippedExtensions.contains(probe))
        }
    }

    func testACustomGrammarHighlightsItsOwnExtensionAndFence() throws {
        let store = try temporaryStore()
        XCTAssertNil(store.upsert(tomlGrammar()))

        let byExtension = SyntaxHighlighter.grammar(forExtension: "TOML", store: store)
        XCTAssertEqual(byExtension, .custom(id: "toml", rules: []))
        let byFence = SyntaxHighlighter.grammar(forFence: "toml", store: store)
        XCTAssertEqual(byFence, .custom(id: "toml", rules: []))

        let source = """
        # config
        [server]
        port = 8080
        name = "kaisola"
        """
        let spans = SyntaxHighlighter.spans(in: source, rules: byExtension?.rules ?? [])
        XCTAssertTrue(spans.contains { $0.role == .comment }, "the comment rule never fired")
        XCTAssertTrue(spans.contains { $0.role == .tag }, "the table-header rule never fired")
        XCTAssertTrue(spans.contains { $0.role == .keyword }, "the key rule never fired")
        XCTAssertTrue(spans.contains { $0.role == .string }, "the string rule never fired")
    }

    /// The shipped table always wins: a custom grammar claiming "swift" is
    /// invalid, and even a stale cache can never shadow a shipped language
    /// because resolution checks shipped first.
    func testShippedExtensionsCannotBeTakenOver() throws {
        let store = try temporaryStore()
        var greedy = tomlGrammar()
        greedy.extensions = ["swift"]
        let reason = store.upsert(greedy)
        XCTAssertTrue(reason?.contains("built-in") == true, String(describing: reason))
        XCTAssertEqual(SyntaxHighlighter.grammar(forExtension: "swift", store: store), .shipped(.swift))
    }

    func testInvalidGrammarsNameTheirReason() {
        var spec = tomlGrammar()
        spec.rules[0].pattern = "([unclosed"
        XCTAssertTrue(spec.validationError?.contains("does not compile") == true)

        spec = tomlGrammar()
        spec.rules[0].role = "rainbow"
        XCTAssertTrue(spec.validationError?.contains("not a color role") == true)

        spec = tomlGrammar()
        spec.extensions = []
        XCTAssertEqual(spec.validationError, "The grammar claims no file extensions.")

        spec = tomlGrammar()
        spec.rules = Array(repeating: spec.rules[0], count: CustomGrammarSpec.maximumRules + 1)
        XCTAssertTrue(spec.validationError?.contains("at most") == true)

        XCTAssertNil(tomlGrammar().validationError)
    }

    /// An invalid grammar is kept for the settings roster and skipped by the
    /// cache — its extension resolves to plain text, not to a half-working
    /// grammar.
    func testAnInvalidGrammarIsKeptButNeverInstalled() throws {
        let store = try temporaryStore()
        var broken = tomlGrammar()
        broken.rules[0].pattern = "([unclosed"
        XCTAssertNotNil(store.upsert(broken))
        XCTAssertEqual(store.specs().count, 1)
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
    }

    /// The cache re-reads when the store file changes, so an import or
    /// removal is visible without a relaunch.
    func testTheCacheFollowsStoreChanges() throws {
        let store = try temporaryStore()
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
        store.upsert(tomlGrammar())
        XCTAssertNotNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
        store.remove(id: "toml")
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
    }
}

/// The custom-agent chat gate: pinned installs, declared credentials, and a
/// resolver that never lets `npx @latest` back in for user-registered agents.
final class AdapterInstallTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-adapters-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func manager() -> AdapterInstallManager {
        AdapterInstallManager(
            store: .init(fileURL: directory.appending(path: "installs.json")),
            installsRoot: directory.appending(path: "adapters", directoryHint: .isDirectory)
        )
    }

    /// A fake npm: writes a lockfile, a package manifest with a bin, and the
    /// executable itself — everything install() reads back.
    private func fakeInstaller(version: String = "1.2.3") -> @Sendable (URL, String) async throws -> Void {
        { root, package in
            let bare = AdapterInstallManager.bareName(of: package)
            let packageDirectory = root.appending(path: "node_modules/\(bare)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
            let lock = """
            {"lockfileVersion":3,"packages":{"node_modules/\(bare)":{"version":"\(version)"}}}
            """
            try Data(lock.utf8).write(to: root.appending(path: "package-lock.json"))
            let manifest = #"{"name":"\#(bare)","bin":{"adapter":"./cli.js"}}"#
            try Data(manifest.utf8).write(to: packageDirectory.appending(path: "package.json"))
            let bin = packageDirectory.appending(path: "cli.js")
            try Data("#!/usr/bin/env node\n".utf8).write(to: bin)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        }
    }

    func testInstallPinsAndVerifies() async throws {
        let manager = manager()
        let record = try await manager.install(
            agentID: "custom-probe",
            package: "@example/probe-acp@2",
            runner: fakeInstaller(version: "2.0.1")
        )
        XCTAssertEqual(record.resolvedVersion, "2.0.1")
        XCTAssertEqual(record.binRelativePath, "node_modules/@example/probe-acp/cli.js")
        guard case .verified = manager.verify(agentID: "custom-probe") else {
            return XCTFail("a fresh install must verify")
        }
    }

    /// Any change to the pinned graph refuses the chat surface with a named
    /// reason — the durability the review demanded.
    func testDriftIsRefusedByName() async throws {
        let manager = manager()
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        let lockfile = manager.installRoot(agentID: "custom-probe")
            .appending(path: "package-lock.json")
        try Data(#"{"lockfileVersion":3,"packages":{}}"#.utf8).write(to: lockfile)
        guard case let .drifted(reason) = manager.verify(agentID: "custom-probe") else {
            return XCTFail("an edited lockfile must drift")
        }
        XCTAssertTrue(reason.contains("dependency graph"), reason)

        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        let bin = manager.installRoot(agentID: "custom-probe")
            .appending(path: "node_modules/probe-acp/cli.js")
        try FileManager.default.removeItem(at: bin)
        guard case let .drifted(binReason) = manager.verify(agentID: "custom-probe") else {
            return XCTFail("a missing executable must drift")
        }
        // The tree digest catches the removal before the executable check.
        XCTAssertTrue(binReason.contains("files changed"), binReason)

        // Editing the executable's CONTENT leaves the lockfile untouched —
        // the tree digest is what makes that drift (review finding 1).
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        let cli = manager.installRoot(agentID: "custom-probe")
            .appending(path: "node_modules/probe-acp/cli.js")
        try Data("#!/usr/bin/env node\nrequire(\"evil\")\n".utf8).write(to: cli)
        guard case let .drifted(codeReason) = manager.verify(agentID: "custom-probe") else {
            return XCTFail("edited adapter code must drift")
        }
        XCTAssertTrue(codeReason.contains("files changed"), codeReason)

        // And an approval for one package never satisfies another
        // declaration (review finding 2).
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        guard case let .drifted(packageReason) = manager.verify(
            agentID: "custom-probe", expectedPackage: "other-acp"
        ) else {
            return XCTFail("a package mismatch must drift")
        }
        XCTAssertTrue(packageReason.contains("probe-acp"), packageReason)
    }

    func testUninstallIsTotal() async throws {
        let manager = manager()
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        manager.uninstall(agentID: "custom-probe")
        XCTAssertEqual(manager.verify(agentID: "custom-probe"), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: manager.installRoot(agentID: "custom-probe").path
        ))
    }

    func testPackageNamesAreRegistryOnly() {
        XCTAssertNil(CustomAgentSpec.packageNameError("@scope/name"))
        XCTAssertNil(CustomAgentSpec.packageNameError("plain-name@1.2.3"))
        XCTAssertNotNil(CustomAgentSpec.packageNameError("../escape"))
        XCTAssertNotNil(CustomAgentSpec.packageNameError("/usr/bin/thing"))
        XCTAssertNotNil(CustomAgentSpec.packageNameError("https://evil.example/pkg.tgz"))
        XCTAssertNotNil(CustomAgentSpec.packageNameError("name; rm -rf ~"))
        XCTAssertNotNil(CustomAgentSpec.packageNameError("git+ssh://host/repo"))
    }

    /// The resolver honors only the full contract: enabled + declared +
    /// verified. Built-in ids never consult it.
    @MainActor
    func testResolverRequiresTheFullContract() async throws {
        let manager = manager()
        let store = CustomAgentStore(fileURL: directory.appending(path: "agents.json"))
        var spec = CustomAgentSpec(
            id: "custom-probe", name: "Probe", launchCommand: "probe", symbol: "cpu",
            acpPackage: "probe-acp", credentials: "none", chatEnabled: nil
        )
        store.save([spec])
        XCTAssertNil(
            AcpAdapter.forCustomAgent("custom-probe", store: store, installs: manager),
            "a legacy/undeclared enablement flag reads as disabled"
        )
        spec.chatEnabled = true
        store.save([spec])
        XCTAssertNil(
            AcpAdapter.forCustomAgent("custom-probe", store: store, installs: manager),
            "enabled without a verified install stays chatless"
        )
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        let adapter = try XCTUnwrap(
            AcpAdapter.forCustomAgent("custom-probe", store: store, installs: manager)
        )
        XCTAssertTrue(
            adapter.arguments.last?.contains("node_modules/probe-acp/cli.js") == true,
            "the executed command is the pinned executable, not npx"
        )
        XCTAssertFalse(adapter.arguments.last?.contains("npx") == true)
    }

    /// Declared credentials, never inferred (finding 3), and legacy specs
    /// decode as chat-disabled with no provider (finding 4).
    func testDeclaredCredentialsAndLegacyDecode() throws {
        let store = CustomAgentStore(fileURL: directory.appending(path: "agents.json"))
        store.save([
            CustomAgentSpec(
                id: "custom-claude-ish", name: "C", launchCommand: "c", symbol: "cpu",
                acpPackage: "c-acp", credentials: "claude", chatEnabled: true
            ),
        ])
        XCTAssertEqual(
            SessionAccountBinding.declaredProvider(forAgentID: "custom-claude-ish", store: store),
            .claude
        )
        XCTAssertEqual(SessionAccountBinding.declaredProvider(forAgentID: "claude-code", store: store), .claude)
        XCTAssertNil(SessionAccountBinding.declaredProvider(forAgentID: "custom-unknown", store: store))

        let legacy = Data(#"{"agents":[{"id":"custom-old","name":"Old","launchCommand":"old","symbol":"cpu"}]}"#.utf8)
        try legacy.write(to: store.fileURL)
        let decoded = try XCTUnwrap(store.all().first)
        XCTAssertNil(decoded.chatEnabled)
        XCTAssertEqual(decoded.resolvedCredentials, .none)
        XCTAssertNil(SessionAccountBinding.declaredProvider(forAgentID: "custom-old", store: store))
    }
}
