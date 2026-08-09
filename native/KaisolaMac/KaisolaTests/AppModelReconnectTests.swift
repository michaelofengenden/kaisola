import Combine
import Darwin
import KaisolaBrokerProtocol
import KaisolaCore
import XCTest
@testable import Kaisola

@MainActor
final class AppModelReconnectTests: XCTestCase {
    func testInventoryCompletionRaceRaisesOnlyWorkingToRespondedTransitions() {
        let working = terminal("terminal-working", activity: .working)
        let idle = terminal("terminal-idle", activity: .idle)
        let alreadyResponded = terminal("terminal-old", activity: .responded(at: 10))
        let transitions = AppModel.inventoryCompletionTransitions(
            previous: [working, idle, alreadyResponded],
            next: [
                terminal("terminal-working", activity: .responded(at: 20)),
                terminal("terminal-idle", activity: .responded(at: 20)),
                terminal("terminal-old", activity: .responded(at: 30)),
            ]
        )

        XCTAssertEqual(transitions.map(\.id), ["terminal-working"])
    }

    func testColdConnectRecoversOnlyUnvisitedRespondedSessions() async throws {
        let firstCompletion: Int64 = 1_785_000_200_000
        let secondCompletion: Int64 = 1_785_000_300_000
        let fixture = try Fixture(
            failingConnectAttempts: [],
            completedAtByTerminalID: [
                ReconnectBrokerClient.firstTerminalID: firstCompletion,
                ReconnectBrokerClient.secondTerminalID: secondCompletion,
            ]
        )
        defer { fixture.cleanUp() }

        await fixture.model.reload()

        // The first terminal is automatically restored and visible. The other
        // completed terminal must survive the cold-connect inventory as a
        // durable needs-you entry even though this process never saw it work.
        XCTAssertEqual(
            fixture.attentionCenter.entries.map(\.targetID),
            [ReconnectBrokerClient.secondTerminalID]
        )
        XCTAssertTrue(fixture.attentionCenter.hasAcknowledgedSessionResponse(
            targetID: ReconnectBrokerClient.firstTerminalID,
            completedAt: firstCompletion
        ))

        await fixture.model.select(ReconnectBrokerClient.secondTerminalID)
        XCTAssertTrue(fixture.attentionCenter.entries.isEmpty)
        XCTAssertTrue(fixture.attentionCenter.hasAcknowledgedSessionResponse(
            targetID: ReconnectBrokerClient.secondTerminalID,
            completedAt: secondCompletion
        ))

        // Reconnecting replays both responded rows. Neither badge may return.
        await fixture.model.reload()
        XCTAssertTrue(fixture.attentionCenter.entries.isEmpty)
        await fixture.model.disconnect()
    }

    func testDisconnectRetriesAndResubscribesFromTheVisibleCursor() async throws {
        let fixture = try Fixture(failingConnectAttempts: [2])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        XCTAssertTrue(fixture.model.connectionState.isConnected)
        XCTAssertEqual(fixture.model.terminalDocument.output, "hello")

        await fixture.client.simulateDisconnect()
        await waitUntil {
            let attempts = await fixture.client.connectionAttempts()
            let subscriptions = await fixture.client.subscriptionCursors()
            return attempts >= 3
                && subscriptions.count >= 2
                && fixture.model.connectionState.isConnected
        }

        let attempts = await fixture.client.connectionAttempts()
        let cursors = await fixture.client.subscriptionCursors()
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(cursors, [nil, TerminalCursor(streamEpoch: "epoch", offset: 5)])
        XCTAssertEqual(fixture.model.terminalDocument.output, "hello")
        await fixture.model.disconnect()
    }

    func testContiguousBrokerBurstPublishesOneTerminalDocumentPerDisplayInterval() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        let feed = try XCTUnwrap(fixture.model.terminalSurfaceFeed(
            for: ReconnectBrokerClient.firstTerminalID
        ))
        var terminalPublications = 0
        var shellPublications = 0
        let terminalWatcher = feed.$document.dropFirst().sink { _ in terminalPublications += 1 }
        let shellWatcher = fixture.model.objectWillChange.sink { _ in shellPublications += 1 }
        defer {
            terminalWatcher.cancel()
            shellWatcher.cancel()
        }

