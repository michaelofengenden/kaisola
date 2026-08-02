import Foundation
import XCTest
@testable import Kaisola

/// The pure logic behind the redesigned ACP composer: send enablement,
/// permission-posture mapping, model-picker filtering/favourites/shortcuts, the
/// effort·context chip, agent identity, and the empty-state heading. Every one
/// of these is a plain value transform so the SwiftUI layer above stays free of
/// decisions worth arguing about.
final class AcpComposerModelTests: XCTestCase {

    // MARK: - Send enablement

    func testSendIsDisabledWhileDisconnected() {
        XCTAssertFalse(AcpComposerSendPolicy.isEnabled(
            draft: "hello",
            isConnected: false,
            isRunning: false,
            hasAttachments: true
        ))
    }

    func testIdleSendAcceptsTextOrAStagedAttachment() {
        XCTAssertTrue(AcpComposerSendPolicy.isEnabled(
            draft: "hello", isConnected: true, isRunning: false, hasAttachments: false
        ))
        XCTAssertTrue(AcpComposerSendPolicy.isEnabled(
            draft: "   ", isConnected: true, isRunning: false, hasAttachments: true
        ))
        XCTAssertFalse(AcpComposerSendPolicy.isEnabled(
            draft: " \n ", isConnected: true, isRunning: false, hasAttachments: false
        ))
    }

    /// A queued follow-up cannot carry attachments, so a staged file alone must
    /// not arm the button mid-turn.
    func testRunningSendRequiresText() {
        XCTAssertFalse(AcpComposerSendPolicy.isEnabled(
            draft: "", isConnected: true, isRunning: true, hasAttachments: true
        ))
        XCTAssertTrue(AcpComposerSendPolicy.isEnabled(
            draft: "next", isConnected: true, isRunning: true, hasAttachments: false
        ))
    }

    func testActionSwitchesToQueueWhileRunning() {
        XCTAssertEqual(AcpComposerSendPolicy.action(isRunning: false), .send)
        XCTAssertEqual(AcpComposerSendPolicy.action(isRunning: true), .queue)
    }

    // MARK: - Permission posture

    func testBypassModesReadAsFullAccess() {
        let posture = AcpPermissionPostureMap.posture(id: "bypassPermissions", name: "Bypass Permissions")
        XCTAssertEqual(posture.label, "Full access")
        XCTAssertEqual(posture.level, .fullAccess)
        XCTAssertTrue(posture.isPermissive)
    }

    func testPlanModeReadsAsReadOnly() {
        let posture = AcpPermissionPostureMap.posture(id: "plan", name: "Plan")
        XCTAssertEqual(posture.label, "Read only")
        XCTAssertEqual(posture.level, .readOnly)
        XCTAssertFalse(posture.isPermissive)
    }

    func testAcceptEditsKeepsItsOwnRung() {
        let posture = AcpPermissionPostureMap.posture(id: "acceptEdits", name: "Accept Edits")
        XCTAssertEqual(posture.label, "Accept edits")
        XCTAssertEqual(posture.level, .acceptEdits)
        XCTAssertFalse(posture.isPermissive)
    }

    func testDefaultModeReadsAsAskEachTime() {
        let posture = AcpPermissionPostureMap.posture(id: "default", name: "Always Ask")
        XCTAssertEqual(posture.label, "Ask each time")
        XCTAssertEqual(posture.level, .ask)
    }

    /// An adapter is free to invent modes. Never relabel one we do not
    /// recognize — show the adapter's own word and assume the cautious rung.
    func testUnknownModeKeepsTheAdapterWording() {
        let posture = AcpPermissionPostureMap.posture(id: "custom-7", name: "Supervised")
        XCTAssertEqual(posture.label, "Supervised")
        XCTAssertEqual(posture.level, .ask)
        XCTAssertFalse(posture.isPermissive)
    }

    func testUnknownModeWithoutANameFallsBackToItsIdentifier() {
        XCTAssertEqual(AcpPermissionPostureMap.posture(id: "custom-7", name: "   ").label, "custom-7")
    }

