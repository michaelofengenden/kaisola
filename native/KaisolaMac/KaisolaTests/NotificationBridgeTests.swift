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

    func testAttentionRestoreRetainsCorruptStorageForRecovery() {
        let defaults = makeDefaults()
        let key = "attention.entries.v1"
        let raw = Data("not-json".utf8)
        defaults.set(raw, forKey: key)

        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertTrue(center.entries.isEmpty)
        XCTAssertEqual(defaults.data(forKey: key), raw)
        XCTAssertEqual(center.persistenceNotice, .corruptStatePreserved)
        XCTAssertTrue(center.persistenceNotice?.offersReset == true)
    }

    func testAttentionRestoreSalvagesValidLegacyEntryAndRetainsMalformedSource() throws {
        let defaults = makeDefaults()
        let key = "attention.entries.v1"
        let valid = AttentionCenter.Entry(
            id: "terminal-valid-permission-1000",
            kind: .permission,
            targetID: "terminal-valid",
            title: "Approval needed",
            detail: "Review the command",
            at: Date(timeIntervalSince1970: 1)
        )
        let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        let raw = try JSONSerialization.data(withJSONObject: [
            validObject,
            ["id": 42, "kind": "permission", "targetID": "broken"],
        ])
        defaults.set(raw, forKey: key)

        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )

        XCTAssertEqual(center.entries, [valid])
        XCTAssertEqual(defaults.data(forKey: key), raw, "malformed source must remain recoverable")
        XCTAssertEqual(
            center.persistenceNotice,
            .recovered(discardedEntries: 1, discardedAcknowledgements: 0)
        )
    }

    func testAttentionRestoreDropsSessionTimestampThatCannotBeAcknowledged() throws {
        let defaults = makeDefaults()
        let key = "attention.entries.v1"
        let valid = AttentionCenter.Entry(
            id: "terminal-valid-permission-1000",
            kind: .permission,
            targetID: "terminal-valid",
            title: "Approval needed",
            detail: "Review the command",
            at: Date(timeIntervalSince1970: 1)
        )
        let outOfRange = AttentionCenter.Entry(
            id: "terminal-extreme-session-responded",
            kind: .sessionResponded,
            targetID: "terminal-extreme",
            title: "Agent responded",
            detail: "Corrupt timestamp",
            at: Date(timeIntervalSince1970: 1e20)
        )
        let raw = try JSONEncoder().encode([valid, outOfRange])
        defaults.set(raw, forKey: key)

        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )

        XCTAssertEqual(center.entries, [valid])
        XCTAssertEqual(defaults.data(forKey: key), raw)
        XCTAssertEqual(
            center.persistenceNotice,
            .recovered(discardedEntries: 1, discardedAcknowledgements: 0)
        )
        center.clearAll()
        XCTAssertTrue(center.entries.isEmpty)
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

    func testAttentionRestoreRetainsCorruptAcknowledgementStorageForRecovery() {
        let defaults = makeDefaults()
        let key = "attention.acknowledged-session-completions.v1"
        let raw = Data("not-json".utf8)
        defaults.set(raw, forKey: key)

        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertFalse(center.hasAcknowledgedSessionResponse(targetID: "terminal", completedAt: 1))
        XCTAssertEqual(defaults.data(forKey: key), raw)
        XCTAssertEqual(center.persistenceNotice, .corruptStatePreserved)
        XCTAssertTrue(center.persistenceNotice?.offersReset == true)
    }

    func testAttentionRestoreSalvagesValidLegacyAcknowledgementAndRetainsMalformedSource() throws {
        let defaults = makeDefaults()
        let key = "attention.acknowledged-session-completions.v1"
        let raw = try JSONSerialization.data(withJSONObject: [
            "terminal-valid": 1_785_000_100_000,
            "terminal-broken": "not-an-integer",
        ])
        defaults.set(raw, forKey: key)

        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )

        XCTAssertTrue(center.hasAcknowledgedSessionResponse(
            targetID: "terminal-valid",
            completedAt: 1_785_000_100_000
        ))
        XCTAssertEqual(defaults.data(forKey: key), raw, "malformed source must remain recoverable")
        XCTAssertEqual(
            center.persistenceNotice,
            .recovered(discardedEntries: 0, discardedAcknowledgements: 1)
        )
    }

    func testAttentionWritesOneAtomicIndependentlyVersionedStateEnvelope() throws {
        let defaults = makeDefaults()
        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        center.notify(
            kind: .permission,
            targetID: "terminal-atomic",
            title: "Approval needed",
            detail: "Review the command"
        )

        let data = try XCTUnwrap(defaults.data(forKey: "attention.state.v2"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(root["entries"] as? [String: Any])
        let acknowledgements = try XCTUnwrap(root["acknowledgements"] as? [String: Any])

        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertEqual(entries["schemaVersion"] as? Int, 1)
        XCTAssertEqual(acknowledgements["schemaVersion"] as? Int, 1)
        XCTAssertEqual((entries["values"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((acknowledgements["values"] as? [String: Int64])?.count, 0)
    }

    func testLossyVersionedRepairCopiesOriginalBeforeClearingRecoveredState() throws {
        let defaults = makeDefaults()
        let stateKey = "attention.state.v2"
        let recoveryKey = "attention.state.recovery.v2"
        let valid = AttentionCenter.Entry(
            id: "terminal-valid-permission-1000",
            kind: .permission,
            targetID: "terminal-valid",
            title: "Approval needed",
            detail: "Review the command",
            at: Date(timeIntervalSince1970: 1)
        )
        let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        let raw = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "entries": [
                "schemaVersion": 1,
                "values": [
                    validObject,
                    ["id": 42, "kind": "permission", "targetID": "broken"],
                ],
            ],
            "acknowledgements": [
                "schemaVersion": 1,
                "values": [
                    "terminal-acknowledged": 1_785_000_100_000,
                    "terminal-broken": "not-an-integer",
                ],
            ],
        ])
        defaults.set(raw, forKey: stateKey)
        var rejectRecoveryWrite = true
        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false,
            persistenceWriter: { defaults, key, data in
                guard !(rejectRecoveryWrite && key == recoveryKey) else { return false }
                defaults.set(data, forKey: key)
                return defaults.data(forKey: key) == data
            }
        )

        XCTAssertEqual(center.entries, [valid])
        XCTAssertTrue(center.hasAcknowledgedSessionResponse(
            targetID: "terminal-acknowledged",
            completedAt: 1_785_000_100_000
        ))
        XCTAssertEqual(
            center.persistenceNotice,
            .recovered(discardedEntries: 1, discardedAcknowledgements: 1)
        )

        center.clearAll()
        XCTAssertEqual(center.entries, [valid], "a failed recovery copy must fence the clear")
        XCTAssertEqual(defaults.data(forKey: stateKey), raw)
        XCTAssertNil(defaults.data(forKey: recoveryKey))
        XCTAssertEqual(center.persistenceNotice, .writeFailed)

        rejectRecoveryWrite = false
        center.clearAll()
        XCTAssertTrue(center.entries.isEmpty)
        XCTAssertEqual(defaults.data(forKey: recoveryKey), raw)
        XCTAssertNotEqual(defaults.data(forKey: stateKey), raw)
    }

    func testAttentionClearWaitsForAConfirmedAtomicWrite() {
        let defaults = makeDefaults()
        var rejectStateWrites = false
        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false,
            persistenceWriter: { defaults, key, data in
                guard !(rejectStateWrites && key == "attention.state.v2") else { return false }
                defaults.set(data, forKey: key)
                return defaults.data(forKey: key) == data
            }
        )
        let completedAt: Int64 = 1_785_000_200_000
        XCTAssertTrue(center.notifySessionResponded(
            targetID: "terminal-write-failure",
            title: "Agent responded",
            detail: "Review the result",
            completedAt: completedAt
        ))
        XCTAssertEqual(center.entries.count, 1)

        rejectStateWrites = true
        center.clear(targetID: "terminal-write-failure")

        XCTAssertEqual(center.entries.count, 1, "failed persistence must not clear visible state")
        XCTAssertFalse(center.hasAcknowledgedSessionResponse(
            targetID: "terminal-write-failure",
            completedAt: completedAt
        ))
        XCTAssertEqual(center.persistenceNotice, .writeFailed)

        let restored = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertEqual(restored.entries.map(\.targetID), ["terminal-write-failure"])
        XCTAssertFalse(restored.hasAcknowledgedSessionResponse(
            targetID: "terminal-write-failure",
            completedAt: completedAt
        ))
    }

    func testCorruptVersionedStateRequiresExplicitResetAndKeepsRecoveryCopy() throws {
        let defaults = makeDefaults()
        let stateKey = "attention.state.v2"
        let recoveryKey = "attention.state.recovery.v2"
        let raw = Data("not-json-v2".utf8)
        defaults.set(raw, forKey: stateKey)
        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )

        XCTAssertEqual(center.persistenceNotice, .corruptStatePreserved)
        center.notify(
            kind: .permission,
            targetID: "terminal-after-corruption",
            title: "Approval needed",
            detail: "Review the command"
        )
        XCTAssertEqual(defaults.data(forKey: stateKey), raw, "ordinary writes must not replace corrupt state")

        XCTAssertTrue(center.resetCorruptPersistence())
        XCTAssertEqual(defaults.data(forKey: recoveryKey), raw)
        XCTAssertNotEqual(defaults.data(forKey: stateKey), raw)
        XCTAssertNil(center.persistenceNotice)

        let restored = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )
        XCTAssertEqual(restored.entries.map(\.targetID), ["terminal-after-corruption"])
    }

    func testWrongTypedVersionedStateIsCorruptRatherThanAbsent() {
        let defaults = makeDefaults()
        let stateKey = "attention.state.v2"
        let recoveryKey = "attention.state.recovery.v2"
        defaults.set("not-a-data-payload", forKey: stateKey)

        let center = AttentionCenter(
            defaults: defaults,
            postsNotifications: false,
            updatesDockBadge: false
        )

        XCTAssertEqual(center.persistenceNotice, .corruptStatePreserved)
        center.notify(
            kind: .permission,
            targetID: "terminal-after-wrong-type",
            title: "Approval needed",
            detail: "Review the command"
        )
        XCTAssertEqual(defaults.string(forKey: stateKey), "not-a-data-payload")

        XCTAssertTrue(center.resetCorruptPersistence())
        XCTAssertEqual(defaults.string(forKey: recoveryKey), "not-a-data-payload")
        XCTAssertNotNil(defaults.data(forKey: stateKey))
        XCTAssertNil(center.persistenceNotice)
    }
}

