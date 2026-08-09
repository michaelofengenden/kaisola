import Foundation
import XCTest
@testable import Kaisola

/// CustomAgentStore persistence against a throwaway file — save/all round-trip
/// across instances, corrupt-file degradation, the 12-entry cap, the slugify
/// matrix, `asProfiles` mapping (symbol fallback) — plus the `AgentRegistry`
/// integration through the `customStoreOverride` test seam.
final class CustomAgentStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: CustomAgentStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-custom-agents-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("custom-agents.json")
        store = CustomAgentStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        AgentRegistry.customStoreOverride = nil   // never leak the seam
    }

    // MARK: - Round-trip

    func testSaveAllRoundTripAcrossInstances() {
        let specs = [
            CustomAgentSpec(id: "custom-aider", name: "Aider", launchCommand: "aider", symbol: "bolt"),
            CustomAgentSpec(id: "custom-my-tool", name: "My Tool", launchCommand: "mytool --flag", symbol: "cpu"),
        ]
        store.save(specs)

        let reopened = CustomAgentStore(fileURL: fileURL)
        XCTAssertEqual(reopened.all(), specs)
    }

    func testCorruptFileDegradesToEmpty() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testCorruptRegistryFailsClosedAndPreservesMalformedBytes() throws {
        let malformed = Data("not json".utf8)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try malformed.write(to: fileURL)

        guard case let .failure(.corruptRegistry(path)) = store.load() else {
            return XCTFail("Expected a typed corrupt-registry failure")
        }
        XCTAssertEqual(path, fileURL.path)

        let attempted = [
            CustomAgentSpec(
                id: "custom-replacement", name: "Replacement",
                launchCommand: "replacement", symbol: "terminal"
            ),
        ]
        guard case .failure(.corruptRegistry) = store.save(
            attempted, affectedAgentID: "custom-replacement"
        ) else {
            return XCTFail("A save must not overwrite registry bytes it could not decode")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), malformed)
    }

    func testForwardSchemaFailsClosedAndPreservesNewerRegistry() throws {
        let forward = Data(#"{"schemaVersion":99,"agents":[]}"#.utf8)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try forward.write(to: fileURL)

        guard case let .failure(.unsupportedSchema(found, supported)) = store.load() else {
            return XCTFail("Expected an unsupported-schema failure")
        }
        XCTAssertEqual(found, 99)
        XCTAssertEqual(supported, CustomAgentStore.schemaVersion)

        guard case .failure(.unsupportedSchema) = store.save([], affectedAgentID: nil) else {
            return XCTFail("An older build must not overwrite a newer registry")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), forward)
    }

    func testPartiallyDecodedRegistryNamesTheBrokenEntryAndLaunchFailsClosed() throws {
        let partial = Data(#"{"schemaVersion":1,"agents":[{"id":"custom-good","name":"Good","launchCommand":"good","symbol":"bolt"},{"id":"custom-broken","name":"Broken","symbol":"bolt"}]}"#.utf8)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try partial.write(to: fileURL)

        guard case let .failure(.invalidEntry(index, id, reason)) = store.load() else {
            return XCTFail("Expected an entry-specific decoding failure")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(id, "custom-broken")
        XCTAssertTrue(reason.contains("launchCommand"), reason)

        AgentRegistry.customStoreOverride = store
        guard case .failure(.invalidEntry) = AgentRegistry.customLoadResult else {
            return XCTFail("The terminal launch registry must retain the typed load failure")
        }
        XCTAssertTrue(AgentRegistry.custom.isEmpty, "No partially decoded agent may launch")
    }

    func testInterruptedReplacementPreservesLastKnownGoodAndCleansTemporaryFile() throws {
        let original = [
            CustomAgentSpec(
                id: "custom-original", name: "Original",
                launchCommand: "original", symbol: "bolt"
            ),
        ]
        guard case .success = store.save(original, affectedAgentID: "custom-original") else {
            return XCTFail("Test setup save failed")
        }
        let originalBytes = try Data(contentsOf: fileURL)
        let interrupted = CustomAgentStore(fileURL: fileURL) { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }

        guard case let .failure(.persistenceFailed(entryID, operation, _, _)) = interrupted.save(
            [CustomAgentSpec(
                id: "custom-next", name: "Next", launchCommand: "next", symbol: "cpu"
            )],
            affectedAgentID: "custom-next"
        ) else {
            return XCTFail("Expected a typed replacement failure")
        }
        XCTAssertEqual(entryID, "custom-next")
        XCTAssertEqual(operation, .replaceRegistry)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        XCTAssertEqual(try store.load().get(), original)

        let directoryEntries = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(directoryEntries.contains {
            $0.lastPathComponent.hasPrefix(".custom-agents.json.")
                && $0.lastPathComponent.hasSuffix(".tmp")
        })
    }

    func testUnwritableParentReturnsTypedPersistenceFailureForAffectedEntry() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        let unwritable = CustomAgentStore(fileURL: fileURL)
        guard case let .failure(.persistenceFailed(entryID, operation, path, _)) = unwritable.save(
            [CustomAgentSpec(
                id: "custom-blocked", name: "Blocked",
                launchCommand: "blocked", symbol: "terminal"
            )],
            affectedAgentID: "custom-blocked"
        ) else {
            return XCTFail("Expected a typed directory-write failure")
        }
        XCTAssertEqual(entryID, "custom-blocked")
        XCTAssertEqual(operation, .writeTemporaryFile)
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent(), directory)
    }

    func testValidationFailureNamesExactEntryWithoutReplacingRegistry() throws {
        let original = [
            CustomAgentSpec(
                id: "custom-original", name: "Original",
                launchCommand: "original", symbol: "bolt"
            ),
        ]
        guard case .success = store.save(original, affectedAgentID: "custom-original") else {
            return XCTFail("Test setup save failed")
        }
        let originalBytes = try Data(contentsOf: fileURL)
        let invalid = original + [
            CustomAgentSpec(
                id: "custom-broken", name: "Broken",
                launchCommand: "broken", symbol: "cpu",
                acpPackage: "probe-acp", credentials: "unknown", chatEnabled: false
            ),
        ]

        guard case let .failure(.invalidEntry(index, id, reason)) = store.save(
            invalid, affectedAgentID: "custom-broken"
        ) else {
            return XCTFail("Expected entry-specific validation to fail before persistence")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(id, "custom-broken")
        XCTAssertTrue(reason.contains("credential context"), reason)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
    }

    // MARK: - Cap

    func testSaveRejectsTheThirteenthEntryWithoutWritingASubset() {
        let specs = (0..<15).map {
            CustomAgentSpec(id: "custom-\($0)", name: "Agent \($0)", launchCommand: "a\($0)", symbol: "terminal")
        }
        guard case let .failure(.invalidEntry(index, id, reason)) = store.save(specs) else {
            return XCTFail("Expected overflow to fail instead of partially saving")
        }
        XCTAssertEqual(index, 12)
        XCTAssertEqual(id, "custom-12")
        XCTAssertTrue(reason.contains("at most 12"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveRejectsDuplicateIDAtTheSecondEntry() {
        let specs = [
            CustomAgentSpec(id: "custom-same", name: "First", launchCommand: "first", symbol: "bolt"),
            CustomAgentSpec(id: "custom-same", name: "Second", launchCommand: "second", symbol: "cpu"),
        ]
        guard case let .failure(.invalidEntry(index, id, reason)) = store.save(specs) else {
            return XCTFail("Expected a duplicate-id failure")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(id, "custom-same")
        XCTAssertTrue(reason.contains("duplicates"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - slugify

    func testSlugifyMatrix() {
        XCTAssertEqual(CustomAgentStore.slugify("My Agent!"), "custom-my-agent")
        XCTAssertEqual(CustomAgentStore.slugify(""), "custom-agent")
        XCTAssertEqual(CustomAgentStore.slugify("   "), "custom-agent")
        XCTAssertEqual(CustomAgentStore.slugify("!!!"), "custom-agent")
        XCTAssertEqual(CustomAgentStore.slugify("Aider"), "custom-aider")
        XCTAssertEqual(CustomAgentStore.slugify("a/b c"), "custom-a-b-c")
        XCTAssertEqual(CustomAgentStore.slugify("Claude 3.5"), "custom-claude-3-5")
        XCTAssertEqual(CustomAgentStore.slugify("--Lead--"), "custom-lead")
        // Collision suffixing is intentionally NOT applied: same name → same id.
        XCTAssertEqual(CustomAgentStore.slugify("My Agent"), CustomAgentStore.slugify("my  agent"))
    }

    // MARK: - asProfiles mapping

    func testAsProfilesMapsFieldsAndSymbolFallback() throws {
        store.save([
            CustomAgentSpec(id: "custom-x", name: "X", launchCommand: "xcli", symbol: "bolt"),
            CustomAgentSpec(id: "custom-y", name: "Y", launchCommand: "ycli", symbol: ""),
        ])

        let profiles = try store.asProfiles().get()
        XCTAssertEqual(profiles.map(\.id), ["custom-x", "custom-y"])
        XCTAssertEqual(profiles.map(\.name), ["X", "Y"])
        XCTAssertEqual(profiles.map(\.launchCommand), ["xcli", "ycli"])
        XCTAssertEqual(profiles[0].symbol, "bolt")
        XCTAssertEqual(profiles[1].symbol, "terminal")   // empty symbol → fallback
    }

    // MARK: - AgentRegistry integration via the test seam

    func testRegistryAllContainsCustomAndResolvesByID() {
        store.save([
            CustomAgentSpec(id: "custom-aider", name: "Aider", launchCommand: "aider", symbol: "bolt"),
        ])
        AgentRegistry.customStoreOverride = store

        // Built-ins are still present and resolvable…
        XCTAssertNotNil(AgentRegistry.profile(id: "claude-code"))
        XCTAssertTrue(AgentRegistry.all.contains { $0.id == "claude-code" })
        // …and the custom agent is appended after them and resolvable by id.
        XCTAssertTrue(AgentRegistry.all.contains { $0.id == "custom-aider" })
        let resolved = AgentRegistry.profile(id: "custom-aider")
        XCTAssertEqual(resolved?.name, "Aider")
        XCTAssertEqual(resolved?.launchCommand, "aider")
        XCTAssertEqual(resolved?.symbol, "bolt")
        // Terminal-only: a custom id has no ACP adapter (deterministic empty env).
        XCTAssertNil(AcpAdapter.forAgent("custom-aider", environment: [:]))
    }

    func testRegistryCustomIsEmptyWithoutOverride() {
        // Absent the seam and a real file, the default store yields no customs,
        // leaving `all` equal to the built-ins.
        AgentRegistry.customStoreOverride = CustomAgentStore(fileURL: fileURL)
        XCTAssertTrue(AgentRegistry.custom.isEmpty)
        XCTAssertEqual(AgentRegistry.all.count, AgentRegistry.builtIns.count)
    }

    func testContainmentApprovalRoundTripsAndLegacyEntriesFailClosed() throws {
        let spec = CustomAgentSpec(
            id: "custom-contained",
            name: "Contained",
            launchCommand: "contained",
            symbol: "cpu",
            acpPackage: "contained-acp",
            credentials: "claude",
            chatEnabled: true,
            acpPrivileges: ["workspaceRead", "network"]
        )
        store.save([spec])

        let reopened = try XCTUnwrap(store.all().first)
        XCTAssertEqual(reopened, spec)
        XCTAssertEqual(
            reopened.containmentApproval,
            CustomAdapterApproval(
                credentials: .claude,
                privileges: [.network, .workspaceRead]
            )
        )
        XCTAssertEqual(reopened.containmentApproval?.privileges, ["network", "workspaceRead"])

        let explicitLeastPrivilege = CustomAgentSpec(
            id: "custom-none",
            name: "None",
            launchCommand: "none",
            symbol: "cpu",
            acpPackage: "none-acp",
            acpPrivileges: []
        )
        XCTAssertEqual(
            explicitLeastPrivilege.containmentApproval,
            CustomAdapterApproval(credentials: .none, privileges: [])
        )

        let legacy = Data(#"{"agents":[{"id":"custom-old","name":"Old","launchCommand":"old","symbol":"cpu","acpPackage":"old-acp","credentials":"none","chatEnabled":true}]}"#.utf8)
        try legacy.write(to: fileURL)
        let decodedLegacy = try XCTUnwrap(store.all().first)
        XCTAssertNil(decodedLegacy.containmentApproval)
        XCTAssertTrue(decodedLegacy.containmentIssue?.localizedCaseInsensitiveContains("review") == true)

        var unknown = spec
        unknown.acpPrivileges = ["network", "futureHostEscape"]
        XCTAssertNil(unknown.containmentApproval)
        XCTAssertTrue(unknown.containmentIssue?.contains("unknown") == true)

        var unknownCredentials = spec
        unknownCredentials.credentials = "future-provider"
        XCTAssertNil(unknownCredentials.containmentApproval)
        XCTAssertTrue(unknownCredentials.containmentIssue?.contains("credential context is unknown") == true)
    }

    @MainActor
    func testInstallApprovalMustMatchTheCurrentRosterContract() async throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonicalDirectory: URL
        if let resolved = realpath(directory.path, nil) {
            canonicalDirectory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        } else {
            canonicalDirectory = directory
        }
        let manager = AdapterInstallManager(
            store: .init(fileURL: canonicalDirectory.appending(path: "installs.json")),
            installsRoot: canonicalDirectory.appending(path: "adapters", directoryHint: .isDirectory)
        )
        let approval = CustomAdapterApproval(
            credentials: .codex,
            privileges: [.network, .workspaceRead]
        )
        let runner: @Sendable (URL, String) async throws -> Void = { root, package in
            let bare = AdapterInstallManager.bareName(of: package)
            let packageDirectory = root.appending(path: "node_modules/\(bare)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
            try Data(#"{"lockfileVersion":3,"packages":{"node_modules/contained-acp":{"version":"1.0.0"}}}"#.utf8)
                .write(to: root.appending(path: "package-lock.json"))
            try Data(#"{"name":"contained-acp","bin":{"adapter":"./cli.js"}}"#.utf8)
                .write(to: packageDirectory.appending(path: "package.json"))
            let executable = packageDirectory.appending(path: "cli.js")
            try Data("#!/usr/bin/env node\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        _ = try await manager.install(
            agentID: "custom-contained",
            package: "contained-acp",
            approval: approval,
            runner: runner
        )

        guard case .verified = manager.verify(
            agentID: "custom-contained",
            expectedPackage: "contained-acp",
            expectedApproval: approval
        ) else { return XCTFail("the exact reviewed containment contract must verify") }
        guard case let .drifted(privilegeReason) = manager.verify(
            agentID: "custom-contained",
            expectedApproval: CustomAdapterApproval(credentials: .codex, privileges: [.network])
        ) else { return XCTFail("privilege drift must invalidate approval") }
        XCTAssertTrue(privilegeReason.contains("access changed"), privilegeReason)
        guard case let .drifted(credentialsReason) = manager.verify(
            agentID: "custom-contained",
            expectedApproval: CustomAdapterApproval(credentials: .claude, privileges: [.network, .workspaceRead])
        ) else { return XCTFail("credential-context drift must invalidate approval") }
        XCTAssertTrue(credentialsReason.contains("access changed"), credentialsReason)

        store.save([CustomAgentSpec(
            id: "custom-contained",
            name: "Contained",
            launchCommand: "contained",
            symbol: "cpu",
            acpPackage: "contained-acp",
            credentials: "codex",
            chatEnabled: true,
            acpPrivileges: ["network", "workspaceRead"]
        )])
        let containment = try XCTUnwrap(
            AcpAdapter.forCustomAgent(
                "custom-contained",
                store: store,
                installs: manager
            )?.containment
        )
        try Data("#!/usr/bin/env node\nrequire('drift')\n".utf8).write(
            to: containment.executableURL
        )
        let workspace = directory.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try containment.prepare(environment: [:], cwd: workspace.path)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("files changed"), error.localizedDescription)
        }
    }
}
