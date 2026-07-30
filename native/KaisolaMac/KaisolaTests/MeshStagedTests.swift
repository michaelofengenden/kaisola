import Foundation
import XCTest
@testable import Kaisola

/// Pure unit tests for the staged + idea Mesh upgrade: diff-stat parsing, the
/// integrate patch round-trip on a real temp repo, the flat-by-default mode, and
/// the role-split / idea-role / reaction-prompt helpers — all WITHOUT spawning
/// any agents.
final class MeshStagedTests: XCTestCase {

    // MARK: - MeshDiffStats.stat

    func testDiffStatCountsTwoFilesFivePlusTwoMinus() {
        let patch = """
        diff --git a/one.txt b/one.txt
        index 1111111..2222222 100644
        --- a/one.txt
        +++ b/one.txt
        @@ -1,2 +1,4 @@
         keep-one
        +added-1
        +added-2
        +added-3
        -removed-1
        diff --git a/two.txt b/two.txt
        index 3333333..4444444 100644
        --- a/two.txt
        +++ b/two.txt
        @@ -1,2 +1,3 @@
         keep-two
        +added-4
        +added-5
        -removed-2
        """
        // 2 `diff --git` files; +1..+5 added; -1,-2 removed. Header lines
        // (+++/---) are excluded from the counts.
        XCTAssertEqual(MeshDiffStats.stat(fromPatch: patch), "2 files changed, +5 -2")
    }

    func testDiffStatEmptyPatchReportsNoChanges() {
        XCTAssertEqual(MeshDiffStats.stat(fromPatch: "   \n \n"), "No changes")
        XCTAssertEqual(MeshDiffStats.stat(fromPatch: ""), "No changes")
    }

    func testDiffStatSingleFileGrammar() {
        let patch = """
        diff --git a/solo.txt b/solo.txt
        --- a/solo.txt
        +++ b/solo.txt
        @@ -1 +1 @@
        -old
        +new
        """
        XCTAssertEqual(MeshDiffStats.stat(fromPatch: patch), "1 file changed, +1 -1")
    }

    // MARK: - GitService.applyPatch round-trip

    func testApplyPatchGraftsUnifiedDiffOntoTrackedFile() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("file.txt")
        try "line1\nline2\nline3\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "file.txt"], in: repo)
        try git(["commit", "-q", "-m", "base"], in: repo)

