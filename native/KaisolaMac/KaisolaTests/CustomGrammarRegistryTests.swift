import Darwin
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

    func testMissingVersionedAndLegacyStatesAreDistinctAndMigrateOnSave() throws {
        let store = try temporaryStore()
        XCTAssertEqual(store.load(), .init(specs: [], state: .missing))

        let legacySpec = tomlGrammar()
        let legacy = try JSONEncoder().encode(["grammars": [legacySpec]])
        try legacy.write(to: store.fileURL)
        XCTAssertEqual(
            store.load(),
            .init(specs: [legacySpec], state: .ready(schemaVersion: 0))
        )

        var second = tomlGrammar()
        second.id = "hcl"
        second.title = "HCL"
        second.extensions = ["hcl"]
        second.fences = ["hcl"]
        try store.upsert(second)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, CustomGrammarStore.schemaVersion)
        XCTAssertEqual((object["grammars"] as? [[String: Any]])?.count, 2)
    }

    func testMalformedPartialRegistryIsPreservedAndLastKnownGoodGrammarStaysLive() throws {
        let store = try temporaryStore()
        let baseline = tomlGrammar()
        try store.upsert(baseline)
        XCTAssertEqual(store.load().specs, [baseline])

        let encoded = try JSONEncoder().encode(baseline)
        let validObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let malformedObject: [String: Any] = [
            "version": CustomGrammarStore.schemaVersion,
            "grammars": [validObject, ["id": "structurally-broken"]],
        ]
        let malformed = try JSONSerialization.data(withJSONObject: malformedObject, options: [.sortedKeys])
        try malformed.write(to: store.fileURL)

        let snapshot = store.load()
        guard case let .corrupt(.preserved(copyURL)) = snapshot.state else {
            return XCTFail("One undecodable grammar must quarantine the complete registry")
        }
        XCTAssertEqual(snapshot.specs, [baseline])
        XCTAssertEqual(try Data(contentsOf: copyURL), malformed)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
        XCTAssertNotNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
        XCTAssertThrowsError(try store.upsert(tomlGrammar()))
        XCTAssertThrowsError(try store.remove(id: baseline.id))

        let reset = try store.resetUnreadableRegistry()
        XCTAssertEqual(
            reset,
            .init(specs: [], state: .ready(schemaVersion: CustomGrammarStore.schemaVersion))
        )
        XCTAssertEqual(try Data(contentsOf: copyURL), malformed)
    }

    func testRepeatedMalformedReadsReuseOnePrivateRecoveryCopy() throws {
        let store = try temporaryStore()
        let malformed = Data("not json at all".utf8)
        try malformed.write(to: store.fileURL)

        let first = try XCTUnwrap(store.load().state.preservedCopyURL)
        let second = try XCTUnwrap(store.load().state.preservedCopyURL)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), malformed)

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: store.fileURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(siblings.count, 2, "Expected the registry and exactly one recovery copy")

        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testDamagedRecoveryCopyFailsClosedAndCannotAuthorizeReset() throws {
        let store = try temporaryStore()
        let baseline = tomlGrammar()
        try store.upsert(baseline)
        _ = store.load()
        let malformed = Data("not-json".utf8)
        try malformed.write(to: store.fileURL)
        let first = store.load()
        let copyURL = try XCTUnwrap(first.state.preservedCopyURL)
        try Data("different".utf8).write(to: copyURL)

        let second = store.load()
        guard case .corrupt(.failed) = second.state else {
            return XCTFail("A mismatched recovery copy must fail closed, got \(second.state)")
        }
        XCTAssertEqual(second.specs, [baseline])
        XCTAssertFalse(second.state.canReset)
        XCTAssertThrowsError(try store.resetUnreadableRegistry())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
    }

    func testFutureSchemaIsPreservedWithoutDowngradingRuntimeGrammar() throws {
        let store = try temporaryStore()
        let baseline = tomlGrammar()
        try store.upsert(baseline)
        _ = store.load()

        let future = Data(#"{"version":42,"grammars":[],"futurePolicy":{"mode":"sealed"}}"#.utf8)
        try future.write(to: store.fileURL)
        let snapshot = store.load()
        guard case let .newerVersion(version, .preserved(copyURL)) = snapshot.state else {
            return XCTFail("Expected preserved future schema, got \(snapshot.state)")
        }
        XCTAssertEqual(version, 42)
        XCTAssertEqual(snapshot.specs, [baseline])
        XCTAssertEqual(try Data(contentsOf: copyURL), future)
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
    }

    func testIOReadFailureKeepsRuntimeGrammarButCannotOfferDestructiveReset() throws {
        let store = try temporaryStore()
        let baseline = tomlGrammar()
        try store.upsert(baseline)
        _ = store.load()
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)

        let snapshot = store.load()
        guard case .ioFailure = snapshot.state else {
            return XCTFail("A directory at the registry path must be an I/O failure")
        }
        XCTAssertEqual(snapshot.specs, [baseline])
        XCTAssertFalse(snapshot.state.canReset)
        XCTAssertThrowsError(try store.resetUnreadableRegistry())
        XCTAssertThrowsError(try store.upsert(baseline))
    }

    func testDurableWriteFailureIsVisibleAndLeavesRegistryUntouched() throws {
        let store = try temporaryStore()
        let baseline = tomlGrammar()
        try store.upsert(baseline)
        let before = try Data(contentsOf: store.fileURL)
        let directory = store.fileURL.deletingLastPathComponent()

        XCTAssertEqual(chmod(directory.path, 0o500), 0)
        defer { _ = chmod(directory.path, 0o700) }
        var lost = baseline
        lost.id = "lost"
        lost.title = "Lost"
        lost.extensions = ["lost"]
        XCTAssertThrowsError(try store.upsert(lost)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Kaisola could not save language grammars. The existing registry was left unchanged."
            )
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(store.specs(), [baseline])
    }

    func testOversizedBulkSaveIsRejectedWithoutTruncatingOrReplacingTheRegistry() throws {
        let store = try temporaryStore()
        let baseline = tomlGrammar()
        try store.save([baseline])
        let before = try Data(contentsOf: store.fileURL)
        let oversized = (0..<17).map { index -> CustomGrammarSpec in
            var spec = baseline
            spec.id = "grammar-\(index)"
            spec.title = "Grammar \(index)"
            spec.extensions = ["g\(index)"]
            return spec
        }

        XCTAssertThrowsError(try store.save(oversized))
        XCTAssertEqual(store.specs(), [baseline])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }
}