    func testOnlyTheMostPermissiveRungIsPermissive() {
        let levels: [AcpPermissionPosture.Level] = [.readOnly, .ask, .acceptEdits, .fullAccess]
        XCTAssertEqual(levels.sorted(), levels)
        XCTAssertEqual(levels.filter { $0 == .fullAccess }.count, 1)
    }

    func testCurrentPostureFollowsTheSelectedMode() {
        let modes = [
            AcpSessionInfo.Mode(id: "default", name: "Always Ask"),
            AcpSessionInfo.Mode(id: "bypassPermissions", name: "Bypass Permissions"),
        ]
        XCTAssertEqual(
            AcpPermissionPostureMap.current(modes: modes, currentID: "bypassPermissions")?.label,
            "Full access"
        )
        // No selection yet: the adapter's first declared mode is the one in force.
        XCTAssertEqual(
            AcpPermissionPostureMap.current(modes: modes, currentID: nil)?.label,
            "Ask each time"
        )
        XCTAssertNil(AcpPermissionPostureMap.current(modes: [], currentID: nil))
    }

    // MARK: - Model picker

    private var models: [AcpSessionInfo.Model] {
        [
            AcpSessionInfo.Model(id: "claude-opus-4-5", name: "Opus 4.5"),
            AcpSessionInfo.Model(id: "claude-sonnet-4-5", name: "Sonnet 4.5"),
            AcpSessionInfo.Model(id: "claude-haiku-4-5", name: "Haiku 4.5"),
        ]
    }

    func testChoicesPreserveAdapterOrderAndNumberTheFirstNine() {
        let choices = AcpModelPicker.choices(models: models, currentID: "claude-sonnet-4-5", favorites: [], query: "")
        XCTAssertEqual(choices.map(\.name), ["Opus 4.5", "Sonnet 4.5", "Haiku 4.5"])
        XCTAssertEqual(choices.map(\.shortcut), [1, 2, 3])
        XCTAssertEqual(choices.filter(\.isCurrent).map(\.id), ["claude-sonnet-4-5"])
    }

    func testFavouritesFloatToTheTopWithoutReorderingTheirPeers() {
        let choices = AcpModelPicker.choices(
            models: models,
            currentID: nil,
            favorites: ["claude-haiku-4-5", "claude-sonnet-4-5"],
            query: ""
        )
        // Favourites keep the adapter's relative order among themselves.
        XCTAssertEqual(choices.map(\.name), ["Sonnet 4.5", "Haiku 4.5", "Opus 4.5"])
        XCTAssertEqual(choices.map(\.isFavorite), [true, true, false])
        XCTAssertEqual(choices.map(\.shortcut), [1, 2, 3])
    }

    func testQueryFiltersOnNameOrIdentifierAndRenumbers() {
        let choices = AcpModelPicker.choices(models: models, currentID: nil, favorites: [], query: "haiku")
        XCTAssertEqual(choices.map(\.name), ["Haiku 4.5"])
        XCTAssertEqual(choices.map(\.shortcut), [1])
    }

    func testQueryMatchesTheModelIdentifierToo() {
        let choices = AcpModelPicker.choices(models: models, currentID: nil, favorites: [], query: "opus4")
        XCTAssertEqual(choices.map(\.id), ["claude-opus-4-5"])
    }

    func testNonMatchingQueryYieldsNoRows() {
        XCTAssertTrue(AcpModelPicker.choices(models: models, currentID: nil, favorites: [], query: "zzz").isEmpty)
    }

    func testShortcutsStopAtNine() {
        let many = (1...12).map { AcpSessionInfo.Model(id: "m\($0)", name: "Model \($0)") }
        let choices = AcpModelPicker.choices(models: many, currentID: nil, favorites: [], query: "")
        XCTAssertEqual(choices.prefix(9).compactMap(\.shortcut), Array(1...9))
        XCTAssertTrue(choices.dropFirst(9).allSatisfy { $0.shortcut == nil })
    }