        await fixture.client.emitOutput(
            for: ReconnectBrokerClient.firstTerminalID,
            epoch: "epoch",
            startOffset: 5,
            data: " "
        )
        await fixture.client.emitOutput(
            for: ReconnectBrokerClient.firstTerminalID,
            epoch: "epoch",
            startOffset: 6,
            data: "wo"
        )
        await fixture.client.emitOutput(
            for: ReconnectBrokerClient.firstTerminalID,
            epoch: "epoch",
            startOffset: 8,
            data: "rld"
        )
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(fixture.model.terminalDocument.output, "hello world")
        XCTAssertEqual(fixture.model.terminalDocument.cursor?.offset, 11)
        XCTAssertEqual(terminalPublications, 1)
        XCTAssertEqual(shellPublications, 0, "terminal bytes must not invalidate the full IDE shell")
        await fixture.model.disconnect()
    }

    func testSecondaryBrokerBurstPublishesOnlyItsTerminalCard() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        let terminalID = ReconnectBrokerClient.secondTerminalID
        await fixture.model.openInSplit(terminalID)
        _ = try XCTUnwrap(fixture.model.splitDocuments[terminalID])
        let feed = try XCTUnwrap(fixture.model.terminalSurfaceFeed(for: terminalID))
        var terminalPublications = 0
        var shellPublications = 0
        let terminalWatcher = feed.$document.dropFirst().sink { _ in terminalPublications += 1 }
        let shellWatcher = fixture.model.objectWillChange.sink { _ in shellPublications += 1 }
        defer {
            terminalWatcher.cancel()
            shellWatcher.cancel()
        }

        await fixture.client.emitOutput(
            for: terminalID,
            epoch: "epoch-2",
            startOffset: 5,
            data: "!"
        )
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(fixture.model.splitDocuments[terminalID]?.output, "world!")
        XCTAssertEqual(feed.document.output, "world!")
        XCTAssertEqual(terminalPublications, 1)
        XCTAssertEqual(shellPublications, 0, "split bytes must not invalidate the full IDE shell")
        await fixture.model.disconnect()
    }

    func testSettledOfflineStateDoesNotStrobeWhileRetrying() async throws {
        let fixture = try Fixture(failingConnectAttempts: Set(1...500))
        defer { fixture.cleanUp() }
        var transitions: [String] = []
        let watcher = fixture.model.$connectionState.sink { transitions.append($0.title) }
        defer { watcher.cancel() }

        await fixture.model.reload()
        await waitUntil {
            await fixture.client.connectionAttempts() >= 6
        }

        // A session service that keeps refusing settles into one visible
        // unavailable state;
        // the silent retries behind it must not strobe the UI through
        // "Reconnecting" or repeated unavailable flips on every backoff cycle.
        let attempts = await fixture.client.connectionAttempts()
        XCTAssertGreaterThanOrEqual(attempts, 6)
        XCTAssertEqual(transitions.filter { $0 == "Reconnecting" }.count, 0, "state churned: \(transitions)")
        XCTAssertEqual(
            transitions.filter { $0 == "Session Connection Unavailable" }.count,
            1,
            "state churned: \(transitions)"
        )
        await fixture.model.disconnect()
    }

    func testWakeReopensTheSocketWithoutDiscardingVisibleScrollback() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.model.recoverAfterWake()

        let attempts = await fixture.client.connectionAttempts()
        let cursors = await fixture.client.subscriptionCursors()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(cursors, [nil, TerminalCursor(streamEpoch: "epoch", offset: 5)])
        XCTAssertEqual(fixture.model.terminalDocument.output, "hello")
        await fixture.model.disconnect()
    }

    func testWakeRestoresEveryVisibleSecondaryAndPreservesPaneGeometry() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        let before = fixture.model.paneLayout(for: "project.one")
        XCTAssertEqual(before.sessionIDs, [
            ReconnectBrokerClient.firstTerminalID,
            ReconnectBrokerClient.secondTerminalID,
        ])

        await fixture.model.recoverAfterWake()

        XCTAssertEqual(fixture.model.paneLayout(for: "project.one"), before)
        XCTAssertEqual(
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID]?.output,
            "world"
        )
        let wakeSubscriptions = await fixture.client.subscriptionIDs()
        XCTAssertEqual(wakeSubscriptions, [
            ReconnectBrokerClient.firstTerminalID,
            ReconnectBrokerClient.secondTerminalID,
            ReconnectBrokerClient.firstTerminalID,
            ReconnectBrokerClient.secondTerminalID,
        ])
        await fixture.model.disconnect()
    }

    func testColdRestoreSubscribesEveryPersistedVisibleTerminal() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        let layout = SessionPaneLayout(columns: [
            .init(id: "left", sessionIDs: [ReconnectBrokerClient.firstTerminalID], weight: 1.35),
            .init(id: "right", sessionIDs: [ReconnectBrokerClient.secondTerminalID], weight: 0.65),
        ])
        try await fixture.workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: "project.one",
                projects: [NativeProjectWorkspaceState(
                    projectID: "project.one",
                    layout: layout,
                    arrangement: .columns,
                    panes: [
                        Self.terminalPane(ReconnectBrokerClient.firstTerminalID),
                        Self.terminalPane(ReconnectBrokerClient.secondTerminalID),
                    ]
                )]
            )
        )

        await fixture.model.reload()

        XCTAssertEqual(fixture.model.paneLayout(for: "project.one"), layout)
        XCTAssertEqual(fixture.model.selectedProjectID, "project.one")
        XCTAssertEqual(
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID]?.output,
            "world"
        )
        let restoredSubscriptions = await fixture.client.subscriptionIDs()
        XCTAssertEqual(restoredSubscriptions, [
            ReconnectBrokerClient.firstTerminalID,
            ReconnectBrokerClient.secondTerminalID,
        ])
        await fixture.model.disconnect()
    }

    func testMinimizingWhileSecondarySubscribeIsBlockedRejectsLateResult() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.client.setSubscriptionBlocked(
            ReconnectBrokerClient.secondTerminalID,
            blocked: true
        )

        let opening = Task {
            await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        }
        await waitUntil {
            await fixture.client.subscriptionIDs().contains(ReconnectBrokerClient.secondTerminalID)
        }
        await fixture.model.minimizeSurface(ReconnectBrokerClient.secondTerminalID)
        await fixture.client.setSubscriptionBlocked(
            ReconnectBrokerClient.secondTerminalID,
            blocked: false
        )
        await opening.value

        XCTAssertFalse(
            fixture.model.paneLayout(for: "project.one")
                .contains(ReconnectBrokerClient.secondTerminalID)
        )
        XCTAssertNil(fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID])
        await fixture.model.disconnect()
    }

    func testSidebarRevealPublishesPaneBeforeBlockedBrokerSnapshotReturns() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        let terminalID = ReconnectBrokerClient.secondTerminalID
        await fixture.model.reload()
        await fixture.client.setSubscriptionBlocked(terminalID, blocked: true)

        fixture.model.revealSurfaceBeside(terminalID)

        XCTAssertTrue(fixture.model.paneLayout(for: "project.one").contains(terminalID))
        XCTAssertEqual(fixture.model.focusedPaneID, terminalID)
        XCTAssertNil(fixture.model.splitDocuments[terminalID])

        await fixture.client.setSubscriptionBlocked(terminalID, blocked: false)
        await waitUntil {
            fixture.model.splitDocuments[terminalID]?.output == "world"
        }
        await fixture.model.disconnect()
    }

    func testFailedReconnectKeepsLastGoodSecondaryFrame() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        XCTAssertEqual(
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID]?.output,
            "world"
        )
        await fixture.client.setSubscriptionFailure(
            ReconnectBrokerClient.secondTerminalID,
            failing: true
        )

        await fixture.model.recoverAfterWake()

        XCTAssertEqual(
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID]?.output,
            "world"
        )
        XCTAssertTrue(
            fixture.model.paneLayout(for: "project.one")
                .contains(ReconnectBrokerClient.secondTerminalID)
        )
        await fixture.model.disconnect()
    }

    func testReopeningWhileUnsubscribeIsBlockedRestoresSecondarySubscription() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        await fixture.client.setUnsubscribeBlocked(true)

        let minimizing = Task {
            await fixture.model.minimizeSurface(ReconnectBrokerClient.secondTerminalID)
        }
        await waitUntil {
            !fixture.model.paneLayout(for: "project.one")
                .contains(ReconnectBrokerClient.secondTerminalID)
        }
        let reopening = Task {
            await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        }
        await fixture.client.setUnsubscribeBlocked(false)
        await minimizing.value
        await reopening.value
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(
            fixture.model.paneLayout(for: "project.one")
                .contains(ReconnectBrokerClient.secondTerminalID)
        )
        XCTAssertEqual(
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID]?.output,
            "world"
        )
        let subscriptionCount = await fixture.client.subscriptionCount(
            for: ReconnectBrokerClient.secondTerminalID
        )
        // Reopen can invalidate before the old unsubscribe starts (one live
        // subscription) or while it is suspended (a clean replacement).
        XCTAssertTrue((1...2).contains(subscriptionCount))
        await fixture.model.disconnect()
    }

    func testSnapshotRecoveryCannotResurrectMinimizedSecondary() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        await fixture.client.setSubscriptionBlocked(
            ReconnectBrokerClient.secondTerminalID,
            blocked: true
        )
        await fixture.client.emitSnapshotRequired(for: ReconnectBrokerClient.secondTerminalID)
        await waitUntil {
            await fixture.client.subscriptionCount(for: ReconnectBrokerClient.secondTerminalID) >= 2
        }

        await fixture.model.minimizeSurface(ReconnectBrokerClient.secondTerminalID)
        await fixture.client.setSubscriptionBlocked(
            ReconnectBrokerClient.secondTerminalID,
            blocked: false
        )
        await waitUntil {
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID] == nil
        }

        XCTAssertFalse(
            fixture.model.paneLayout(for: "project.one")
                .contains(ReconnectBrokerClient.secondTerminalID)
        )
        XCTAssertNil(fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID])
        await fixture.model.disconnect()
    }

    /// Closing a split card and the terminal vanishing from the broker's
    /// inventory are independent events, so they can land together. The close
    /// captures its intent token, suspends on the cursor write, and the
    /// inventory tick that arrives in that window used to prune the token as
    /// dead weight — the fence then read "superseded", the early return skipped
    /// the teardown, and the card's document held a split slot until reconnect.
    func testInventoryTickDuringSplitTeardownStillReleasesTheSlot() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        let terminalID = ReconnectBrokerClient.secondTerminalID
        await fixture.model.reload()
        await fixture.model.openInSplit(terminalID)
        _ = try XCTUnwrap(fixture.model.splitDocuments[terminalID])

        await fixture.client.setTerminalHidden(terminalID, hidden: true)
        let close = Task { await fixture.model.minimizeSurface(terminalID) }
        await fixture.model.refreshInventory()
        await close.value

        XCTAssertNil(
            fixture.model.splitDocuments[terminalID],
            "The closed card must release its document even when the inventory " +
                "tick that removed the terminal raced the teardown"
        )
        XCTAssertFalse(fixture.model.splitOrder.contains(terminalID))
        XCTAssertFalse(
            fixture.model.paneLayout(for: "project.one").contains(terminalID)
        )
        await fixture.model.disconnect()
    }

    func testReopenDuringStaleSubscribeCleanupReestablishesObserver() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.client.setSubscriptionBlocked(
            ReconnectBrokerClient.secondTerminalID,
            blocked: true
        )
        let firstOpen = Task {
            await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        }
        await waitUntil {
            await fixture.client.subscriptionCount(for: ReconnectBrokerClient.secondTerminalID) == 1
        }
        await fixture.model.minimizeSurface(ReconnectBrokerClient.secondTerminalID)
        await fixture.client.setUnsubscribeBlocked(true)
        await fixture.client.setSubscriptionBlocked(
            ReconnectBrokerClient.secondTerminalID,
            blocked: false
        )
        await waitUntil { await fixture.client.unsubscribeCount() >= 1 }

        let reopen = Task {
            await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        }
        await waitUntil {
            await fixture.client.subscriptionCount(for: ReconnectBrokerClient.secondTerminalID) >= 2
        }
        await fixture.client.setUnsubscribeBlocked(false)
        await firstOpen.value
        await reopen.value
        await waitUntil {
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID]?.output == "world"
        }

        XCTAssertTrue(
            fixture.model.paneLayout(for: "project.one")
                .contains(ReconnectBrokerClient.secondTerminalID)
        )
        XCTAssertEqual(
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID]?.output,
            "world"
        )
        await fixture.model.disconnect()
    }

    func testStaleHiddenCleanupReestablishesTerminalPromotedToPrimary() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        let terminalID = ReconnectBrokerClient.secondTerminalID
        await fixture.model.reload()
        await fixture.client.setSubscriptionBlocked(terminalID, blocked: true)

        let firstOpen = Task { await fixture.model.openInSplit(terminalID) }
        await waitUntil {
            await fixture.client.subscriptionCount(for: terminalID) == 1
        }
        await fixture.model.minimizeSurface(terminalID)
        await fixture.client.setUnsubscribeBlocked(terminalID, blocked: true)
        await fixture.client.setSubscriptionBlocked(terminalID, blocked: false)
        await waitUntil {
            await fixture.client.unsubscribeCount(for: terminalID) == 1
        }

        // The stale cleanup is blocked after the old secondary subscribe won.
        // Promote the now-hidden card, allowing the new primary observer to
        // attach before that destructive cleanup resumes.
        let promotion = Task { await fixture.model.focusSurface(terminalID) }
        await waitUntil {
            let subscriptionCount = await fixture.client.subscriptionCount(for: terminalID)
            let isSubscribed = await fixture.client.isSubscribed(to: terminalID)
            return fixture.model.selectedSessionID == terminalID
                && fixture.model.terminalDocument.output == "world"
                && subscriptionCount >= 2
                && isSubscribed
        }

        await fixture.client.setUnsubscribeBlocked(terminalID, blocked: false)
        await firstOpen.value
        await promotion.value
        await waitUntil {
            let subscriptionCount = await fixture.client.subscriptionCount(for: terminalID)
            let isSubscribed = await fixture.client.isSubscribed(to: terminalID)
            return subscriptionCount >= 3 && isSubscribed
        }

        XCTAssertEqual(fixture.model.selectedSessionID, terminalID)
        XCTAssertEqual(fixture.model.terminalDocument.output, "world")
        let isSubscribed = await fixture.client.isSubscribed(to: terminalID)
        XCTAssertTrue(isSubscribed)
        await fixture.model.disconnect()
    }

    func testTerminalSurfaceDocumentSurvivesSelectionRoundTrip() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        let terminalID = try XCTUnwrap(fixture.model.terminalDocument.sessionID)

        XCTAssertEqual(fixture.model.terminalSurfaceDocuments[terminalID]?.output, "hello")
        XCTAssertEqual(fixture.model.terminalSurfaceOrder, [terminalID])

        await fixture.model.select(nil)
        XCTAssertNil(fixture.model.terminalDocument.sessionID)
        XCTAssertEqual(fixture.model.terminalSurfaceDocuments[terminalID]?.output, "hello")

        await fixture.model.select(terminalID)
        XCTAssertEqual(fixture.model.terminalDocument.output, "hello")
        XCTAssertEqual(fixture.model.terminalSurfaceOrder, [terminalID])
        await fixture.model.disconnect()
    }

    func testSelectionPublishesBeforeBlockedBrokerUnsubscribe() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.client.setUnsubscribeBlocked(true)

        let switchTask = Task { await fixture.model.select(ReconnectBrokerClient.secondTerminalID) }
        await waitUntil {
            fixture.model.selectedSessionID == ReconnectBrokerClient.secondTerminalID
                && fixture.model.terminalDocument.sessionID == ReconnectBrokerClient.secondTerminalID
        }

        // The new retained/loading surface is already visible even though the
        // old broker subscription is deliberately unable to finish closing.
        let subscriptionsWhileBlocked = await fixture.client.subscriptionIDs()
        XCTAssertEqual(subscriptionsWhileBlocked, [ReconnectBrokerClient.firstTerminalID])

        await fixture.client.setUnsubscribeBlocked(false)
        await switchTask.value
        XCTAssertEqual(fixture.model.terminalDocument.output, "world")
        let completedSubscriptions = await fixture.client.subscriptionIDs()
        XCTAssertEqual(completedSubscriptions, [
            ReconnectBrokerClient.firstTerminalID,
            ReconnectBrokerClient.secondTerminalID,
        ])
        await fixture.model.disconnect()
    }

    func testPromotingVisibleSplitRetainsBothDocumentsThroughBrokerHandoff() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.model.openInSplit(ReconnectBrokerClient.secondTerminalID)
        XCTAssertEqual(
            fixture.model.splitDocuments[ReconnectBrokerClient.secondTerminalID]?.output,
            "world"
        )
        await fixture.client.setUnsubscribeBlocked(true)

        let promotion = Task {
            await fixture.model.focusSurface(ReconnectBrokerClient.secondTerminalID)
        }
        await waitUntil {
            fixture.model.terminalSurfaceDocuments[ReconnectBrokerClient.secondTerminalID]?.output == "world"
        }

        // The unified card can keep rendering the same retained document while
        // the broker is deliberately blocked closing the secondary subscription.
        XCTAssertEqual(
            fixture.model.terminalSurfaceDocuments[ReconnectBrokerClient.secondTerminalID]?.output,
            "world"
        )
        XCTAssertEqual(fixture.model.terminalDocument.output, "hello")

        await fixture.client.setUnsubscribeBlocked(false)
        await promotion.value
        XCTAssertEqual(fixture.model.terminalDocument.output, "world")
        XCTAssertEqual(
            fixture.model.splitDocuments[ReconnectBrokerClient.firstTerminalID]?.output,
            "hello"
        )
        await fixture.model.disconnect()
    }

    func testExplicitTranscriptRemovalRejectsLateBufferedSave() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        let chatID = "closing-stream"
        let firstRows: [AcpTranscriptRow] = [.message(id: "before", text: "before close")]
        let lateRows: [AcpTranscriptRow] = [.message(id: "late", text: "buffered after close")]

        fixture.model.enqueueTranscriptSave(firstRows, chatID: chatID)
        fixture.model.enqueueTranscriptRemoval(chatID: chatID)
        fixture.model.enqueueTranscriptSave(lateRows, chatID: chatID)
        await fixture.model.flushTranscriptPersistence()

        let entry = await fixture.transcriptStore.entry(for: chatID)
        XCTAssertNil(entry)
    }

    func testTerminalResizeSendsOnlyLatestSettledGeometryAndDeduplicatesRepeats() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)

        fixture.model.resizeTerminal("visual-terminal", columns: 20, rows: 5)
        fixture.model.resizeTerminal("visual-terminal", columns: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(100))

        let settledResizes = await fixture.control.resizeCalls()
        XCTAssertEqual(
            settledResizes,
            [.init(terminalID: "visual-terminal", columns: 120, rows: 40)]
        )

        fixture.model.resizeTerminal("visual-terminal", columns: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(100))
        let repeatedResizes = await fixture.control.resizeCalls()
        XCTAssertEqual(repeatedResizes.count, 1)
        await fixture.model.disconnect()
    }

    func testCompanionLeaseReleaseForceRestoresLatestDesktopGeometry() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        let terminal = try XCTUnwrap(fixture.model.sessions.first { $0.id == "visual-terminal" })

        fixture.model.resizeTerminal(terminal.id, columns: 128, rows: 42)
        try await Task.sleep(for: .milliseconds(100))
        try await fixture.model.setCompanionControlActive(true, for: terminal)
        // AppKit can continue reporting desktop layout while Companion owns
        // the PTY. It must update desired state without sending it yet.
        fixture.model.resizeTerminal(terminal.id, columns: 140, rows: 46)
        try await fixture.model.setCompanionControlActive(false, for: terminal)
        try await Task.sleep(for: .milliseconds(30))

        let leaseResizes = await fixture.control.resizeCalls()
        XCTAssertEqual(
            Array(leaseResizes.suffix(2)),
            [
                .init(terminalID: terminal.id, columns: 128, rows: 42),
                .init(terminalID: terminal.id, columns: 140, rows: 46),
            ]
        )
        await fixture.model.disconnect()
    }

    func testTerminalInputQueuePreservesExactFIFOBytes() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)

        let acceptedInOneOwnershipEpoch = [
            "text",
            "\u{1B}",
            "\u{1B}[A",
            "\u{1B}[200~pasted line\r\u{1B}[201~",
            "\r",
        ]
        for data in acceptedInOneOwnershipEpoch {
            fixture.model.sendInput(data, to: "visual-terminal")
        }
        await waitUntil {
            await fixture.control.writes().count == acceptedInOneOwnershipEpoch.count
        }

        let writes = await fixture.control.writes()
        XCTAssertEqual(writes, acceptedInOneOwnershipEpoch)
        await fixture.model.disconnect()
    }

    func testStaleSurfaceCallbackCannotWriteAcrossVisualOwnershipFlap() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        defer {
            for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        }
        await fixture.model.reload()
        let fixtureConnectionCount = await fixture.control.connectionCount()
        XCTAssertEqual(
            fixtureConnectionCount,
            0,
            "A fixture-side reload must remain broker-free even if future UI automation invokes it."
        )
        let staleSurfaceCallback = {
            fixture.model.sendInput("stale", to: "visual-terminal")
        }

        // Both packets are accepted while owned but remain queued until the
        // drain task gets an actor turn. Revocation must invalidate that whole
        // capability generation, not leave them waiting for the next owner.
        fixture.model.sendInput("queued-stale-1", to: "visual-terminal")
        fixture.model.sendInput("queued-stale-2", to: "visual-terminal")
        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(false))
        staleSurfaceCallback()
        await Task.yield()
        let staleWrites = await fixture.control.writes()
        XCTAssertTrue(
            staleWrites.isEmpty,
            "AppModel must reject a stale callback even after the view-level capability is revoked."
        )
        XCTAssertEqual(
            ToastCenter.shared.toasts.map(\.message),
            ["Terminal 2" + AppModel.terminalInputDiscardNoticeSuffix],
            "Discard feedback must name the same project-local terminal identity shown in the rail."
        )

        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(true))
        fixture.model.sendInput("live", to: "visual-terminal")
        await waitUntil { await fixture.control.writes().count == 1 }
        let liveWrites = await fixture.control.writes()
        XCTAssertEqual(liveWrites, ["live"])
        await fixture.model.disconnect()
    }

    func testOwnershipFlapDiscardsEveryQueuedInputFormWithOneRedactedNotice() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        defer {
            for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        }

        fixture.model.sendInput("baseline", to: "visual-codex")
        await waitUntil {
            await fixture.control.writes().count == 1
                && fixture.model.terminalDraftTextForTesting("visual-codex") == "baseline"
        }

        let staleInputs = [
            "stale-text-secret",
            "\u{1B}",
            "\u{1B}[A",
            "\u{1B}[200~private pasted command\r\u{1B}[201~",
            "\r",
        ]
        for data in staleInputs {
            fixture.model.sendInput(data, to: "visual-codex")
        }

        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(
            false,
            terminalID: "visual-codex"
        ))
        // A repeated loss callback belongs to the same empty epoch and must not
        // produce another warning after the queue has already been discarded.
        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(
            false,
            terminalID: "visual-codex"
        ))
        fixture.model.sendInput("stale-callback-secret", to: "visual-codex")
        await Task.yield()

        let discardedWrites = await fixture.control.writes()
        XCTAssertEqual(discardedWrites, ["baseline"])
        XCTAssertEqual(
            fixture.model.terminalDraftTextForTesting("visual-codex"),
            "baseline",
            "Discarded text, escape sequences, paste wrappers, and Return must not alter a future draft retype."
        )
        let notices = ToastCenter.shared.toasts
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(
            notices.first?.message,
            "Codex · \(fixture.root.lastPathComponent)"
                + AppModel.terminalInputDiscardNoticeSuffix
        )
        XCTAssertEqual(notices.first?.style, .error)
        for staleInput in staleInputs + ["stale-callback-secret"] where staleInput != "\r" {
            XCTAssertFalse(
                notices.first?.message.contains(staleInput) == true,
                "Discard feedback must never echo terminal input contents."
            )
        }

        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(
            true,
            terminalID: "visual-codex"
        ))
        fixture.model.sendInput("-fresh", to: "visual-codex")
        await waitUntil {
            await fixture.control.writes().count == 2
                && fixture.model.terminalDraftTextForTesting("visual-codex") == "baseline-fresh"
        }
        let resumedWrites = await fixture.control.writes()
        XCTAssertEqual(resumedWrites, ["baseline", "-fresh"])
        XCTAssertEqual(ToastCenter.shared.toasts.count, 1)
        await fixture.model.disconnect()
    }

    func testOwnershipFlapWithoutQueuedInputDoesNotClaimAnythingWasDiscarded() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        defer {
            for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        }

        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(false))

        XCTAssertTrue(ToastCenter.shared.toasts.isEmpty)
        await fixture.model.disconnect()
    }

    func testExplicitQuitSealsQueuedInputSilentlyBeforeItsFirstSuspension() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        defer {
            for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        }

        fixture.model.sendInput("never-send-on-quit", to: "visual-codex")
        await fixture.model.releaseOwnedSessionsForQuit()
        await Task.yield()

        let writes = await fixture.control.writes()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(fixture.model.terminalDraftTextForTesting("visual-codex"))
        XCTAssertTrue(
            ToastCenter.shared.toasts.isEmpty,
            "An explicit quit is intentional and must not show ownership-loss feedback."
        )
        await fixture.model.disconnect()
    }

    func testLateOldEpochSuccessCannotDrainResidueOrPublishStaleAgentTurn() async throws {
        let fixture = try GatedVisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        defer {
            for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        }

        fixture.model.sendInput("old-head\r", to: "visual-codex")
        await fixture.control.waitForAttemptCount(1)
        fixture.model.sendInput("old-tail", to: "visual-codex")
        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(
            false,
            terminalID: "visual-codex"
        ))
        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(
            true,
            terminalID: "visual-codex"
        ))

        fixture.model.sendInput("fresh-head\r", to: "visual-codex")
        await fixture.control.waitForAttemptCount(2)
        await fixture.control.resolveAttempt(0, with: .success)
        await Task.yield()

        // A late generation-zero defer must not clear generation one's drain.
        // This packet stays behind fresh-head until its acknowledgement.
        fixture.model.sendInput("fresh-tail", to: "visual-codex")
        await Task.yield()
        let attemptsBeforeFreshAcknowledgement = await fixture.control.writeAttempts()
        XCTAssertEqual(
            attemptsBeforeFreshAcknowledgement,
            ["old-head\r", "fresh-head\r"]
        )

        await fixture.control.resolveAttempt(1, with: .success)
        await fixture.control.waitForAttemptCount(3)
        let allAttempts = await fixture.control.writeAttempts()
        XCTAssertEqual(
            allAttempts,
            ["old-head\r", "fresh-head\r", "fresh-tail"]
        )
        await fixture.control.resolveAttempt(2, with: .success)
        await waitUntil { await fixture.control.successfulWrites().count == 3 }

        let agentTurnCount = await fixture.control.agentTurnCount()
        XCTAssertEqual(agentTurnCount, 1)
        XCTAssertEqual(
            fixture.model.terminalDraftTextForTesting("visual-codex"),
            "fresh-tail",
            "A late old-epoch acknowledgement must not mutate the persisted composer."
        )
        XCTAssertEqual(ToastCenter.shared.toasts.count, 1)
        await fixture.model.disconnect()
    }

    func testLateOldEpochFailureCannotInvalidateReplacementEpochOrDuplicateFeedback() async throws {
        let fixture = try GatedVisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        defer {
            for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        }

        fixture.model.sendInput("old-in-flight", to: "visual-codex")
        await fixture.control.waitForAttemptCount(1)
        fixture.model.sendInput("old-never-attempted", to: "visual-codex")
        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(
            false,
            terminalID: "visual-codex"
        ))
        XCTAssertTrue(fixture.model.setVisualFixtureTerminalOwnership(
            true,
            terminalID: "visual-codex"
        ))

        fixture.model.sendInput("fresh-one", to: "visual-codex")
        await fixture.control.waitForAttemptCount(2)
        await fixture.control.resolveAttempt(0, with: .failure)
        await fixture.control.resolveAttempt(1, with: .success)
        await waitUntil { await fixture.control.successfulWrites() == ["fresh-one"] }

        fixture.model.sendInput("fresh-two", to: "visual-codex")
        await fixture.control.waitForAttemptCount(3)
        await fixture.control.resolveAttempt(2, with: .success)
        await waitUntil { await fixture.control.successfulWrites().count == 2 }

        let attempts = await fixture.control.writeAttempts()
        XCTAssertEqual(
            attempts,
            ["old-in-flight", "fresh-one", "fresh-two"]
        )
        XCTAssertTrue(fixture.model.isOwned("visual-codex"))
        XCTAssertEqual(
            ToastCenter.shared.toasts.count,
            1,
            "The discard notice already explains the flap; a stale failure must not add a generic recovery warning."
        )
        await fixture.model.disconnect()
    }

    func testTerminalWriteTimeoutDegradesOnlyThatTerminal() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        await fixture.control.failNextWrite(to: "visual-terminal")

        fixture.model.sendInput("uncertain", to: "visual-terminal")
        await waitUntil {
            fixture.model.isTerminalInputDegraded("visual-terminal")
        }

        XCTAssertTrue(fixture.model.connectionState.isConnected)
        XCTAssertTrue(fixture.model.controlAvailable)
        XCTAssertTrue(fixture.model.isOwned("visual-terminal"))
        XCTAssertTrue(fixture.model.isOwned("visual-codex"))
        let failedTerminalAttemptCount = await fixture.control.writeAttemptCount(for: "visual-terminal")
        XCTAssertEqual(
            failedTerminalAttemptCount,
            1,
            "a timed-out terminal.write has an unknown outcome and must never be replayed"
        )

        fixture.model.sendInput("must stay blocked", to: "visual-terminal")
        await Task.yield()
        let blockedTerminalAttemptCount = await fixture.control.writeAttemptCount(for: "visual-terminal")
        XCTAssertEqual(
            blockedTerminalAttemptCount,
            1,
            "later input must remain quarantined until the controller is explicitly re-established"
        )

        fixture.model.sendInput("still works", to: "visual-codex")
        await waitUntil { await fixture.control.writes().count == 1 }

        let successfulWrites = await fixture.control.writes()
        XCTAssertEqual(successfulWrites, ["still works"])
        XCTAssertFalse(fixture.model.isTerminalInputDegraded("visual-codex"))
        XCTAssertTrue(fixture.model.isOwned("visual-codex"))

        let controllerConnectionsBeforeRecovery = await fixture.control.connectionCount()
        await fixture.model.recoverTerminalInput("visual-terminal")
        XCTAssertFalse(fixture.model.isTerminalInputDegraded("visual-terminal"))
        XCTAssertTrue(fixture.model.isOwned("visual-terminal"))
        let targetedAttachCalls = await fixture.control.attachCalls()
        XCTAssertEqual(targetedAttachCalls, ["visual-terminal"])
        let controllerConnectionsAfterRecovery = await fixture.control.connectionCount()
        XCTAssertEqual(
            controllerConnectionsAfterRecovery,
            controllerConnectionsBeforeRecovery,
            "recovering one terminal must not reconnect the shared controller or observer"
        )

        fixture.model.sendInput("resumed", to: "visual-terminal")
        await waitUntil { await fixture.control.writes().count == 2 }
        let writesAfterRecovery = await fixture.control.writes()
        XCTAssertEqual(writesAfterRecovery, ["still works", "resumed"])
        await fixture.model.disconnect()
    }

    func testInputToAnUnownedTerminalExplainsItselfInsteadOfVanishing() async throws {
        let fixture = try Fixture(failingConnectAttempts: Set(2...20))
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        XCTAssertTrue(fixture.model.connectionState.isConnected)

        // Connection loss clears ownership while the owned surface is still
        // mounted, so its keystrokes still route here. Those bytes used to
        // vanish with no explanation — the same silence the 2026-08-07
        // phantom-owner incident turned into "typing is broken".
        await fixture.client.failNextInventoryRequests(3)
        await fixture.model.refreshInventory()
        await fixture.model.refreshInventory()
        await fixture.model.refreshInventory()
        XCTAssertFalse(fixture.model.connectionState.isConnected)

        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        fixture.model.sendInput("x", to: ReconnectBrokerClient.firstTerminalID)
        XCTAssertEqual(
            ToastCenter.shared.toasts.last?.message,
            "Terminal connection is recovering; input was not sent"
        )
        await fixture.model.disconnect()
    }

    func testAcknowledgedAgentTurnOpensLocalActivityAndLeavesUpdatesFlowing() async throws {
        let fixture = try AgentTurnGateFixture(agentTurnAccepted: true)
        defer { fixture.cleanUp() }
        await fixture.model.reload()

        fixture.model.sendInput("go\r", to: fixture.terminalID)
        await waitUntil { await fixture.control.agentTurnCalls() == [true] }

        XCTAssertEqual(fixture.model.openAgentTurnTerminalIDs, [fixture.terminalID])
        XCTAssertTrue(fixture.model.agentTurnSignalFailureTerminalIDs.isEmpty)
        XCTAssertTrue(fixture.model.unprotectedAgentTurnTerminalIDs.isEmpty)
        XCTAssertNil(fixture.model.brokerUpdateGateBlockedDetail)

        let before = await fixture.upgradeAttempts.count()
        await fixture.model.refreshInventory()
        let after = await fixture.upgradeAttempts.count()
        XCTAssertEqual(after, before + 1, "An acknowledged turn leaves the update gate open.")
        await fixture.model.disconnect()
    }

    func testRefusedAgentTurnLeavesNoLocalTurnAndShutsTheUpdateGate() async throws {
        let fixture = try AgentTurnGateFixture(agentTurnAccepted: false)
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }

        // The broker refuses the turn, so it still counts this terminal idle
        // and would accept a rolling cutover underneath the running agent.
        fixture.model.sendInput("go\r", to: fixture.terminalID)
        await waitUntil { await fixture.control.agentTurnCalls() == [true] }

        XCTAssertTrue(fixture.model.openAgentTurnTerminalIDs.isEmpty)
        XCTAssertEqual(fixture.model.agentTurnSignalFailureTerminalIDs, [fixture.terminalID])
        XCTAssertEqual(fixture.model.unprotectedAgentTurnTerminalIDs, [fixture.terminalID])
        XCTAssertNotNil(fixture.model.brokerUpdateGateBlockedDetail)
        XCTAssertEqual(
            ToastCenter.shared.toasts.last?.message,
            "Agent activity could not be reported; terminal-continuity updates are paused"
        )

        // A refused signal must not cost the keystrokes themselves.
        let writes = await fixture.control.writes()
        XCTAssertEqual(writes, ["go\r"])

        let before = await fixture.upgradeAttempts.count()
        await fixture.model.refreshInventory()
        let after = await fixture.upgradeAttempts.count()
        XCTAssertEqual(after, before, "An unprotected turn must hold the update gate shut.")
        await fixture.model.disconnect()
    }

    func testStaleAttentionJumpLeavesCurrentSurfaceSelected() async throws {
        let fixture = try VisualControlFixture()
        defer { fixture.cleanUp() }
        fixture.model.loadVisualFixture(workspace: fixture.root)
        let selected = fixture.model.selectedSessionID

        fixture.model.jumpToAttentionTarget("closed-or-stale-surface")

        XCTAssertEqual(fixture.model.selectedSessionID, selected)
        await fixture.model.disconnect()
    }

    func testThreeInventoryTimeoutsForceAReconnectInsteadOfStayingFalselyConnected() async throws {
        let fixture = try Fixture(failingConnectAttempts: Set(2...20))
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.client.failNextInventoryRequests(3)

        await fixture.model.refreshInventory()
        await fixture.model.refreshInventory()
        XCTAssertTrue(fixture.model.connectionState.isConnected)
        await fixture.model.refreshInventory()

        await waitUntil { await fixture.client.connectionAttempts() >= 2 }
        XCTAssertFalse(fixture.model.connectionState.isConnected)
        await fixture.model.disconnect()
    }

    func testControllerLaneDisconnectReconnectsAndReattachesOwnership() async throws {
        let fixture = try ControllerReconnectFixture()
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        let initialControlConnections = await fixture.control.connectionCount()
        XCTAssertEqual(initialControlConnections, 1)

        await fixture.control.simulateDisconnect()
        // The control lane reattaches *after* the observer lane comes back, so
        // waiting only on the observer made this assert against a half-finished
        // reconnect roughly one run in five.
        await waitUntil {
            let attempts = await fixture.client.connectionAttempts()
            let controlConnections = await fixture.control.connectionCount()
            let attachCalls = await fixture.control.attachCalls()
            return attempts >= 2
                && fixture.model.connectionState.isConnected
                && controlConnections >= 2
                && attachCalls.count >= 2
        }

        let controlConnections = await fixture.control.connectionCount()
        let attachCalls = await fixture.control.attachCalls()
        XCTAssertGreaterThanOrEqual(controlConnections, 2)
        XCTAssertGreaterThanOrEqual(attachCalls.count, 2)
        await fixture.model.disconnect()
    }

    private func waitUntil(
        iterations: Int = 500,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("The reconnect state machine did not settle")
    }

    private func terminal(_ id: String, activity: AgentActivity) -> BrokerTerminalRecord {
        BrokerTerminalRecord(
            id: id,
            projectID: "project.one",
            pid: 123,
            exited: false,
            streamEpoch: "epoch",
            endOffset: 0,
            agentActivity: activity
        )
    }

    private static func terminalPane(_ id: String) -> NativeRestorablePaneState {
        NativeRestorablePaneState(
            id: id,
            surface: NativeRestorableSurfaceState(
                kind: .terminal,
                id: id,
                projectID: "project.one",
                title: id
            )
        )
    }
}

