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

    // MARK: - damaged attention storage

    private static let attentionEntriesKey = "attention.entries.v1"
    private static let attentionAcknowledgementsKey = "attention.acknowledged-session-completions.v1"
    private static let attentionPreservedEntriesKey = "attention.entries.unreadable.v1"

    private func makeCenter(defaults: UserDefaults) -> AttentionCenter {
        AttentionCenter(defaults: defaults, postsNotifications: false, updatesDockBadge: false)
    }

    func testOneMalformedEntryDoesNotTakeItsNeighboursWithIt() {
        let defaults = makeDefaults()
        let payload = """
        {"schemaVersion":2,"entries":[
        {"id":"a","kind":"permission","targetID":"chat-a","title":"Approve","detail":"edit","at":100},
        {"id":"b","kind":"permission","targetID":"chat-b","title":"Approve","detail":"edit","at":"soon"},
        {"id":"c","kind":"bell","targetID":"term-c","title":"Bell","detail":"ping","at":300}
        ]}
        """
        defaults.set(Data(payload.utf8), forKey: Self.attentionEntriesKey)

        let center = makeCenter(defaults: defaults)
        XCTAssertEqual(
            center.entries.map(\.targetID),
            ["chat-a", "term-c"],
            "one unreadable record must not discard the pending asks around it"
        )
        XCTAssertEqual(center.storageNotices.map(\.kind), [.recordsDropped(count: 1)])
        XCTAssertEqual(center.storageNotices.map(\.payload), [.entries])
    }

    func testAttentionRestoreDropsSessionTimestampThatCannotBeAcknowledged() throws {
        let defaults = makeDefaults()
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
        defaults.set(raw, forKey: Self.attentionEntriesKey)

        let center = makeCenter(defaults: defaults)

        XCTAssertEqual(center.entries, [valid])
        XCTAssertEqual(
            defaults.data(forKey: Self.attentionEntriesKey),
            raw,
            "dropping one unsafe record must not discard the recoverable source"
        )
        XCTAssertEqual(center.storageNotices.map(\.kind), [.recordsDropped(count: 1)])
        XCTAssertEqual(center.storageNotices.map(\.payload), [.entries])
        XCTAssertFalse(center.notifySessionResponded(
            targetID: "terminal-negative",
            title: "Agent responded",
            detail: "Invalid timestamp",
            completedAt: -1
        ))
        XCTAssertFalse(center.notifySessionResponded(
            targetID: "terminal-overflow",
            title: "Agent responded",
            detail: "Invalid timestamp",
            completedAt: .max
        ))
    }

    func testAnUnreadableAcknowledgementKeepsTheRest() {
        let completedAt: Int64 = 1_785_000_000_123
        let defaults = makeDefaults()
        let payload = """
        {"schemaVersion":2,"acknowledgements":{"terminal-a":\(completedAt),"terminal-b":"never"}}
        """
        defaults.set(Data(payload.utf8), forKey: Self.attentionAcknowledgementsKey)

        let center = makeCenter(defaults: defaults)
        XCTAssertTrue(center.hasAcknowledgedSessionResponse(
            targetID: "terminal-a",
            completedAt: completedAt
        ))
        XCTAssertFalse(
            center.notifySessionResponded(
                targetID: "terminal-a",
                title: "Codex · Kaisola",
                detail: "replayed inventory",
                completedAt: completedAt
            ),
            "a damaged neighbour must not re-notify a response the user already visited"
        )
        XCTAssertEqual(center.storageNotices.map(\.kind), [.recordsDropped(count: 1)])
        XCTAssertEqual(center.storageNotices.map(\.payload), [.acknowledgements])
    }

    func testUnreadableAttentionBytesAreKeptForRecoveryRatherThanDeleted() throws {
        let defaults = makeDefaults()
        let damaged = Data(#"{"schemaVersion":2,"entries":[{"id""#.utf8)
        defaults.set(damaged, forKey: Self.attentionEntriesKey)

        let center = makeCenter(defaults: defaults)
        XCTAssertTrue(center.entries.isEmpty)
        XCTAssertNil(
            defaults.data(forKey: Self.attentionEntriesKey),
            "the live key is cleared so the next save can land"
        )
        XCTAssertEqual(defaults.data(forKey: Self.attentionPreservedEntriesKey), damaged)
        let notice = try XCTUnwrap(center.storageNotices.first)
        XCTAssertEqual(notice.kind, .unreadable)
        XCTAssertEqual(notice.preservedCopyKey, Self.attentionPreservedEntriesKey)
        XCTAssertFalse(notice.blocksSaving)
    }

    func testAbsentAttentionStorageIsNotReportedAsCorrupt() {
        let center = makeCenter(defaults: makeDefaults())
        XCTAssertTrue(center.entries.isEmpty)
        XCTAssertTrue(center.storageNotices.isEmpty, "a first launch has nothing to explain")
    }

    func testAClearThatCannotBeSavedKeepsTheRowOnScreen() throws {
        let suite = "kaisola-attention-write-drop-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(WriteDroppingDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let center = makeCenter(defaults: defaults)
        center.notify(kind: .permission, targetID: "chat-a", title: "Approve", detail: "edit")
        XCTAssertEqual(
            center.entries.count,
            1,
            "arriving work shows up whether or not it can be saved"
        )

        center.clearAll()
        XCTAssertEqual(
            center.entries.count,
            1,
            "an unsaved clear would come back on the next launch, so the badge stays honest"
        )
        XCTAssertTrue(center.storageNotices.contains { $0.kind == .saveNotConfirmed })
    }

    func testNewerVersionAttentionDataIsLeftAloneUntilTheUserResets() throws {
        let defaults = makeDefaults()
        let future = Data(#"{"schemaVersion":99,"entries":[],"visitedAt":1}"#.utf8)
        defaults.set(future, forKey: Self.attentionEntriesKey)

        let center = makeCenter(defaults: defaults)
        let notice = try XCTUnwrap(center.storageNotices.first)
        XCTAssertEqual(notice.kind, .newerVersion(schemaVersion: 99))
        XCTAssertTrue(notice.blocksSaving)
        XCTAssertEqual(
            defaults.data(forKey: Self.attentionEntriesKey),
            future,
            "data this build cannot interpret stays exactly where its owner expects it"
        )

        center.notify(kind: .permission, targetID: "chat-a", title: "Approve", detail: "edit")
        center.clearAll()
        XCTAssertEqual(center.entries.count, 1, "saving is blocked, so clearing cannot commit")
        XCTAssertEqual(defaults.data(forKey: Self.attentionEntriesKey), future)
        center.dismissStorageNotices()
        XCTAssertEqual(
            center.storageNotices.map(\.kind),
            [.newerVersion(schemaVersion: 99)],
            "the reason saving is blocked cannot be dismissed away"
        )

        center.resetStorage()
        XCTAssertTrue(center.storageNotices.isEmpty)
        XCTAssertEqual(makeCenter(defaults: defaults).entries.map(\.targetID), ["chat-a"])
    }

    func testTheUnversionedLegacyAttentionPayloadStillLoadsAndIsRewrittenVersioned() throws {
        let defaults = makeDefaults()
        let legacyEntries = """
        [{"id":"a","kind":"turnCompleted","targetID":"chat-a","title":"Done","detail":"x","at":100}]
        """
        defaults.set(Data(legacyEntries.utf8), forKey: Self.attentionEntriesKey)
        defaults.set(Data(#"{"terminal-a":5}"#.utf8), forKey: Self.attentionAcknowledgementsKey)

        let center = makeCenter(defaults: defaults)
        XCTAssertEqual(center.entries.map(\.targetID), ["chat-a"])
        XCTAssertTrue(center.hasAcknowledgedSessionResponse(targetID: "terminal-a", completedAt: 5))
        XCTAssertTrue(center.storageNotices.isEmpty, "readable schema 1 data is not a problem")

        center.notify(kind: .bell, targetID: "term-b", title: "Bell", detail: "ping")
        let stored = try XCTUnwrap(defaults.data(forKey: Self.attentionEntriesKey))
        let object = try JSONSerialization.jsonObject(with: stored) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 2)
    }
}

/// A defaults store whose writes silently do not land: the shape of a full
/// container or a revoked sandbox extension, and the case that used to let the
/// badge clear work the next launch brought straight back.
private final class WriteDroppingDefaults: UserDefaults {
    override func set(_ value: Any?, forKey defaultName: String) {}
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