/// The custom-agent chat gate: pinned installs, declared credentials, and a
/// resolver that never lets `npx @latest` back in for user-registered agents.
final class AdapterInstallTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-adapters-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func canonicalTemporaryDirectory() -> URL {
        guard let resolved = realpath(directory.path, nil) else { return directory }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func manager() -> AdapterInstallManager {
        // `/var` is a system compatibility symlink to `/private/var`; use the
        // canonical temp root so tests exercise the installer's intentional
        // rejection of newly introduced symlink components, not that macOS
        // compatibility alias.
        let canonicalDirectory = canonicalTemporaryDirectory()
        return AdapterInstallManager(
            store: .init(fileURL: canonicalDirectory.appending(path: "installs.json")),
            installsRoot: canonicalDirectory.appending(path: "adapters", directoryHint: .isDirectory)
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

    private func assertRejectedAndCleaned(
        _ manager: AdapterInstallManager,
        agentID: String = "custom-probe",
        package: String = "probe-acp",
        runner: @escaping @Sendable (URL, String) async throws -> Void,
        beforePublish: @escaping @Sendable (URL) async throws -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await manager.install(
                agentID: agentID,
                package: package,
                runner: runner,
                beforePublish: beforePublish
            )
            XCTFail("an unsafe candidate must be rejected", file: file, line: line)
        } catch {
            // The named error is surfaced by Settings. The security invariant
            // below matters more than the exact wording.
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
        XCTAssertNil(manager.store.record(agentID: agentID), file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manager.installRoot(agentID: agentID).path),
            file: file,
            line: line
        )
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: manager.installsRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(candidates.isEmpty, "candidate cache was retained: \(candidates)", file: file, line: line)
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

    func testInstallRejectsSymlinksWithoutTouchingTheirTarget() async throws {
        let manager = manager()
        let outside = directory.appending(path: "outside.txt")
        let original = Data("outside stays unchanged".utf8)
        try original.write(to: outside)
        let base = fakeInstaller()

        await assertRejectedAndCleaned(manager, runner: { root, package in
            try await base(root, package)
            let link = root.appending(path: "node_modules/probe-acp/outside-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        })

        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testInstallRejectsHardLinksWithoutTouchingTheirTarget() async throws {
        let manager = manager()
        let outside = directory.appending(path: "outside.txt")
        let original = Data("outside stays linked but unchanged".utf8)
        try original.write(to: outside)
        let base = fakeInstaller()

        await assertRejectedAndCleaned(manager, runner: { root, package in
            try await base(root, package)
            let linked = root.appending(path: "node_modules/probe-acp/outside-hard-link")
            guard link(outside.path, linked.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        })

        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testInstallRejectsDotDotBinPathsAndCleansTheCandidate() async {
        let manager = manager()
        let base = fakeInstaller()
        await assertRejectedAndCleaned(manager, runner: { root, package in
            try await base(root, package)
            let manifest = root.appending(path: "node_modules/probe-acp/package.json")
            try Data(#"{"name":"probe-acp","bin":{"adapter":"../../outside"}}"#.utf8)
                .write(to: manifest)
        })
    }

    func testCaseFoldedPathCollisionsAreRejected() {
        XCTAssertNotNil(AdapterInstallManager.firstCaseCollision(in: [
            "node_modules/probe-acp/README",
            "node_modules/probe-acp/readme",
        ]))
        XCTAssertNotNil(AdapterInstallManager.firstCaseCollision(in: [
            "node_modules/probe-acp/Cafe\u{301}.js",
            "node_modules/probe-acp/CAF\u{00C9}.JS",
        ]))
        XCTAssertNil(AdapterInstallManager.firstCaseCollision(in: [
            "node_modules/probe-acp/README",
            "node_modules/probe-acp/cli.js",
        ]))
    }

    func testCandidateReplacementAfterValidationIsRejectedWithoutFollowingIt() async throws {
        let manager = manager()
        let outsideRoot = directory.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let marker = outsideRoot.appending(path: "marker.txt")
        let original = Data("outside survives cleanup".utf8)
        try original.write(to: marker)

        await assertRejectedAndCleaned(
            manager,
            runner: fakeInstaller(),
            beforePublish: { candidate in
                try FileManager.default.removeItem(at: candidate)
                try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: outsideRoot)
            }
        )

        XCTAssertEqual(try Data(contentsOf: marker), original)
    }

    func testFileReplacementAfterValidationIsRejectedWithoutFollowingIt() async throws {
        let manager = manager()
        let outside = directory.appending(path: "outside-script.js")
        let original = Data("outside survives file replacement".utf8)
        try original.write(to: outside)

        await assertRejectedAndCleaned(
            manager,
            runner: fakeInstaller(),
            beforePublish: { candidate in
                let cli = candidate.appending(path: "node_modules/probe-acp/cli.js")
                try FileManager.default.removeItem(at: cli)
                try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: outside)
            }
        )

        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testExecutableModeReplacementAfterValidationIsRejected() async {
        let manager = manager()
        await assertRejectedAndCleaned(
            manager,
            runner: fakeInstaller(),
            beforePublish: { candidate in
                let cli = candidate.appending(path: "node_modules/probe-acp/cli.js")
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: cli.path
                )
            }
        )
    }

    func testCacheRootReplacementDoesNotRedirectCandidateCleanup() async throws {
        let manager = manager()
        let canonicalDirectory = canonicalTemporaryDirectory()
        let parked = canonicalDirectory.appending(path: "parked-cache", directoryHint: .isDirectory)
        let outside = canonicalDirectory.appending(path: "outside-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        do {
            _ = try await manager.install(
                agentID: "custom-probe",
                package: "probe-acp",
                runner: fakeInstaller(),
                beforePublish: { candidate in
                    try FileManager.default.moveItem(at: manager.installsRoot, to: parked)
                    try FileManager.default.createSymbolicLink(
                        at: manager.installsRoot,
                        withDestinationURL: outside
                    )
                    let redirectedCandidate = outside.appending(
                        path: candidate.lastPathComponent,
                        directoryHint: .isDirectory
                    )
                    try FileManager.default.createDirectory(
                        at: redirectedCandidate,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let marker = redirectedCandidate.appending(path: "outside-marker.txt")
                    try Data("must not be removed".utf8).write(to: marker)
                }
            )
            XCTFail("a replaced cache root must reject the candidate")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        let redirectedCandidate = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: outside,
                includingPropertiesForKeys: nil
            ).first
        )
        let marker = redirectedCandidate.appending(path: "outside-marker.txt")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "must not be removed")
        XCTAssertNil(manager.store.record(agentID: "custom-probe"))
    }

    func testInstallRejectsAnIntermediateSymlinkInTheCacheRoot() async throws {
        let canonicalDirectory = canonicalTemporaryDirectory()
        let redirected = canonicalDirectory.appending(path: "redirected", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        let linkedParent = canonicalDirectory.appending(path: "linked-cache", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: redirected)
        let manager = AdapterInstallManager(
            store: .init(fileURL: canonicalDirectory.appending(path: "installs.json")),
            installsRoot: linkedParent.appending(path: "adapters", directoryHint: .isDirectory)
        )

        do {
            _ = try await manager.install(
                agentID: "custom-probe",
                package: "probe-acp",
                runner: fakeInstaller()
            )
            XCTFail("a redirected cache root must be rejected before npm runs")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("symbolic-link"), error.localizedDescription)
        }
        XCTAssertNil(manager.store.record(agentID: "custom-probe"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: redirected.path), [])
    }

    func testFailureAfterAtomicPromotionRestoresThePriorApprovedCacheAndRecord() async throws {
        let manager = manager()
        let original = try await manager.install(
            agentID: "custom-probe",
            package: "probe-acp",
            runner: fakeInstaller(version: "1.0.0")
        )

        do {
            _ = try await manager.install(
                agentID: "custom-probe",
                package: "probe-acp",
                runner: fakeInstaller(version: "2.0.0"),
                afterPublish: { _ in throw InjectedFailure.stop }
            )
            XCTFail("the injected interruption must fail the replacement")
        } catch InjectedFailure.stop {
            // Expected: the candidate had been swapped into place, then the
            // one-step exchange was reversed before the error escaped.
        }

        XCTAssertEqual(manager.store.record(agentID: "custom-probe"), original)
        guard case .verified = manager.verify(agentID: "custom-probe", expectedPackage: "probe-acp") else {
            return XCTFail("the previous approval and tree must remain valid")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: manager.installsRoot,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            ["custom-probe"]
        )
    }

    func testCacheRootReplacementAfterPromotionRollsBackWithoutRecordingCandidate() async throws {
        let manager = manager()
        let original = try await manager.install(
            agentID: "custom-probe",
            package: "probe-acp",
            runner: fakeInstaller(version: "1.0.0")
        )
        let canonicalDirectory = canonicalTemporaryDirectory()
        let parked = canonicalDirectory.appending(path: "parked-after-publish", directoryHint: .isDirectory)
        let outside = canonicalDirectory.appending(path: "outside-after-publish", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let decoyInstaller = fakeInstaller(version: "2.0.0")

        do {
            _ = try await manager.install(
                agentID: "custom-probe",
                package: "probe-acp",
                runner: fakeInstaller(version: "2.0.0"),
                afterPublish: { _ in
                    try FileManager.default.moveItem(at: manager.installsRoot, to: parked)
                    try FileManager.default.createSymbolicLink(
                        at: manager.installsRoot,
                        withDestinationURL: outside
                    )
                    let redirectedFinal = outside.appending(
                        path: "custom-probe",
                        directoryHint: .isDirectory
                    )
                    try FileManager.default.createDirectory(
                        at: redirectedFinal,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try await decoyInstaller(redirectedFinal, "probe-acp")
                }
            )
            XCTFail("a post-promotion cache-root replacement must reject the candidate")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        XCTAssertEqual(manager.store.record(agentID: "custom-probe"), original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: parked,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            ["custom-probe"]
        )
        let restoredLock = try String(
            contentsOf: parked.appending(path: "custom-probe/package-lock.json"),
            encoding: .utf8
        )
        XCTAssertTrue(restoredLock.contains(#""version":"1.0.0""#), restoredLock)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outside.appending(path: "custom-probe/package-lock.json").path
        ))
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

    // MARK: - Deleting a custom agent

    /// Deleting a chat-enabled agent takes its pinned adapter with it. The
    /// roster entry used to go alone, leaving executable install artifacts on
    /// disk with no owner in Settings and no route to remove them.
    func testDeletingAnAgentRemovesItsPinnedInstall() async throws {
        let manager = manager()
        let store = CustomAgentStore(fileURL: directory.appending(path: "agents.json"))
        let spec = CustomAgentSpec(
            id: "custom-probe", name: "Probe", launchCommand: "probe", symbol: "cpu",
            acpPackage: "probe-acp", credentials: "none", chatEnabled: true
        )
        store.save([spec])
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        let root = manager.installRoot(agentID: "custom-probe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        let deletion = CustomAgentDeletion(store: store, installs: manager)
        let remaining = try deletion.delete(agentID: "custom-probe", from: [spec])

        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(manager.verify(agentID: "custom-probe"), .notInstalled)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "a deleted agent must not leave adapter artifacts behind"
        )
    }

    /// The confirmation names the agent and the exact pinned version that the
    /// deletion destroys, and claims no version when there is no install.
    func testDeletionPlanNamesTheAgentAndPinnedVersion() async throws {
        let manager = manager()
        let store = CustomAgentStore(fileURL: directory.appending(path: "agents.json"))
        let spec = CustomAgentSpec(
            id: "custom-probe", name: "Probe", launchCommand: "probe", symbol: "cpu",
            acpPackage: "probe-acp", credentials: "none", chatEnabled: nil
        )
        let deletion = CustomAgentDeletion(store: store, installs: manager)

        let uninstalled = deletion.plan(for: spec)
        XCTAssertNil(uninstalled.pinnedInstall)
        XCTAssertTrue(uninstalled.message.contains("Probe"), uninstalled.message)
        XCTAssertFalse(uninstalled.message.contains("v1.2.3"), uninstalled.message)

        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller(version: "1.2.3")
        )
        let pinned = deletion.plan(for: spec)
        XCTAssertEqual(pinned.pinnedInstall, "probe-acp v1.2.3")
        XCTAssertTrue(pinned.message.contains("Probe"), pinned.message)
        XCTAssertTrue(pinned.message.contains("probe-acp v1.2.3"), pinned.message)
    }

    /// An install that cannot be removed aborts the deletion and says why: the
    /// roster entry and the install record both survive, so the artifacts keep
    /// an owner and the delete can be retried.
    func testAFailedPurgeKeepsTheAgentAndReportsWhy() async throws {
        let manager = manager()
        let store = CustomAgentStore(fileURL: directory.appending(path: "agents.json"))
        let spec = CustomAgentSpec(
            id: "custom-probe", name: "Probe", launchCommand: "probe", symbol: "cpu",
            acpPackage: "probe-acp", credentials: "none", chatEnabled: true
        )
        store.save([spec])
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        // A read-only installs root refuses to give up its child directory.
        let installsRoot = manager.installRoot(agentID: "custom-probe").deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: installsRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: installsRoot.path
            )
        }

        let deletion = CustomAgentDeletion(store: store, installs: manager)
        XCTAssertThrowsError(try deletion.delete(agentID: "custom-probe", from: [spec])) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("Probe"), message)
            XCTAssertTrue(message.lowercased().contains("not deleted"), message)
        }
        XCTAssertEqual(store.all(), [spec], "an aborted deletion keeps the roster entry")
        XCTAssertNotNil(
            manager.store.record(agentID: "custom-probe"),
            "an aborted deletion keeps the install record, so the files stay owned"
        )
    }

    /// A durable roster failure happens after the adapter tree and install
    /// record have entered their reversible phase. Both must be restored byte-
    /// for-byte so the row still owns runnable files and the same click can be
    /// retried after the registry becomes writable.
    func testRegistrySaveFailureRestoresExactInstallAndKeepsDeletionRetryable() async throws {
        let manager = manager()
        let registryURL = directory.appending(path: "agents.json")
        let store = CustomAgentStore(fileURL: registryURL)
        let spec = CustomAgentSpec(
            id: "custom-probe", name: "Probe", launchCommand: "probe", symbol: "cpu",
            acpPackage: "probe-acp", credentials: "none", chatEnabled: true
        )
        _ = try store.save([spec]).get()
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", runner: fakeInstaller()
        )
        let root = manager.installRoot(agentID: "custom-probe")
        let exactRecord = try XCTUnwrap(manager.store.record(agentID: "custom-probe"))
        let exactTree = try XCTUnwrap(AdapterInstallManager.treeDigest(root: root))

        let failingStore = CustomAgentStore(fileURL: registryURL) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        let failingDeletion = CustomAgentDeletion(store: failingStore, installs: manager)
        XCTAssertThrowsError(try failingDeletion.delete(agentID: "custom-probe", from: [spec])) { error in
            guard case .registryNotRemoved = error as? CustomAgentDeletion.Failure else {
                return XCTFail("expected a typed registry failure, got \(error)")
            }
        }

        XCTAssertEqual(try store.load().get(), [spec])
        XCTAssertEqual(manager.store.record(agentID: "custom-probe"), exactRecord)
        XCTAssertEqual(AdapterInstallManager.treeDigest(root: root), exactTree)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let stagedNames = try FileManager.default.contentsOfDirectory(
            atPath: root.deletingLastPathComponent().path
        ).filter { $0.hasPrefix(".delete-") }
        XCTAssertTrue(stagedNames.isEmpty, "failed deletion left staged adapter trees: \(stagedNames)")

        let remaining = try CustomAgentDeletion(store: store, installs: manager)
            .delete(agentID: "custom-probe", from: [spec])
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(try store.load().get().isEmpty)
        XCTAssertNil(manager.store.record(agentID: "custom-probe"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// Deletion shares installation's path policy: an id is one descriptor-
    /// relative leaf, never syntax that can name a parent or outside target.
    func testPurgeRejectsUnsafeAgentIDWithoutTouchingOutsideFile() throws {
        let manager = manager()
        let outside = directory.appending(path: "outside.txt")
        try Data("keep".utf8).write(to: outside)

        XCTAssertThrowsError(try manager.purge(agentID: "../outside.txt"))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
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
            acpPackage: "probe-acp", credentials: "none", chatEnabled: nil,
            acpPrivileges: []
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
        let approval = try XCTUnwrap(spec.containmentApproval)
        _ = try await manager.install(
            agentID: "custom-probe", package: "probe-acp", approval: approval,
            runner: fakeInstaller()
        )
        let adapter = try XCTUnwrap(
            AcpAdapter.forCustomAgent("custom-probe", store: store, installs: manager)
        )
        XCTAssertTrue(
            adapter.containment?.executableURL.path.contains("node_modules/probe-acp/cli.js") == true,
            "the contained launch binds the pinned executable, not npx"
        )
        XCTAssertFalse(adapter.containment?.executableURL.path.contains("npx") == true)
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