private struct RecordedTerminalResize: Equatable, Sendable {
    let terminalID: String
    let columns: Int
    let rows: Int
}

private actor RecordingBrokerControlClient: BrokerControlServing {
    private var recordedResizes: [RecordedTerminalResize] = []
    private var recordedWrites: [String] = []
    private var writeFailuresRemainingByTerminalID: [String: Int] = [:]
    private var writeAttemptCountsByTerminalID: [String: Int] = [:]
    private var disconnectHandler: (@Sendable (any Error) -> Void)?
    private var connectCount = 0
    private var recordedAttaches: [String] = []
    private let agentTurnAccepted: Bool
    private var recordedAgentTurns: [Bool] = []

    init(agentTurnAccepted: Bool = true) {
        self.agentTurnAccepted = agentTurnAccepted
    }

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        disconnectHandler = handler
    }

    func connect(to info: BrokerInfo, ownerID: String) async throws {
        connectCount += 1
    }

    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int,
        restore: Bool
    ) async throws -> TerminalCreation {
        TerminalCreation(
            terminalID: terminalID,
            projectID: projectID,
            pid: 1,
            streamEpoch: "recording"
        )
    }

    func attach(projectID: String, terminalID: String) async throws {
        recordedAttaches.append(terminalID)
    }

    func write(projectID: String, terminalID: String, data: String) async throws {
        // Yield here so the test exercises AppModel's serializer rather than
        // accidentally relying on immediately completing actor calls.
        await Task.yield()
        writeAttemptCountsByTerminalID[terminalID, default: 0] += 1
        if writeFailuresRemainingByTerminalID[terminalID, default: 0] > 0 {
            writeFailuresRemainingByTerminalID[terminalID, default: 0] -= 1
            throw BrokerClientError.requestTimedOut
        }
        recordedWrites.append(data)
    }

    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {
        recordedResizes.append(.init(terminalID: terminalID, columns: columns, rows: rows))
    }

    func kill(projectID: String, terminalID: String) async throws {}
    func release(projectID: String, terminalID: String) async throws {}
    func detachOwner(projectID: String, terminalID: String) async throws {}
    /// Mirrors `BrokerControlClient`, which now turns the broker's inner
    /// `{ok:false}` into this error instead of discarding it.
    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws {
        recordedAgentTurns.append(busy)
        guard agentTurnAccepted else {
            throw BrokerClientError.requestFailed("terminal.agentTurn")
        }
    }

    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws {}
    func disconnect() async {}

    func resizeCalls() -> [RecordedTerminalResize] { recordedResizes }
    func agentTurnCalls() -> [Bool] { recordedAgentTurns }
    func writes() -> [String] { recordedWrites }
    func failNextWrite(to terminalID: String) {
        writeFailuresRemainingByTerminalID[terminalID, default: 0] += 1
    }
    func writeAttemptCount(for terminalID: String) -> Int {
        writeAttemptCountsByTerminalID[terminalID, default: 0]
    }
    func connectionCount() -> Int { connectCount }
    func attachCalls() -> [String] { recordedAttaches }
    func simulateDisconnect() { disconnectHandler?(BrokerClientError.connectionClosed) }
}