    /// A model whose display name already says everything the identifier does
    /// gets no second line.
    func testSubtitleAppearsOnlyWhenTheIdentifierAddsInformation() {
        let choices = AcpModelPicker.choices(
            models: [
                AcpSessionInfo.Model(id: "gpt-5.6-sol", name: "GPT-5.6-Sol"),
                AcpSessionInfo.Model(id: "claude-sonnet-4-5-20250929", name: "Sonnet 4.5"),
            ],
            currentID: nil,
            favorites: [],
            query: ""
        )
        XCTAssertNil(choices[0].subtitle)
        XCTAssertEqual(choices[1].subtitle, "claude-sonnet-4-5-20250929")
    }

    func testToggleFavouriteAddsThenRemoves() {
        var favorites: Set<String> = []
        favorites = AcpModelPicker.toggledFavorites(favorites, modelID: "a")
        XCTAssertEqual(favorites, ["a"])
        favorites = AcpModelPicker.toggledFavorites(favorites, modelID: "a")
        XCTAssertTrue(favorites.isEmpty)
    }

    func testFavouritesOnlyFilterHidesEverythingElse() {
        let choices = AcpModelPicker.choices(
            models: models,
            currentID: nil,
            favorites: ["claude-haiku-4-5"],
            query: "",
            favoritesOnly: true
        )
        XCTAssertEqual(choices.map(\.id), ["claude-haiku-4-5"])
    }

    // MARK: - Favourites store

    func testFavouritesStoreRoundTripsPerAgent() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("acp-favorites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AcpModelFavoritesStore(
            fileURL: directory.appendingPathComponent("favorites.json", isDirectory: false)
        )

