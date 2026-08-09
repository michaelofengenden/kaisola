import Foundation
import XCTest
@testable import Kaisola

/// Kaisola Mesh end-to-end: one prompt fans out to every ACP-capable agent,
/// each column in an isolated `kaisola-mesh-*` worktree, all streaming from a
/// REAL spawned mock adapter; shutdown cleans the worktrees up. Skips cleanly
/// without node.
final class MeshSessionTests: XCTestCase {
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
        guard let node = Self.resolveNode() else { throw XCTSkip("node unavailable") }
        let mock = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KaisolaTests
            .deletingLastPathComponent()   // KaisolaMac
            .deletingLastPathComponent()   // native
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("tests/fixtures/acp/nativeAcpMock.cjs").path
        guard FileManager.default.fileExists(atPath: mock) else { throw XCTSkip("mock unavailable") }

        var environment = ProcessInfo.processInfo.environment
        environment["KAISOLA_ACP_ADAPTER_OVERRIDE"] = "\(node)\t\(mock)"

        let mesh = MeshSession(baseDirectory: repo, worktreeRoot: worktreeRoot)
        mesh.persistDescriptor = {}
        await mesh.start(
            agents: AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil },
            environment: environment
        )
        XCTAssertGreaterThanOrEqual(mesh.columns.count, 2, "expected multiple agent columns")

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
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyFile))
        XCTAssertFalse(try branchesLeft().isEmpty)
        let descriptor = mesh.restorationDescriptor
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
            agents: AgentRegistry.all,
            environment: environment
        )
        XCTAssertEqual(restored.columns.map(\.id), mesh.columns.map(\.id))
        XCTAssertEqual(restored.columns.map(\.worktreePath), mesh.columns.map(\.worktreePath))
        XCTAssertEqual(restored.draft, "follow up after restart")
        XCTAssertEqual(
            try branchesLeft().split(separator: "\n").count,
            branchCountBeforeRestore,
            "restoration must adopt existing worktrees, never create duplicates"
        )
        XCTAssertTrue(restored.columns.allSatisfy { !$0.conversation.rows.isEmpty })

        let assessment = await restored.discardAssessment()
        XCTAssertEqual(assessment, .recoverableWork(columns: 1))
        let refusedDestroy = await restored.destroy(allowRecoverableWork: false)
        XCTAssertEqual(refusedDestroy, .recoverableWork(columns: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyFile))

        // Only a confirmed destructive close removes the verified worktrees +
        // branches (sequential cleanup avoids Git's repository lock race).
        let confirmedDestroy = await restored.destroy(allowRecoverableWork: true)
        XCTAssertEqual(confirmedDestroy, .safe)
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
        for path in worktrees {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "worktree should be removed on shutdown")
        }
        XCTAssertTrue(try branchesLeft().isEmpty, "mesh branches should be deleted on shutdown")
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

    private static func resolveNode() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["KAISOLA_NODE"],
            "/Users/michaelofengenden/miniforge3/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
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