private enum GatedWriteResolution: Sendable {
    case success
    case failure
}

/// A cancellation-resistant transport double: ownership can change while the
/// old request remains suspended, then the test chooses whether its late
/// completion is success or failure. Attempts and acknowledgements are kept
/// separate so no sleep or wall-clock threshold defines the epoch boundary.
private actor GatedBrokerControlClient: BrokerControlServing {
    private struct AttemptWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var attempts: [String] = []
    private var successes: [String] = []
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var attemptWaiters: [AttemptWaiter] = []
    private var agentTurns = 0

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {}
    func connect(to info: BrokerInfo, ownerID: String) async throws {}

    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int,
        restore: Bool
    ) async throws -> TerminalCreation {
        TerminalCreation(
            terminalID: terminalID,
            projectID: projectID,
            pid: 1,
            streamEpoch: "gated"
        )
    }

    func attach(projectID: String, terminalID: String) async throws {}

    func write(projectID: String, terminalID: String, data: String) async throws {
        let index = attempts.count
        attempts.append(data)
        resumeSatisfiedWaiters()
        try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
        }
        successes.append(data)
    }

    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {}
    func kill(projectID: String, terminalID: String) async throws {}
    func release(projectID: String, terminalID: String) async throws {}
    func detachOwner(projectID: String, terminalID: String) async throws {}

    func setAgentTurn(
        projectID: String,
        terminalID: String,
        busy: Bool
    ) async throws {
        if busy { agentTurns += 1 }
    }

    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws {}

    func disconnect() async {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: BrokerClientError.connectionClosed)
        }
    }

    func waitForAttemptCount(_ count: Int) async {
        if attempts.count >= count { return }
        await withCheckedContinuation { continuation in
            attemptWaiters.append(AttemptWaiter(count: count, continuation: continuation))
        }
    }

    func resolveAttempt(_ index: Int, with resolution: GatedWriteResolution) {
        guard let continuation = pending.removeValue(forKey: index) else { return }
        switch resolution {
        case .success:
            continuation.resume()
        case .failure:
            continuation.resume(throwing: BrokerClientError.connectionClosed)
        }
    }

    func writeAttempts() -> [String] { attempts }
    func successfulWrites() -> [String] { successes }
    func agentTurnCount() -> Int { agentTurns }

    private func resumeSatisfiedWaiters() {
        var remaining: [AttemptWaiter] = []
        for waiter in attemptWaiters {
            if attempts.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        attemptWaiters = remaining
    }
}

