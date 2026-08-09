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
        XCTAssertNil(try store.upsert(tomlGrammar()))

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
        let reason = try store.upsert(greedy)
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
        XCTAssertNotNil(try store.upsert(broken))
        XCTAssertEqual(store.specs().count, 1)
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
    }

    /// The cache re-reads when the store file changes, so an import or
    /// removal is visible without a relaunch.
    func testTheCacheFollowsStoreChanges() throws {
        let store = try temporaryStore()
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
        try store.upsert(tomlGrammar())
        XCTAssertNotNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
        try store.remove(id: "toml")
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
    }

    // MARK: - Quarantine

    /// A registry whose entries are only half-written decodes as nothing, and
    /// "nothing" used to mean "empty" — the next upsert then wrote that empty
    /// catalog over the only copy. Now the bytes are preserved beside the file,
    /// the file itself is untouched, and the upsert is refused by name.
    func testAPartialEntryIsQuarantinedInsteadOfEmptied() throws {
        let store = try temporaryStore()
        let original = Data(#"{"version":1,"grammars":[{"id":"toml","title":"TOML"}]}"#.utf8)
        try original.write(to: store.fileURL)

        let snapshot = store.load()
        guard case let .malformed(preserved) = snapshot.state else {
            return XCTFail("a half-written entry must read as malformed, got \(snapshot.state)")
        }
        XCTAssertTrue(snapshot.specs.isEmpty)
        let copy = try XCTUnwrap(preserved.url)
        XCTAssertEqual(try Data(contentsOf: copy), original, "the preserved copy must be byte-for-byte")
        XCTAssertNotEqual(copy, store.fileURL, "the copy lives beside the active file, not over it")

        XCTAssertThrowsError(try store.upsert(tomlGrammar())) { error in
            guard case .registryUnreadable = error as? CustomGrammarStore.WriteRefusal else {
                return XCTFail("an upsert over an unreadable registry must be refused, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original, "the registry was overwritten")
        XCTAssertThrowsError(try store.remove(id: "toml"))
        XCTAssertThrowsError(try store.save([tomlGrammar()]))
    }

    /// Re-reading the same broken registry lands on the same preserved copy
    /// instead of filling the directory with one per read.
    func testPreservingTheSameBytesTwiceReusesOneCopy() throws {
        let store = try temporaryStore()
        try Data("not json at all".utf8).write(to: store.fileURL)
        let first = try XCTUnwrap(store.load().state.preservedCopy)
        let second = try XCTUnwrap(store.load().state.preservedCopy)
        XCTAssertEqual(first, second)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: store.fileURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(siblings.count, 2, "expected the registry and exactly one copy, got \(siblings)")
    }

    /// A registry written by a newer Kaisola is preserved by its version alone,
    /// before this build tries to read entries whose shape it does not know.
    func testAForwardVersionIsPreservedNotParsed() throws {
        let store = try temporaryStore()
        let future = Data(#"{"version":99,"grammars":[],"palettes":[{"id":"x"}]}"#.utf8)
        try future.write(to: store.fileURL)

        let snapshot = store.load()
        guard case let .newerSchema(version, preserved) = snapshot.state else {
            return XCTFail("a forward version must read as newerSchema, got \(snapshot.state)")
        }
        XCTAssertEqual(version, 99)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(preserved.url)), future)
        XCTAssertThrowsError(try store.upsert(tomlGrammar()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future, "the newer registry was overwritten")
    }

    /// The registry predating the version field still reads, and the next
    /// successful write stamps the current schema on it.
    func testALegacyRegistryReadsAndIsStampedOnTheNextWrite() throws {
        let store = try temporaryStore()
        let legacy = Data(#"{"grammars":[{"id":"ini","title":"INI","extensions":["ini"],"rules":[{"pattern":";[^\n]*","role":"comment"}]}]}"#.utf8)
        try legacy.write(to: store.fileURL)

        XCTAssertEqual(store.load().state, .ready(version: 0))
        XCTAssertEqual(store.specs().map(\.id), ["ini"])
        try store.upsert(tomlGrammar())
        XCTAssertEqual(store.load().state, .ready(version: CustomGrammarStore.schemaVersion))
        XCTAssertEqual(store.specs().map(\.id), ["ini", "toml"])
    }

    /// Recovery is explicit and never blind: the reset is offered only once the
    /// copy exists, it clears the way for new grammars, and the preserved file
    /// is still there afterwards.
    func testResetIsTheOnlyWayBackAndKeepsThePreservedCopy() throws {
        let store = try temporaryStore()
        XCTAssertThrowsError(try store.resetUnreadableRegistry()) { error in
            XCTAssertEqual(
                error as? CustomGrammarStore.WriteRefusal, .resetNeedsPreservedCopy,
                "a readable registry has nothing to reset"
            )
        }

        let original = Data("{".utf8)
        try original.write(to: store.fileURL)
        let copy = try XCTUnwrap(store.load().state.preservedCopy)

        let after = try store.resetUnreadableRegistry()
        XCTAssertEqual(after.state, .ready(version: CustomGrammarStore.schemaVersion))
        XCTAssertTrue(after.specs.isEmpty)
        XCTAssertNil(try store.upsert(tomlGrammar()))
        XCTAssertEqual(store.specs().map(\.id), ["toml"])
        XCTAssertEqual(try Data(contentsOf: copy), original, "the recovery copy must survive the reset")
    }

    /// A write that cannot land says so and leaves the stored registry alone —
    /// the failure reaches the settings row instead of vanishing.
    func testUnwritableStorageSurfacesTheFailure() throws {
        let store = try temporaryStore()
        try store.upsert(tomlGrammar())
        let stored = try Data(contentsOf: store.fileURL)

        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }

        var second = tomlGrammar()
        second.id = "ini"
        second.extensions = ["ini"]
        XCTAssertThrowsError(try store.upsert(second)) { error in
            guard case let .writeFailed(reason) = error as? CustomGrammarStore.WriteRefusal else {
                return XCTFail("an unwritable directory must surface a write failure, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(
                (error as? CustomGrammarStore.WriteRefusal)?.errorDescription?
                    .contains("could not save") == true
            )
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), stored)
        XCTAssertEqual(store.specs().map(\.id), ["toml"])
    }

    /// Extensions settings names the preserved copy, keeps the reset button
    /// honest, and stays quiet when the registry is fine.
    func testExtensionsSettingsNamesThePreservedCopy() throws {
        let store = try temporaryStore()
        XCTAssertNil(ExtensionsSettingsPolicy.registryNotice(for: .absent))
        XCTAssertNil(ExtensionsSettingsPolicy.registryNotice(for: .ready(version: 1)))

        try Data("{".utf8).write(to: store.fileURL)
        let state = store.load().state
        let copy = try XCTUnwrap(state.preservedCopy)
        let notice = try XCTUnwrap(ExtensionsSettingsPolicy.registryNotice(for: state))
        XCTAssertTrue(notice.message.contains(copy.path), notice.message)
        XCTAssertTrue(notice.canReset)
        XCTAssertEqual(notice.preservedCopy, copy)

        let unpreservable = ExtensionsSettingsPolicy.registryNotice(
            for: .newerSchema(version: 9, preserved: .failed("The disk is full."))
        )
        XCTAssertEqual(unpreservable?.canReset, false)
        XCTAssertTrue(unpreservable?.message.contains("The disk is full.") == true)
        XCTAssertTrue(unpreservable?.message.contains("version 9") == true)
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
