import Foundation
import XCTest
@testable import Kaisola

/// CustomAgentStore persistence against a throwaway file — save/all round-trip
/// across instances, corrupt-file degradation, the 12-entry cap, the slugify
/// matrix, the duplicate display-name rules, `asProfiles` mapping (symbol
/// fallback) — plus the `AgentRegistry` integration through the
/// `customStoreOverride` test seam.
final class CustomAgentStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: CustomAgentStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-custom-agents-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("custom-agents.json")
        store = CustomAgentStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        AgentRegistry.customStoreOverride = nil   // never leak the seam
    }

    // MARK: - Round-trip

    func testSaveAllRoundTripAcrossInstances() {
        let specs = [
            CustomAgentSpec(id: "custom-aider", name: "Aider", launchCommand: "aider", symbol: "bolt"),
            CustomAgentSpec(id: "custom-my-tool", name: "My Tool", launchCommand: "mytool --flag", symbol: "cpu"),
        ]
        store.save(specs)

        let reopened = CustomAgentStore(fileURL: fileURL)
        XCTAssertEqual(reopened.all(), specs)
    }

    func testCorruptFileDegradesToEmpty() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(store.all().isEmpty)
    }

    // MARK: - Cap

    func testSaveCapsAtTwelve() {
        let specs = (0..<15).map {
            CustomAgentSpec(id: "custom-\($0)", name: "Agent \($0)", launchCommand: "a\($0)", symbol: "terminal")
        }
        store.save(specs)

        let stored = store.all()
        XCTAssertEqual(stored.count, 12)
        // The first twelve are kept; the overflow is dropped.
        XCTAssertEqual(stored.first?.id, "custom-0")
        XCTAssertEqual(stored.last?.id, "custom-11")
    }

    // MARK: - slugify

    func testSlugifyMatrix() {
        XCTAssertEqual(CustomAgentStore.slugify("My Agent!"), "custom-my-agent")
        XCTAssertEqual(CustomAgentStore.slugify(""), "custom-agent")
        XCTAssertEqual(CustomAgentStore.slugify("   "), "custom-agent")
        XCTAssertEqual(CustomAgentStore.slugify("!!!"), "custom-agent")
        XCTAssertEqual(CustomAgentStore.slugify("Aider"), "custom-aider")
        XCTAssertEqual(CustomAgentStore.slugify("a/b c"), "custom-a-b-c")
        XCTAssertEqual(CustomAgentStore.slugify("Claude 3.5"), "custom-claude-3-5")
        XCTAssertEqual(CustomAgentStore.slugify("--Lead--"), "custom-lead")
        // Collision suffixing is intentionally NOT applied: same name → same id.
        XCTAssertEqual(CustomAgentStore.slugify("My Agent"), CustomAgentStore.slugify("my  agent"))
    }

    // MARK: - Duplicate display names

    func testNormalizedNameFoldsCaseAndWhitespace() {
        XCTAssertEqual(CustomAgentStore.normalizedName("  My   Agent \n"), "my agent")
        XCTAssertEqual(CustomAgentStore.normalizedName("MY\tAGENT"), "my agent")
        XCTAssertEqual(CustomAgentStore.normalizedName("   "), "")
        // Folding stops at spacing and case: joined words stay a different name.
        XCTAssertNotEqual(
            CustomAgentStore.normalizedName("myagent"),
            CustomAgentStore.normalizedName("my agent"))
    }

    func testDuplicateNameErrorCatchesCaseAndWhitespaceTwins() throws {
        let roster = [makeSpec("custom-aider", "Aider"), makeSpec("custom-lead", "Lead Dev")]
        XCTAssertNil(CustomAgentStore.duplicateNameError("Reviewer", in: roster))
        XCTAssertNil(CustomAgentStore.duplicateNameError("   ", in: roster))
        for twin in ["Aider", "aider", "  AIDER  ", "lead   dev", "LEAD\tDEV"] {
            XCTAssertNotNil(CustomAgentStore.duplicateNameError(twin, in: roster), twin)
        }
        // The refusal names the entry that took it, so the fix is obvious.
        let reason = try XCTUnwrap(CustomAgentStore.duplicateNameError(" aider ", in: roster))
        XCTAssertTrue(reason.contains("\"Aider\""), reason)
    }

    func testDuplicateNameErrorExemptsOnlyTheRowBeingRenamed() {
        let roster = [makeSpec("custom-aider", "Aider")]
        // A row re-saved under its own name does not collide with itself…
        XCTAssertNil(CustomAgentStore.duplicateNameError("Aider", in: roster, ignoring: "custom-aider"))
        XCTAssertNil(CustomAgentStore.duplicateNameError("aider", in: roster, ignoring: "custom-aider"))
        // …and exempting some other row does not excuse the collision.
        XCTAssertNotNil(CustomAgentStore.duplicateNameError("Aider", in: roster, ignoring: "custom-other"))
    }

    func testAddingRefusesADuplicateDisplayName() throws {
        let roster = try XCTUnwrap(CustomAgentStore.adding(makeSpec("custom-aider", "Aider"), to: []))
        XCTAssertEqual(roster.map(\.name), ["Aider"])

        // Unique ids are not enough: these all read as "Aider" in the New menu.
        for twin in ["aider", "  Aider  ", "AIDER"] {
            let candidate = CustomAgentSpec(
                id: CustomAgentStore.slugify(twin, existing: Set(roster.map(\.id))),
                name: twin,
                launchCommand: "aider --other-model",
                symbol: "cpu")
            XCTAssertNotEqual(candidate.id, "custom-aider")   // the id really did differ
            XCTAssertNil(CustomAgentStore.adding(candidate, to: roster), twin)
        }
        // A distinct name is still free; a repeated id is refused too.
        XCTAssertEqual(
            CustomAgentStore.adding(makeSpec("custom-aider-cli", "Aider CLI"), to: roster)?.map(\.name),
            ["Aider", "Aider CLI"])
        XCTAssertNil(CustomAgentStore.adding(makeSpec("custom-aider", "Something Else"), to: roster))
    }

    func testAddSequenceStoresOneRowPerVisibleName() {
        // The Settings ▸ Agents add row, three times over.
        var roster: [CustomAgentSpec] = []
        for (name, command) in [("Aider", "aider"), (" aider  ", "aider --alt"), ("Aider Two", "aider2")] {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = CustomAgentSpec(
                id: CustomAgentStore.slugify(trimmed, existing: Set(roster.map(\.id))),
                name: trimmed,
                launchCommand: command,
                symbol: "terminal")
            if let next = CustomAgentStore.adding(candidate, to: roster) { roster = next }
        }
        store.save(roster)

        XCTAssertEqual(store.all().map(\.name), ["Aider", "Aider Two"])
        XCTAssertEqual(store.all().map(\.launchCommand), ["aider", "aider2"])
    }

    func testExistingDuplicatesSurviveSaveAndAreRepairableByRename() throws {
        // A roster written before this rule existed: two rows, one visible name.
        store.save([makeSpec("custom-aider", "Aider"), makeSpec("custom-aider-2", "aider")])
        var roster = store.all()
        XCTAssertEqual(roster.count, 2, "an existing duplicate must never be dropped on save")
        XCTAssertNotNil(
            CustomAgentStore.duplicateNameError(roster[1].name, in: roster, ignoring: roster[1].id),
            "the duplicated row should flag itself so the user can find it")

        // The repair is a rename in place — the id, and with it the pinned
        // adapter install and credential context, is untouched.
        roster[1].name = "Aider Alt"
        store.save(roster)

        let repaired = store.all()
        XCTAssertEqual(repaired.map(\.id), ["custom-aider", "custom-aider-2"])
        XCTAssertEqual(repaired.map(\.name), ["Aider", "Aider Alt"])
        for entry in repaired {
            XCTAssertNil(CustomAgentStore.duplicateNameError(entry.name, in: repaired, ignoring: entry.id))
        }
    }

    private func makeSpec(_ id: String, _ name: String) -> CustomAgentSpec {
        CustomAgentSpec(id: id, name: name, launchCommand: "cli", symbol: "terminal")
    }

    // MARK: - asProfiles mapping

    func testAsProfilesMapsFieldsAndSymbolFallback() {
        store.save([
            CustomAgentSpec(id: "custom-x", name: "X", launchCommand: "xcli", symbol: "bolt"),
            CustomAgentSpec(id: "custom-y", name: "Y", launchCommand: "ycli", symbol: ""),
        ])

        let profiles = store.asProfiles()
        XCTAssertEqual(profiles.map(\.id), ["custom-x", "custom-y"])
        XCTAssertEqual(profiles.map(\.name), ["X", "Y"])
        XCTAssertEqual(profiles.map(\.launchCommand), ["xcli", "ycli"])
        XCTAssertEqual(profiles[0].symbol, "bolt")
        XCTAssertEqual(profiles[1].symbol, "terminal")   // empty symbol → fallback
    }

    // MARK: - AgentRegistry integration via the test seam

    func testRegistryAllContainsCustomAndResolvesByID() {
        store.save([
            CustomAgentSpec(id: "custom-aider", name: "Aider", launchCommand: "aider", symbol: "bolt"),
        ])
        AgentRegistry.customStoreOverride = store

        // Built-ins are still present and resolvable…
        XCTAssertNotNil(AgentRegistry.profile(id: "claude-code"))
        XCTAssertTrue(AgentRegistry.all.contains { $0.id == "claude-code" })
        // …and the custom agent is appended after them and resolvable by id.
        XCTAssertTrue(AgentRegistry.all.contains { $0.id == "custom-aider" })
        let resolved = AgentRegistry.profile(id: "custom-aider")
        XCTAssertEqual(resolved?.name, "Aider")
        XCTAssertEqual(resolved?.launchCommand, "aider")
        XCTAssertEqual(resolved?.symbol, "bolt")
        // Terminal-only: a custom id has no ACP adapter (deterministic empty env).
        XCTAssertNil(AcpAdapter.forAgent("custom-aider", environment: [:]))
    }

    func testRegistryCustomIsEmptyWithoutOverride() {
        // Absent the seam and a real file, the default store yields no customs,
        // leaving `all` equal to the built-ins.
        AgentRegistry.customStoreOverride = CustomAgentStore(fileURL: fileURL)
        XCTAssertTrue(AgentRegistry.custom.isEmpty)
        XCTAssertEqual(AgentRegistry.all.count, AgentRegistry.builtIns.count)
    }
}