@MainActor
private final class VisualControlFixture {
    let root: URL
    let control = RecordingBrokerControlClient()
    let model: AppModel

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptStore = AcpTranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        model = AppModel(
            controlClient: control,
            sessionStore: NativeSessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: root.appendingPathComponent("workspace.json")),
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            attentionCenter: AttentionCenter(
                defaults: UserDefaults(suiteName: "kaisola-control-\(UUID().uuidString)")!,
                postsNotifications: false,
                updatesDockBadge: false
            )
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class GatedVisualControlFixture {
    let root: URL
    let control = GatedBrokerControlClient()
    let model: AppModel

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-gated-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptStore = AcpTranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        model = AppModel(
            controlClient: control,
            sessionStore: NativeSessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: root.appendingPathComponent("workspace.json")),
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            attentionCenter: AttentionCenter(
                defaults: UserDefaults(suiteName: "kaisola-gated-control-\(UUID().uuidString)")!,
                postsNotifications: false,
                updatesDockBadge: false
            )
        )
    }

    func cleanUp() {
        Task { await control.disconnect() }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ControllerReconnectFixture {
    let root: URL
    let client = ReconnectBrokerClient(failingConnectAttempts: [])
    let control = RecordingBrokerControlClient()
    let model: AppModel

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-controller-reconnect-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionStore = NativeSessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        sessionStore.upsert(NativeOwnedSession(
            id: ReconnectBrokerClient.firstTerminalID,
            projectID: "project.one",
            cwd: root.path,
            title: "Controller reconnect",
            createdAt: 1
        ))
        let transcriptStore = AcpTranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        model = AppModel(
            brokerPreparer: LocatedBrokerInfoPreparer(locator: FixedBrokerLocator(info: Self.brokerInfo)),
            client: client,
            controlClient: control,
            sessionStore: sessionStore,
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: root.appendingPathComponent("workspace.json")),
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            attentionCenter: AttentionCenter(
                defaults: UserDefaults(suiteName: "kaisola-controller-reconnect-\(UUID().uuidString)")!,
                postsNotifications: false,
                updatesDockBadge: false
            ),
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 1,
                maximumNanoseconds: 2,
                jitterFraction: 0
            ),
            sleep: { nanoseconds in
                if nanoseconds >= 1_000_000_000 {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } else {
                    await Task.yield()
                }
            },
            jitter: { 0 }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static var brokerInfo: BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            pid: 12_345,
            socketPath: "/tmp/kaisola-controller-reconnect.sock",
            token: String(repeating: "b", count: 64),
            startedAt: 1_784_250_001_000,
            version: "test"
        )
    }
}