/// Per-event delivery rules: each needs-you group carries its own
/// Never / when-backgrounded / Always, defaulting to the historical
/// background-only behavior.
@MainActor
final class NotificationRuleTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "notification-rules-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testTheGateIsPureAndExact() {
        XCTAssertFalse(NotificationBridge.shouldPost(rule: .never, appIsActive: false))
        XCTAssertFalse(NotificationBridge.shouldPost(rule: .never, appIsActive: true))
        XCTAssertTrue(NotificationBridge.shouldPost(rule: .always, appIsActive: true))
        XCTAssertTrue(NotificationBridge.shouldPost(rule: .always, appIsActive: nil))
        XCTAssertTrue(NotificationBridge.shouldPost(rule: .whenBackgrounded, appIsActive: false))
        XCTAssertFalse(NotificationBridge.shouldPost(rule: .whenBackgrounded, appIsActive: true))
        XCTAssertFalse(
            NotificationBridge.shouldPost(rule: .whenBackgrounded, appIsActive: nil),
            "an unknowable app state stays ineligible — the historical contract"
        )
    }

    func testRulesDefaultToBackgroundOnlyAndPersistPerGroup() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        for group in NotificationBridge.RuleGroup.allCases {
            XCTAssertEqual(bridge.rule(for: group), .whenBackgrounded)
        }
        bridge.setRule(.always, for: .permission)
        bridge.setRule(.never, for: .done)
        XCTAssertEqual(bridge.rule(for: .permission), .always)
        XCTAssertEqual(bridge.rule(for: .done), .never)
        XCTAssertEqual(bridge.rule(for: .bell), .whenBackgrounded, "untouched groups keep the default")
    }

    /// Every attention kind belongs to a group, so no event can slip past the
    /// rules unclassified.
    func testEveryKindHasAGroup() {
        for kind in AttentionCenter.Kind.allCases {
            _ = NotificationBridge.RuleGroup(kind)
        }
    }

    func testPostHonorsThePerGroupRule() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.enabled = true
        var posted: [NotificationBridge.PostRequest] = []
        bridge.postHook = { posted.append($0) }

        // App active: the default background-only rule stays silent…
        bridge.appIsActiveProvider = { true }
        bridge.post(kind: .permission, title: "t", detail: "d", targetID: "x")
        XCTAssertTrue(posted.isEmpty)

        // …but Always speaks through focus.
        bridge.setRule(.always, for: .permission)
        bridge.post(kind: .permission, title: "t", detail: "d", targetID: "x")
        XCTAssertEqual(posted.count, 1)

        // Never silences even a backgrounded app.
        bridge.setRule(.never, for: .done)
        bridge.appIsActiveProvider = { false }
        bridge.post(kind: .turnCompleted, title: "t", detail: "d", targetID: "y")
        XCTAssertEqual(posted.count, 1)

        // And an unconfigured group still behaves as it always has.
        bridge.post(kind: .bell, title: "t", detail: "d", targetID: "z")
        XCTAssertEqual(posted.count, 2)
    }
}
