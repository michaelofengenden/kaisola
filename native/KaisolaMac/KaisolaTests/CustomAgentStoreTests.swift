import Foundation
import XCTest
@testable import Kaisola

/// CustomAgentStore persistence against a throwaway file — save/all round-trip
/// across instances, corrupt-file degradation, the 12-entry cap, the slugify
/// matrix, `asProfiles` mapping (symbol fallback) — plus the `AgentRegistry`
/// integration through the `customStoreOverride` test seam.
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