private actor UpgradeAttemptRecorder {
    private var attempts = 0

    func record() { attempts += 1 }
    func count() -> Int { attempts }
}

/// A preparer that is also the upgrade monitor, so a test can see whether the
/// app asked for a terminal-continuity update on an inventory tick.
private struct MonitoredBrokerPreparer: BrokerInfoPreparing, BrokerUpgradeMonitoring {
    let info: BrokerInfo
    let attempts: UpgradeAttemptRecorder

    func prepare() async throws -> BrokerInfo { info }

    func upgradeState() async -> BrokerUpgradeState { .unknown }

    func attemptUpgradeIfNeeded() async -> BrokerUpgradeState {
        await attempts.record()
        return .unknown
    }

    func retirementDiagnostics() async -> [BrokerRetirementDiagnostic] { [] }
}

/// An owned agent terminal on a broker whose upgrade monitor is observable,
/// so the agent-turn signal and the update gate can be exercised together.
@MainActor
private final class AgentTurnGateFixture {
    let root: URL
    let client = ReconnectBrokerClient(failingConnectAttempts: [])
    let control: RecordingBrokerControlClient
    let upgradeAttempts = UpgradeAttemptRecorder()
    let model: AppModel

    var terminalID: String { ReconnectBrokerClient.firstTerminalID }

