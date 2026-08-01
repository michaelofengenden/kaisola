import Foundation
import XCTest
@testable import Kaisola

/// Degraded-state visibility for the two persistence paths that used to fail
/// invisibly.
///
/// `NativeWorkspaceStateStore` deliberately fails closed on an archive it
/// cannot decode, because schema 2 carries the only durable identity for
/// unintegrated Mesh work. AppModel then swallowed that failure, so the user
/// got an unexplained empty workspace whose every later save also threw —
/// silently, forever. `NativeSessionStore.write` has the mirror problem: the
/// in-memory cache accepts the payload before the disk does, so a full or
/// read-only volume is invisible until the next launch loses the session.
final class WorkspacePersistenceVisibilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kaisola-persistence-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        SessionStoreWriteFailureMonitor.shared.reset()
        if let directory {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private var archiveURL: URL {
        directory.appendingPathComponent("workspace-state-v1.json")
    }

    private func writeArchive(_ contents: String) throws {
        try Data(contents.utf8).write(to: archiveURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archiveURL.path
        )
    }

    /// `ToastCenter` is a process-wide singleton, so a toast assertion is only
    /// meaningful from a known-empty queue.
    @MainActor
    private func clearToasts() {
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
    }

    @MainActor
    private func makeModel(_ workspaceStore: NativeWorkspaceStateStore) -> AppModel {
        AppModel(
            sessionStore: NativeSessionStore(
                fileURL: directory.appendingPathComponent("native-sessions.json")
            ),
            workspaceStateStore: workspaceStore
        )
    }

    // MARK: - Rename-aside policy

    func testPreservedCopyNameSitsBesideTheArchiveAndNeverReusesATakenName() {
        let stamp = Date(timeIntervalSince1970: 1_785_000_000)
        let first = NativeWorkspaceStateStore.preservedCopyURL(
            for: archiveURL,
            at: stamp,
            isTaken: { _ in false }
        )

        XCTAssertEqual(
            first.deletingLastPathComponent().standardizedFileURL,
            archiveURL.deletingLastPathComponent().standardizedFileURL,
            "The preserved copy must sit beside the archive it replaces"
        )
        XCTAssertNotEqual(first.path, archiveURL.path)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("workspace-state-v1.corrupt-"))
        XCTAssertEqual(first.pathExtension, "json")

        // Deterministic for the same instant, so a repeated failure inside one
        // launch cannot silently produce a second unexplained file.
        XCTAssertEqual(
            first,
            NativeWorkspaceStateStore.preservedCopyURL(
                for: archiveURL,
                at: stamp,
                isTaken: { _ in false }
            )
        )

        // An occupied name is never overwritten: the protected bytes of an
        // earlier failure are exactly what recovery needs.
        let second = NativeWorkspaceStateStore.preservedCopyURL(
            for: archiveURL,
            at: stamp,
            isTaken: { $0 == first }
        )
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second.pathExtension, "json")
    }

    func testPreservingACorruptArchiveKeepsItsBytesAndUnblocksTheNextSave() async throws {
        let corrupt = "{\"schemaVersion\":2,\"restoration\":"
        try writeArchive(corrupt)
        let store = NativeWorkspaceStateStore(fileURL: archiveURL)

        do {
            _ = try await store.restorationState()
            XCTFail("Expected a truncated schema-2 archive to fail closed")
        } catch {
            XCTAssertEqual(
                error as? NativeWorkspaceStateStore.StoreError,
                .corruptArchive
            )
        }

        let moved = try await store.preserveUnreadableArchive()
        guard case .movedAside(let preserved) = moved else {
            return XCTFail("A corrupt archive on disk must be moved aside, not reported missing")
        }
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))

        try await store.saveRestorationState(
            NativeWorkspaceRestorationState(selectedProjectID: "nproj_fresh")
        )
        let restored = try await store.restorationState()
        XCTAssertEqual(restored.selectedProjectID, "nproj_fresh")
        XCTAssertEqual(
            try String(contentsOf: preserved, encoding: .utf8),
            corrupt,
            "The fresh archive must not disturb the preserved copy"
        )
    }

    /// Several windows launching at once all read the same damaged archive and
    /// all try to rescue it. Exactly one finds anything left to move; the rest
    /// used to report that the rescue had failed and that their saves were
    /// blocked, when in fact a sibling had already cleared the path for them.
    func testASecondWindowFindsNothingToPreserveAndIsNotBlockedBecauseOfIt() async throws {
        let corrupt = "{\"schemaVersion\":2,\"restoration\":"
        try writeArchive(corrupt)
        let windowA = NativeWorkspaceStateStore(fileURL: archiveURL)
        let windowB = NativeWorkspaceStateStore(fileURL: archiveURL)

        // Both windows read the damaged bytes and fail closed before either
        // gets as far as moving them.
        for window in [windowA, windowB] {
            do {
                _ = try await window.restorationState()
                XCTFail("Both windows must fail closed on the same damaged archive")
            } catch {
                XCTAssertEqual(
                    error as? NativeWorkspaceStateStore.StoreError,
                    .corruptArchive
                )
            }
        }

        guard case .movedAside(let preserved) = try await windowA.preserveUnreadableArchive() else {
            return XCTFail("The first window to arrive must be the one that moves the bytes")
        }
        let secondRescue = try await windowB.preserveUnreadableArchive()
        XCTAssertEqual(
            secondRescue,
            .nothingToPreserve,
            "A window that arrives second finds the rescue already done, not failed"
        )

        // The distinguishing consequence: window B can save.
        try await windowB.saveRestorationState(
            NativeWorkspaceRestorationState(selectedProjectID: "nproj_second_window")
        )
        let reread = try await windowB.restorationState()
        XCTAssertEqual(reread.selectedProjectID, "nproj_second_window")
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), corrupt)
    }

    func testASecondWindowsNoticeReportsRecoveryRatherThanAFailedRescue() {
        let notice = WorkspaceRestorationNotice(
            kind: .corruptArchive,
            archiveURL: archiveURL,
            disposition: .alreadyPreservedByAnotherWindow
        )

        XCTAssertFalse(
            notice.savesBlocked,
            "Another window's rescue clears this window's archive path too"
        )
        XCTAssertNil(notice.preservedCopyURL, "This window is not the one that moved the bytes")
        XCTAssertFalse(
            notice.message.contains("couldn't move"),
            "Reporting a failed rescue that never failed is the bug: \(notice.message)"
        )
        XCTAssertFalse(
            notice.message.contains("aren't being saved"),
            "Saving works here: \(notice.message)"
        )
        XCTAssertEqual(notice.summary, "Window layout not restored")
        XCTAssertEqual(
            notice.revealURL,
            archiveURL.deletingLastPathComponent(),
            "There is no file at the archive path to select, only the folder holding the kept copy"
        )

        // A repeat failure that preserves nothing must not forget the recovery.
        let repeated = WorkspaceRestorationNotice(
            kind: .corruptArchive,
            archiveURL: archiveURL,
            disposition: .protectedInPlace
        ).continuing(notice)
        XCTAssertFalse(repeated.savesBlocked)
    }

    func testPreservingWithoutAnArchiveIsANoOp() async throws {
        let store = NativeWorkspaceStateStore(fileURL: archiveURL)
        let moved = try await store.preserveUnreadableArchive()
        XCTAssertEqual(
            moved,
            .nothingToPreserve,
            "An absent archive is a cleared path, not a failed rescue"
        )
        try await store.saveRestorationState(NativeWorkspaceRestorationState())
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    /// The reason `unsupportedSchema` is worth a blocked window: every write
    /// path loads before it persists, so a newer version's archive can never be
    /// silently downgraded to something this build happens to understand. The
    /// notice tells the user saves are blocked — this is the test that they
    /// actually are, byte for byte.
    func testANewerSchemaRefusesEverySaveAndLeavesItsBytesExactlyAsFound() async throws {
        let future = "{\"schemaVersion\":999,\"restoration\":{\"projects\":[]},\"future\":true}"
        try writeArchive(future)
        let store = NativeWorkspaceStateStore(fileURL: archiveURL)

        func expectRefusal(
            _ operation: String,
            _ save: () async throws -> Void
        ) async {
            do {
                try await save()
                XCTFail("\(operation) must refuse an archive this build cannot read")
            } catch {
                XCTAssertEqual(
                    error as? NativeWorkspaceStateStore.StoreError,
                    .unsupportedSchema(found: 999),
                    "\(operation) must fail for the schema, not incidentally"
                )
            }
        }

        await expectRefusal("saveRestorationState") {
            try await store.saveRestorationState(
                NativeWorkspaceRestorationState(selectedProjectID: "nproj_downgrade")
            )
        }
        await expectRefusal("saveProjectState") {
            try await store.saveProjectState(
                NativeProjectWorkspaceState(projectID: "nproj_downgrade")
            )
        }
        await expectRefusal("setSelectedProjectID") {
            try await store.setSelectedProjectID("nproj_downgrade")
        }
        await expectRefusal("saveDraft") {
            try await store.saveDraft(
                "half-typed prompt",
                stableKey: "nproj_downgrade|chat",
                projectID: "nproj_downgrade",
                agentID: "claude",
                workspacePath: "/tmp"
            )
        }

        XCTAssertEqual(
            try String(contentsOf: archiveURL, encoding: .utf8),
            future,
            "A refused save must not rewrite a single byte of the newer archive"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            [archiveURL.lastPathComponent],
            "No preserved copy and no abandoned temp file may be left behind"
        )
    }

    // MARK: - Notice state machine

    func testNoticeDistinguishesCorruptionFromANewerVersionsData() {
        let preserved = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.corrupt-20260731T000000Z.json")
        let corrupt = WorkspaceRestorationNotice(
            kind: .corruptArchive,
            archiveURL: archiveURL,
            disposition: .movedAside(preserved)
        )
        XCTAssertFalse(corrupt.savesBlocked)
        XCTAssertEqual(corrupt.revealURL, preserved)
        XCTAssertTrue(corrupt.message.contains(preserved.lastPathComponent))

        let newer = WorkspaceRestorationNotice(
            kind: .newerVersionData(schemaVersion: 999),
            archiveURL: archiveURL,
            disposition: .protectedInPlace
        )
        XCTAssertTrue(newer.savesBlocked)
        XCTAssertEqual(newer.revealURL, archiveURL)
        XCTAssertNotEqual(newer.title, corrupt.title)
        XCTAssertNotEqual(newer.message, corrupt.message)

        XCTAssertTrue(WorkspaceRestorationNotice.Kind.corruptArchive.allowsPreservingAside)
        XCTAssertFalse(
            WorkspaceRestorationNotice.Kind
                .newerVersionData(schemaVersion: 3).allowsPreservingAside
        )
        XCTAssertEqual(
            WorkspaceRestorationNotice.Kind(
                storeError: NativeWorkspaceStateStore.StoreError.unsupportedSchema(found: 7)
            ),
            .newerVersionData(schemaVersion: 7)
        )
        XCTAssertEqual(
            WorkspaceRestorationNotice.Kind(
                storeError: NativeWorkspaceStateStore.StoreError.corruptArchive
            ),
            .corruptArchive
        )
        if case .unreadable = WorkspaceRestorationNotice.Kind(
            storeError: NativeWorkspaceStateStore.StoreError.unsafePath
        ) {} else {
            XCTFail("An unsafe archive path must remain a distinct, untouched failure")
        }
    }

    func testNoticeTracksRetriesAndKeepsADurableFlagAfterDismissal() {
        var notice = WorkspaceRestorationNotice(
            kind: .corruptArchive,
            archiveURL: archiveURL,
            disposition: .protectedInPlace
        )
        XCTAssertEqual(notice.retryCount, 0)
        XCTAssertFalse(notice.isRetrying)
        XCTAssertFalse(notice.isBannerDismissed)

        notice.dismissBanner()
        XCTAssertTrue(notice.isBannerDismissed)

        notice.beginRetry()
        XCTAssertTrue(notice.isRetrying)
        XCTAssertFalse(
            notice.isBannerDismissed,
            "A retry the user asked for must bring the explanation back"
        )

        let repeated = WorkspaceRestorationNotice(
            kind: .corruptArchive,
            archiveURL: archiveURL,
            disposition: .protectedInPlace
        ).continuing(notice)
        XCTAssertEqual(repeated.retryCount, 1)
        XCTAssertFalse(repeated.isRetrying)
        XCTAssertFalse(repeated.isBannerDismissed)
    }

    // MARK: - AppModel restoration

    @MainActor
    func testCorruptArchiveRestorationMovesItAsideAndRaisesARecoverableNotice() async throws {
        let corrupt = "{\"schemaVersion\":2,\"restoration\":"
        try writeArchive(corrupt)
        let store = NativeWorkspaceStateStore(fileURL: archiveURL)
        let model = makeModel(store)

        await model.restoreWorkspaceStateIfNeeded()

        let notice = try XCTUnwrap(model.workspaceRestorationNotice)
        XCTAssertEqual(notice.kind, .corruptArchive)
        let preserved = try XCTUnwrap(notice.preservedCopyURL)
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), corrupt)
        XCTAssertFalse(notice.savesBlocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))

        // The whole point of moving it aside: saving works again.
        try await store.saveRestorationState(
            NativeWorkspaceRestorationState(selectedProjectID: "nproj_after")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    @MainActor
    func testNewerVersionArchiveIsLeftUntouchedAndSaysWhy() async throws {
        let future = "{\"schemaVersion\":999,\"future\":true}"
        try writeArchive(future)
        let store = NativeWorkspaceStateStore(fileURL: archiveURL)
        let model = makeModel(store)

        await model.restoreWorkspaceStateIfNeeded()

        let notice = try XCTUnwrap(model.workspaceRestorationNotice)
        XCTAssertEqual(notice.kind, .newerVersionData(schemaVersion: 999))
        XCTAssertNil(notice.preservedCopyURL)
        XCTAssertTrue(notice.savesBlocked)
        XCTAssertEqual(try String(contentsOf: archiveURL, encoding: .utf8), future)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.contains(".corrupt-") },
            [],
            "A newer version's archive must never be moved aside"
        )
    }

    @MainActor
    func testRetryAfterRepairClearsTheNotice() async throws {
        try writeArchive("{\"schemaVersion\":2,\"restoration\":")
        let store = NativeWorkspaceStateStore(fileURL: archiveURL)
        let model = makeModel(store)

        await model.restoreWorkspaceStateIfNeeded()
        XCTAssertNotNil(model.workspaceRestorationNotice)

        try await store.saveRestorationState(
            NativeWorkspaceRestorationState(selectedProjectID: "nproj_repaired")
        )
        clearToasts()
        await model.retryWorkspaceRestoration()

        XCTAssertNil(model.workspaceRestorationNotice)
        XCTAssertEqual(
            ToastCenter.shared.toasts.last?.message,
            "Restored your saved window layout",
            "This retry really did read the user's repaired archive"
        )
    }

    /// The corrupt path's retry always succeeds — it reads the empty archive
    /// that replaced the damaged one — so a "restored your layout" toast would
    /// congratulate the user on getting back panes that are gone for good.
    @MainActor
    func testRetryOnTheFreshArchiveSaysTheLayoutIsNewRatherThanRestored() async throws {
        try writeArchive("{\"schemaVersion\":2,\"restoration\":")
        let store = NativeWorkspaceStateStore(fileURL: archiveURL)
        let model = makeModel(store)

        await model.restoreWorkspaceStateIfNeeded()
        let notice = try XCTUnwrap(model.workspaceRestorationNotice)
        XCTAssertEqual(notice.kind, .corruptArchive)
        XCTAssertFalse(notice.savesBlocked)
        clearToasts()

        await model.retryWorkspaceRestoration()

        XCTAssertNil(model.workspaceRestorationNotice)
        let message = try XCTUnwrap(ToastCenter.shared.toasts.last?.message)
        XCTAssertEqual(
            message,
            "Started a fresh layout — your damaged copy is kept beside it"
        )
        XCTAssertFalse(
            message.lowercased().contains("restored"),
            "Nothing was restored: the archive this retry read is the empty one"
        )
    }

    @MainActor
    func testRestoringAHealthyArchiveRaisesNoNotice() async throws {
        let store = NativeWorkspaceStateStore(fileURL: archiveURL)
        try await store.saveRestorationState(
            NativeWorkspaceRestorationState(selectedProjectID: "nproj_healthy")
        )
        let model = makeModel(store)

        await model.restoreWorkspaceStateIfNeeded()

        XCTAssertNil(model.workspaceRestorationNotice)
    }

    // MARK: - Session-store write failures

    func testWriteFailureThrottleSurfacesOncePerWindowAndCountsTheRest() {
        var throttle = SessionStoreWriteFailureThrottle(minimumInterval: 300)
        let start = Date(timeIntervalSince1970: 1_785_000_000)

        XCTAssertTrue(throttle.shouldSurface(at: start))
        XCTAssertFalse(throttle.shouldSurface(at: start.addingTimeInterval(1)))
        XCTAssertFalse(throttle.shouldSurface(at: start.addingTimeInterval(299)))
        XCTAssertEqual(throttle.suppressedCount, 2)
        XCTAssertTrue(throttle.shouldSurface(at: start.addingTimeInterval(300)))
        XCTAssertEqual(throttle.suppressedCount, 0)
        XCTAssertEqual(throttle.totalCount, 4)
    }

    func testSessionStoreSurfacesADiskWriteFailureWithoutLosingTheCachedPayload() throws {
        let unwritable = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unwritable,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let storeURL = unwritable.appendingPathComponent("native-sessions.json")
        let store = NativeSessionStore(fileURL: storeURL)
        _ = store.sessions()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: unwritable.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: unwritable.path
            )
        }

        let observed = CollectedWriteFailures()
        SessionStoreWriteFailureMonitor.shared.reset()
        SessionStoreWriteFailureMonitor.shared.setObserver { observed.append($0) }

        store.upsert(NativeOwnedSession(
            id: "term-disk-full",
            projectID: "nproj_disk",
            cwd: "/tmp",
            title: "Disk",
            createdAt: 1
        ))

        XCTAssertEqual(observed.paths(), [storeURL.path])
        XCTAssertTrue(
            try XCTUnwrap(observed.messages().first).lowercased().contains("disk"),
            "The surfaced message must name the failure the user can act on"
        )
        // Cache-first semantics are unchanged: the live app still agrees with
        // what it just chose to persist.
        XCTAssertEqual(store.sessions().map(\.id), ["term-disk-full"])

        store.upsert(NativeOwnedSession(
            id: "term-disk-full-2",
            projectID: "nproj_disk",
            cwd: "/tmp",
            title: "Disk",
            createdAt: 2
        ))
        XCTAssertEqual(
            observed.paths().count,
            1,
            "A failing volume must not turn every write into another toast"
        )
    }

}

/// Write failures are reported from whatever thread performed the write.
private final class CollectedWriteFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [SessionStoreWriteFailure] = []

    func append(_ failure: SessionStoreWriteFailure) {
        lock.lock()
        defer { lock.unlock() }
        failures.append(failure)
    }

    func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures.map(\.path)
    }

    func messages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures.map(\.message)
    }
}
