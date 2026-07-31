import Foundation
import UserNotifications
import XCTest
@testable import Kaisola

/// Covers only the pure, deterministic surface of `NotificationBridge`: the
/// persisted enable flag and the `post()` gate. The real UserNotifications path
/// is never exercised here — `UNUserNotificationCenter.current()` traps in the
/// unbundled test host, so every test either stays behind the enable/background
/// guards or installs `postHook` (which returns before any UN access).
@MainActor
final class NotificationBridgeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "kaisola-notification-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - enabled flag

    func testEnabledDefaultsToTrue() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        XCTAssertTrue(bridge.enabled)
    }

    func testEnabledPersistsRoundTrip() {
        let defaults = makeDefaults()
        let bridge = NotificationBridge(defaults: defaults)
        XCTAssertTrue(bridge.enabled)

        bridge.enabled = false
        let reloaded = NotificationBridge(defaults: defaults)
        XCTAssertFalse(reloaded.enabled)

        reloaded.enabled = true
        let reloadedAgain = NotificationBridge(defaults: defaults)
        XCTAssertTrue(reloadedAgain.enabled)
    }

    // MARK: - post() gate

    func testPostRecordsWhenBackgroundAndEnabled() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.appIsActiveProvider = { false }   // app in the background
        var recorded: [NotificationBridge.PostRequest] = []
        bridge.postHook = { recorded.append($0) }

        bridge.post(kind: .permission, title: "Needs you", detail: "Approve edit", targetID: "chat-42")

        XCTAssertEqual(recorded, [
            NotificationBridge.PostRequest(
                identifier: "chat-42",
                categoryID: NotificationBridge.Category.permission.rawValue,
                title: "Needs you",
                body: "Approve edit"
            )
        ])
    }

    func testPostSuppressedWhenDisabled() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.enabled = false
        bridge.appIsActiveProvider = { false }   // background, but notifications off
        var recorded: [NotificationBridge.PostRequest] = []
        bridge.postHook = { recorded.append($0) }

        bridge.post(kind: .turnCompleted, title: "Done", detail: "Turn finished", targetID: "term-1")

        XCTAssertTrue(recorded.isEmpty)
    }

    func testPostSuppressedWhenAppActive() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.appIsActiveProvider = { true }    // Kaisola is frontmost
        var recorded: [NotificationBridge.PostRequest] = []
        bridge.postHook = { recorded.append($0) }

        bridge.post(kind: .sessionResponded, title: "Agent", detail: "Responded", targetID: "term-2")

        XCTAssertTrue(recorded.isEmpty)
    }

    func testPostSuppressedWhenAppStateUnknown() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.appIsActiveProvider = { nil }     // can't confirm background ⇒ don't post
        var recorded: [NotificationBridge.PostRequest] = []
        bridge.postHook = { recorded.append($0) }

        bridge.post(kind: .permission, title: "x", detail: "y", targetID: "z")

        XCTAssertTrue(recorded.isEmpty)
    }

    func testCategoryCoversEveryAttentionKind() {
        // Driven off `allCases`, and the expectation switch is exhaustive, so a
        // new kind fails to compile here rather than shipping unmapped.
        XCTAssertFalse(AttentionCenter.Kind.allCases.isEmpty)
        for kind in AttentionCenter.Kind.allCases {
            let expected: NotificationBridge.Category = switch kind {
            case .permission: .permission
            // A bell posts as a completed-turn-style system notification.
            case .turnCompleted, .bell: .turnCompleted
            case .sessionResponded: .sessionResponded
            }
            XCTAssertEqual(NotificationBridge.Category(kind), expected, "\(kind.rawValue)")
        }
    }

    func testSettingsAuthorizationPresentationDistinguishesDeniedFromAllowed() {
        XCTAssertEqual(NotificationAuthorizationState(.notDetermined), .notDetermined)
        XCTAssertEqual(NotificationAuthorizationState(.denied), .denied)
        XCTAssertEqual(NotificationAuthorizationState(.authorized), .allowed)
        XCTAssertEqual(NotificationAuthorizationState(.provisional), .allowed)
    }

    // MARK: - durable attention inbox

    func testAttentionEntriesPersistAcrossCenterRecreation() {
        let defaults = makeDefaults()
        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        center.notify(
            kind: .sessionResponded,
            targetID: "terminal-42",
            title: "Codex · Kaisola",
            detail: "Codex finished"
        )

        let restored = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries.first?.targetID, "terminal-42")
        XCTAssertEqual(restored.entries.first?.kind, .sessionResponded)
        XCTAssertEqual(restored.entries.first?.detail, "Codex finished")
    }

    func testAttentionReplacementAndClearArePersisted() {
        let defaults = makeDefaults()
        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        center.notify(kind: .sessionResponded, targetID: "terminal-1", title: "Old", detail: "Old")
        center.notify(kind: .sessionResponded, targetID: "terminal-1", title: "New", detail: "New")
        XCTAssertEqual(center.entries.map(\.title), ["New"])

        center.clear(targetID: "terminal-1")
        let restored = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertTrue(restored.entries.isEmpty)
    }

    func testAttentionRestoreRejectsCorruptStorage() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: "attention.entries.v1")

        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertTrue(center.entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "attention.entries.v1"))
    }

    func testSessionResponseAcknowledgementSurvivesRelaunchAndAllowsNewerCompletion() {
        let defaults = makeDefaults()
        let firstCompletion: Int64 = 1_785_000_000_123
        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )

        XCTAssertTrue(center.notifySessionResponded(
            targetID: "terminal-durable",
            title: "Codex · Kaisola",
            detail: "Codex finished",
            completedAt: firstCompletion
        ))
        XCTAssertFalse(center.notifySessionResponded(
            targetID: "terminal-durable",
            title: "Codex · Kaisola",
            detail: "Codex finished",
            completedAt: firstCompletion
        ))
        XCTAssertEqual(center.entries.count, 1)

        center.clear(targetID: "terminal-durable")
        let restored = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(restored.hasAcknowledgedSessionResponse(
            targetID: "terminal-durable",
            completedAt: firstCompletion
        ))
        XCTAssertFalse(restored.notifySessionResponded(
            targetID: "terminal-durable",
            title: "Codex · Kaisola",
            detail: "replayed inventory",
            completedAt: firstCompletion
        ))
        XCTAssertTrue(restored.notifySessionResponded(
            targetID: "terminal-durable",
            title: "Codex · Kaisola",
            detail: "new response",
            completedAt: firstCompletion + 1
        ))
        XCTAssertEqual(restored.entries.map(\.detail), ["new response"])
    }

    func testSessionResponseCanBeAcknowledgedWithoutAnExistingEntry() {
        let defaults = makeDefaults()
        let completedAt: Int64 = 1_785_000_100_000
        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        center.acknowledgeSessionResponse(targetID: "restored-primary", completedAt: completedAt)

        let restored = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertTrue(restored.hasAcknowledgedSessionResponse(
            targetID: "restored-primary",
            completedAt: completedAt
        ))
        XCTAssertFalse(restored.notifySessionResponded(
            targetID: "restored-primary",
            title: "Visible terminal",
            detail: "already visited on restore",
            completedAt: completedAt
        ))
    }

    func testAttentionRestoreRejectsCorruptAcknowledgementStorage() {
        let defaults = makeDefaults()
        let key = "attention.acknowledged-session-completions.v1"
        defaults.set(Data("not-json".utf8), forKey: key)

        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertFalse(center.hasAcknowledgedSessionResponse(targetID: "terminal", completedAt: 1))
        XCTAssertNil(defaults.data(forKey: key))
    }
}