        XCTAssertTrue(store.favorites(agentKey: "Claude").isEmpty)
        XCTAssertEqual(store.toggle("opus", agentKey: "Claude"), ["opus"])
        XCTAssertEqual(store.favorites(agentKey: "Claude"), ["opus"])
        // A second agent keeps its own set.
        XCTAssertTrue(store.favorites(agentKey: "Codex").isEmpty)
        XCTAssertEqual(store.toggle("opus", agentKey: "Claude"), [])
    }

    func testFavouritesStoreSurvivesACorruptFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("acp-favorites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("favorites.json", isDirectory: false)
        try Data("not json".utf8).write(to: fileURL)

        let store = AcpModelFavoritesStore(fileURL: fileURL)
        XCTAssertTrue(store.favorites(agentKey: "Claude").isEmpty)
        XCTAssertEqual(store.toggle("opus", agentKey: "Claude"), ["opus"])
    }

    // MARK: - Effort · context chip

    func testCompactTokensUseThousandsAndMillions() {
        XCTAssertEqual(AcpComposerMetrics.compactTokens(1_000_000), "1M")
        XCTAssertEqual(AcpComposerMetrics.compactTokens(1_500_000), "1.5M")
        XCTAssertEqual(AcpComposerMetrics.compactTokens(200_000), "200k")
        XCTAssertEqual(AcpComposerMetrics.compactTokens(512), "512")
    }

    func testPrimaryOptionPrefersAReasoningEffortControl() {
        let options = [
            AcpConfigOption(id: "preset", name: "Approval preset", currentValue: "a", choices: []),
            AcpConfigOption(id: "effort", name: "Reasoning effort", currentValue: "high", choices: [
                .init(value: "high", name: "High"),
            ]),
        ]
        XCTAssertEqual(AcpComposerMetrics.primaryOption(options)?.id, "effort")
        XCTAssertEqual(AcpComposerMetrics.primaryOption([options[0]])?.id, "preset")
        XCTAssertNil(AcpComposerMetrics.primaryOption([]))
    }

    func testOptionLabelPrefersTheChoicesDisplayName() {
        let option = AcpConfigOption(id: "effort", name: "Effort", currentValue: "high", choices: [
            .init(value: "high", name: "High"),
        ])
        XCTAssertEqual(AcpComposerMetrics.optionLabel(option), "High")
        let unmatched = AcpConfigOption(id: "effort", name: "Effort", currentValue: "xtra", choices: [])
        XCTAssertEqual(AcpComposerMetrics.optionLabel(unmatched), "xtra")
        XCTAssertNil(AcpComposerMetrics.optionLabel(nil))
    }

    func testChipLabelJoinsEffortAndContextAndCollapsesGracefully() {
        let option = AcpConfigOption(id: "effort", name: "Effort", currentValue: "high", choices: [
            .init(value: "high", name: "High"),
        ])
        let usage = AcpUsage(used: 12_000, max: 1_000_000)
        XCTAssertEqual(AcpComposerMetrics.chipLabel(option: option, usage: usage), "High · 1M")
        XCTAssertEqual(AcpComposerMetrics.chipLabel(option: option, usage: nil), "High")
        XCTAssertEqual(AcpComposerMetrics.chipLabel(option: nil, usage: usage), "1M")
        XCTAssertNil(AcpComposerMetrics.chipLabel(option: nil, usage: nil))
    }

    func testContextLabelIgnoresAnUndeclaredWindow() {
        XCTAssertNil(AcpComposerMetrics.contextLabel(AcpUsage(used: 0, max: 0)))
    }

    // MARK: - Agent identity

    func testAgentNameIsTheLeadingSegmentOfAChatTitle() {
        XCTAssertEqual(AcpAgentIdentity.agentName(fromChatTitle: "Claude · Kaisola"), "Claude")
        XCTAssertEqual(AcpAgentIdentity.agentName(fromChatTitle: "Codex · Kaisola"), "Codex")
        XCTAssertEqual(AcpAgentIdentity.agentName(fromChatTitle: "Renamed chat"), "Renamed chat")
    }

    func testIdentityResolvesTheTwoFirstClassMarks() {
        XCTAssertEqual(AcpAgentIdentity.identity(fromChatTitle: "Claude · Kaisola"), .claude)
        XCTAssertEqual(AcpAgentIdentity.identity(fromChatTitle: "Codex · Kaisola"), .openai)
    }

    /// A renamed chat still carries the agent's word somewhere in its title far
    /// more often than not; fall back to scanning the whole title before giving
    /// up on the brand mark.
    func testIdentityFallsBackToScanningTheWholeTitle() {
        XCTAssertEqual(AcpAgentIdentity.identity(fromChatTitle: "Rewrite the parser with Claude"), .claude)
        XCTAssertEqual(AcpAgentIdentity.identity(fromChatTitle: "Zebra"), .letter("Z"))
    }

    func testChipLabelAvoidsSayingTheBrandTwice() {
        XCTAssertEqual(AcpAgentIdentity.chipLabel(agentName: "Claude", modelName: "Sonnet 4.5"), "Claude Sonnet 4.5")
        XCTAssertEqual(AcpAgentIdentity.chipLabel(agentName: "Claude", modelName: "Claude Fable 5"), "Claude Fable 5")
        XCTAssertEqual(AcpAgentIdentity.chipLabel(agentName: "Claude", modelName: nil), "Claude")
        XCTAssertEqual(AcpAgentIdentity.chipLabel(agentName: "Claude", modelName: "  "), "Claude")
    }

    // MARK: - Empty state

    func testHeadingNamesTheProjectFolder() {
        let heading = AcpEmptyState.heading(projectName: "Developer")
        XCTAssertEqual(heading.lead, "What should we build in ")
        XCTAssertEqual(heading.project, "Developer")
        XCTAssertEqual(heading.tail, "?")
        XCTAssertEqual(heading.spoken, "What should we build in Developer?")
    }

    func testHeadingDropsTheClauseWithoutAProject() {
        let heading = AcpEmptyState.heading(projectName: "   ")
        XCTAssertEqual(heading.lead, "What should we build?")
        XCTAssertTrue(heading.project.isEmpty)
        XCTAssertTrue(heading.tail.isEmpty)
        XCTAssertEqual(heading.spoken, "What should we build?")
    }

    func testProjectNameComesFromTheWorkspaceFolder() {
        XCTAssertEqual(
            AcpEmptyState.projectName(for: URL(fileURLWithPath: "/Users/me/Developer", isDirectory: true)),
            "Developer"
        )
        XCTAssertEqual(AcpEmptyState.projectName(for: nil), "")
    }
}