    init(agentTurnAccepted: Bool) throws {
        control = RecordingBrokerControlClient(agentTurnAccepted: agentTurnAccepted)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-agent-turn-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionStore = NativeSessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        sessionStore.upsert(NativeOwnedSession(
            id: ReconnectBrokerClient.firstTerminalID,
            projectID: "project.one",
            cwd: root.path,
            title: "Codex · agent turn",
            createdAt: 1,
            agentID: "codex"
        ))
        let transcriptStore = AcpTranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        model = AppModel(
            brokerPreparer: MonitoredBrokerPreparer(info: Self.brokerInfo, attempts: upgradeAttempts),
            client: client,
            controlClient: control,
            sessionStore: sessionStore,
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: root.appendingPathComponent("workspace.json")),
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            attentionCenter: AttentionCenter(
                defaults: UserDefaults(suiteName: "kaisola-agent-turn-\(UUID().uuidString)")!,
                postsNotifications: false,
                updatesDockBadge: false
            ),
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 1,
                maximumNanoseconds: 2,
                jitterFraction: 0
            ),
            sleep: { nanoseconds in
                if nanoseconds >= 1_000_000_000 {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } else {
                    await Task.yield()
                }
            },
            jitter: { 0 }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static var brokerInfo: BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            pid: 12_345,
            socketPath: "/tmp/kaisola-agent-turn.sock",
            token: String(repeating: "c", count: 64),
            startedAt: 1_784_250_001_000,
            version: "test"
        )
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let client: ReconnectBrokerClient
    let transcriptStore: AcpTranscriptStore
    let workspaceStore: NativeWorkspaceStateStore
    let attentionCenter: AttentionCenter
    let model: AppModel

    init(
        failingConnectAttempts: Set<Int>,
        completedAtByTerminalID: [String: Int64] = [:]
    ) throws {
        root = URL(fileURLWithPath: "/tmp/kaisola-app-model-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(root.path, 0o700)
        client = ReconnectBrokerClient(
            failingConnectAttempts: failingConnectAttempts,
            completedAtByTerminalID: completedAtByTerminalID
        )
        transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("agent-chat-transcripts-v1.json")
        )
        workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        let defaultsSuite = "kaisola-app-model-attention-\(UUID().uuidString)"
        let attentionDefaults = UserDefaults(suiteName: defaultsSuite)!
        attentionDefaults.removePersistentDomain(forName: defaultsSuite)
        attentionCenter = AttentionCenter(
            defaults: attentionDefaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        model = AppModel(
            brokerPreparer: LocatedBrokerInfoPreparer(locator: FixedBrokerLocator(info: Self.brokerInfo)),
            client: client,
            sessionStore: NativeSessionStore(fileURL: root.appendingPathComponent("native-sessions.json")),
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            attentionCenter: attentionCenter,
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 1,
                maximumNanoseconds: 2,
                jitterFraction: 0
            ),
            sleep: { nanoseconds in
                // Keep nanosecond reconnect backoffs deterministic and fast,
                // but do not turn the 2.5-second inventory poll into a hot
                // loop. That unrelated refresh publishes structural model
                // state and can race terminal-card isolation assertions on a
                // slower CI host.
                if nanoseconds >= 1_000_000_000 {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } else {
                    await Task.yield()
                }
            },
            jitter: { 0 }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static var brokerInfo: BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            pid: 12_345,
            socketPath: "/tmp/kaisola-app-model.sock",
            token: String(repeating: "a", count: 64),
            startedAt: 1_784_250_001_000,
            version: "test"
        )
    }
}

