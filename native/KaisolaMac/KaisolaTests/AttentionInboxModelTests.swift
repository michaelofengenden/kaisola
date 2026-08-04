import XCTest
@testable import Kaisola

/// The all-agents inbox's grouping, ordering, filtering, and stale-row rules.
@MainActor
final class AttentionInboxModelTests: XCTestCase {
    private func entry(
        _ id: String,
        kind: AttentionCenter.Kind = .turnCompleted,
        target: String,
        at seconds: TimeInterval
    ) -> AttentionCenter.Entry {
        AttentionCenter.Entry(
            id: id,
            kind: kind,
            targetID: target,
            title: "Title \(id)",
            detail: "Detail \(id)",
            at: Date(timeIntervalSince1970: seconds)
        )
    }

    /// Sections order by their newest entry; the unnamed group is always
    /// last; rows inside a section are newest first.
    func testSectionsGroupByProjectNewestFirst() {
        let entries = [
            entry("a", target: "chat-alpha", at: 100),
            entry("b", target: "term-alpha", at: 300),
            entry("c", target: "chat-beta", at: 200),
            entry("d", target: "gone", at: 400),
        ]
        let sections = AttentionInboxModel.sections(entries: entries) { target in
            switch target {
            case "chat-alpha", "term-alpha": ("Alpha", true)
            case "chat-beta": ("Beta", true)
            default: (nil, false)
            }
        }
        XCTAssertEqual(sections.map(\.title), ["Alpha", "Beta", "Elsewhere"])
        XCTAssertEqual(sections[0].rows.map(\.entry.id), ["b", "a"], "newest first inside a section")
        XCTAssertFalse(sections[2].rows[0].targetExists, "the gone target is marked stale")
    }

    func testKindFilterSelectsExactly() {
        let entries = [
            entry("p", kind: .permission, target: "x", at: 3),
            entry("t", kind: .turnCompleted, target: "x", at: 2),
            entry("s", kind: .sessionResponded, target: "x", at: 1),
            entry("b", kind: .bell, target: "x", at: 0),
        ]
        let context: (String) -> (projectName: String?, exists: Bool) = { _ in ("P", true) }
        let permissions = AttentionInboxModel.sections(
            entries: entries, kinds: [.permission], context: context
        )
        XCTAssertEqual(permissions.flatMap(\.rows).map(\.entry.id), ["p"])
        let done = AttentionInboxModel.sections(
            entries: entries, kinds: [.turnCompleted, .sessionResponded], context: context
        )
        XCTAssertEqual(done.flatMap(\.rows).map(\.entry.id), ["t", "s"])
        let all = AttentionInboxModel.sections(entries: entries, kinds: nil, context: context)
        XCTAssertEqual(all.flatMap(\.rows).count, 4)
    }

    /// Every kind is reachable through some filter chip — a new kind that
    /// nobody adds to a chip would otherwise vanish whenever any filter is on.
    func testEveryKindBelongsToAChip() {
        let covered = AttentionInboxModel.filterChips.reduce(into: Set<AttentionCenter.Kind>()) {
            $0.formUnion($1.kinds)
        }
        XCTAssertEqual(covered, Set(AttentionCenter.Kind.allCases))
    }

    func testEmptyEntriesYieldNoSections() {
        XCTAssertTrue(AttentionInboxModel.sections(entries: []) { _ in (nil, true) }.isEmpty)
    }
}

/// Where the ⌥⌘K summon lands.
final class SummonPolicyTests: XCTestCase {
    func testTheSelectedChatWinsWhenItExists() {
        XCTAssertEqual(
            SummonPolicy.chatToFocus(selectedChatID: "b", chatIDs: ["a", "b", "c"]),
            "b"
        )
    }

    func testAStaleSelectionFallsBackToTheNewestChat() {
        XCTAssertEqual(
            SummonPolicy.chatToFocus(selectedChatID: "gone", chatIDs: ["a", "b"]),
            "b"
        )
        XCTAssertEqual(SummonPolicy.chatToFocus(selectedChatID: nil, chatIDs: ["a"]), "a")
    }

    func testNoChatsMeansNoFocusTarget() {
        XCTAssertNil(SummonPolicy.chatToFocus(selectedChatID: nil, chatIDs: []))
        XCTAssertNil(SummonPolicy.chatToFocus(selectedChatID: "x", chatIDs: []))
    }
}
