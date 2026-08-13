import Foundation
import XCTest
@testable import Kaisola

/// NativeSessionStore against a throwaway file — owner identity, owned-session
/// upsert/remove, and the opened-project-tab persistence added for the shell
/// spine's explicit open/rename/close.
final class NativeSessionStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: NativeSessionStore!

    override func setUpWithError() throws {
        SessionStoreProjectIdentityQuarantineMonitor.shared.reset()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-store-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("native-sessions.json")
        store = NativeSessionStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        SessionStoreQuarantineMonitor.shared.reset()
        SessionStoreProjectIdentityQuarantineMonitor.shared.reset()
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testOwnerIDIsStableAcrossReads() {
        let first = store.ownerID()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, store.ownerID())
    }

    func testProjectIDIsDeterministicAndNamespaced() {
        let path = "/Users/example/Developer/Kaisola"
        let id = NativeSessionStore.projectID(forDirectory: path)
        XCTAssertTrue(id.hasPrefix("nproj_"))
        XCTAssertEqual(id, NativeSessionStore.projectID(forDirectory: path))
        // Distinct from Electron's proj_* namespace by construction.
        XCTAssertFalse(id.hasPrefix("proj_"))
    }

    func testOpenProjectIsIdempotentByDirectory() {
        let path = "/tmp/example-project"
        let a = store.openProject(directory: path)
        let b = store.openProject(directory: path)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(store.projects().count, 1)
        XCTAssertEqual(store.projects().first?.name, "example-project")
    }

    func testOpenProjectPersistsAcrossStoreInstances() {
        let opened = store.openProject(directory: "/tmp/persisted-project")
        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.projects().count, 1)
        // Same normalized path the store recorded survives the round-trip.
        XCTAssertEqual(reopened.projects().first?.path, opened.path)
        XCTAssertEqual(reopened.projects().first?.name, "persisted-project")
    }

    func testOpeningProjectsIsAdditiveAndNavigationSnapshotIsCoherent() {
        let first = store.openProject(directory: "/tmp/additive-first")
        let session = NativeOwnedSession(
            id: "term-additive-first",
            projectID: first.id,
            cwd: first.path,
            title: "Terminal 1",
            createdAt: 1
        )
        store.upsert(session)
        store.setSessionAlias("Build", for: session.id)

        let second = store.openProject(directory: "/tmp/additive-second")
        let snapshot = store.navigationSnapshot()

        XCTAssertEqual(snapshot.projects.map(\.id), [first.id, second.id])
        XCTAssertEqual(snapshot.sessions, [session])
        XCTAssertEqual(snapshot.sessionAliases, [session.id: "Build"])
    }

    func testRenameProjectUpdatesNameOnly() {
        let project = store.openProject(directory: "/tmp/rename-me")
        store.renameProject(id: project.id, name: "Custom Name")
        let renamed = store.projects().first { $0.id == project.id }
        XCTAssertEqual(renamed?.name, "Custom Name")
        XCTAssertEqual(renamed?.path, project.path)
    }

    func testCloseProjectRemovesTabButLeavesOthers() {
        let keep = store.openProject(directory: "/tmp/keep")
        let drop = store.openProject(directory: "/tmp/drop")
        store.closeProject(id: drop.id)
        let ids = store.projects().map(\.id)
        XCTAssertTrue(ids.contains(keep.id))
        XCTAssertFalse(ids.contains(drop.id))
    }

    func testCloseThenReopenRestoresMostRecentProject() {
        let a = store.openProject(directory: "/tmp/alpha")
        let b = store.openProject(directory: "/tmp/beta")
        store.closeProject(id: a.id)
        store.closeProject(id: b.id)
        XCTAssertTrue(store.projects().isEmpty)

        // ⌘⇧T restores newest-first: beta, then alpha.
        let first = store.reopenLastClosedProject()
        XCTAssertEqual(first?.id, b.id)
        XCTAssertEqual(store.projects().map(\.id), [b.id])
        let second = store.reopenLastClosedProject()
        XCTAssertEqual(second?.id, a.id)
        XCTAssertNil(store.reopenLastClosedProject())   // stack drained
    }

    func testReopenPersistsClosedStackAcrossInstances() {
        let a = store.openProject(directory: "/tmp/persisted-closed")
        store.closeProject(id: a.id)
        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.closedProjects().map(\.id), [a.id])
        XCTAssertEqual(reopened.reopenLastClosedProject()?.id, a.id)
    }

    func testReopeningAFolderDirectlyRetiresItsClosedEntry() {
        let a = store.openProject(directory: "/tmp/gamma")
        store.closeProject(id: a.id)
        XCTAssertFalse(store.closedProjects().isEmpty)
        // Opening the same folder again should clear the stale closed entry.
        _ = store.openProject(directory: "/tmp/gamma")
        XCTAssertTrue(store.closedProjects().isEmpty)
    }

    func testClosedSessionStackPushesAndPopsNewestFirst() {
        store.pushClosedSession(ClosedSession(cwd: "/tmp/one", agentID: nil, title: "one"))
        store.pushClosedSession(ClosedSession(cwd: "/tmp/two", agentID: "claude-code", title: "two"))
        let first = store.popClosedSession()
        XCTAssertEqual(first?.cwd, "/tmp/two")
        XCTAssertEqual(first?.agentID, "claude-code")
        XCTAssertEqual(store.popClosedSession()?.cwd, "/tmp/one")
        XCTAssertNil(store.popClosedSession())
    }

    func testOwnedAndClosedSessionsPreserveImmutableAccountBinding() throws {
        let binding = try XCTUnwrap(SessionAccountBinding(
            accountID: "codex-work",
            provider: .codex,
            label: "Work",
            configDirectory: "/tmp/codex-work"
        ).normalized)
        let session = NativeOwnedSession(
            id: "term-account-bound",
            projectID: "nproj_account_bound",
            cwd: "/tmp/account-bound",
            title: "Codex · account-bound",
            createdAt: 1,
            agentID: "codex",
            accountBinding: binding
        )
        store.upsert(session)
        store.pushClosedSession(ClosedSession(
            cwd: session.cwd,
            agentID: session.agentID,
            title: session.title,
            accountBinding: binding,
            sourceTerminalID: session.id
        ))

        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.sessions().first?.accountBinding, binding)
        XCTAssertEqual(reopened.sessions().first?.accountID, "codex-work")
        XCTAssertEqual(reopened.closedSessions().first?.accountBinding, binding)
        XCTAssertEqual(reopened.closedSessions().first?.sourceTerminalID, session.id)
    }

    func testClosedSessionStackIsBounded() {
        // Cap raised 10 → 50 (2026-08-06 spec §4a-1): the stack is a UI
        // convenience; permanent tombstones carry the closed-state guarantee.
        for index in 0..<55 {
            store.pushClosedSession(ClosedSession(cwd: "/tmp/s\(index)", agentID: nil, title: "s\(index)"))
        }
        XCTAssertEqual(store.closedSessions().count, 50)
        XCTAssertEqual(store.closedSessions().first?.cwd, "/tmp/s5")   // oldest dropped
    }

    func testProjectColorPersistsAndClears() {
        let project = store.openProject(directory: "/tmp/tinted")
        store.setProjectColor(id: project.id, colorHex: "E16A6A")
        XCTAssertEqual(store.projects().first?.colorHex, "E16A6A")
        store.setProjectColor(id: project.id, colorHex: nil)
        XCTAssertNil(store.projects().first?.colorHex)
    }

    func testMoveProjectReordersWithinBounds() {
        let a = store.openProject(directory: "/tmp/order-a")
        let b = store.openProject(directory: "/tmp/order-b")
        _ = store.openProject(directory: "/tmp/order-c")
        store.moveProject(id: b.id, delta: -1)
        XCTAssertEqual(store.projects().map(\.path), ["/tmp/order-b", "/tmp/order-a", "/tmp/order-c"])
        // Out-of-bounds moves are no-ops.
        store.moveProject(id: b.id, delta: -1)
        XCTAssertEqual(store.projects().first?.id, b.id)
        store.moveProject(id: a.id, delta: 5)
        XCTAssertEqual(store.projects().map(\.path), ["/tmp/order-b", "/tmp/order-a", "/tmp/order-c"])
    }

    func testRelocateProjectCarriesNameAndColorToTheNewPath() {
        let project = store.openProject(directory: "/tmp/old-home")
        store.renameProject(id: project.id, name: "My Workspace")
        store.setProjectColor(id: project.id, colorHex: "5AA9E6")
        let relocated = store.relocateProject(id: project.id, toDirectory: "/tmp/new-home")
        XCTAssertEqual(relocated?.name, "My Workspace")
        XCTAssertEqual(relocated?.colorHex, "5AA9E6")
        XCTAssertEqual(store.projects().count, 1)
        XCTAssertEqual(store.projects().first?.path, "/tmp/new-home")
        XCTAssertEqual(store.projects().first?.name, "My Workspace")
        XCTAssertEqual(store.projects().first?.colorHex, "5AA9E6")
        // The old id's closed-stack entry must not resurrect the old path.
        XCTAssertNotEqual(store.projects().first?.id, project.id)
    }

    func testRecentFoldersAreMostRecentFirstDedupedAndBounded() {
        for index in 0..<10 {
            _ = store.openProject(directory: "/tmp/recent-\(index)")
        }
        _ = store.openProject(directory: "/tmp/recent-3")   // re-open moves to head
        let recents = store.recentFolders()
        XCTAssertEqual(recents.first, "/tmp/recent-3")
        XCTAssertEqual(recents.count, 8)
        XCTAssertEqual(recents.filter { $0 == "/tmp/recent-3" }.count, 1)
    }

    func testRemovingARecentPersistsWithoutDeletingTheProjectDirectory() throws {
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("still-on-disk")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store.recordRecentFolder(directory.path)

        store.removeRecentFolder(directory.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(NativeSessionStore(fileURL: fileURL).recentFolders().contains(directory.path))
    }

    func testSelectedSessionPersistsAcrossInstances() {
        _ = store.openProject(directory: "/tmp/sel")   // ensures the file exists
        store.recordSelectedSession("term-abc")
        XCTAssertEqual(NativeSessionStore(fileURL: fileURL).lastSelectedSessionID(), "term-abc")
        store.recordSelectedSession(nil)
        XCTAssertNil(NativeSessionStore(fileURL: fileURL).lastSelectedSessionID())
    }

    func testOpenProjectDoesNotDisturbOwnedSessions() {
        let session = NativeOwnedSession(
            id: "term-1",
            projectID: NativeSessionStore.projectID(forDirectory: "/tmp/with-session"),
            cwd: "/tmp/with-session",
            title: "shell",
            createdAt: 1
        )
        store.upsert(session)
        _ = store.openProject(directory: "/tmp/with-session")
        XCTAssertEqual(store.sessions().count, 1)
        XCTAssertEqual(store.sessions().first?.id, "term-1")
        XCTAssertEqual(store.projects().count, 1)
    }

    func testObservedSessionAliasPersistsClearsAndIsRemovedWithSession() {
        store.setSessionAlias("  Build watcher  ", for: "terminal:observed")
        XCTAssertEqual(
            NativeSessionStore(fileURL: fileURL).sessionAliases()["terminal:observed"],
            "Build watcher"
        )
        store.setSessionAlias("   ", for: "terminal:observed")
        XCTAssertNil(store.sessionAliases()["terminal:observed"])

        let session = NativeOwnedSession(
            id: "term-owned",
            projectID: "nproj_alias",
            cwd: "/tmp/alias",
            title: "Alias",
            createdAt: 1
        )
        store.upsert(session)
        store.setSessionAlias("Temporary", for: session.id)
        store.remove(terminalID: session.id)
        XCTAssertNil(store.sessionAliases()[session.id])
    }

    func testRecoverOwnedSessionsRequiresExactStableOwnerAndKnownProject() throws {
        let project = store.openProject(directory: "/tmp/recover-owned")
        let stableOwnerID = store.ownerID()
        let record = BrokerTerminalRecord(
            id: "term-\(project.id)-recovered",
            projectID: project.id,
            pid: 4_321,
            exited: false,
            streamEpoch: "epoch",
            endOffset: 42,
            lastOwnerID: stableOwnerID
        )

        let recovered = store.recoverOwnedSessions(from: [record], now: 123_456)

        let session = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(session.id, record.id)
        XCTAssertEqual(session.projectID, project.id)
        XCTAssertEqual(session.cwd, project.path)
        XCTAssertEqual(session.title, project.name)
        XCTAssertEqual(session.createdAt, 123_456)
        XCTAssertEqual(store.sessions(), recovered)
        XCTAssertTrue(store.recoverOwnedSessions(from: [record]).isEmpty)
    }

    func testRecoverOwnedSessionsRejectsObservedExitedAndUnknownProjectRecords() {
        let project = store.openProject(directory: "/tmp/recover-guarded")
        let stableOwnerID = store.ownerID()
        let observed = BrokerTerminalRecord(
            id: "term-observed",
            projectID: project.id,
            pid: 1,
            exited: false,
            streamEpoch: nil,
            endOffset: 0,
            lastOwnerID: "another-install"
        )
        let exited = BrokerTerminalRecord(
            id: "term-exited",
            projectID: project.id,
            pid: nil,
            exited: true,
            streamEpoch: nil,
            endOffset: 0,
            lastOwnerID: stableOwnerID
        )
        let unknownProject = BrokerTerminalRecord(
            id: "term-unknown-project",
            projectID: "nproj_missing",
            pid: 2,
            exited: false,
            streamEpoch: nil,
            endOffset: 0,
            currentOwnerID: stableOwnerID
        )

        XCTAssertTrue(
            store.recoverOwnedSessions(from: [observed, exited, unknownProject]).isEmpty
        )
        XCTAssertTrue(store.sessions().isEmpty)
    }

    func testDuplicateProjectIdentitiesAreQuarantinedDuringDecode() throws {
        let duplicateA = OpenProject(
            id: "nproj_duplicated",
            path: "/tmp/duplicate-a",
            name: "Duplicate A",
            createdAt: 10
        )
        let unaffected = OpenProject(
            id: "nproj_unaffected",
            path: "/tmp/unaffected",
            name: "Unaffected",
            createdAt: 20
        )
        let duplicateB = OpenProject(
            id: duplicateA.id,
            path: "/tmp/duplicate-b",
            name: "Duplicate B",
            createdAt: 30
        )
        let existingSession = NativeOwnedSession(
            id: "term-existing",
            projectID: duplicateA.id,
            cwd: "/tmp/already-established",
            title: "Existing",
            createdAt: 40
        )
        let (archiveURL, bytes) = try writeProjectArchive(
            ownerID: "native-duplicate-projects",
            sessions: [existingSession],
            projects: [duplicateA, unaffected, duplicateB],
            named: "duplicate-projects"
        )
        let observed = CollectedProjectIdentityQuarantines()
        SessionStoreProjectIdentityQuarantineMonitor.shared.setObserver { observed.append($0) }
        let decoded = NativeSessionStore(fileURL: archiveURL)

        XCTAssertEqual(decoded.ownerID(), "native-duplicate-projects")
        XCTAssertEqual(decoded.projects(), [unaffected])
        XCTAssertEqual(decoded.sessions(), [existingSession])
        XCTAssertNil(decoded.archiveQuarantine(), "The readable archive itself remains usable")
        let quarantine = try XCTUnwrap(decoded.projectIdentityQuarantine())
        XCTAssertEqual(
            quarantine.conflicts,
            [SessionStoreProjectIdentityConflict(
                projectID: duplicateA.id,
                records: [duplicateA, duplicateB]
            )]
        )
        XCTAssertEqual(quarantine.quarantinedRecordCount, 2)
        XCTAssertTrue(quarantine.message.contains("Other projects and sessions remain available"))
        let copyPath = try XCTUnwrap(quarantine.copyPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copyPath)), bytes)

        // The process-wide decoded cache and report ledger prevent repeated
        // reads from creating copies or presenting duplicate notices.
        XCTAssertEqual(NativeSessionStore(fileURL: archiveURL).projects(), [unaffected])
        XCTAssertEqual(observed.all(), [quarantine])

        // Ordinary writes remain available and persist only the validated
        // records; the original conflicting bytes stay in the recovery copy.
        decoded.renameProject(id: unaffected.id, name: "Renamed safely")
        let persisted = try JSONDecoder().decode(
            ProjectArchiveFixture.self,
            from: Data(contentsOf: archiveURL)
        )
        XCTAssertEqual(persisted.projects.map(\.id), [unaffected.id])
        XCTAssertEqual(persisted.projects.first?.name, "Renamed safely")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copyPath)), bytes)
    }

    func testRecoveryRejectsAmbiguousProjectsAndRecoversUnaffectedProjects() throws {
        let duplicateA = OpenProject(
            id: "nproj_ambiguous",
            path: "/tmp/ambiguous-a",
            name: "Ambiguous A",
            createdAt: 1
        )
        let duplicateB = OpenProject(
            id: duplicateA.id,
            path: "/tmp/ambiguous-b",
            name: "Ambiguous B",
            createdAt: 2
        )
        let unaffected = OpenProject(
            id: "nproj_safe",
            path: "/tmp/safe",
            name: "Safe",
            createdAt: 3
        )
        let ownerID = "native-project-recovery"
        let (archiveURL, _) = try writeProjectArchive(
            ownerID: ownerID,
            projects: [duplicateA, duplicateB, unaffected],
            named: "duplicate-recovery"
        )
        let decoded = NativeSessionStore(fileURL: archiveURL)
        let ambiguousRecord = BrokerTerminalRecord(
            id: "term-ambiguous",
            projectID: duplicateA.id,
            pid: 1,
            exited: false,
            streamEpoch: "epoch-ambiguous",
            endOffset: 1,
            lastOwnerID: ownerID
        )
        let unaffectedRecord = BrokerTerminalRecord(
            id: "term-safe",
            projectID: unaffected.id,
            pid: 2,
            exited: false,
            streamEpoch: "epoch-safe",
            endOffset: 2,
            lastOwnerID: ownerID
        )

        let recovered = decoded.recoverOwnedSessions(
            from: [ambiguousRecord, unaffectedRecord],
            now: 123_456
        )

        XCTAssertEqual(recovered.map(\.id), [unaffectedRecord.id])
        XCTAssertEqual(recovered.first?.cwd, unaffected.path)
        XCTAssertEqual(recovered.first?.title, unaffected.name)
        XCTAssertEqual(decoded.sessions(), recovered)
        XCTAssertEqual(decoded.projects(), [unaffected])
        XCTAssertEqual(
            decoded.projectIdentityQuarantine()?.conflicts.first?.records,
            [duplicateA, duplicateB]
        )
    }

    func testWorkspaceRestorationRoundTripsPaneOrderAndAgentDescriptor() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let projectID = "nproj_workspace"
        let chat = NativeRestorableAgentChatDescriptor(
            id: "chat-1",
            projectID: projectID,
            agentID: "claude-code",
            workspacePath: "/tmp/workspace",
            acpSessionID: "acp-session-1",
            accountBinding: SessionAccountBinding(
                accountID: "claude-work",
                provider: .claude,
                label: "Work",
                configDirectory: "/tmp/claude-work"
            ),
            title: "Claude · workspace",
            queuedPrompts: ["oldest follow-up", "newest follow-up"]
        )
        let panes = [
            NativeRestorablePaneState(
                id: "term-live",
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: "term-live",
                    projectID: projectID,
                    title: "Build"
                ),
                sizeWeight: 0.65
            ),
            NativeRestorablePaneState(
                id: "chat-1",
                surface: NativeRestorableSurfaceState(agentChat: chat),
                sizeWeight: 0.35
            ),
        ]
        let state = NativeWorkspaceRestorationState(
            selectedProjectID: projectID,
            projects: [
                NativeProjectWorkspaceState(
                    projectID: projectID,
                    layout: SessionPaneLayout(columns: [
                        .init(
                            id: "main-column",
                            sessionIDs: ["term-live", "chat-1"],
                            rowWeights: [0.7, 0.3]
                        ),
                    ]),
                    arrangement: .columns,
                    panes: panes,
                    focusedPaneID: "chat-1",
                    updatedAt: 123
                ),
            ]
        )

        try await workspaceStore.saveRestorationState(state)

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let restored = try await reopened.restorationState()
        XCTAssertEqual(restored, state)
        XCTAssertEqual(
            restored.projects.first?.panes.last?.surface.agentChatDescriptor,
            chat
        )
        XCTAssertEqual(
            restored.projects.first?.layout.columns.first?.sessionIDs,
            ["term-live", "chat-1"]
        )
        XCTAssertEqual(
            restored.projects.first?.layout.columns.first?.rowWeights,
            [0.7, 0.3]
        )
        XCTAssertEqual(
            restored.projects.first?.panes.last?.surface.accountBinding?.continuationKey,
            "claude\u{1f}\(URL(fileURLWithPath: "/tmp/claude-work", isDirectory: true).resolvingSymlinksInPath().path)"
        )
    }

    /// A corrupt-archive drill run under `KAISOLA_NATIVE_BROKER_PROFILE=development`
    /// once moved the *production* workspace archive aside, because both
    /// profiles resolved to the same file. The dev profile must land on its
    /// own filename beside — never instead of — the production archive.
    func testDevelopmentProfileArchiveURLIsDistinctFromProduction() {
        let directory = fileURL.deletingLastPathComponent()
        let production = NativeWorkspaceStateStore.archiveURL(in: directory, forDevelopmentProfile: false)
        let development = NativeWorkspaceStateStore.archiveURL(in: directory, forDevelopmentProfile: true)

        XCTAssertNotEqual(production, development)
        XCTAssertEqual(production.deletingLastPathComponent(), directory)
        XCTAssertEqual(development.deletingLastPathComponent(), directory)
        XCTAssertEqual(production.lastPathComponent, "workspace-state-v1.json")
        XCTAssertEqual(development.lastPathComponent, "workspace-state-v1.dev.json")
    }

    /// The behavioral guarantee behind the path split: writing through the
    /// dev-profile store must never appear in — or overwrite — the production
    /// archive, and vice versa.
    func testStoreCreatedUnderTheDevelopmentProfileWritesToADistinctPathFromProduction() async throws {
        let directory = fileURL.deletingLastPathComponent()
        let productionURL = NativeWorkspaceStateStore.archiveURL(in: directory, forDevelopmentProfile: false)
        let developmentURL = NativeWorkspaceStateStore.archiveURL(in: directory, forDevelopmentProfile: true)

        let developmentStore = NativeWorkspaceStateStore(fileURL: developmentURL)
        try await developmentStore.setSelectedProjectID("dev-only-project")

        XCTAssertTrue(FileManager.default.fileExists(atPath: developmentURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: productionURL.path),
            "Writing the dev-profile archive must not create or touch the production archive."
        )

        let productionStore = NativeWorkspaceStateStore(fileURL: productionURL)
        let productionState = try await productionStore.restorationState()
        XCTAssertNil(
            productionState.selectedProjectID,
            "The production archive must stay untouched by dev-profile writes."
        )
    }

    func testLegacyAgentChatDescriptorDecodesWithoutAccountBinding() throws {
        let json = #"{"id":"chat-legacy","projectID":"nproj_legacy","agentID":"codex","workspacePath":"/tmp/legacy","acpSessionID":"provider-legacy","title":"Legacy"}"#
        let decoded = try JSONDecoder().decode(
            NativeRestorableAgentChatDescriptor.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )

        XCTAssertNil(decoded.accountBinding)
        XCTAssertEqual(decoded.acpSessionID, "provider-legacy")
        XCTAssertEqual(decoded.queuedPrompts, [])
    }

    func testWorkspaceSanitizerDropsCrossProviderBindingAndContinuation() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let projectID = "nproj_cross_provider"
        let unsafe = NativeRestorableAgentChatDescriptor(
            id: "chat-cross-provider",
            projectID: projectID,
            agentID: "codex",
            workspacePath: "/tmp/cross-provider",
            acpSessionID: "must-not-resume",
            accountBinding: SessionAccountBinding(
                accountID: "claude-work",
                provider: .claude,
                label: "Claude Work",
                configDirectory: "/tmp/claude-work"
            ),
            title: "Unsafe continuation"
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            panes: [NativeRestorablePaneState(
                id: unsafe.id,
                surface: NativeRestorableSurfaceState(agentChat: unsafe)
            )]
        ))

        let restored = try await workspaceStore.restorationState()
        let surface = try XCTUnwrap(restored.projects.first?.panes.first?.surface)
        XCTAssertNil(surface.accountBinding)
        XCTAssertNil(surface.acpSessionID)
    }

    func testWorkspaceRestorationRoundTripsSchemaTwoMeshManifest() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let worktreeRoot = fileURL.deletingLastPathComponent()
            .appendingPathComponent("mesh-worktrees", isDirectory: true)
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: stateURL,
            meshWorktreeRoot: worktreeRoot
        )
        let basePath = "/tmp/mesh-round-trip"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let meshID = "mesh-round-trip"
        let descriptor = NativeRestorableMeshDescriptor(
            id: meshID,
            projectID: projectID,
            basePath: basePath,
            title: "Release review",
            mode: .staged,
            purpose: .build,
            lifecycle: .suspended,
            columns: [
                NativeRestorableMeshColumnDescriptor(
                    id: "mesh-round-trip-executor",
                    agentID: "codex",
                    role: .executor,
                    worktreePath: worktreeRoot
                        .appendingPathComponent("\(meshID)-codex", isDirectory: true)
                        .path,
                    branch: "kaisola-mesh-\(meshID.suffix(6))-codex",
                    createdBaseOID: String(repeating: "a", count: 40),
                    acpSessionID: "acp-mesh-executor",
                    accountBinding: SessionAccountBinding(
                        accountID: "codex-research",
                        provider: .codex,
                        label: "Research",
                        configDirectory: "/tmp/codex-research"
                    ),
                    provisioning: .attached,
                    workspaceKind: .worktree
                ),
                NativeRestorableMeshColumnDescriptor(
                    id: "mesh-round-trip-scout",
                    agentID: "claude-code",
                    role: .scout,
                    worktreePath: nil,
                    branch: nil,
                    createdBaseOID: nil,
                    acpSessionID: "acp-mesh-scout",
                    accountBinding: SessionAccountBinding(
                        accountID: nil,
                        provider: .claude,
                        label: "Project/default",
                        configDirectory: "/tmp/claude-project"
                    ),
                    provisioning: .attached,
                    workspaceKind: .base
                ),
            ],
            stagedPrompts: ["oldest queued request", "newest queued request"]
        )
        let state = NativeWorkspaceRestorationState(
            selectedProjectID: projectID,
            projects: [
                NativeProjectWorkspaceState(
                    projectID: projectID,
                    layout: SessionPaneLayout(),
                    arrangement: .grid,
                    panes: [
                        NativeRestorablePaneState(
                            id: descriptor.id,
                            surface: NativeRestorableSurfaceState(mesh: descriptor),
                            sizeWeight: 0.8,
                            isMinimized: true
                        ),
                    ],
                    updatedAt: 123
                ),
            ]
        )

        try await workspaceStore.saveRestorationState(state)

        let persistedJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        XCTAssertEqual(persistedJSON["schemaVersion"] as? Int, 2)

        let reopened = NativeWorkspaceStateStore(
            fileURL: stateURL,
            meshWorktreeRoot: worktreeRoot
        )
        let restored = try await reopened.restorationState()
        let restoredPane = try XCTUnwrap(restored.projects.first?.panes.first)
        XCTAssertTrue(restoredPane.isMinimized)
        XCTAssertEqual(restoredPane.sizeWeight, 0.8, accuracy: 0.0001)
        XCTAssertEqual(restoredPane.surface.meshDescriptor, descriptor)
        XCTAssertEqual(
            restoredPane.surface.meshDescriptor?.stagedPrompts,
            ["oldest queued request", "newest queued request"]
        )
        XCTAssertTrue(try XCTUnwrap(restored.projects.first).layout.isEmpty)
    }

    func testRestorableMeshDescriptorDefaultsLegacyMissingStagedPromptsToEmpty() throws {
        let legacyJSON = """
        {
          "id": "mesh-before-queued-prompts",
          "projectID": "nproj_legacy_mesh",
          "basePath": "/tmp/legacy-mesh",
          "title": "Legacy Mesh",
          "mode": "staged",
          "purpose": "build",
          "lifecycle": "suspended",
          "columns": []
        }
        """

        let descriptor = try JSONDecoder().decode(
            NativeRestorableMeshDescriptor.self,
            from: try XCTUnwrap(legacyJSON.data(using: .utf8))
        )

        XCTAssertEqual(descriptor.stagedPrompts, [])
    }

    func testWorkspaceRestorationRoundTripsRecentlyClosedWithoutAddingItToLayout() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let basePath = "/tmp/recently-closed-project"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let chat = NativeRestorableAgentChatDescriptor(
            id: "chat-recent",
            projectID: projectID,
            agentID: "codex",
            workspacePath: basePath,
            acpSessionID: "provider-recent",
            title: "Closed chat",
            queuedPrompts: ["preserve first", "preserve second"]
        )
        let recentPane = NativeRestorablePaneState(
            id: chat.id,
            surface: NativeRestorableSurfaceState(agentChat: chat),
            isRecentlyClosed: true,
            closedAt: 123_456
        )
        let terminalPane = NativeRestorablePaneState(
            id: "term-live",
            surface: NativeRestorableSurfaceState(
                kind: .terminal,
                id: "term-live",
                projectID: projectID
            )
        )

        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            layout: SessionPaneLayout(sessionID: terminalPane.id),
            panes: [terminalPane, recentPane],
            focusedPaneID: terminalPane.id
        ))

        let restoredValue = try await workspaceStore.projectState(for: projectID)
        let restored = try XCTUnwrap(restoredValue)
        let closed = try XCTUnwrap(restored.panes.first { $0.id == chat.id })
        XCTAssertTrue(closed.isRecentlyClosed)
        XCTAssertTrue(closed.isMinimized)
        XCTAssertEqual(closed.closedAt, 123_456)
        XCTAssertEqual(
            closed.surface.agentChatDescriptor?.queuedPrompts,
            ["preserve first", "preserve second"]
        )
        XCTAssertEqual(restored.layout.sessionIDs, [terminalPane.id])
        XCTAssertFalse(restored.layout.contains(chat.id))
        XCTAssertEqual(restored.focusedPaneID, terminalPane.id)
    }

    func testPartialWindowSavePreservesRecentlyClosedChatUntilExplicitTombstone() async throws {
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        let basePath = "/tmp/recently-closed-merge"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let chat = NativeRestorableAgentChatDescriptor(
            id: "chat-preserved",
            projectID: projectID,
            agentID: "codex",
            workspacePath: basePath,
            acpSessionID: nil,
            title: "Preserve me"
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            panes: [NativeRestorablePaneState(
                id: chat.id,
                surface: NativeRestorableSurfaceState(agentChat: chat),
                isRecentlyClosed: true,
                closedAt: 9
            )]
        ))

        // A second window has no local copy of this closed chat. Its partial
        // snapshot must not erase the durable entry.
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(projectID: projectID))
        let preserved = try await workspaceStore.projectState(for: projectID)
        XCTAssertEqual(preserved?.panes.map(\.id), [chat.id])

        try await workspaceStore.removeRecentlyClosedSurfaceState(
            projectID: projectID,
            surfaceID: chat.id
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(projectID: projectID))
        let tombstoned = try await workspaceStore.projectState(for: projectID)
        XCTAssertTrue(tombstoned?.panes.isEmpty == true)
    }

    func testFullSnapshotFromAnotherWindowPreservesActiveChatUntilExplicitRemoval() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let basePath = "/tmp/active-chat-window-merge"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: "chat-owned-by-first-window",
            projectID: projectID,
            agentID: "codex",
            workspacePath: basePath,
            acpSessionID: "provider-session",
            title: "Keep active chat"
        )
        let activePane = NativeRestorablePaneState(
            id: descriptor.id,
            surface: NativeRestorableSurfaceState(agentChat: descriptor)
        )
        try await workspaceStore.saveRestorationState(NativeWorkspaceRestorationState(
            selectedProjectID: projectID,
            projects: [NativeProjectWorkspaceState(
                projectID: projectID,
                layout: SessionPaneLayout(sessionID: descriptor.id),
                panes: [activePane],
                focusedPaneID: descriptor.id
            )]
        ))

        // A second AppModel may have restored before the first window opened
        // this chat. Its full teardown snapshot must not erase work it never
        // owned or even knew existed.
        try await workspaceStore.saveRestorationState(NativeWorkspaceRestorationState(
            selectedProjectID: nil,
            projects: []
        ))
        let preserved = try await workspaceStore.projectState(for: projectID)
        let preservedChat = try XCTUnwrap(
            preserved?.panes.first { $0.id == descriptor.id }
        )
        XCTAssertEqual(preservedChat.surface.agentChatDescriptor, descriptor)
        XCTAssertTrue(preservedChat.isMinimized)
        XCTAssertFalse(preserved?.layout.contains(descriptor.id) == true)

        let explicitRemoval = try await workspaceStore.removeAgentChatState(
            projectID: projectID,
            chatID: descriptor.id
        )
        XCTAssertTrue(explicitRemoval)

        // A stale window that still carries the old descriptor cannot revive
        // it after the explicit permanent-delete boundary in this process.
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            layout: SessionPaneLayout(sessionID: descriptor.id),
            panes: [activePane],
            focusedPaneID: descriptor.id
        ))
        let removed = try await workspaceStore.projectState(for: projectID)
        XCTAssertFalse(removed?.panes.contains { $0.id == descriptor.id } == true)

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let relaunched = try await reopened.projectState(for: projectID)
        XCTAssertFalse(relaunched?.panes.contains { $0.id == descriptor.id } == true)
    }

    func testStaleRecentlyClosedDeleteCannotRemoveEntryRestoredByAnotherWindow() async throws {
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        let basePath = "/tmp/recently-closed-stale-delete"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let chat = NativeRestorableAgentChatDescriptor(
            id: "chat-restored-elsewhere",
            projectID: projectID,
            agentID: "codex",
            workspacePath: basePath,
            acpSessionID: nil,
            title: "Restored elsewhere"
        )
        let closed = NativeRestorablePaneState(
            id: chat.id,
            surface: NativeRestorableSurfaceState(agentChat: chat),
            isRecentlyClosed: true,
            closedAt: 1
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            panes: [closed]
        ))

        // Another window restores the same identity to its active pane list.
        let active = NativeRestorablePaneState(
            id: chat.id,
            surface: NativeRestorableSurfaceState(agentChat: chat)
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            layout: SessionPaneLayout(sessionID: chat.id),
            panes: [active],
            focusedPaneID: chat.id
        ))

        let removed = try await workspaceStore.removeRecentlyClosedSurfaceState(
            projectID: projectID,
            surfaceID: chat.id
        )
        let state = try await workspaceStore.projectState(for: projectID)
        XCTAssertFalse(removed)
        XCTAssertFalse(state?.panes.first?.isRecentlyClosed == true)
        XCTAssertEqual(state?.panes.first?.id, chat.id)
    }

    func testWorkspaceStoreMigratesSchemaOneArchiveToSchemaTwoWithoutLosingLegacyPanes() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let projectID = "nproj_schema_one"
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "restoration": {
            "selectedProjectID": "\(projectID)",
            "projects": [
              {
                "projectID": "\(projectID)",
                "arrangement": "rows",
                "panes": [
                  {
                    "id": "term-legacy",
                    "surface": {
                      "kind": "terminal",
                      "id": "term-legacy",
                      "projectID": "\(projectID)"
                    },
                    "sizeWeight": 1,
                    "isMinimized": false
                  }
                ],
                "focusedPaneID": "term-legacy",
                "updatedAt": 9
              }
            ]
          },
          "drafts": []
        }
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: stateURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let migrated = try await workspaceStore.restorationState()
        XCTAssertEqual(migrated.selectedProjectID, projectID)
        XCTAssertEqual(migrated.projects.first?.panes.map(\.id), ["term-legacy"])
        XCTAssertFalse(migrated.projects.first?.panes.first?.isRecentlyClosed == true)
        XCTAssertNil(migrated.projects.first?.panes.first?.closedAt)
        XCTAssertEqual(
            migrated.projects.first?.layout.columns.first?.sessionIDs,
            ["term-legacy"]
        )

        try await workspaceStore.saveRestorationState(migrated)
        let persistedJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        XCTAssertEqual(persistedJSON["schemaVersion"] as? Int, 2)

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let restored = try await reopened.restorationState()
        XCTAssertEqual(restored.projects.first?.panes.map(\.id), ["term-legacy"])
        XCTAssertEqual(restored.projects.first?.focusedPaneID, "term-legacy")
    }

    func testWorkspaceRestorationSanitizesUnsafeMeshColumns() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let worktreeRoot = fileURL.deletingLastPathComponent()
            .appendingPathComponent("mesh-worktrees", isDirectory: true)
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: stateURL,
            meshWorktreeRoot: worktreeRoot
        )
        let basePath = "/tmp/mesh-sanitize"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let validOID = String(repeating: "b", count: 40)
        let meshID = "mesh-sanitize"
        let columns = [
            NativeRestorableMeshColumnDescriptor(
                id: "valid-executor",
                agentID: "codex",
                role: .executor,
                worktreePath: worktreeRoot.appendingPathComponent("\(meshID)-codex").path,
                branch: "kaisola-mesh-\(meshID.suffix(6))-codex",
                createdBaseOID: validOID.uppercased(),
                acpSessionID: "valid-provider-session",
                provisioning: .attached,
                workspaceKind: .worktree
            ),
            NativeRestorableMeshColumnDescriptor(
                id: "valid-scout",
                agentID: "claude-code",
                role: .scout,
                worktreePath: nil,
                branch: nil,
                createdBaseOID: nil,
                acpSessionID: "valid-scout-session",
                provisioning: .attached,
                workspaceKind: .base
            ),
            NativeRestorableMeshColumnDescriptor(
                id: "outside-root",
                agentID: "codex",
                role: .executor,
                worktreePath: "/tmp/not-owned-by-kaisola",
                branch: "kaisola-mesh-unsafe",
                createdBaseOID: validOID,
                acpSessionID: nil,
                provisioning: .attached,
                workspaceKind: .worktree
            ),
            NativeRestorableMeshColumnDescriptor(
                id: "wrong-branch",
                agentID: "codex",
                role: .executor,
                worktreePath: worktreeRoot.appendingPathComponent("wrong-branch").path,
                branch: "feature/not-mesh-owned",
                createdBaseOID: validOID,
                acpSessionID: nil,
                provisioning: .attached,
                workspaceKind: .worktree
            ),
            NativeRestorableMeshColumnDescriptor(
                id: "missing-base-oid",
                agentID: "codex",
                role: .peer,
                worktreePath: worktreeRoot.appendingPathComponent("missing-base-oid").path,
                branch: "kaisola-mesh-no-base",
                createdBaseOID: nil,
                acpSessionID: nil,
                provisioning: .attached,
                workspaceKind: .worktree
            ),
            NativeRestorableMeshColumnDescriptor(
                id: "scout-with-worktree",
                agentID: "claude-code",
                role: .scout,
                worktreePath: worktreeRoot.appendingPathComponent("scout").path,
                branch: "kaisola-mesh-scout",
                createdBaseOID: validOID,
                acpSessionID: nil,
                provisioning: .attached,
                workspaceKind: .worktree
            ),
        ]
        let descriptor = NativeRestorableMeshDescriptor(
            id: meshID,
            projectID: projectID,
            basePath: basePath + "/./",
            title: "Sanitize me",
            mode: .staged,
            purpose: .build,
            lifecycle: .recoveryRequired,
            columns: columns
        )

        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: projectID,
                panes: [
                    NativeRestorablePaneState(
                        id: descriptor.id,
                        surface: NativeRestorableSurfaceState(mesh: descriptor)
                    ),
                ]
            )
        )

        let projectState = try await workspaceStore.projectState(for: projectID)
        let restored = try XCTUnwrap(
            projectState?.panes.first?.surface.meshDescriptor
        )
        XCTAssertEqual(restored.basePath, basePath)
        XCTAssertEqual(restored.columns.map(\.id), ["valid-executor", "valid-scout"])
        XCTAssertEqual(restored.columns.first?.createdBaseOID, validOID)
        XCTAssertEqual(restored.columns.last?.worktreePath, nil)
        XCTAssertEqual(restored.columns.last?.branch, nil)
    }

    func testWorkspaceRestorationDropsMeshWhoseBasePathDoesNotMatchProject() async throws {
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json"),
            meshWorktreeRoot: fileURL.deletingLastPathComponent()
                .appendingPathComponent("mesh-worktrees", isDirectory: true)
        )
        let descriptor = NativeRestorableMeshDescriptor(
            id: "mesh-wrong-project",
            projectID: "nproj_wrong",
            basePath: "/tmp/actual-project",
            title: "Untrusted Mesh",
            mode: .flat,
            purpose: .idea,
            lifecycle: .suspended,
            columns: []
        )

        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: descriptor.projectID,
                panes: [
                    NativeRestorablePaneState(
                        id: descriptor.id,
                        surface: NativeRestorableSurfaceState(mesh: descriptor)
                    ),
                ],
                focusedPaneID: descriptor.id
            )
        )

        let projectState = try await workspaceStore.projectState(for: descriptor.projectID)
        let restored = try XCTUnwrap(projectState)
        XCTAssertTrue(restored.panes.isEmpty)
        XCTAssertTrue(restored.layout.isEmpty)
        XCTAssertNil(restored.focusedPaneID)
    }

    func testSaveProjectStatePreservesMeshMissingFromIncomingWindowSnapshot() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let basePath = "/tmp/mesh-project-merge"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let meshPane = makeMeshPane(id: "mesh-project-merge", basePath: basePath)
        let staleTerminal = NativeRestorablePaneState(
            id: "term-stale",
            surface: NativeRestorableSurfaceState(
                kind: .terminal,
                id: "term-stale",
                projectID: projectID
            )
        )
        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: projectID,
                panes: [meshPane, staleTerminal],
                focusedPaneID: meshPane.id
            )
        )

        let incomingTerminal = NativeRestorablePaneState(
            id: "term-incoming",
            surface: NativeRestorableSurfaceState(
                kind: .terminal,
                id: "term-incoming",
                projectID: projectID
            )
        )
        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: projectID,
                panes: [incomingTerminal],
                focusedPaneID: incomingTerminal.id
            )
        )

        let projectState = try await workspaceStore.projectState(for: projectID)
        let restored = try XCTUnwrap(projectState)
        XCTAssertEqual(Set(restored.panes.map(\.id)), ["term-incoming", meshPane.id])
        XCTAssertFalse(restored.panes.contains { $0.id == staleTerminal.id })
        XCTAssertTrue(restored.panes.first { $0.id == meshPane.id }?.isMinimized == true)
        XCTAssertFalse(restored.layout.contains(meshPane.id))
        XCTAssertTrue(restored.layout.contains(incomingTerminal.id))
        XCTAssertEqual(restored.focusedPaneID, incomingTerminal.id)
    }

    func testSaveProjectStatePreservesMeshBeyondIncomingOrdinaryPaneCap() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let basePath = "/tmp/mesh-project-cap-merge"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let meshPane = makeMeshPane(id: "mesh-project-cap-merge", basePath: basePath)
        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(projectID: projectID, panes: [meshPane])
        )

        let incoming = makeTerminalPanes(
            count: NativeWorkspaceStateStore.maximumPanesPerProject,
            projectID: projectID,
            prefix: "term-project-cap"
        )
        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(projectID: projectID, panes: incoming)
        )

        let projectState = try await workspaceStore.projectState(for: projectID)
        let restored = try XCTUnwrap(projectState)
        XCTAssertEqual(
            restored.panes.filter { $0.surface.kind != .mesh }.map(\.id),
            incoming.map(\.id)
        )
        XCTAssertEqual(restored.panes.filter { $0.surface.kind == .mesh }.map(\.id), [meshPane.id])
        XCTAssertEqual(
            restored.panes.count,
            NativeWorkspaceStateStore.maximumPanesPerProject + 1
        )
        XCTAssertTrue(restored.panes.first { $0.id == meshPane.id }?.isMinimized == true)
    }

    func testSaveRestorationStatePreservesMeshesMissingFromIncomingWindowSnapshot() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let basePathA = "/tmp/mesh-restoration-merge-a"
        let basePathB = "/tmp/mesh-restoration-merge-b"
        let projectIDA = NativeSessionStore.projectID(forDirectory: basePathA)
        let projectIDB = NativeSessionStore.projectID(forDirectory: basePathB)
        let meshA = makeMeshPane(id: "mesh-restoration-a", basePath: basePathA)
        let meshB = makeMeshPane(id: "mesh-restoration-b", basePath: basePathB)
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectIDA,
                projects: [
                    NativeProjectWorkspaceState(projectID: projectIDA, panes: [meshA]),
                    NativeProjectWorkspaceState(projectID: projectIDB, panes: [meshB]),
                ]
            )
        )

        let incomingTerminal = NativeRestorablePaneState(
            id: "term-restoration-incoming",
            surface: NativeRestorableSurfaceState(
                kind: .terminal,
                id: "term-restoration-incoming",
                projectID: projectIDA
            )
        )
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectIDA,
                projects: [
                    NativeProjectWorkspaceState(
                        projectID: projectIDA,
                        panes: [incomingTerminal],
                        focusedPaneID: incomingTerminal.id
                    ),
                ]
            )
        )

        let restored = try await workspaceStore.restorationState()
        let restoredA = try XCTUnwrap(restored.projects.first { $0.projectID == projectIDA })
        XCTAssertEqual(Set(restoredA.panes.map(\.id)), [incomingTerminal.id, meshA.id])
        XCTAssertTrue(restoredA.panes.first { $0.id == meshA.id }?.isMinimized == true)
        XCTAssertFalse(restoredA.layout.contains(meshA.id))
        XCTAssertTrue(restoredA.layout.contains(incomingTerminal.id))

        let restoredB = try XCTUnwrap(restored.projects.first { $0.projectID == projectIDB })
        XCTAssertEqual(restoredB.panes.map(\.id), [meshB.id])
        XCTAssertTrue(restoredB.panes.first?.isMinimized == true)
        XCTAssertTrue(restoredB.layout.isEmpty)
    }

    func testSaveRestorationStatePreservesMeshBeyondIncomingOrdinaryPaneCap() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let basePath = "/tmp/mesh-restoration-cap-merge"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let meshPane = makeMeshPane(id: "mesh-restoration-cap-merge", basePath: basePath)
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [NativeProjectWorkspaceState(projectID: projectID, panes: [meshPane])]
            )
        )

        let incoming = makeTerminalPanes(
            count: NativeWorkspaceStateStore.maximumPanesPerProject,
            projectID: projectID,
            prefix: "term-restoration-cap"
        )
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [NativeProjectWorkspaceState(projectID: projectID, panes: incoming)]
            )
        )

        let restoration = try await workspaceStore.restorationState()
        let restored = try XCTUnwrap(restoration.projects.first { $0.projectID == projectID })
        XCTAssertEqual(
            restored.panes.filter { $0.surface.kind != .mesh }.map(\.id),
            incoming.map(\.id)
        )
        XCTAssertEqual(restored.panes.filter { $0.surface.kind == .mesh }.map(\.id), [meshPane.id])
        XCTAssertEqual(
            restored.panes.count,
            NativeWorkspaceStateStore.maximumPanesPerProject + 1
        )
        XCTAssertTrue(restored.panes.first { $0.id == meshPane.id }?.isMinimized == true)
    }

    func testWorkspaceRestorationRetainsNineMeshPanesWithoutOrdinaryPaneTruncation() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let basePath = "/tmp/mesh-nine-pane-retention"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let meshes = (0..<9).map { index in
            makeMeshPane(
                id: "mesh-nine-pane-\(index)",
                basePath: basePath,
                isMinimized: true
            )
        }
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [NativeProjectWorkspaceState(projectID: projectID, panes: meshes)]
            )
        )

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let restoration = try await reopened.restorationState()
        let restored = try XCTUnwrap(restoration.projects.first { $0.projectID == projectID })
        XCTAssertEqual(restored.panes.map(\.id), meshes.map(\.id))
        XCTAssertEqual(restored.panes.count, 9)
        XCTAssertTrue(restored.panes.allSatisfy { $0.surface.kind == .mesh })
    }

    func testWorkspaceRestorationRetainsMeshAsSixtyFifthProjectAndBoundsOnlyOrdinaryProjects() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let ordinaryProjects = (0...NativeWorkspaceStateStore.maximumProjects).map { index in
            let projectID = "ordinary-project-\(index)"
            let terminal = NativeRestorablePaneState(
                id: "ordinary-terminal-\(index)",
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: "ordinary-terminal-\(index)",
                    projectID: projectID
                )
            )
            return NativeProjectWorkspaceState(
                projectID: projectID,
                panes: [terminal],
                updatedAt: Int64(10_000 - index)
            )
        }
        let meshPath = "/tmp/mesh-sixty-fifth-project"
        let meshProjectID = NativeSessionStore.projectID(forDirectory: meshPath)
        let meshProject = NativeProjectWorkspaceState(
            projectID: meshProjectID,
            panes: [
                makeMeshPane(
                    id: "mesh-sixty-fifth-project",
                    basePath: meshPath,
                    isMinimized: true
                ),
            ],
            updatedAt: 0
        )
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(projects: ordinaryProjects + [meshProject])
        )

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let restoration = try await reopened.restorationState()
        let ordinary = restoration.projects.filter {
            !$0.panes.contains { $0.surface.kind == .mesh }
        }
        XCTAssertEqual(ordinary.count, NativeWorkspaceStateStore.maximumProjects)
        XCTAssertEqual(restoration.projects.count, NativeWorkspaceStateStore.maximumProjects + 1)
        XCTAssertEqual(restoration.projects.last?.projectID, meshProjectID)
        XCTAssertNotNil(restoration.projects.first { $0.projectID == meshProjectID })
        XCTAssertNil(
            restoration.projects.first {
                $0.projectID == "ordinary-project-\(NativeWorkspaceStateStore.maximumProjects)"
            }
        )
    }

    func testRemoveMeshStateRemovesOnlyExplicitMesh() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let basePath = "/tmp/mesh-explicit-removal"
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let remove = makeMeshPane(id: "mesh-remove", basePath: basePath)
        let keep = makeMeshPane(id: "mesh-keep", basePath: basePath)
        let terminal = NativeRestorablePaneState(
            id: "term-keep",
            surface: NativeRestorableSurfaceState(
                kind: .terminal,
                id: "term-keep",
                projectID: projectID
            )
        )
        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: projectID,
                panes: [terminal, remove, keep],
                focusedPaneID: remove.id
            )
        )

        try await workspaceStore.removeMeshState(projectID: projectID, meshID: remove.id)

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let projectState = try await reopened.projectState(for: projectID)
        let restored = try XCTUnwrap(projectState)
        XCTAssertEqual(Set(restored.panes.map(\.id)), [terminal.id, keep.id])
        XCTAssertFalse(restored.layout.contains(remove.id))
        XCTAssertTrue(restored.layout.contains(terminal.id))
        XCTAssertTrue(restored.layout.contains(keep.id))
        XCTAssertNil(restored.focusedPaneID)
    }

    func testWorkspaceRestorationDoesNotMutateBrokerOwnedSessions() async throws {
        let project = store.openProject(directory: "/tmp/durable-terminal")
        let session = NativeOwnedSession(
            id: "term-detached",
            projectID: project.id,
            cwd: project.path,
            title: "Detached",
            createdAt: 7
        )
        store.upsert(session)

        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: project.id,
                panes: [
                    NativeRestorablePaneState(
                        id: session.id,
                        surface: NativeRestorableSurfaceState(
                            kind: .terminal,
                            id: session.id,
                            projectID: project.id
                        )
                    ),
                ]
            ),
            makeSelected: true
        )

        XCTAssertEqual(NativeSessionStore(fileURL: fileURL).sessions(), [session])
    }

    func testWorkspaceRestorationSanitizesInvalidDuplicateAndOversizedPaneState() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let projectID = "nproj_bounded"
        var panes = (0..<(NativeWorkspaceStateStore.maximumPanesPerProject + 3)).map { index in
            NativeRestorablePaneState(
                id: "term-\(index)",
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: "term-\(index)",
                    projectID: projectID
                ),
                sizeWeight: index == 0 ? .infinity : 1
            )
        }
        panes.insert(
            NativeRestorablePaneState(
                id: "term-0",
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: "term-duplicate-pane",
                    projectID: projectID
                )
            ),
            at: 1
        )
        panes.insert(
            NativeRestorablePaneState(
                id: "chat-invalid",
                surface: NativeRestorableSurfaceState(
                    kind: .agentChat,
                    id: "chat-invalid",
                    projectID: projectID,
                    agentID: "claude-code",
                    workspacePath: "relative/path"
                )
            ),
            at: 2
        )

        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: projectID,
                panes: panes,
                focusedPaneID: "missing-pane",
                updatedAt: 1
            )
        )

        let storedProject = try await workspaceStore.projectState(for: projectID)
        let restored = try XCTUnwrap(storedProject)
        XCTAssertEqual(restored.panes.count, NativeWorkspaceStateStore.maximumPanesPerProject)
        XCTAssertEqual(Set(restored.panes.map(\.id)).count, restored.panes.count)
        XCTAssertEqual(restored.panes.first?.sizeWeight, 1)
        XCTAssertFalse(restored.panes.contains { $0.id == "chat-invalid" })
        XCTAssertNil(restored.focusedPaneID)
    }

    func testWorkspaceRestorationBoundsAndSanitizesProjectRelativeFileTabs() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let valid = (0..<(NativeWorkspaceStateStore.maximumFileTabsPerProject + 2)).map {
            NativeRestorableFileTabState(
                relativePath: "docs/file-\($0).md",
                isPinned: $0.isMultiple(of: 2),
                line: $0 == 0 ? -4 : $0 + 1
            )
        }
        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: "nproj_files",
                fileTabs: [
                    .init(relativePath: "../secret"),
                    .init(relativePath: "/absolute"),
                    valid[0],
                ] + valid,
                selectedFilePath: "docs/file-1.md"
            )
        )

        let storedProject = try await workspaceStore.projectState(for: "nproj_files")
        let restored = try XCTUnwrap(storedProject)
        XCTAssertEqual(
            restored.fileTabs.count,
            NativeWorkspaceStateStore.maximumFileTabsPerProject
        )
        XCTAssertEqual(Set(restored.fileTabs.map(\.relativePath)).count, restored.fileTabs.count)
        XCTAssertFalse(restored.fileTabs.contains { $0.relativePath.hasPrefix("/") || $0.relativePath.contains("..") })
        XCTAssertEqual(restored.fileTabs.filter { !$0.isPinned }.count, 1)
        XCTAssertNil(restored.fileTabs.first(where: { $0.relativePath == "docs/file-0.md" })?.line)
        XCTAssertEqual(restored.selectedFilePath, "docs/file-1.md")
    }

    func testProjectWorkspaceStateDecodesSnapshotWrittenBeforePaneLayout() throws {
        let projectID = "nproj_legacy-layout"
        let legacyJSON = """
        {
          "projectID": "\(projectID)",
          "arrangement": "rows",
          "panes": [
            {
              "id": "term-one",
              "surface": {
                "kind": "terminal",
                "id": "term-one",
                "projectID": "\(projectID)"
              },
              "sizeWeight": 1,
              "isMinimized": false
            },
            {
              "id": "term-two",
              "surface": {
                "kind": "terminal",
                "id": "term-two",
                "projectID": "\(projectID)"
              },
              "sizeWeight": 1,
              "isMinimized": false
            }
          ],
          "focusedPaneID": "term-two",
          "updatedAt": 42
        }
        """

        let decoded = try JSONDecoder().decode(
            NativeProjectWorkspaceState.self,
            from: try XCTUnwrap(legacyJSON.data(using: .utf8))
        )

        XCTAssertEqual(decoded.layout.columns.count, 1)
        XCTAssertEqual(decoded.layout.columns.first?.sessionIDs, ["term-one", "term-two"])
        XCTAssertEqual(decoded.focusedPaneID, "term-two")
    }

    func testWorkspaceStoreRefusesToOverwriteNewerSchema() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let futureData = try XCTUnwrap(
            "{\"schemaVersion\":999,\"future\":true}".data(using: .utf8)
        )
        try futureData.write(to: stateURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        do {
            try await workspaceStore.saveRestorationState(NativeWorkspaceRestorationState())
            XCTFail("Expected a newer schema to be preserved")
        } catch {
            XCTAssertEqual(
                error as? NativeWorkspaceStateStore.StoreError,
                .unsupportedSchema(found: 999)
            )
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), futureData)
    }

    func testWorkspaceStoreRefusesToOverwriteMalformedOrTruncatedSchemaTwoArchive() async throws {
        let corruptArchives: [(name: String, data: Data)] = [
            (
                "truncated",
                try XCTUnwrap("{\"schemaVersion\":2,\"restoration\":".data(using: .utf8))
            ),
            (
                "malformed",
                try XCTUnwrap(
                    "{\"schemaVersion\":2,\"restoration\":{\"projects\":\"invalid\"},\"drafts\":[]}"
                        .data(using: .utf8)
                )
            ),
        ]

        for corrupt in corruptArchives {
            let stateURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-\(corrupt.name).json")
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try corrupt.data.write(to: stateURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateURL.path
            )
            let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)

            do {
                _ = try await workspaceStore.restorationState()
                XCTFail("Expected \(corrupt.name) schema-v2 archive to fail closed")
            } catch {
                XCTAssertEqual(
                    error as? NativeWorkspaceStateStore.StoreError,
                    .corruptArchive
                )
            }

            do {
                try await workspaceStore.saveRestorationState(
                    NativeWorkspaceRestorationState()
                )
                XCTFail("Expected save to preserve \(corrupt.name) schema-v2 archive")
            } catch {
                XCTAssertEqual(
                    error as? NativeWorkspaceStateStore.StoreError,
                    .corruptArchive
                )
            }
            XCTAssertEqual(try Data(contentsOf: stateURL), corrupt.data)
        }
    }

    func testAgentChatDraftRoundTripsAcrossStoreInstancesAndEmptyTextClearsIt() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let key = NativeWorkspaceStateStore.agentChatStableKey(
            agentID: "claude-code",
            workspacePath: "/tmp/draft-project/./"
        )

        try await workspaceStore.saveDraft(
            "Unsent follow-up",
            stableKey: key,
            projectID: "nproj_draft",
            agentID: "claude-code",
            workspacePath: "/tmp/draft-project",
            updatedAt: 10
        )

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let restoredText = try await reopened.draft(for: key)
        XCTAssertEqual(restoredText, "Unsent follow-up")
        let allDrafts = try await reopened.allDrafts()
        let draft = try XCTUnwrap(allDrafts.first)
        XCTAssertEqual(draft.workspacePath, "/tmp/draft-project")
        XCTAssertNotEqual(draft.id, key)

        try await reopened.saveDraft(
            "",
            stableKey: key,
            projectID: "nproj_draft",
            agentID: "claude-code",
            workspacePath: "/tmp/draft-project"
        )
        let clearedText = try await reopened.draft(for: key)
        XCTAssertNil(clearedText)
    }

    func testAgentChatDraftRejectsOversizeWithoutLosingPreviousText() async throws {
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        let key = "claude-code|/tmp/draft-limit"
        try await workspaceStore.saveDraft(
            "keep me",
            stableKey: key,
            projectID: "nproj_limit",
            agentID: "claude-code",
            workspacePath: "/tmp/draft-limit"
        )

        do {
            try await workspaceStore.saveDraft(
                String(repeating: "x", count: NativeWorkspaceStateStore.maximumDraftBytes + 1),
                stableKey: key,
                projectID: "nproj_limit",
                agentID: "claude-code",
                workspacePath: "/tmp/draft-limit"
            )
            XCTFail("Expected an oversized draft to be rejected")
        } catch {
            XCTAssertEqual(
                error as? NativeWorkspaceStateStore.StoreError,
                .draftTooLarge(maxBytes: NativeWorkspaceStateStore.maximumDraftBytes)
            )
        }
        let preservedText = try await workspaceStore.draft(for: key)
        XCTAssertEqual(preservedText, "keep me")
    }

    func testAgentChatDraftArchiveEvictsOldestEntriesAtBound() async throws {
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        for index in 0...NativeWorkspaceStateStore.maximumDrafts {
            try await workspaceStore.saveDraft(
                "draft \(index)",
                stableKey: "agent|/tmp/project-\(index)",
                projectID: "nproj_\(index)",
                agentID: "agent",
                workspacePath: "/tmp/project-\(index)",
                updatedAt: Int64(index)
            )
        }

        let drafts = try await workspaceStore.allDrafts()
        let oldestDraft = try await workspaceStore.draft(for: "agent|/tmp/project-0")
        let newestDraft = try await workspaceStore.draft(
            for: "agent|/tmp/project-\(NativeWorkspaceStateStore.maximumDrafts)"
        )
        XCTAssertEqual(drafts.count, NativeWorkspaceStateStore.maximumDrafts)
        XCTAssertNil(oldestDraft)
        XCTAssertEqual(
            newestDraft,
            "draft \(NativeWorkspaceStateStore.maximumDrafts)"
        )
    }

    // MARK: - Unreadable archives (issue #477)

    func testMissingArchiveStillMintsAStableIdentity() {
        let owner = store.ownerID()
        XCTAssertTrue(owner.hasPrefix("native-"))
        XCTAssertNil(store.archiveQuarantine())
        XCTAssertEqual(NativeSessionStore(fileURL: fileURL).ownerID(), owner)
    }

    func testCorruptArchiveIsQuarantinedInsteadOfMintingAFreshOwnerIdentity() throws {
        let bytes = Data("{\"sessions\":[{\"id\":\"term-1\"".utf8)
        let archiveURL = try writeArchive(bytes, named: "corrupt")
        let observed = CollectedQuarantines()
        SessionStoreQuarantineMonitor.shared.setObserver { observed.append($0) }
        let corrupted = NativeSessionStore(fileURL: archiveURL)

        XCTAssertEqual(
            corrupted.ownerID(),
            "",
            "A damaged archive is not evidence that this install never owned anything"
        )
        XCTAssertEqual(corrupted.sessions(), [])
        XCTAssertEqual(corrupted.archiveQuarantine()?.failure, .corrupt)

        // Ordinary activity must not overwrite the quarantined bytes either.
        corrupted.openProject(directory: "/tmp/after-corruption")
        corrupted.upsert(NativeOwnedSession(
            id: "term-after-corruption",
            projectID: "nproj_after",
            cwd: "/tmp",
            title: "After",
            createdAt: 1
        ))
        XCTAssertEqual(try Data(contentsOf: archiveURL), bytes)

        let quarantine = try XCTUnwrap(observed.all().first)
        XCTAssertEqual(quarantine.path, archiveURL.path)
        XCTAssertNil(quarantine.salvagedOwnerID)
        let copyPath = try XCTUnwrap(quarantine.copyPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copyPath)), bytes)
    }

    func testTornArchiveSalvagesItsOwnerIdentityRatherThanRotatingIt() throws {
        let owner = "native-8f2c1d40-torn"
        let torn = Data("{\"ownerID\":\"\(owner)\",\"schemaVersion\":1,\"sessions\":[{\"id\"".utf8)
        let archiveURL = try writeArchive(torn, named: "torn")
        let recovered = NativeSessionStore(fileURL: archiveURL)

        XCTAssertEqual(
            recovered.ownerID(),
            owner,
            "Re-adopting the identity still in the bytes is repair, not rotation"
        )
        // The registry is genuinely lost; recoverOwnedSessions repopulates it
        // from the broker under this same authority.
        XCTAssertEqual(recovered.sessions(), [])
        XCTAssertNil(
            recovered.archiveQuarantine(),
            "Salvaging the identity resolves the quarantine"
        )
        XCTAssertEqual(NativeSessionStore(fileURL: archiveURL).ownerID(), owner)

        let copies = try FileManager.default
            .contentsOfDirectory(atPath: archiveURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("torn.json.corrupt-") }
        let copyPath = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(try XCTUnwrap(copies.first))
        XCTAssertEqual(try Data(contentsOf: copyPath), torn)
    }

    func testFutureFormatArchiveIsLeftIntactAndRefusesIdentityRotation() throws {
        let future = Data(
            "{\"ownerID\":\"native-from-the-future\",\"schemaVersion\":999,\"sessions\":[]}".utf8
        )
        let archiveURL = try writeArchive(future, named: "future")
        let downgraded = NativeSessionStore(fileURL: archiveURL)

        XCTAssertEqual(downgraded.ownerID(), "")
        XCTAssertEqual(
            downgraded.archiveQuarantine()?.failure,
            .futureVersion(found: 999, supported: NativeSessionStore.archiveSchemaVersion)
        )
        downgraded.openProject(directory: "/tmp/after-downgrade")
        XCTAssertEqual(
            try Data(contentsOf: archiveURL),
            future,
            "Upgrading back must find the newer archive exactly as it was left"
        )
    }

    func testUnreadableArchiveIsQuarantinedWithoutRotatingTheIdentity() throws {
        let readable = Data("{\"ownerID\":\"native-locked-away\",\"sessions\":[]}".utf8)
        let archiveURL = try writeArchive(readable, named: "locked")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: archiveURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: archiveURL.path
            )
        }
        let blocked = NativeSessionStore(fileURL: archiveURL)

        XCTAssertEqual(blocked.ownerID(), "")
        let quarantine = try XCTUnwrap(blocked.archiveQuarantine())
        if case .unreadable = quarantine.failure {} else {
            XCTFail("Expected an unreadable archive, got \(quarantine.failure)")
        }
        // Nothing was read, so nothing could be copied aside — leaving the file
        // untouched is the whole of the quarantine here.
        XCTAssertNil(quarantine.copyPath)

        blocked.upsert(NativeOwnedSession(
            id: "term-blocked",
            projectID: "nproj_blocked",
            cwd: "/tmp",
            title: "Blocked",
            createdAt: 1
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archiveURL.path
        )
        XCTAssertEqual(try Data(contentsOf: archiveURL), readable)
    }

    // MARK: - Bounded archive reads (issue #475)

    func testOversizedArchiveIsRejectedBeforeReadAndLeftUntouched() throws {
        let byteCount = NativeSessionStore.maximumArchiveBytes + 1
        let archiveURL = try writeSparseArchive(byteCount: byteCount, named: "oversized-cold")
        let refused = NativeSessionStore(fileURL: archiveURL)

        XCTAssertEqual(refused.ownerID(), "")
        XCTAssertEqual(refused.sessions(), [])
        let quarantine = try XCTUnwrap(refused.archiveQuarantine())
        XCTAssertEqual(
            quarantine.failure,
            .oversized(
                foundBytes: byteCount,
                maximumBytes: NativeSessionStore.maximumArchiveBytes
            )
        )
        XCTAssertNil(quarantine.copyPath, "Refused bytes must not be read just to make a copy")
        XCTAssertNil(quarantine.salvagedOwnerID)
        XCTAssertFalse(quarantine.lastKnownGoodAvailable)
        XCTAssertTrue(quarantine.recoveryInstructions.contains("move the oversized archive"))
        XCTAssertTrue(quarantine.recoveryInstructions.contains("restore a trusted archive"))
        XCTAssertTrue(quarantine.recoveryInstructions.contains("then relaunch"))

        refused.openProject(directory: "/tmp/must-not-replace-oversized")
        let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, byteCount)
    }

    func testArchiveAtExactByteLimitStillDecodes() throws {
        let owner = "native-exact-archive-limit"
        var bytes = Data("{\"ownerID\":\"\(owner)\",\"sessions\":[]}".utf8)
        bytes.append(
            Data(
                repeating: Character(" ").asciiValue!,
                count: Int(NativeSessionStore.maximumArchiveBytes) - bytes.count
            )
        )
        let archiveURL = try writeArchive(bytes, named: "exact-limit")
        let accepted = NativeSessionStore(fileURL: archiveURL)

        XCTAssertEqual(accepted.ownerID(), owner)
        XCTAssertEqual(accepted.sessions(), [])
        XCTAssertNil(accepted.archiveQuarantine())
    }

    func testOversizedArchiveKeepsLastKnownGoodPayloadButBlocksFurtherWrites() throws {
        let owner = store.ownerID()
        let original = NativeOwnedSession(
            id: "term-before-oversize",
            projectID: "nproj_before_oversize",
            cwd: "/tmp/before-oversize",
            title: "Before oversize",
            createdAt: 10
        )
        store.upsert(original)
        XCTAssertEqual(store.sessions(), [original])

        let oversizedByteCount = UInt64(NativeSessionStore.maximumArchiveBytes + 1)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: oversizedByteCount)
        try handle.close()

        XCTAssertEqual(store.ownerID(), owner)
        XCTAssertEqual(store.sessions(), [original])
        let quarantine = try XCTUnwrap(store.archiveQuarantine())
        XCTAssertEqual(
            quarantine.failure,
            .oversized(
                foundBytes: Int64(oversizedByteCount),
                maximumBytes: NativeSessionStore.maximumArchiveBytes
            )
        )
        XCTAssertTrue(quarantine.lastKnownGoodAvailable)
        XCTAssertNil(quarantine.copyPath)
        XCTAssertTrue(quarantine.message.contains("last known-good in-memory session state"))
        XCTAssertTrue(quarantine.message.contains("changes will not be saved until recovery"))
        XCTAssertTrue(quarantine.message.contains("restore a trusted archive"))

        store.upsert(NativeOwnedSession(
            id: "term-after-oversize",
            projectID: "nproj_after_oversize",
            cwd: "/tmp/after-oversize",
            title: "After oversize",
            createdAt: 11
        ))
        XCTAssertEqual(store.sessions(), [original])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, oversizedByteCount)
    }

    func testArchiveCarriesItsFormatVersionForwardOnEveryWrite() throws {
        store.openProject(directory: "/tmp/stamped")
        let object = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: fileURL)
        ) as? [String: Any]
        XCTAssertEqual(
            object?["schemaVersion"] as? Int,
            NativeSessionStore.archiveSchemaVersion
        )
    }

    /// Writes bytes straight to disk so the store meets them cold: the decoded
    /// payload cache is process-wide and keyed by URL.
    private func writeArchive(_ data: Data, named name: String) throws -> URL {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let archiveURL = directory.appendingPathComponent("\(name).json")
        try data.write(to: archiveURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archiveURL.path
        )
        return archiveURL
    }

    private func writeSparseArchive(byteCount: Int64, named name: String) throws -> URL {
        let archiveURL = try writeArchive(Data(), named: name)
        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
        return archiveURL
    }

    private func writeProjectArchive(
        ownerID: String,
        sessions: [NativeOwnedSession] = [],
        projects: [OpenProject],
        named name: String
    ) throws -> (url: URL, bytes: Data) {
        let bytes = try JSONEncoder().encode(ProjectArchiveFixture(
            ownerID: ownerID,
            schemaVersion: NativeSessionStore.archiveSchemaVersion,
            sessions: sessions,
            projects: projects
        ))
        return (try writeArchive(bytes, named: name), bytes)
    }

    private func makeMeshPane(
        id: String,
        basePath: String,
        isMinimized: Bool = false
    ) -> NativeRestorablePaneState {
        let descriptor = NativeRestorableMeshDescriptor(
            id: id,
            projectID: NativeSessionStore.projectID(forDirectory: basePath),
            basePath: basePath,
            title: "Mesh · \(id)",
            mode: .flat,
            purpose: .idea,
            lifecycle: .suspended,
            columns: []
        )
        return NativeRestorablePaneState(
            id: id,
            surface: NativeRestorableSurfaceState(mesh: descriptor),
            isMinimized: isMinimized
        )
    }

    private func makeTerminalPanes(
        count: Int,
        projectID: String,
        prefix: String
    ) -> [NativeRestorablePaneState] {
        (0..<count).map { index in
            let id = "\(prefix)-\(index)"
            return NativeRestorablePaneState(
                id: id,
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: id,
                    projectID: projectID
                )
            )
        }
    }

}

/// Sink for quarantine notices, which arrive on whichever thread read the
/// archive.
private final class CollectedQuarantines: @unchecked Sendable {
    private let lock = NSLock()
    private var quarantines: [SessionStoreQuarantine] = []

    func append(_ quarantine: SessionStoreQuarantine) {
        lock.lock()
        defer { lock.unlock() }
        quarantines.append(quarantine)
    }

    func all() -> [SessionStoreQuarantine] {
        lock.lock()
        defer { lock.unlock() }
        return quarantines
    }
}

private struct ProjectArchiveFixture: Codable {
    let ownerID: String
    let schemaVersion: Int
    let sessions: [NativeOwnedSession]
    let projects: [OpenProject]
}

private final class CollectedProjectIdentityQuarantines: @unchecked Sendable {
    private let lock = NSLock()
    private var quarantines: [SessionStoreProjectIdentityQuarantine] = []

    func append(_ quarantine: SessionStoreProjectIdentityQuarantine) {
        lock.lock()
        defer { lock.unlock() }
        quarantines.append(quarantine)
    }

    func all() -> [SessionStoreProjectIdentityQuarantine] {
        lock.lock()
        defer { lock.unlock() }
        return quarantines
    }
}