private struct FixedBrokerLocator: BrokerInfoLocating {
    let info: BrokerInfo

    func locate() throws -> BrokerInfo { info }
}

private actor ReconnectBrokerClient: ObserveOnlyBrokerServing {
    static let firstTerminalID = "terminal:codex-1"
    static let secondTerminalID = "terminal:codex-2"

    private let failingConnectAttempts: Set<Int>
    private let completedAtByTerminalID: [String: Int64]
    private var connectCount = 0
    private var inventoryFailuresRemaining = 0
    private var cursors: [TerminalCursor?] = []
    private var subscribedTerminalIDs: [String] = []
    private var activeTerminalIDs: Set<String> = []
    private var ownerIDsByTerminal: [String: String] = [:]
    private var hiddenTerminalIDs: Set<String> = []
    private var blockedSubscriptionIDs: Set<String> = []
    private var failingSubscriptionIDs: Set<String> = []
    private var unsubscribeBlocked = false
    private var blockedUnsubscribeIDs: Set<String> = []
    private var unsubscribeCalls = 0
    private var unsubscribedTerminalIDs: [String] = []
    private var eventHandler: (@Sendable (BrokerEvent) -> Void)?
    private var disconnectHandler: (@Sendable (any Error) -> Void)?

    init(
        failingConnectAttempts: Set<Int>,
        completedAtByTerminalID: [String: Int64] = [:]
    ) {
        self.failingConnectAttempts = failingConnectAttempts
        self.completedAtByTerminalID = completedAtByTerminalID
    }

    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {
        eventHandler = handler
    }

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        disconnectHandler = handler
    }

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        connectCount += 1
        if failingConnectAttempts.contains(connectCount) {
            throw BrokerClientError.connectionClosed
        }
        return BrokerHello(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: nil,
            packageVersion: nil,
            features: [BrokerWire.terminalObserveFeature, BrokerWire.observerRoleFeature],
            pid: info.pid,
            startedAt: info.startedAt,
            version: info.version,
            serverEnforcedObserver: true
        )
    }

    func inventory() async throws -> BrokerStatus {
        if inventoryFailuresRemaining > 0 {
            inventoryFailuresRemaining -= 1
            throw BrokerClientError.requestTimedOut
        }
        let expectedHello = BrokerHello(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: nil,
            packageVersion: nil,
            features: [BrokerWire.terminalObserveFeature, BrokerWire.observerRoleFeature],
            pid: 12_345,
            startedAt: 1_784_250_001_000,
            version: "test",
            serverEnforcedObserver: true
        )
        var firstLive: [String: JSONValue] = [
            "id": .string(Self.firstTerminalID),
            "pid": .integer(123),
        ]
        if let completedAt = completedAtByTerminalID[Self.firstTerminalID] {
            firstLive["agentCompletedAt"] = .integer(completedAt)
        }
        var secondLive: [String: JSONValue] = [
            "id": .string(Self.secondTerminalID),
            "pid": .integer(124),
        ]
        if let completedAt = completedAtByTerminalID[Self.secondTerminalID] {
            secondLive["agentCompletedAt"] = .integer(completedAt)
        }
        return try BrokerStatus(
            status: .object([
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
            ]),
            diagnostics: .array([
                .object([
                    "id": .string(Self.firstTerminalID),
                    "owner": .string("instance|42|project.one"),
                    "pid": .integer(123),
                    "streamEpoch": .string("epoch"),
                    "endOffset": .integer(5),
                ]),
                .object([
                    "id": .string(Self.secondTerminalID),
                    "owner": .string("instance|42|project.one"),
                    "pid": .integer(124),
                    "streamEpoch": .string("epoch-2"),
                    "endOffset": .integer(5),
                ]),
            ].filter { record in
                guard case .object(let fields) = record,
                      case .string(let id)? = fields["id"] else { return true }
                return !hiddenTerminalIDs.contains(id)
            }),
            live: .array([
                .object(firstLive),
                .object(secondLive),
            ].filter { record in
                guard case .object(let fields) = record,
                      case .string(let id)? = fields["id"] else { return true }
                return !hiddenTerminalIDs.contains(id)
            }),
            expectedHello: expectedHello
        )
    }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        cursors.append(cursor)
        subscribedTerminalIDs.append(terminal.id)
        ownerIDsByTerminal[terminal.id] = ownerID
        while blockedSubscriptionIDs.contains(terminal.id) { await Task.yield() }
        if failingSubscriptionIDs.contains(terminal.id) {
            throw BrokerClientError.connectionClosed
        }
        activeTerminalIDs.insert(terminal.id)
        if let cursor { return .current(cursor) }
        let output = terminal.id == Self.secondTerminalID ? "world" : "hello"
        let epoch = terminal.id == Self.secondTerminalID ? "epoch-2" : "epoch"
        return .snapshot(
            try TerminalSnapshot(value: .object([
                "streamEpoch": .string(epoch),
                "output": .string(output),
                "startOffset": .integer(0),
                "endOffset": .integer(5),
            ])),
            resetReason: nil
        )
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {
        unsubscribeCalls += 1
        unsubscribedTerminalIDs.append(terminal.id)
        while unsubscribeBlocked || blockedUnsubscribeIDs.contains(terminal.id) {
            await Task.yield()
        }
        activeTerminalIDs.remove(terminal.id)
    }
    func disconnect() async {}

    func simulateDisconnect() {
        disconnectHandler?(BrokerClientError.connectionClosed)
    }

    func emitOutput(for id: String, epoch: String, startOffset: Int64, data: String) {
        guard let ownerID = ownerIDsByTerminal[id] else { return }
        eventHandler?(BrokerEvent(
            ownerID: ownerID,
            projectID: "project.one",
            terminalID: id,
            kind: .output(
                epoch: epoch,
                startOffset: startOffset,
                endOffset: startOffset + Int64(data.utf8.count),
                data: data
            )
        ))
    }

    func connectionAttempts() -> Int { connectCount }
    func failNextInventoryRequests(_ count: Int) {
        inventoryFailuresRemaining = max(0, count)
    }
    func subscriptionCursors() -> [TerminalCursor?] { cursors }
    func subscriptionIDs() -> [String] { subscribedTerminalIDs }
    func subscriptionCount(for id: String) -> Int {
        subscribedTerminalIDs.filter { $0 == id }.count
    }
    func unsubscribeCount() -> Int { unsubscribeCalls }
    func unsubscribeCount(for id: String) -> Int {
        unsubscribedTerminalIDs.filter { $0 == id }.count
    }
    func isSubscribed(to id: String) -> Bool { activeTerminalIDs.contains(id) }
    func setUnsubscribeBlocked(_ blocked: Bool) { unsubscribeBlocked = blocked }
    func setUnsubscribeBlocked(_ id: String, blocked: Bool) {
        if blocked { blockedUnsubscribeIDs.insert(id) }
        else { blockedUnsubscribeIDs.remove(id) }
    }
    func setSubscriptionFailure(_ id: String, failing: Bool) {
        if failing { failingSubscriptionIDs.insert(id) }
        else { failingSubscriptionIDs.remove(id) }
    }
    /// Drop a terminal from the authoritative inventory, as the broker does
    /// once its process exits.
    func setTerminalHidden(_ id: String, hidden: Bool) {
        if hidden { hiddenTerminalIDs.insert(id) } else { hiddenTerminalIDs.remove(id) }
    }

    func setSubscriptionBlocked(_ id: String, blocked: Bool) {
        if blocked {
            blockedSubscriptionIDs.insert(id)
        } else {
            blockedSubscriptionIDs.remove(id)
        }
    }

    func emitSnapshotRequired(for id: String) {
        guard let ownerID = ownerIDsByTerminal[id] else { return }
        guard let event = BrokerEvent(frame: .object([
            "type": .string("event"),
            "ownerId": .string(ownerID),
            "projectId": .string("project.one"),
            "channel": .string("terminal:observer-snapshot-required"),
            "payload": .object(["id": .string(id)]),
        ])) else { return }
        eventHandler?(event)
    }
}
