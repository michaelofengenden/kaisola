import Darwin
import Foundation
import XCTest
@testable import Kaisola

/// Kaisola Mesh end-to-end: one prompt fans out to every ACP-capable agent,
/// each column in an isolated `kaisola-mesh-*` worktree, all streaming from a
/// REAL spawned mock adapter; shutdown cleans the worktrees up. Local runs may
/// skip without Node, while the dedicated required CI lane fails closed.
final class MeshSessionTests: XCTestCase {
    private enum RequiredIntegrationError: Error, Equatable {
        case missingRequiredNode
        case missingRequiredMock
        case missingExpectedNodeVersion
        case nodeVersionMismatch(expected: String, actual: String)
        case missingReceiptPath
        case invalidRequiredConfiguration(String)
        case processInspection(String)
    }

    private struct NodeRuntime: Equatable {
        let path: String
        let version: String
    }

    private struct RequiredIntegrationConfiguration: Codable, Equatable {
        let schemaVersion: Int
        let nodePath: String
        let nodeVersion: String
        let receiptPath: String

        var environment: [String: String] {
            [
                "KAISOLA_REQUIRE_MESH_INTEGRATION": "1",
                "KAISOLA_NODE": nodePath,
                "KAISOLA_EXPECTED_NODE_VERSION": nodeVersion,
                "KAISOLA_MESH_LIFECYCLE_RECEIPT": receiptPath,
            ]
        }
    }

    private struct RuntimePolicy: Decodable {
        struct Node: Decodable { let version: String }
        let node: Node
    }

    private struct ChildProcessRecord: Equatable {
        let pid: Int32
        let parentPID: Int32
        let command: String
    }

    private struct MeshLifecycleReceipt: Codable {
        let schemaVersion: Int
        let nodeVersion: String
        let columns: Int
        let adapterProcessesAtStart: Int
        let minimumAdapterFileDescriptorsAtStart: Int
        let adaptersStoppedAfterSuspend: Bool
        let worktreesPreservedAfterSuspend: Bool
        let descriptorColumnsAfterSuspend: Int
        let recoverableColumnCount: Int
        let unconfirmedDestroyRefused: Bool
        let restoredColumns: Int
        let adapterProcessesAfterRestore: Int
        let restoredWithoutDuplicateWorktrees: Bool
        let meshWorktreesRemoved: Bool
        let meshBranchesRemoved: Bool
        let adaptersStoppedAfterDestroy: Bool
        let unrelatedProcessPreserved: Bool
        let unrelatedWorktreePreserved: Bool
    }

