import Foundation
import XCTest
@testable import Kaisola

/// GitService against a real throwaway repo — the porcelain-v2 parse, stage,
/// and commit paths, mirroring the Node service Codex verified.
final class GitServiceTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("kaisola-git-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testCheckpointSnapshotsAndRestoresTrackedChanges() throws {
        try write("file.txt", "original\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])

        // Dirty the tree, checkpoint, dirty differently, then restore.
        try write("file.txt", "checkpointed change\n")
        let service = GitService(repoRoot: repo)
        let checkpoint = try XCTUnwrap(service.checkpoint(
            ownerID: "chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 1
        ))
        XCTAssertFalse(checkpoint.commitHash.isEmpty)
        // The snapshot must not disturb the working tree.
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8), "checkpointed change\n")

        try git(["checkout", "--", "file.txt"])   // wipe the change
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8), "original\n")

        try service.applyCheckpoint(checkpoint)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8), "checkpointed change\n")
    }

    func testCheckpointOnCleanTreeReturnsNil() throws {
        try write("clean.txt", "x\n")
        try git(["add", "clean.txt"])
        try git(["commit", "-q", "-m", "base"])
        XCTAssertNil(try GitService(repoRoot: repo).checkpoint(
            ownerID: "chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 1
        ))
    }

    func testCheckpointRefsAreNamespacedByOwnerAndTurnWhenSnapshotHashIsShared() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("file.txt", "shared dirty tree\n")

        let service = GitService(repoRoot: repo, checkpointDate: "2026-08-08T12:00:00Z")
        let first = try XCTUnwrap(service.checkpoint(
            ownerID: "chat-one",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 7
        ))
        let second = try XCTUnwrap(service.checkpoint(
            ownerID: "chat-two",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 7
        ))

        XCTAssertEqual(first.commitHash, second.commitHash)
        XCTAssertNotEqual(first.keepAliveRef, second.keepAliveRef)
        XCTAssertEqual(try git(["show-ref", "--verify", "--quiet", first.keepAliveRef]), 0)
        XCTAssertEqual(try git(["show-ref", "--verify", "--quiet", second.keepAliveRef]), 0)

        try service.dropCheckpoint(first)
        XCTAssertNotEqual(try git(["show-ref", "--verify", "--quiet", first.keepAliveRef]), 0)
        XCTAssertEqual(
            try git(["show-ref", "--verify", "--quiet", second.keepAliveRef]),
            0,
            "expiring one logical owner must retain the other owner ref"
        )
        XCTAssertEqual(try git(["reflog", "expire", "--expire=now", "--all"]), 0)
        XCTAssertEqual(try git(["gc", "--prune=now"]), 0)
        XCTAssertEqual(try git(["cat-file", "-e", "\(second.commitHash)^{commit}"]), 0)

        try git(["checkout", "--", "file.txt"])
        try service.applyCheckpoint(second)
        XCTAssertEqual(
            try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8),
            "shared dirty tree\n"
        )

        try service.dropCheckpoint(second)
        XCTAssertNotEqual(try git(["show-ref", "--verify", "--quiet", second.keepAliveRef]), 0)
    }

    func testCheckpointTurnsAreIndependentForTheSameOwnerAndIncarnation() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("file.txt", "shared dirty tree\n")

        let service = GitService(repoRoot: repo, checkpointDate: "2026-08-08T12:00:00Z")
        let incarnation = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let first = try XCTUnwrap(service.checkpoint(
            ownerID: "chat",
            incarnationID: incarnation,
            turn: 7
        ))
        let second = try XCTUnwrap(service.checkpoint(
            ownerID: "chat",
            incarnationID: incarnation,
            turn: 8
        ))

        XCTAssertEqual(first.commitHash, second.commitHash)
        XCTAssertNotEqual(first.keepAliveRef, second.keepAliveRef)
        try service.dropCheckpoint(first)
        XCTAssertNotEqual(try git(["show-ref", "--verify", "--quiet", first.keepAliveRef]), 0)
        XCTAssertEqual(try git(["show-ref", "--verify", "--quiet", second.keepAliveRef]), 0)
    }

    func testCheckpointIncarnationsAreIndependentForTheSameDurableChatAndTurn() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("file.txt", "shared dirty tree\n")

        let service = GitService(repoRoot: repo, checkpointDate: "2026-08-08T12:00:00Z")
        let first = try XCTUnwrap(service.checkpoint(
            ownerID: "restored-chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 7
        ))
        let second = try XCTUnwrap(service.checkpoint(
            ownerID: "restored-chat",
            incarnationID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            turn: 7
        ))

        XCTAssertEqual(first.commitHash, second.commitHash)
        XCTAssertNotEqual(first.keepAliveRef, second.keepAliveRef)
        try service.dropCheckpoint(first)
        XCTAssertNotEqual(try git(["show-ref", "--verify", "--quiet", first.keepAliveRef]), 0)
        XCTAssertEqual(try git(["show-ref", "--verify", "--quiet", second.keepAliveRef]), 0)
    }

    func testCheckpointDropFailsClosedWhenTheRefWasRepointed() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        let head = try GitService(repoRoot: repo).headOID()
        try write("file.txt", "dirty\n")

        let service = GitService(repoRoot: repo)
        let checkpoint = try XCTUnwrap(service.checkpoint(
            ownerID: "chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 1
        ))
        try git(["update-ref", checkpoint.keepAliveRef, head, checkpoint.commitHash])

        XCTAssertThrowsError(try service.dropCheckpoint(checkpoint))
        XCTAssertEqual(try gitOutput(["rev-parse", checkpoint.keepAliveRef]), head)
    }

    func testSymbolicCheckpointRefsNeverDereferenceIntoBranches() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        let head = try GitService(repoRoot: repo).headOID()
        try write("file.txt", "dirty\n")

        let service = GitService(repoRoot: repo)
        let checkpoint = try XCTUnwrap(service.checkpoint(
            ownerID: "chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 1
        ))
        try git(["symbolic-ref", checkpoint.keepAliveRef, "refs/heads/main"])
        let symbolicLegacyRef = "refs/kaisola/checkpoints/\(head)"
        try git(["symbolic-ref", symbolicLegacyRef, "refs/heads/main"])

        XCTAssertThrowsError(try service.dropCheckpoint(checkpoint))
        try service.migrateLegacyCheckpointRefs()

        XCTAssertEqual(try service.headOID(), head)
        XCTAssertEqual(try gitOutput(["symbolic-ref", checkpoint.keepAliveRef]), "refs/heads/main")
        XCTAssertEqual(try gitOutput(["symbolic-ref", symbolicLegacyRef]), "refs/heads/main")
        XCTAssertNotEqual(
            try git(["show-ref", "--verify", "--quiet", "refs/kaisola/checkpoints/legacy/\(head)"]),
            0
        )
    }

    func testLegacyCheckpointMigrationPreservesAReservedKeepAliveCopy() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("file.txt", "legacy dirty tree\n")

        let service = GitService(repoRoot: repo)
        let current = try XCTUnwrap(service.checkpoint(
            ownerID: "current-chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 1
        ))
        let oldRef = "refs/kaisola/checkpoints/\(current.commitHash)"
        let preservedRef = "refs/kaisola/checkpoints/legacy/\(current.commitHash)"
        try git(["update-ref", oldRef, current.commitHash])

        try service.migrateLegacyCheckpointRefs()
        try service.migrateLegacyCheckpointRefs() // idempotent after a partial/previous migration

        XCTAssertNotEqual(try git(["show-ref", "--verify", "--quiet", oldRef]), 0)
        XCTAssertEqual(try git(["show-ref", "--verify", "--quiet", preservedRef]), 0)
        XCTAssertEqual(try git(["show-ref", "--verify", "--quiet", current.keepAliveRef]), 0)

        try service.dropCheckpoint(current)
        XCTAssertEqual(
            try git(["show-ref", "--verify", "--quiet", preservedRef]),
            0,
            "namespaced expiry must never collect a legacy checkpoint with unknown ownership"
        )
        try git(["checkout", "--", "file.txt"])
        XCTAssertEqual(try git(["reflog", "expire", "--expire=now", "--all"]), 0)
        XCTAssertEqual(try git(["gc", "--prune=now"]), 0)
        XCTAssertEqual(try git(["cat-file", "-e", "\(current.commitHash)^{commit}"]), 0)
        try service.applyCheckpoint(current)
        XCTAssertEqual(
            try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8),
            "legacy dirty tree\n"
        )
    }

    func testLegacyCheckpointMigrationPreservesBothRefsOnDestinationConflict() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        let head = try GitService(repoRoot: repo).headOID()
        try write("file.txt", "legacy dirty tree\n")

        let service = GitService(repoRoot: repo)
        let checkpoint = try XCTUnwrap(service.checkpoint(
            ownerID: "chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 1
        ))
        let oldRef = "refs/kaisola/checkpoints/\(checkpoint.commitHash)"
        let preservedRef = "refs/kaisola/checkpoints/legacy/\(checkpoint.commitHash)"
        try git(["update-ref", oldRef, checkpoint.commitHash])
        try git(["update-ref", preservedRef, head])

        XCTAssertThrowsError(try service.migrateLegacyCheckpointRefs())
        XCTAssertEqual(try gitOutput(["rev-parse", oldRef]), checkpoint.commitHash)
        XCTAssertEqual(try gitOutput(["rev-parse", preservedRef]), head)
    }

    func testLegacyCheckpointMigrationLeavesMismatchedAndNonCommitRefsUntouched() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        let head = try GitService(repoRoot: repo).headOID()
        let blob = try gitOutput(["hash-object", "-w", "file.txt"])
        let mismatchedRef = "refs/kaisola/checkpoints/\(head)"
        let blobRef = "refs/kaisola/checkpoints/\(blob)"
        try git(["update-ref", mismatchedRef, blob])
        try git(["update-ref", blobRef, blob])

        try GitService(repoRoot: repo).migrateLegacyCheckpointRefs()

        XCTAssertEqual(try gitOutput(["rev-parse", mismatchedRef]), blob)
        XCTAssertEqual(try gitOutput(["rev-parse", blobRef]), blob)
        XCTAssertNotEqual(
            try git(["show-ref", "--verify", "--quiet", "refs/kaisola/checkpoints/legacy/\(blob)"]),
            0
        )
    }

    func testConcurrentLegacyCheckpointMigrationsConverge() async throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("file.txt", "legacy dirty tree\n")

        let service = GitService(repoRoot: repo)
        let checkpoint = try XCTUnwrap(service.checkpoint(
            ownerID: "chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 1
        ))
        let oldRef = "refs/kaisola/checkpoints/\(checkpoint.commitHash)"
        let preservedRef = "refs/kaisola/checkpoints/legacy/\(checkpoint.commitHash)"
        try git(["update-ref", oldRef, checkpoint.commitHash])

        async let first: Void = service.migrateLegacyCheckpointRefs()
        async let second: Void = service.migrateLegacyCheckpointRefs()
        _ = try await (first, second)

        XCTAssertNotEqual(try git(["show-ref", "--verify", "--quiet", oldRef]), 0)
        XCTAssertEqual(try gitOutput(["rev-parse", preservedRef]), checkpoint.commitHash)
    }

    func testCheckpointSupportsSHA256RepositoriesWhenGitDoes() throws {
        let shaRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-git-sha256-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: shaRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shaRepo) }
        guard try git(["init", "-q", "--object-format=sha256", "-b", "main"], at: shaRepo) == 0 else {
            throw XCTSkip("System Git does not support SHA-256 repositories")
        }
        try git(["config", "user.email", "test@example.com"], at: shaRepo)
        try git(["config", "user.name", "Test"], at: shaRepo)
        try "base\n".write(
            to: shaRepo.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "file.txt"], at: shaRepo)
        try git(["commit", "-q", "-m", "base"], at: shaRepo)
        try "dirty\n".write(
            to: shaRepo.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let service = GitService(repoRoot: shaRepo)
        let checkpoint = try XCTUnwrap(service.checkpoint(
            ownerID: "chat",
            incarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turn: 1
        ))
        XCTAssertEqual(checkpoint.commitHash.count, 64)
        XCTAssertTrue(checkpoint.keepAliveRef.hasSuffix("-\(checkpoint.commitHash)"))
        try service.dropCheckpoint(checkpoint)
    }

    func testCheckpointOwnerValidationFailsClosed() throws {
        try write("file.txt", "base\n")
        try git(["add", "file.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("file.txt", "dirty\n")

        let service = GitService(repoRoot: repo)
        let incarnation = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        XCTAssertThrowsError(try service.checkpoint(ownerID: "", incarnationID: incarnation, turn: 1))
        XCTAssertThrowsError(try service.checkpoint(ownerID: "chat", incarnationID: incarnation, turn: 0))
    }

    func testRestoreFileDiscardsUnstagedChanges() throws {
        try write("keep.txt", "one\n")
        try git(["add", "keep.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("keep.txt", "dirty\n")
        try GitService(repoRoot: repo).restoreFile(path: "keep.txt")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("keep.txt"), encoding: .utf8), "one\n")
    }

    func testWorktreeAddDiffRemoveLifecycle() throws {
        try write("base.txt", "base\n")
        try git(["add", "base.txt"])
        try git(["commit", "-q", "-m", "base"])
        let service = GitService(repoRoot: repo)
        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-wt-\(UUID().uuidString.prefix(6))").path
        let branch = "\(GitService.meshBranchPrefix)test-claude"

        try service.worktreeAdd(path: worktreePath, branch: branch, startPoint: service.headOID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath + "/base.txt"))

        // An edit inside the worktree shows in ITS diff, not the base repo's.
        try "changed\n".write(toFile: worktreePath + "/base.txt", atomically: true, encoding: .utf8)
        let worktreeService = GitService(repoRoot: URL(fileURLWithPath: worktreePath, isDirectory: true))
        XCTAssertTrue(try worktreeService.diffAgainstHead().contains("+changed"))
        XCTAssertFalse(try service.diffAgainstHead().contains("+changed"))

        try service.worktreeRemove(path: worktreePath, branch: branch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
    }

    func testWorktreeAPIsRefuseNonMeshBranches() throws {
        try write("f.txt", "x\n")
        try git(["add", "f.txt"])
        try git(["commit", "-q", "-m", "base"])
        let service = GitService(repoRoot: repo)
        XCTAssertThrowsError(
            try service.worktreeAdd(path: "/tmp/anywhere", branch: "main-2", startPoint: service.headOID())
        )
        XCTAssertThrowsError(try service.worktreeRemove(path: "/tmp/anywhere", branch: "main"))
    }

    func testWorktreeAddForksCapturedOIDAfterBaseHEADAdvances() throws {
        try write("captured.txt", "captured\n")
        try git(["add", "captured.txt"])
        try git(["commit", "-q", "-m", "captured base"])

        let service = GitService(repoRoot: repo)
        let capturedOID = try service.headOID()
        try write("later.txt", "later\n")
        try git(["add", "later.txt"])
        try git(["commit", "-q", "-m", "advance base"])
        XCTAssertNotEqual(try service.headOID(), capturedOID)

        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-wt-\(UUID().uuidString.prefix(6))").path
        let branch = "\(GitService.meshBranchPrefix)captured"
        defer { try? service.worktreeRemove(path: worktreePath, branch: branch) }
        try service.worktreeAdd(path: worktreePath, branch: branch, startPoint: capturedOID)

        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        XCTAssertEqual(try GitService(repoRoot: worktreeURL).headOID(), capturedOID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath + "/captured.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath + "/later.txt"))
    }

    func testBranchExistsDistinguishesMissingBranchFromGitFailure() throws {
        try write("base.txt", "base\n")
        try git(["add", "base.txt"])
        try git(["commit", "-q", "-m", "base"])

        let validMissingBranch = "\(GitService.meshBranchPrefix)missing"
        XCTAssertFalse(try GitService(repoRoot: repo).branchExists(validMissingBranch))
        XCTAssertThrowsError(try GitService(repoRoot: repo).branchExists("main"))

        let nonRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-not-a-repo-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }
        XCTAssertThrowsError(try GitService(repoRoot: nonRepo).branchExists(validMissingBranch)) { error in
            XCTAssertEqual(error as? GitService.GitError, .notARepository)
        }
    }

    func testRegisteredWorktreeRequiresExactPathAndBranchPair() throws {
        try write("base.txt", "base\n")
        try git(["add", "base.txt"])
        try git(["commit", "-q", "-m", "base"])

        let service = GitService(repoRoot: repo)
        let firstPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-wt-\(UUID().uuidString.prefix(6))").path
        let secondPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-wt-\(UUID().uuidString.prefix(6))").path
        let firstBranch = "\(GitService.meshBranchPrefix)first"
        let secondBranch = "\(GitService.meshBranchPrefix)second"
        let baseOID = try service.headOID()
        defer {
            try? service.worktreeRemove(path: firstPath, branch: firstBranch)
            try? service.worktreeRemove(path: secondPath, branch: secondBranch)
        }

        try service.worktreeAdd(path: firstPath, branch: firstBranch, startPoint: baseOID)
        try service.worktreeAdd(path: secondPath, branch: secondBranch, startPoint: baseOID)

        XCTAssertTrue(try service.isRegisteredWorktree(path: firstPath, branch: firstBranch))
        XCTAssertTrue(try service.isRegisteredWorktree(path: secondPath, branch: secondBranch))
        XCTAssertFalse(try service.isRegisteredWorktree(path: firstPath, branch: secondBranch))
        XCTAssertFalse(try service.isRegisteredWorktree(path: secondPath, branch: firstBranch))

        XCTAssertThrowsError(try service.worktreeRemove(path: firstPath, branch: secondBranch))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))
        XCTAssertTrue(try service.branchExists(firstBranch))
        XCTAssertTrue(try service.isRegisteredWorktree(path: firstPath, branch: firstBranch))
    }

    func testMeshDiscardInventoryDetectsDirtyFiles() throws {
        try write("tracked.txt", "base\n")
        try git(["add", "tracked.txt"])
        try git(["commit", "-q", "-m", "base"])

        let service = GitService(repoRoot: repo)
        let baseOID = try service.headOID()
        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-wt-\(UUID().uuidString.prefix(6))").path
        let branch = "\(GitService.meshBranchPrefix)dirty"
        defer { try? service.worktreeRemove(path: worktreePath, branch: branch) }
        try service.worktreeAdd(path: worktreePath, branch: branch, startPoint: baseOID)

        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        try "changed\n".write(
            to: worktreeURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "untracked\n".write(
            to: worktreeURL.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let inventory = try GitService(repoRoot: worktreeURL)
            .meshDiscardInventory(createdBaseOID: baseOID)
        XCTAssertEqual(inventory.commitsSinceBase, 0)
        XCTAssertTrue(inventory.status.unstaged.contains { $0.path == "tracked.txt" })
        XCTAssertTrue(inventory.status.untracked.contains("untracked.txt"))
        XCTAssertTrue(inventory.hasRecoverableWork)
    }

    func testMeshDiscardInventoryDetectsIgnoredOnlyFiles() throws {
        try write(".gitignore", "ignored-output/\n")
        try write("base.txt", "base\n")
        try git(["add", ".gitignore", "base.txt"])
        try git(["commit", "-q", "-m", "base"])

        let service = GitService(repoRoot: repo)
        let baseOID = try service.headOID()
        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-wt-\(UUID().uuidString.prefix(6))").path
        let branch = "\(GitService.meshBranchPrefix)ignored"
        defer { try? service.worktreeRemove(path: worktreePath, branch: branch) }
        try service.worktreeAdd(path: worktreePath, branch: branch, startPoint: baseOID)

        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let ignoredDirectory = worktreeURL.appendingPathComponent("ignored-output", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        try "valuable artifact\n".write(
            to: ignoredDirectory.appendingPathComponent("result.txt"),
            atomically: true,
            encoding: .utf8
        )

        let inventory = try GitService(repoRoot: worktreeURL)
            .meshDiscardInventory(createdBaseOID: baseOID)
        XCTAssertTrue(inventory.status.isClean)
        XCTAssertEqual(inventory.commitsSinceBase, 0)
        XCTAssertTrue(inventory.ignoredUntracked.contains("ignored-output/"))
        XCTAssertTrue(inventory.hasRecoverableWork)
    }

    func testMeshDiscardInventoryDetectsCleanUniqueCommit() throws {
        try write("base.txt", "base\n")
        try git(["add", "base.txt"])
        try git(["commit", "-q", "-m", "base"])

        let service = GitService(repoRoot: repo)
        let baseOID = try service.headOID()
        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-wt-\(UUID().uuidString.prefix(6))").path
        let branch = "\(GitService.meshBranchPrefix)committed"
        defer { try? service.worktreeRemove(path: worktreePath, branch: branch) }
        try service.worktreeAdd(path: worktreePath, branch: branch, startPoint: baseOID)

        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        try "unique\n".write(
            to: worktreeURL.appendingPathComponent("unique.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "unique.txt"], at: worktreeURL)
        try git(["commit", "-q", "-m", "unique Mesh work"], at: worktreeURL)

        let inventory = try GitService(repoRoot: worktreeURL)
            .meshDiscardInventory(createdBaseOID: baseOID)
        XCTAssertTrue(inventory.status.isClean)
        XCTAssertEqual(inventory.commitsSinceBase, 1)
        XCTAssertTrue(inventory.hasRecoverableWork)
    }

    func testStatusParsesStagedUnstagedUntracked() throws {
        try write("committed.txt", "one\n")
        try git(["add", "committed.txt"])
        try git(["commit", "-q", "-m", "init"])
        try write("committed.txt", "one\ntwo\n")   // unstaged modification
        try write("staged.txt", "new\n")
        try git(["add", "staged.txt"])              // staged add
        try write("untracked.txt", "loose\n")       // untracked

        let status = try GitService(repoRoot: repo).status()
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.staged.contains { $0.path == "staged.txt" })
        XCTAssertTrue(status.unstaged.contains { $0.path == "committed.txt" })
        XCTAssertTrue(status.untracked.contains("untracked.txt"))
        XCTAssertFalse(status.isClean)
    }

    func testGitPatchRenderingIsBoundedButPreservesSmallDiffs() {
        let small = "@@ -1 +1 @@\n-old\n+new"
        XCTAssertEqual(
            GitPatchRendering.bounded(small),
            GitBoundedPatch(lines: ["@@ -1 +1 @@", "-old", "+new"], isTruncated: false)
        )

        let oversized = (0 ... GitPatchRendering.lineLimit)
            .map { "+line \($0)" }
            .joined(separator: "\n")
        let rendered = GitPatchRendering.bounded(oversized)
        XCTAssertEqual(rendered.lines.count, GitPatchRendering.lineLimit)
        XCTAssertTrue(rendered.isTruncated)
    }

    func testStageThenCommitClearsTree() throws {
        try write("a.txt", "hello\n")
        let service = GitService(repoRoot: repo)
        try service.stage(path: "a.txt")
        XCTAssertTrue(try service.status().staged.contains { $0.path == "a.txt" })

        let hash = try service.commit(message: "add a")
        XCTAssertEqual(hash.count, 40)
        XCTAssertTrue(try service.status().isClean)
        XCTAssertEqual(try service.log(limit: 5).first?.subject, "add a")
    }

    func testStageAllAndUnstageAllRoundTripEveryChangeKind() throws {
        try write("modified.txt", "before\n")
        try write("deleted.txt", "delete me\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "base"])

        try write("modified.txt", "after\n")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("deleted.txt"))
        try write("untracked.txt", "new\n")

        let service = GitService(repoRoot: repo)
        try service.stageAll()
        let staged = try service.status()
        XCTAssertEqual(Set(staged.staged.map(\.path)), ["modified.txt", "deleted.txt", "untracked.txt"])
        XCTAssertTrue(staged.unstaged.isEmpty)
        XCTAssertTrue(staged.untracked.isEmpty)

        try service.unstageAll()
        let unstaged = try service.status()
        XCTAssertTrue(unstaged.staged.isEmpty)
        XCTAssertEqual(Set(unstaged.unstaged.map(\.path)), ["modified.txt", "deleted.txt"])
        XCTAssertEqual(unstaged.untracked, ["untracked.txt"])
    }

    func testUnstageAllSupportsAnUnbornRepositoryWithoutDeletingFiles() throws {
        try write("first.txt", "still here\n")
        let service = GitService(repoRoot: repo)
        try service.stageAll()
        XCTAssertEqual(try service.status().staged.map(\.path), ["first.txt"])

        try service.unstageAll()
        let status = try service.status()
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(status.untracked, ["first.txt"])
        XCTAssertEqual(
            try String(contentsOf: repo.appendingPathComponent("first.txt"), encoding: .utf8),
            "still here\n"
        )
    }

    func testPullFastForwardUpdatesFromConfiguredUpstreamWithoutMergeCommit() throws {
        try write("base.txt", "base\n")
        try git(["add", "base.txt"])
        try git(["commit", "-q", "-m", "base"])

        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-remote-\(UUID().uuidString.prefix(8)).git", isDirectory: true)
        let publisher = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-publisher-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: publisher)
            try? FileManager.default.removeItem(at: remote)
        }
        try git(["clone", "-q", "--bare", repo.path, remote.path])
        try git(["remote", "add", "origin", remote.path])
        try git(["fetch", "-q", "origin"])
        try git(["branch", "--set-upstream-to=origin/main", "main"])
        try git(["clone", "-q", remote.path, publisher.path])
        try git(["config", "user.email", "publisher@example.com"], at: publisher)
        try git(["config", "user.name", "Publisher"], at: publisher)
        try "remote change\n".write(
            to: publisher.appendingPathComponent("remote.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "remote.txt"], at: publisher)
        try git(["commit", "-q", "-m", "remote change"], at: publisher)
        try git(["push", "-q", "origin", "main"], at: publisher)

        let service = GitService(repoRoot: repo)
        let before = try service.headOID()
        XCTAssertTrue(try service.pullFastForward())
        XCTAssertNotEqual(try service.headOID(), before)
        XCTAssertEqual(
            try String(contentsOf: repo.appendingPathComponent("remote.txt"), encoding: .utf8),
            "remote change\n"
        )
        XCTAssertFalse(try service.pullFastForward())

        // Once local and remote both advance, --ff-only must fail without
        // synthesizing a merge commit or moving the local branch.
        try write("local.txt", "local change\n")
        try git(["add", "local.txt"])
        try git(["commit", "-q", "-m", "local change"])
        let divergentLocalHead = try service.headOID()
        try "second remote change\n".write(
            to: publisher.appendingPathComponent("remote-two.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "remote-two.txt"], at: publisher)
        try git(["commit", "-q", "-m", "second remote change"], at: publisher)
        try git(["push", "-q", "origin", "main"], at: publisher)

        XCTAssertThrowsError(try service.pullFastForward())
        XCTAssertEqual(try service.headOID(), divergentLocalHead)
    }

    func testCommitWithNothingStagedFails() throws {
        try write("committed.txt", "x\n")
        try git(["add", "."]); try git(["commit", "-q", "-m", "init"])
        XCTAssertThrowsError(try GitService(repoRoot: repo).commit(message: "empty"))
    }

    func testNonRepoThrows() {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("kaisola-not-a-repo-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try GitService(repoRoot: outside).status()) { error in
            XCTAssertEqual(error as? GitService.GitError, .notARepository)
        }
    }

    func testPathTraversalRejected() {
        XCTAssertThrowsError(try GitService(repoRoot: repo).stage(path: "../../etc/hosts")) { error in
            XCTAssertEqual(error as? GitService.GitError, .unsafePath)
        }
    }

    // MARK: helpers

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String], at directory: URL? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = directory ?? repo
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func gitOutput(_ args: [String], at directory: URL? = nil) throws -> String {
        let p = Process()
        let output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = directory ?? repo
        p.standardOutput = output
        p.standardError = Pipe()
        try p.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw GitService.GitError.commandFailed("git \(args.joined(separator: " ")) failed")
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