        // A hand-written unified diff that changes line2 → CHANGED. Context lines
        // match the tracked content exactly, so it applies cleanly.
        let patch = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1,3 +1,3 @@
         line1
        -line2
        +CHANGED
         line3
        """
        try GitService(repoRoot: repo).applyPatch(patch)

        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(updated, "line1\nCHANGED\nline3\n")
    }

    func testApplyPatchRejectsEmptyDiff() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        XCTAssertThrowsError(try GitService(repoRoot: repo).applyPatch("   \n"))
    }

    // MARK: - Mode / purpose defaults and role split

    @MainActor
    func testModeDefaultsToFlatAndPurposeToBuild() {
        let mesh = MeshSession(baseDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(mesh.mode, .flat)
        XCTAssertEqual(mesh.purpose, .build)
    }

    func testFlatBuildRolesAreAllPeers() {
        let roles = MeshSession.roles(for: Self.agents, mode: .flat, purpose: .build)
        XCTAssertEqual(roles.map(\.role), [.peer, .peer, .peer])
        XCTAssertTrue(roles.allSatisfy { $0.role.usesWorktree })
        // Agent order is preserved.
        XCTAssertEqual(roles.map { $0.agent.id }, Self.agents.map(\.id))
    }

    func testStagedBuildRolesAreScoutThenExecutors() {
        let roles = MeshSession.roles(for: Self.agents, mode: .staged, purpose: .build)
        XCTAssertEqual(roles.map(\.role), [.scout, .executor, .executor])
        // The scout is read-only (no worktree); executors isolate.
        XCTAssertFalse(roles[0].role.usesWorktree)
        XCTAssertTrue(roles[1].role.usesWorktree)
        XCTAssertTrue(roles[2].role.usesWorktree)
    }

    func testIdeaModeAssignsNoWorktreeIdeatorsRegardlessOfMode() {
        for mode in [MeshMode.flat, .staged] {
            let roles = MeshSession.roles(for: Self.agents, mode: mode, purpose: .idea)
            XCTAssertEqual(roles.map(\.role), [.ideator, .ideator, .ideator],
                           "idea purpose overrides mode \(mode)")
            XCTAssertTrue(roles.allSatisfy { !$0.role.usesWorktree },
                          "idea columns never get a worktree")
        }
    }

    // MARK: - Idea reaction-pass prompt composition

    func testIdeaReactionPromptComposesFromPeerAnswers() {
        let prompt = MeshSession.ideaReactionPrompt(
            agent: "Codex",
            original: "What about a plugin bazaar?",
            peerAnswers: [
                (agent: "Claude", answer: "Distribution is the hard part"),
                (agent: "Gemini", answer: "Trust and review gates matter"),
            ]
        )
        XCTAssertTrue(prompt.contains("You are Codex"))
        XCTAssertTrue(prompt.contains("React briefly"))
        XCTAssertTrue(prompt.contains("What about a plugin bazaar?"))
        // Each peer's answer is carried, labeled by author.
        XCTAssertTrue(prompt.contains("Claude:\nDistribution is the hard part"))
        XCTAssertTrue(prompt.contains("Gemini:\nTrust and review gates matter"))
        // Discussion-only guardrail is present.
        XCTAssertTrue(prompt.range(of: "make no edits", options: .caseInsensitive) != nil)
    }

    func testIdeaReactionPromptHandlesNoPeers() {
        let prompt = MeshSession.ideaReactionPrompt(agent: "Claude", original: "solo idea", peerAnswers: [])
        XCTAssertTrue(prompt.contains("No peer answers"))
        XCTAssertTrue(prompt.contains("solo idea"))
    }

    func testIdeaInitialPromptForbidsEditsAndCarriesRequest() {
        let prompt = MeshSession.ideaInitialPrompt(for: "sketch a caching layer")
        XCTAssertTrue(prompt.contains("sketch a caching layer"))
        XCTAssertTrue(prompt.range(of: "make no file edits", options: .caseInsensitive) != nil)
    }

    // MARK: - Executor prompt composition (staged phase 2)

    func testExecutorPromptCarriesOriginalAndContract() {
        let prompt = MeshSession.executorPrompt(original: "add a health check", contract: "1. Add /healthz\n2. Wire route")
        XCTAssertTrue(prompt.contains("add a health check"))
        XCTAssertTrue(prompt.contains("1. Add /healthz"))
    }

    func testExecutorPromptFallsBackWhenContractEmpty() {
        let prompt = MeshSession.executorPrompt(original: "add a health check", contract: "   ")
        XCTAssertTrue(prompt.contains("add a health check"))
        XCTAssertTrue(prompt.range(of: "no contract", options: .caseInsensitive) != nil)
    }

    // MARK: - Fixtures / helpers

    private static let agents: [AgentProfile] = [
        AgentProfile(id: "claude-code", name: "Claude", launchCommand: "claude", symbol: "sparkle"),
        AgentProfile(id: "codex", name: "Codex", launchCommand: "codex", symbol: "chevron.left.forwardslash.chevron.right"),
        AgentProfile(id: "gemini", name: "Gemini", launchCommand: "gemini", symbol: "diamond"),
    ]

    private func makeTempRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-apply-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["config", "user.email", "test@example.com"], in: repo)
        try git(["config", "user.name", "Test"], in: repo)
        return repo
    }

    @discardableResult
    private func git(_ arguments: [String], in repo: URL) throws -> String {
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
}