    private var repo: URL!
    private var worktreeRoot: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        worktreeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-durable-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: worktreeRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worktreeRoot.path)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        try "seed\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "seed.txt"])
        try git(["commit", "-q", "-m", "seed"])
    }

    func testRequiredMeshRuntimeFailsInsteadOfSkippingMissingOrMismatchedNode() throws {
        let expectedVersion = "9.8.7"
        let requiredEnvironment = [
            "KAISOLA_REQUIRE_MESH_INTEGRATION": "1",
            "KAISOLA_EXPECTED_NODE_VERSION": expectedVersion,
            "KAISOLA_NODE": "/private/tmp/required-node",
        ]

        XCTAssertThrowsError(try Self.resolveNode(
            environment: requiredEnvironment,
            isExecutable: { _ in false },
            versionReader: { _ in XCTFail("a missing executable must not be probed"); return "" }
        )) { error in
            XCTAssertEqual(error as? RequiredIntegrationError, .missingRequiredNode)
        }

        XCTAssertThrowsError(try Self.resolveNode(
            environment: requiredEnvironment,
            isExecutable: { _ in true },
            versionReader: { _ in "9.8.6" }
        )) { error in
            XCTAssertEqual(
                error as? RequiredIntegrationError,
                .nodeVersionMismatch(expected: expectedVersion, actual: "9.8.6")
            )
        }
    }

    func testRequiredMeshConfigurationRejectsUnknownFieldsAndUnpinnedRuntime() throws {
        let expectedVersion = "9.8.7"
        let valid = Data(
            """
            {"schemaVersion":1,"nodePath":"/private/tmp/node","nodeVersion":"9.8.7",\
            "receiptPath":"/private/tmp/receipt.json"}
            """.utf8
        )
        XCTAssertEqual(
            try Self.decodeRequiredConfiguration(valid, expectedNodeVersion: expectedVersion),
            RequiredIntegrationConfiguration(
                schemaVersion: 1,
                nodePath: "/private/tmp/node",
                nodeVersion: expectedVersion,
                receiptPath: "/private/tmp/receipt.json"
            )
        )

        for source in [
            """
            {"schemaVersion":1,"nodePath":"/private/tmp/node","nodeVersion":"9.8.7",\
            "receiptPath":"/private/tmp/receipt.json","unexpected":true}
            """,
            """
            {"schemaVersion":1,"nodePath":"/private/tmp/node","nodeVersion":"9.8.6",\
            "receiptPath":"/private/tmp/receipt.json"}
            """,
        ] {
            let invalid = Data(source.utf8)
            XCTAssertThrowsError(try Self.decodeRequiredConfiguration(
                invalid,
                expectedNodeVersion: expectedVersion
            ))
        }
    }

    func testRequiredMeshPinnedNodeVersionMatchesPackagePolicy() throws {
        let policyURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BrokerHelper/package-policy.json", isDirectory: false)
        let policy = try JSONDecoder().decode(
            RuntimePolicy.self,
            from: Data(contentsOf: policyURL)
        )

        XCTAssertEqual(try Self.pinnedNodeVersion(), policy.node.version)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: worktreeRoot)
    }

    @MainActor
    func testVisualFixtureSeedsEveryConversationWithoutLaunchingAnAdapter() async throws {
        let mesh = MeshSession(baseDirectory: repo, worktreeRoot: worktreeRoot)

        mesh.loadVisualFixture()

        XCTAssertEqual(mesh.lifecycle, .active)
        XCTAssertEqual(mesh.columns.count, 3)
        for column in mesh.columns {
            let rowsBeforeStart = column.conversation.rows
            XCTAssertTrue(column.conversation.isConnected)
            XCTAssertFalse(rowsBeforeStart.isEmpty)

            // Mirrors MeshColumnView's task. A visual conversation has already
            // started in fixture mode, so this must be a side-effect-free no-op.
            await column.conversation.start()

            XCTAssertTrue(column.conversation.isConnected)
            XCTAssertNil(column.conversation.statusMessage)
            XCTAssertEqual(column.conversation.rows, rowsBeforeStart)
        }
    }

    @MainActor
    func testMeshSuspendPreservesRecoverableWorkAndConfirmedDestroyCleansIt() async throws {
        let testEnvironment = ProcessInfo.processInfo.environment
        let fileConfiguration = try Self.requiredIntegrationConfiguration()
        let effectiveEnvironment = fileConfiguration?.environment ?? testEnvironment
        let requiredIntegration = effectiveEnvironment["KAISOLA_REQUIRE_MESH_INTEGRATION"] == "1"
        guard let node = try Self.resolveNode(environment: effectiveEnvironment) else {
            throw XCTSkip("node unavailable")
        }
        let mock = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KaisolaTests
            .deletingLastPathComponent()   // KaisolaMac
            .deletingLastPathComponent()   // native
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("tests/fixtures/acp/nativeAcpMock.cjs").path
        guard FileManager.default.fileExists(atPath: mock) else {
            if requiredIntegration { throw RequiredIntegrationError.missingRequiredMock }
            throw XCTSkip("mock unavailable")
        }
        let receiptURL = effectiveEnvironment["KAISOLA_MESH_LIFECYCLE_RECEIPT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        if requiredIntegration, receiptURL == nil {
            throw RequiredIntegrationError.missingReceiptPath
        }

        // A separate child and Git worktree are deliberate control subjects.
        // Mesh teardown owns neither and must leave both untouched.
        let unrelatedProcess = Process()
        unrelatedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelatedProcess.arguments = ["90"]
        unrelatedProcess.standardInput = FileHandle.nullDevice
        unrelatedProcess.standardOutput = FileHandle.nullDevice
        unrelatedProcess.standardError = FileHandle.nullDevice
        try unrelatedProcess.run()
        defer {
            if unrelatedProcess.isRunning {
                unrelatedProcess.terminate()
                unrelatedProcess.waitUntilExit()
            }
        }

        let unrelatedWorktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-unrelated-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let unrelatedBranch = "unrelated-control-\(UUID().uuidString.lowercased())"
        try git(["worktree", "add", "-q", "-b", unrelatedBranch, unrelatedWorktree.path, "HEAD"])
        defer {
            _ = try? git(["worktree", "remove", "--force", unrelatedWorktree.path])
            _ = try? git(["branch", "-D", unrelatedBranch])
            try? FileManager.default.removeItem(at: unrelatedWorktree)
        }

        var environment = testEnvironment
        environment["KAISOLA_ACP_ADAPTER_OVERRIDE"] = "\(node.path)\t\(mock)"

        let mesh = MeshSession(baseDirectory: repo, worktreeRoot: worktreeRoot)
        addTeardownBlock { @MainActor in await mesh.suspend() }
        mesh.persistDescriptor = {}
        await mesh.start(
            agents: AgentRegistry.builtIns.filter { AcpAdapter.forAgent($0.id) != nil },
            environment: environment
        )
        XCTAssertGreaterThanOrEqual(mesh.columns.count, 2, "expected multiple agent columns")

        let initialAdapters = try await Self.waitForAdapterProcesses(
            mockPath: mock,
            expectedCount: mesh.columns.count
        )
        XCTAssertEqual(initialAdapters.count, mesh.columns.count, "every column must own one child adapter")
        let initialAdapterPIDs = Set(initialAdapters.map(\.pid))
        XCTAssertEqual(initialAdapterPIDs.count, mesh.columns.count, "adapter child PIDs must be distinct")
        let minimumAdapterFileDescriptorsAtStart = try XCTUnwrap(
            try initialAdapters.map { try Self.fileDescriptorCount(pid: $0.pid) }.min()
        )
        XCTAssertGreaterThanOrEqual(
            minimumAdapterFileDescriptorsAtStart,
            3,
            "each live adapter must expose its stdio descriptors"
        )
        XCTAssertTrue(unrelatedProcess.isRunning)
        XCTAssertTrue(try worktreeIsRegistered(unrelatedWorktree.path))

        // Every column is isolated in its own kaisola-mesh-* worktree.
        let worktrees = mesh.columns.compactMap(\.worktreePath)
        XCTAssertEqual(worktrees.count, mesh.columns.count, "every column should get a worktree in a repo")
        XCTAssertEqual(Set(worktrees).count, worktrees.count, "worktrees must be distinct")
        for path in worktrees {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/seed.txt"))
        }

        // The fan-out reaches every column and each streams a full turn.
        mesh.send("hello mesh")
        let deadline = Date().addingTimeInterval(15)
        func allResponded() -> Bool {
            mesh.columns.allSatisfy { column in
                column.conversation.rows.contains { row in
                    if case .message = row { return true } else { return false }
                }
            }
        }
        while !allResponded(), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            // The mock asks a permission mid-turn; grant it per column.
            for column in mesh.columns {
                if let permission = column.conversation.pendingPermission,
                   let allow = permission.options.first(where: { $0.kind.contains("allow") }) {
                    column.conversation.answerPermission(allow.id)
                }
            }
        }
        XCTAssertTrue(allResponded(), "every column should stream an agent message")
        for column in mesh.columns {
            XCTAssertTrue(column.conversation.rows.contains { row in
                if case let .user(_, text, _) = row { return text == "hello mesh" }
                return false
            }, "the prompt lands in every column's transcript")
        }

        // Make one column dirty. A lifecycle suspend must preserve it and an
        // unconfirmed destructive close must refuse it.
        let dirtyFile = try XCTUnwrap(worktrees.first).appending("/recover-me.txt")
        try "unintegrated\n".write(
            to: URL(fileURLWithPath: dirtyFile),
            atomically: true,
            encoding: .utf8
        )
        mesh.draft = "follow up after restart"
        await mesh.suspend()
        await mesh.suspend() // idempotent window-close + app-quit sequence
        XCTAssertEqual(mesh.lifecycle, .suspended)
        let adaptersAfterSuspend = try await Self.waitForAdapterProcesses(mockPath: mock, expectedCount: 0)
        let adaptersStoppedAfterSuspend = adaptersAfterSuspend.isEmpty
        XCTAssertTrue(adaptersStoppedAfterSuspend, "suspend must stop every Mesh-owned adapter")
        let worktreesPreservedAfterSuspend = worktrees.allSatisfy(FileManager.default.fileExists(atPath:))
        XCTAssertTrue(worktreesPreservedAfterSuspend)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyFile))
        XCTAssertFalse(try branchesLeft().isEmpty)
        let descriptor = mesh.restorationDescriptor
        let descriptorColumnsAfterSuspend = descriptor.columns.count
        XCTAssertEqual(descriptorColumnsAfterSuspend, mesh.columns.count)
        XCTAssertTrue(unrelatedProcess.isRunning, "suspend must not signal an unrelated child")
        XCTAssertTrue(try worktreeIsRegistered(unrelatedWorktree.path), "suspend must preserve unrelated worktrees")
        let branchCountBeforeRestore = try branchesLeft()
            .split(separator: "\n").count
        let restored = MeshSession(
            id: descriptor.id,
            baseDirectory: repo,
            mode: descriptor.mode,
            purpose: descriptor.purpose,
            title: descriptor.title,
            lifecycle: descriptor.lifecycle,
            initialDraft: mesh.draft,
            worktreeRoot: worktreeRoot
        )
        addTeardownBlock { @MainActor in await restored.suspend() }
        restored.persistDescriptor = {}
        let restoredStates = descriptor.columns.map { descriptor in
            MeshSession.RestoredColumnState(
                descriptor: descriptor,
                rows: mesh.columns.first(where: { $0.id == descriptor.id })?.conversation.rows ?? [],
                initialDraft: nil,
                usage: nil
            )
        }
        await restored.restore(
            states: restoredStates,
            agents: AgentRegistry.builtIns,
            environment: environment
        )
        for column in restored.columns {
            await column.conversation.start()
        }
        let restoredAdapters = try await Self.waitForAdapterProcesses(
            mockPath: mock,
            expectedCount: restored.columns.count
        )
        let adapterProcessesAfterRestore = restoredAdapters.count
        let restoredColumnCount = restored.columns.count
        XCTAssertEqual(adapterProcessesAfterRestore, restored.columns.count)
        XCTAssertTrue(
            initialAdapterPIDs.isDisjoint(with: restoredAdapters.map(\.pid)),
            "restoration must launch fresh child processes, never reuse suspended PIDs"
        )
        XCTAssertEqual(restored.columns.map(\.id), mesh.columns.map(\.id))
        XCTAssertEqual(restored.columns.map(\.worktreePath), mesh.columns.map(\.worktreePath))
        XCTAssertEqual(restored.draft, "follow up after restart")
        let restoredWithoutDuplicateWorktrees = try branchesLeft().split(separator: "\n").count
            == branchCountBeforeRestore
        XCTAssertTrue(restoredWithoutDuplicateWorktrees, "restoration must adopt existing worktrees, never create duplicates")
        XCTAssertTrue(restored.columns.allSatisfy { !$0.conversation.rows.isEmpty })

        let assessment = await restored.discardAssessment()
        XCTAssertEqual(assessment, .recoverableWork(columns: 1))
        let recoverableColumnCount = try XCTUnwrap({
            if case let .recoverableWork(columns) = assessment { return columns }
            return nil
        }())
        let refusedDestroy = await restored.destroy(allowRecoverableWork: false)
        XCTAssertEqual(refusedDestroy, .recoverableWork(columns: 1))
        let unconfirmedDestroyRefused = refusedDestroy == .recoverableWork(columns: 1)
            && FileManager.default.fileExists(atPath: dirtyFile)
        XCTAssertTrue(unconfirmedDestroyRefused)

        // Only a confirmed destructive close removes the verified worktrees +
        // branches (sequential cleanup avoids Git's repository lock race).
        let confirmedDestroy = await restored.destroy(allowRecoverableWork: true)
        XCTAssertEqual(confirmedDestroy, .safe)
        let adaptersAfterDestroy = try await Self.waitForAdapterProcesses(mockPath: mock, expectedCount: 0)
        let adaptersStoppedAfterDestroy = adaptersAfterDestroy.isEmpty
        XCTAssertTrue(adaptersStoppedAfterDestroy, "destroy must leave no Mesh-owned adapter process")
        let cleanupDeadline = Date().addingTimeInterval(10)
        func branchesLeft() throws -> String {
            try git(["branch", "--list", "\(GitService.meshBranchPrefix)*"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func cleanupPending() throws -> Bool {
            try worktrees.contains(where: { FileManager.default.fileExists(atPath: $0) }) || !branchesLeft().isEmpty
        }
        while Date() < cleanupDeadline, try cleanupPending() {
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let meshWorktreesRemoved = worktrees.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
        let meshBranchesRemoved = try branchesLeft().isEmpty
        XCTAssertTrue(meshWorktreesRemoved, "worktrees should be removed on shutdown")
        XCTAssertTrue(meshBranchesRemoved, "mesh branches should be deleted on shutdown")
        let unrelatedProcessPreserved = unrelatedProcess.isRunning
        let unrelatedWorktreeStillRegistered = try worktreeIsRegistered(unrelatedWorktree.path)
        let unrelatedWorktreePreserved = FileManager.default.fileExists(atPath: unrelatedWorktree.path)
            && unrelatedWorktreeStillRegistered
        XCTAssertTrue(unrelatedProcessPreserved, "destroy must not signal an unrelated child")
        XCTAssertTrue(unrelatedWorktreePreserved, "destroy must not remove an unrelated worktree")

        if let receiptURL {
            try Self.writeReceipt(
                MeshLifecycleReceipt(
                    schemaVersion: 1,
                    nodeVersion: node.version,
                    columns: mesh.columns.count,
                    adapterProcessesAtStart: initialAdapters.count,
                    minimumAdapterFileDescriptorsAtStart: minimumAdapterFileDescriptorsAtStart,
                    adaptersStoppedAfterSuspend: adaptersStoppedAfterSuspend,
                    worktreesPreservedAfterSuspend: worktreesPreservedAfterSuspend,
                    descriptorColumnsAfterSuspend: descriptorColumnsAfterSuspend,
                    recoverableColumnCount: recoverableColumnCount,
                    unconfirmedDestroyRefused: unconfirmedDestroyRefused,
                    restoredColumns: restoredColumnCount,
                    adapterProcessesAfterRestore: adapterProcessesAfterRestore,
                    restoredWithoutDuplicateWorktrees: restoredWithoutDuplicateWorktrees,
                    meshWorktreesRemoved: meshWorktreesRemoved,
                    meshBranchesRemoved: meshBranchesRemoved,
                    adaptersStoppedAfterDestroy: adaptersStoppedAfterDestroy,
                    unrelatedProcessPreserved: unrelatedProcessPreserved,
                    unrelatedWorktreePreserved: unrelatedWorktreePreserved
                ),
                to: receiptURL
            )
        }
    }

    @MainActor
    func testDestroyPersistsAndResumesBranchOnlyCleanupAfterRelaunch() async throws {
        let meshID = "mesh-partial-cleanup"
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        let columnID = "\(meshID)-\(agent.id)"
        let worktreeURL = worktreeRoot.appendingPathComponent(columnID, isDirectory: true)
        let branch = "\(GitService.meshBranchPrefix)\(meshID.suffix(6))-\(agent.id)"
        let branchLock = repo.appendingPathComponent(".git/refs/heads/\(branch).lock")
        let service = GitService(repoRoot: repo)
        let baseOID = try service.headOID()
        defer {
            try? FileManager.default.removeItem(at: branchLock)
            try? FileManager.default.removeItem(at: worktreeURL)
            if (try? service.branchExists(branch)) == true {
                _ = try? git(["branch", "-D", branch])
            }
        }

        try service.worktreeAdd(path: worktreeURL.path, branch: branch, startPoint: baseOID)
        let columnDescriptor = NativeRestorableMeshColumnDescriptor(
            id: columnID,
            agentID: agent.id,
            role: .peer,
            worktreePath: worktreeURL.path,
            branch: branch,
            createdBaseOID: baseOID,
            acpSessionID: nil,
            accountBinding: SessionAccountBinding(
                accountID: "codex-test",
                provider: .codex,
                label: "Test",
                configDirectory: "/tmp/kaisola-codex-test"
            ),
            provisioning: .attached,
            workspaceKind: .worktree
        )
        let mesh = MeshSession(
            id: meshID,
            baseDirectory: repo,
            lifecycle: .suspended,
            worktreeRoot: worktreeRoot
        )
        mesh.persistDescriptor = {}
        var environment = ProcessInfo.processInfo.environment
        environment["KAISOLA_ACP_ADAPTER_OVERRIDE"] = "/usr/bin/true"
        await mesh.restore(
            states: [
                MeshSession.RestoredColumnState(
                    descriptor: columnDescriptor,
                    rows: [],
                    initialDraft: nil,
                    usage: nil
                ),
            ],
            agents: [agent],
            environment: environment
        )
        XCTAssertEqual(mesh.columns.count, 1)

        try "hold branch deletion\n".write(to: branchLock, atomically: true, encoding: .utf8)
        guard case .blocked = await mesh.destroy(allowRecoverableWork: true) else {
            return XCTFail("branch deletion failure must leave a retryable cleanup manifest")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeURL.path))
        XCTAssertTrue(try service.branchExists(branch))
        XCTAssertEqual(mesh.lifecycle, .pendingDeletion)
        XCTAssertEqual(
            try service.worktreeRemovalPhase(path: worktreeURL.path, branch: branch),
            .branchCleanupPending
        )

        // Round-trip the exact partial manifest to prove relaunch recovery does
        // not depend on the old in-memory MeshSession.
        let encoded = try JSONEncoder().encode(mesh.restorationDescriptor)
        let persisted = try JSONDecoder().decode(NativeRestorableMeshDescriptor.self, from: encoded)
        XCTAssertEqual(persisted.lifecycle, .pendingDeletion)
        XCTAssertEqual(persisted.columns.map(\.id), [columnID])

        try FileManager.default.removeItem(at: branchLock)
        try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        let sentinel = worktreeURL.appendingPathComponent("replacement-must-survive.txt")
        try "keep\n".write(to: sentinel, atomically: true, encoding: .utf8)

        let resumed = MeshSession(
            id: persisted.id,
            baseDirectory: repo,
            mode: persisted.mode,
            purpose: persisted.purpose,
            title: persisted.title,
            lifecycle: persisted.lifecycle,
            worktreeRoot: worktreeRoot
        )
        resumed.persistDescriptor = {}
        await resumed.restore(
            states: persisted.columns.map {
                MeshSession.RestoredColumnState(
                    descriptor: $0,
                    rows: [],
                    initialDraft: nil,
                    usage: nil
                )
            },
            agents: [],
            environment: environment
        )

        XCTAssertFalse(try service.branchExists(branch))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(resumed.restorationDescriptor.columns.isEmpty)
    }

    @MainActor
    func testPersistenceFailureCreatesNoWorktreeOrBranch() async throws {
        enum ExpectedFailure: Error { case manifestWrite }

        let mesh = MeshSession(baseDirectory: repo, worktreeRoot: worktreeRoot)
        mesh.persistDescriptor = { throw ExpectedFailure.manifestWrite }
        var environment = ProcessInfo.processInfo.environment
        environment["KAISOLA_ACP_ADAPTER_OVERRIDE"] = "/usr/bin/true"

        await mesh.start(agents: [try XCTUnwrap(AgentRegistry.profile(id: "codex"))], environment: environment)

        XCTAssertEqual(mesh.lifecycle, .recoveryRequired)
        XCTAssertTrue(mesh.columns.isEmpty)
        XCTAssertTrue(mesh.restorationDescriptor.columns.isEmpty)
        XCTAssertTrue(
            try git(["branch", "--list", "\(GitService.meshBranchPrefix)*"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: worktreeRoot.path),
            [],
            "the persistence barrier must fail before any Git worktree is registered"
        )
    }

    @MainActor
    func testRestoreRejectsSymlinkedWorktreeRootWithoutAdoptingACPColumn() async throws {
        let backingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-backing-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.removeItem(at: worktreeRoot)
        try FileManager.default.createDirectory(
            at: backingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: backingRoot) }
        try FileManager.default.createSymbolicLink(at: worktreeRoot, withDestinationURL: backingRoot)

        let meshID = "mesh-hostile"
        let agentID = "codex"
        let descriptor = NativeRestorableMeshColumnDescriptor(
            id: "\(meshID)-\(agentID)",
            agentID: agentID,
            role: .peer,
            worktreePath: worktreeRoot
                .appendingPathComponent("\(meshID)-\(agentID)", isDirectory: true)
                .path,
            branch: "\(GitService.meshBranchPrefix)\(meshID.suffix(6))-\(agentID)",
            createdBaseOID: try GitService(repoRoot: repo).headOID(),
            acpSessionID: "unsafe-session",
            provisioning: .attached,
            workspaceKind: .worktree
        )
        let mesh = MeshSession(
            id: meshID,
            baseDirectory: repo,
            lifecycle: .suspended,
            worktreeRoot: worktreeRoot
        )
        var environment = ProcessInfo.processInfo.environment
        environment["KAISOLA_ACP_ADAPTER_OVERRIDE"] = "/usr/bin/true"

        await mesh.restore(
            states: [
                MeshSession.RestoredColumnState(
                    descriptor: descriptor,
                    rows: [],
                    initialDraft: "must remain parked",
                    usage: nil
                ),
            ],
            agents: [try XCTUnwrap(AgentRegistry.profile(id: agentID))],
            environment: environment
        )

        XCTAssertEqual(mesh.lifecycle, .recoveryRequired)
        XCTAssertTrue(mesh.columns.isEmpty, "an unsafe root must never launch an adopted ACP column")
        XCTAssertEqual(mesh.restorationDescriptor.columns.count, 1)
        XCTAssertEqual(mesh.restorationDescriptor.columns.first?.provisioning, .recoveryRequired)
        XCTAssertFalse(mesh.restorationDescriptor.columns.first?.acpSessionID?.isEmpty ?? true)
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func worktreeIsRegistered(_ path: String) throws -> Bool {
        let expected = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return try git(["worktree", "list", "--porcelain"])
            .split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
            .map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
            }
            .contains(expected)
    }

    private static func resolveNode(environment: [String: String]) throws -> NodeRuntime? {
        try resolveNode(
            environment: environment,
            isExecutable: FileManager.default.isExecutableFile(atPath:),
            versionReader: nodeVersion(at:)
        )
    }

    private static func requiredIntegrationConfiguration() throws -> RequiredIntegrationConfiguration? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KaisolaTests
            .deletingLastPathComponent()   // KaisolaMac
            .appendingPathComponent(".artifacts/required-mesh-lifecycle.json", isDirectory: false)
        var metadata = stat()
        let status = url.path.withCString { Darwin.lstat($0, &metadata) }
        if status != 0, errno == ENOENT { return nil }
        guard status == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == 0o600,
              (1 ... 16 * 1_024).contains(Int(metadata.st_size)) else {
            throw RequiredIntegrationError.invalidRequiredConfiguration("unsafe configuration file")
        }
        return try decodeRequiredConfiguration(
            Data(contentsOf: url),
            expectedNodeVersion: pinnedNodeVersion()
        )
    }

    private static func decodeRequiredConfiguration(
        _ data: Data,
        expectedNodeVersion: String
    ) throws -> RequiredIntegrationConfiguration {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(["schemaVersion", "nodePath", "nodeVersion", "receiptPath"]) else {
            throw RequiredIntegrationError.invalidRequiredConfiguration("unexpected configuration keys")
        }
        let configuration = try JSONDecoder().decode(RequiredIntegrationConfiguration.self, from: data)
        guard configuration.schemaVersion == 1,
              configuration.nodeVersion == expectedNodeVersion,
              configuration.nodePath.hasPrefix("/"),
              configuration.receiptPath.hasPrefix("/") else {
            throw RequiredIntegrationError.invalidRequiredConfiguration("invalid configuration values")
        }
        return configuration
    }

    private static func pinnedNodeVersion() throws -> String {
        let policyURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KaisolaTests
            .deletingLastPathComponent()   // KaisolaMac
            .appendingPathComponent("BrokerHelper/package-policy.json", isDirectory: false)
        let policy = try JSONDecoder().decode(
            RuntimePolicy.self,
            from: Data(contentsOf: policyURL)
        )
        guard !policy.node.version.isEmpty else {
            throw RequiredIntegrationError.invalidRequiredConfiguration("empty runtime policy version")
        }
        return policy.node.version
    }

    private static func resolveNode(
        environment: [String: String],
        isExecutable: (String) -> Bool,
        versionReader: (String) throws -> String
    ) throws -> NodeRuntime? {
        if environment["KAISOLA_REQUIRE_MESH_INTEGRATION"] == "1" {
            guard let configured = environment["KAISOLA_NODE"],
                  !configured.isEmpty,
                  isExecutable(configured) else {
                throw RequiredIntegrationError.missingRequiredNode
            }
            guard let expected = environment["KAISOLA_EXPECTED_NODE_VERSION"], !expected.isEmpty else {
                throw RequiredIntegrationError.missingExpectedNodeVersion
            }
            let actual = try versionReader(configured)
            guard actual == expected else {
                throw RequiredIntegrationError.nodeVersionMismatch(expected: expected, actual: actual)
            }
            return NodeRuntime(path: configured, version: actual)
        }

        let candidates = [
            environment["KAISOLA_NODE"],
            "/Users/michaelofengenden/miniforge3/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        guard let path = candidates.compactMap({ $0 }).first(where: isExecutable) else { return nil }
        return NodeRuntime(path: path, version: try versionReader(path))
    }

    private static func nodeVersion(at path: String) throws -> String {
        let output = try run(path, ["--version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = output.first == "v" ? String(output.dropFirst()) : output
        guard !version.isEmpty else {
            throw RequiredIntegrationError.processInspection("node returned an empty version")
        }
        return version
    }

    private static func adapterProcesses(mockPath: String) throws -> [ChildProcessRecord] {
        let parentPID = ProcessInfo.processInfo.processIdentifier
        return try processSnapshot().filter {
            $0.parentPID == parentPID && $0.command.contains(mockPath)
        }
    }

    private static func waitForAdapterProcesses(
        mockPath: String,
        expectedCount: Int,
        timeout: TimeInterval = 10
    ) async throws -> [ChildProcessRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        var records = try adapterProcesses(mockPath: mockPath)
        while records.count != expectedCount, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            records = try adapterProcesses(mockPath: mockPath)
        }
        guard records.count == expectedCount else {
            throw RequiredIntegrationError.processInspection(
                "expected \(expectedCount) adapter children, found \(records.count)"
            )
        }
        return records
    }

    private static func processSnapshot() throws -> [ChildProcessRecord] {
        try run("/bin/ps", ["-ww", "-axo", "pid=,ppid=,command="])
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                guard fields.count == 3,
                      let pid = Int32(fields[0]),
                      let parentPID = Int32(fields[1]) else { return nil }
                return ChildProcessRecord(pid: pid, parentPID: parentPID, command: String(fields[2]))
            }
    }

    private static func fileDescriptorCount(pid: Int32) throws -> Int {
        try run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-F", "f"])
            .split(separator: "\n")
            .count { $0.first == "f" }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw RequiredIntegrationError.processInspection("could not run \(executable)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RequiredIntegrationError.processInspection(
                "\(executable) exited \(process.terminationStatus)"
            )
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func writeReceipt(_ receipt: MeshLifecycleReceipt, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(receipt)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

extension MeshSessionTests {
    private actor Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    func testStartPublishesExplicitTransitionAndCompletionStates() async {
        let coordinator = MeshLifecycleCoordinator()
        let gate = Gate()
        let entered = expectation(description: "start operation entered")

        coordinator.start(meshID: "mesh") {
            entered.fulfill()
            await gate.wait()
            return .active
        }

        await fulfillment(of: [entered])
        XCTAssertEqual(coordinator.state(for: "mesh"), .starting)

        await gate.open()
        await coordinator.waitForIdle(meshID: "mesh")
        XCTAssertEqual(coordinator.state(for: "mesh"), .active)
    }

    @MainActor
    func testSuspendCancelsInFlightStartAndStaleCompletionCannotWin() async {
        let coordinator = MeshLifecycleCoordinator()
        let gate = Gate()
        let entered = expectation(description: "start operation entered")

        coordinator.start(meshID: "mesh") {
            entered.fulfill()
            await gate.wait()
            return .active
        }
        await fulfillment(of: [entered])

        let completion = await coordinator.suspend(meshID: "mesh") {
            .suspended
        }
        XCTAssertEqual(completion, .completed)
        XCTAssertEqual(coordinator.state(for: "mesh"), .suspended)

        await gate.open()
        await Task.yield()
        XCTAssertEqual(coordinator.state(for: "mesh"), .suspended)
    }

    @MainActor
    func testDestroyMapsResultToRecoveryState() async {
        enum Assessment: Equatable, Sendable {
            case recoverableWork
        }

        let coordinator = MeshLifecycleCoordinator()
        let outcome = await coordinator.destroy(
            meshID: "mesh",
            operation: { Assessment.recoverableWork },
            resolvedState: { _ in .recoveryRequired }
        )

        XCTAssertEqual(outcome, .completed(.recoverableWork))
        XCTAssertEqual(coordinator.state(for: "mesh"), .recoveryRequired)
    }

    @MainActor
    func testCancelledDestroyCannotPublishItsResolvedState() async {
        enum Assessment: Equatable, Sendable {
            case safe
        }

        let coordinator = MeshLifecycleCoordinator()
        let gate = Gate()
        let entered = expectation(description: "destroy operation entered")
        let outcomeTask = Task {
            await coordinator.destroy(
                meshID: "mesh",
                operation: {
                    entered.fulfill()
                    await gate.wait()
                    return Assessment.safe
                },
                resolvedState: { _ in .destroyed }
            )
        }

        await fulfillment(of: [entered])
        XCTAssertEqual(coordinator.state(for: "mesh"), .destroying)
        coordinator.cancel(meshID: "mesh")
        await gate.open()

        let outcome = await outcomeTask.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(coordinator.state(for: "mesh"), .cancelled)
    }

    @MainActor
    func testCancelAllFencesEveryOutstandingCompletion() async {
        let coordinator = MeshLifecycleCoordinator()
        let firstGate = Gate()
        let secondGate = Gate()
        let entered = expectation(description: "both starts entered")
        entered.expectedFulfillmentCount = 2

        coordinator.start(meshID: "first") {
            entered.fulfill()
            await firstGate.wait()
            return .active
        }
        coordinator.start(meshID: "second") {
            entered.fulfill()
            await secondGate.wait()
            return .active
        }
        await fulfillment(of: [entered])

        coordinator.cancelAll()
        XCTAssertEqual(coordinator.state(for: "first"), .cancelled)
        XCTAssertEqual(coordinator.state(for: "second"), .cancelled)

        await firstGate.open()
        await secondGate.open()
        await Task.yield()
        XCTAssertEqual(coordinator.state(for: "first"), .cancelled)
        XCTAssertEqual(coordinator.state(for: "second"), .cancelled)
    }

    @MainActor
    func testForgottenIdentifierCanBeReusedWithoutOldTaskWinning() async {
        let coordinator = MeshLifecycleCoordinator()
        let oldGate = Gate()
        let oldEntered = expectation(description: "old start entered")

        coordinator.start(meshID: "reused") {
            oldEntered.fulfill()
            await oldGate.wait()
            return .recoveryRequired
        }
        await fulfillment(of: [oldEntered])

        coordinator.forget(meshID: "reused")
        coordinator.start(meshID: "reused") { .active }
        await coordinator.waitForIdle(meshID: "reused")
        XCTAssertEqual(coordinator.state(for: "reused"), .active)

        await oldGate.open()
        await Task.yield()
        XCTAssertEqual(coordinator.state(for: "reused"), .active)
    }

    @MainActor
    func testPersistedLifecycleMappingIsStable() {
        XCTAssertEqual(MeshLifecycleCoordinator.State(.provisioning), .starting)
        XCTAssertEqual(MeshLifecycleCoordinator.State(.active), .active)
        XCTAssertEqual(MeshLifecycleCoordinator.State(.suspended), .suspended)
        XCTAssertEqual(MeshLifecycleCoordinator.State(.pendingDeletion), .destroying)
        XCTAssertEqual(MeshLifecycleCoordinator.State(.recoveryRequired), .recoveryRequired)
    }
}
