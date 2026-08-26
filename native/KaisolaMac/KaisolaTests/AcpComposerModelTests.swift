import Foundation
import KaisolaCore
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

    func testChoicesPreserveTheAdapterOrder() {
        let choices = AcpModelPicker.choices(models: models, currentID: "claude-sonnet-4-5", favorites: [], query: "")
        XCTAssertEqual(choices.map(\.name), ["Opus 4.5", "Sonnet 4.5", "Haiku 4.5"])
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
    }

    func testQueryFiltersOnNameOrIdentifier() {
        let choices = AcpModelPicker.choices(models: models, currentID: nil, favorites: [], query: "haiku")
        XCTAssertEqual(choices.map(\.name), ["Haiku 4.5"])
    }

    func testQueryMatchesTheModelIdentifierToo() {
        let choices = AcpModelPicker.choices(models: models, currentID: nil, favorites: [], query: "opus4")
        XCTAssertEqual(choices.map(\.id), ["claude-opus-4-5"])
    }

    func testNonMatchingQueryYieldsNoRows() {
        XCTAssertTrue(AcpModelPicker.choices(models: models, currentID: nil, favorites: [], query: "zzz").isEmpty)
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

    // MARK: - Settings menu rows

    private var effortOption: AcpConfigOption {
        AcpConfigOption(id: "effort", name: "Reasoning effort", currentValue: "light", choices: [
            .init(value: "light", name: "Light"),
            .init(value: "medium", name: "Medium"),
            .init(value: "high", name: "High"),
        ])
    }

    /// The Claude shape, and the control for everything below: one flat model
    /// list, no effort anywhere near it, nothing to reconcile.
    private func claudeSurface(currentModelID: String? = "claude-sonnet-4-5") -> AcpComposerSurface {
        AcpComposerSurface.reconciled(
            models: models,
            currentModelID: currentModelID,
            modes: [],
            configOptions: [effortOption]
        )
    }

    func testMenuLeadsWithAgentThenModelThenTheDeclaredOptions() {
        let rows = AcpComposerMenu.rows(agentName: "Claude", surface: claudeSurface())
        XCTAssertEqual(rows.map(\.label), ["Agent", "Model", "Effort"])
        XCTAssertEqual(rows.map(\.value), ["Claude", "Sonnet 4.5", "Light"])
        XCTAssertEqual(rows.map(\.target), [.agent, .model, .option("effort")])
    }

    /// An adapter that declares no models gets no Model row: a row whose
    /// submenu would be empty is a dead button, not a disclosure.
    func testMenuOmitsRowsTheAdapterCannotFill() {
        let rows = AcpComposerMenu.rows(
            agentName: "Claude",
            surface: AcpComposerSurface.reconciled(
                models: [],
                currentModelID: nil,
                modes: [],
                configOptions: [AcpConfigOption(id: "preset", name: "Preset", currentValue: nil, choices: [])]
            )
        )
        XCTAssertEqual(rows.map(\.label), ["Agent"])
    }

    /// Nothing is selected yet: the adapter's first declared model is the one
    /// in force, exactly as with permission modes.
    func testModelRowFallsBackToTheFirstDeclaredModel() {
        let rows = AcpComposerMenu.rows(
            agentName: "Claude",
            surface: AcpComposerSurface.reconciled(
                models: models, currentModelID: nil, modes: [], configOptions: []
            )
        )
        XCTAssertEqual(rows.first(where: { $0.target == .model })?.value, "Opus 4.5")
    }

    func testOptionLabelsAreShortenedToTheWordThatVaries() {
        XCTAssertEqual(AcpComposerMenu.shortLabel(name: "Reasoning effort", id: "effort"), "Effort")
        XCTAssertEqual(AcpComposerMenu.shortLabel(name: "effort", id: "effort"), "Effort")
        XCTAssertEqual(AcpComposerMenu.shortLabel(name: "Speed", id: "speed"), "Speed")
        // Only a leading qualifier is dropped; a two-word name that says two
        // things keeps both.
        XCTAssertEqual(AcpComposerMenu.shortLabel(name: "Approval preset", id: "preset"), "Approval preset")
        XCTAssertEqual(AcpComposerMenu.shortLabel(name: "   ", id: "preset"), "Preset")
    }

    // MARK: - Adapter surface: saying each setting exactly once

    /// The Codex shape, transcribed from a live `session/new` against
    /// `@agentclientprotocol/codex-acp` 1.1.8 (2026-08-02): effort appears in
    /// every model id, again in every model name, and again as its own option;
    /// the model appears both as the cross product and as a base-model option;
    /// the permission mode appears both in `modes` and as a `mode` option.
    /// Trimmed to three base models — the real payload lists 33 model rows.
    private enum CodexFixture {
        static let models = [
            AcpSessionInfo.Model(id: "gpt-5.6-sol[low]", name: "GPT-5.6-Sol (low)"),
            AcpSessionInfo.Model(id: "gpt-5.6-sol[high]", name: "GPT-5.6-Sol (high)"),
            AcpSessionInfo.Model(id: "gpt-5.6-sol[xhigh]", name: "GPT-5.6-Sol (xhigh)"),
            AcpSessionInfo.Model(id: "gpt-5.6-sol[max]", name: "GPT-5.6-Sol (max)"),
            AcpSessionInfo.Model(id: "gpt-5.6-terra[low]", name: "GPT-5.6-Terra (low)"),
            AcpSessionInfo.Model(id: "gpt-5.6-terra[high]", name: "GPT-5.6-Terra (high)"),
            AcpSessionInfo.Model(id: "gpt-5.6-terra[xhigh]", name: "GPT-5.6-Terra (xhigh)"),
            AcpSessionInfo.Model(id: "gpt-5.6-terra[max]", name: "GPT-5.6-Terra (max)"),
            AcpSessionInfo.Model(id: "gpt-5.6-luna[low]", name: "GPT-5.6-Luna (low)"),
            AcpSessionInfo.Model(id: "gpt-5.6-luna[high]", name: "GPT-5.6-Luna (high)"),
        ]
        static let currentModelID = "gpt-5.6-sol[max]"
        static let modes = [
            AcpSessionInfo.Mode(id: "read-only", name: "Read-only"),
            AcpSessionInfo.Mode(id: "agent", name: "Agent"),
            AcpSessionInfo.Mode(id: "agent-full-access", name: "Agent (full access)"),
        ]

        static func configOptions(effort: String = "max") -> [AcpConfigOption] {
            [
                AcpConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "agent", choices: [
                    .init(value: "read-only", name: "Read-only"),
                    .init(value: "agent", name: "Agent"),
                    .init(value: "agent-full-access", name: "Agent (full access)"),
                ]),
                AcpConfigOption(
                    id: "collaboration_mode",
                    name: "Collaboration mode",
                    category: "collaboration_mode",
                    currentValue: "default",
                    choices: [.init(value: "default", name: "Default"), .init(value: "plan", name: "Plan")]
                ),
                AcpConfigOption(id: "model", name: "Model", category: "model", currentValue: "gpt-5.6-sol", choices: [
                    .init(value: "gpt-5.6-sol", name: "GPT-5.6-Sol"),
                    .init(value: "gpt-5.6-terra", name: "GPT-5.6-Terra"),
                    .init(value: "gpt-5.6-luna", name: "GPT-5.6-Luna"),
                ]),
                AcpConfigOption(
                    id: "reasoning_effort",
                    name: "Reasoning effort",
                    category: "thought_level",
                    currentValue: effort,
                    choices: [
                        .init(value: "low", name: "Low"),
                        .init(value: "medium", name: "Medium"),
                        .init(value: "high", name: "High"),
                        .init(value: "xhigh", name: "Xhigh"),
                        .init(value: "max", name: "Max"),
                        .init(value: "ultra", name: "Ultra"),
                    ]
                ),
                AcpConfigOption(id: "fast-mode", name: "Fast mode", category: "model_config", currentValue: "off", choices: [
                    .init(value: "off", name: "Off"), .init(value: "on", name: "On"),
                ]),
            ]
        }

        static func surface(effort: String = "max") -> AcpComposerSurface {
            AcpComposerSurface.reconciled(
                models: models,
                currentModelID: currentModelID,
                modes: modes,
                configOptions: configOptions(effort: effort)
            )
        }
    }

    /// The bug, stated as an assertion: the word "max" may appear in exactly one
    /// row of the menu. Before the surface existed it appeared in two — the
    /// Model row read "GPT-5.6-Sol (max)" and the Effort row read "Max" — and
    /// the pill read "GPT-5.6-Sol (max)  Max".
    func testCodexStatesTheEffortExactlyOnce() {
        let rows = AcpComposerMenu.rows(agentName: "Codex", surface: CodexFixture.surface())
        XCTAssertEqual(rows.map(\.label), ["Agent", "Model", "Collaboration mode", "Effort", "Fast mode"])
        XCTAssertEqual(rows.map(\.value), ["Codex", "GPT-5.6-Sol", "Default", "Max", "Off"])
        XCTAssertEqual(
            rows.filter { $0.value.lowercased().contains("max") }.count,
            1,
            "the effort in force must be stated by one row, not two"
        )
    }

    /// The pill's face, which is where Michael saw it: model, then effort, each
    /// once.
    func testCodexPillNamesTheModelAndTheEffortOnceEach() {
        let surface = CodexFixture.surface()
        let values = AcpComposerMenu.chipValues(
            agentName: "Codex",
            modelName: AcpComposerMenu.currentModel(surface)?.name,
            option: AcpComposerMetrics.primaryOption(surface.options)
        )
        XCTAssertEqual(values.primary, "GPT-5.6-Sol")
        XCTAssertEqual(values.secondary, "Max")
    }

    /// 33 rows of `<model> × <effort>` collapse to one row per model, because
    /// the effort is chosen one row above.
    func testCodexModelSubmenuNamesEachModelOnceWithoutItsEffort() {
        let submenu = AcpComposerMenu.modelSubmenu(
            surface: CodexFixture.surface(), favorites: [], query: ""
        )
        XCTAssertEqual(submenu.options.map(\.name), ["GPT-5.6-Sol", "GPT-5.6-Terra", "GPT-5.6-Luna"])
        XCTAssertEqual(submenu.options.map(\.isSelected), [true, false, false])
        XCTAssertTrue(
            submenu.options.allSatisfy { !$0.name.contains("(") },
            "no model row may restate the effort the Effort row owns"
        )
    }

    /// Codex declares a base-model option, so choosing a model goes through
    /// `session/set_config_option` — which leaves the effort alone — rather than
    /// the legacy `session/set_model`, which would carry an effort with it.
    func testCodexModelChoiceIsDeliveredAsAConfigOption() {
        XCTAssertEqual(CodexFixture.surface().modelTarget, .configOption("model"))
        XCTAssertEqual(CodexFixture.surface().models.map(\.id), ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
    }

    /// The drift that makes this a correctness bug and not only a tidiness one.
    /// Setting the effort to Low leaves `models.currentModelId` at
    /// `gpt-5.6-sol[max]` — the adapter sends no model update — so a menu built
    /// from the raw payload would show Model "GPT-5.6-Sol (max)" beside Effort
    /// "Low" and be wrong about which one is running.
    func testChangingTheEffortNeverLeavesTheModelRowQuotingTheOldOne() {
        let rows = AcpComposerMenu.rows(agentName: "Codex", surface: CodexFixture.surface(effort: "low"))
        XCTAssertEqual(rows.map(\.value), ["Codex", "GPT-5.6-Sol", "Default", "Low", "Off"])
        XCTAssertFalse(rows.contains { $0.value.lowercased().contains("max") })
    }

    /// The permission chip already renders `modes`. An option offering those
    /// same ids is that chip a second time, so it earns no row.
    func testAnOptionThatRestatesThePermissionModesIsDropped() {
        XCTAssertFalse(CodexFixture.surface().options.contains { $0.id == "mode" })
        // …but only because the ids match. An adapter whose `mode`-ish option
        // offers something else keeps its row.
        let kept = AcpComposerSurface.reconciled(
            models: [],
            currentModelID: nil,
            modes: CodexFixture.modes,
            configOptions: [AcpConfigOption(
                id: "approval", name: "Approval", currentValue: "always", choices: [
                    .init(value: "always", name: "Always"), .init(value: "never", name: "Never"),
                ]
            )]
        )
        XCTAssertEqual(kept.options.map(\.id), ["approval"])
    }

    /// An adapter that bakes the effort into its model names *and* declares a
    /// separate Effort option, but offers no base-model option: the names are
    /// stripped and the variants folded, and the id kept for `session/set_model`
    /// is the one at the effort in force, so choosing a model preserves it.
    func testEffortBakedIntoModelNamesIsStrippedWhenAnEffortRowOwnsIt() {
        let surface = AcpComposerSurface.reconciled(
            models: CodexFixture.models,
            currentModelID: "gpt-5.6-sol[max]",
            modes: [],
            configOptions: CodexFixture.configOptions(effort: "high")
                .filter { $0.id == "reasoning_effort" }
        )
        XCTAssertEqual(surface.modelTarget, .setModel)
        XCTAssertEqual(surface.models.map(\.name), ["GPT-5.6-Sol", "GPT-5.6-Terra", "GPT-5.6-Luna"])
        XCTAssertEqual(
            surface.models.map(\.id),
            ["gpt-5.6-sol[high]", "gpt-5.6-terra[high]", "gpt-5.6-luna[high]"]
        )
        XCTAssertEqual(surface.currentModelID, "gpt-5.6-sol[high]")
    }

    /// No variant at the effort in force — the fixture's Luna stops at `high`,
    /// exactly as the real one stops short of `ultra`. The row still resolves to
    /// a real id rather than vanishing; the adapter reports whatever effort it
    /// lands on and the Effort row follows it.
    func testAModelWithNoVariantAtThisEffortStillResolves() {
        let surface = AcpComposerSurface.reconciled(
            models: CodexFixture.models,
            currentModelID: "gpt-5.6-sol[max]",
            modes: [],
            configOptions: CodexFixture.configOptions(effort: "xhigh")
                .filter { $0.id == "reasoning_effort" }
        )
        XCTAssertEqual(
            surface.models.map(\.id),
            ["gpt-5.6-sol[xhigh]", "gpt-5.6-terra[xhigh]", "gpt-5.6-luna[low]"]
        )
    }

    /// The other shape the spec allows: effort lives *only* in the model names,
    /// with no option of its own. Then the model row is the only thing that can
    /// carry it, so nothing is stripped and no Effort row is invented.
    func testEffortLivingOnlyInModelNamesStaysOnTheModelRow() {
        let surface = AcpComposerSurface.reconciled(
            models: CodexFixture.models,
            currentModelID: "gpt-5.6-sol[max]",
            modes: [],
            configOptions: [AcpConfigOption(
                id: "fast-mode", name: "Fast mode", category: "model_config", currentValue: "off",
                choices: [.init(value: "off", name: "Off"), .init(value: "on", name: "On")]
            )]
        )
        let rows = AcpComposerMenu.rows(agentName: "Codex", surface: surface)
        XCTAssertEqual(rows.map(\.label), ["Agent", "Model", "Fast mode"])
        XCTAssertEqual(rows.first { $0.target == .model }?.value, "GPT-5.6-Sol (max)")
        XCTAssertFalse(rows.contains { $0.label == "Effort" })
        XCTAssertEqual(surface.models.count, CodexFixture.models.count)
    }

    /// The control: Claude declares a flat model list, no effort anywhere near
    /// it, and one option. Reconciling must be a no-op.
    func testTheClaudeShapePassesThroughUntouched() {
        let surface = claudeSurface()
        XCTAssertEqual(surface.models, models)
        XCTAssertEqual(surface.currentModelID, "claude-sonnet-4-5")
        XCTAssertEqual(surface.modelTarget, .setModel)
        XCTAssertEqual(surface.options.map(\.id), ["effort"])
    }

    /// `[xhigh]` is not a stray `high`, and a model that merely rhymes with an
    /// effort level keeps its whole name.
    func testTheEffortSuffixIsReadWholeOrNotAtAll() {
        let values = ["low", "high", "xhigh", "max"]
        XCTAssertEqual(AcpComposerSurface.effortSuffix("gpt-5.6-sol[xhigh]", values: values)?.effort, "xhigh")
        XCTAssertEqual(AcpComposerSurface.effortSuffix("gpt-5.6-sol[xhigh]", values: values)?.base, "gpt-5.6-sol")
        XCTAssertEqual(AcpComposerSurface.effortSuffix("GPT-5.6-Sol (max)", values: values)?.base, "GPT-5.6-Sol")
        XCTAssertEqual(AcpComposerSurface.effortSuffix("sonnet-high", values: values)?.base, "sonnet")
        XCTAssertNil(AcpComposerSurface.effortSuffix("gpt-highlander", values: values))
        XCTAssertNil(AcpComposerSurface.effortSuffix("low", values: values), "nothing left of the name")
    }

    /// The adapter's own `category` decides, so Codex's `collaboration_mode` is
    /// never mistaken for its `mode` despite the word they share.
    func testTheDeclaredCategoryDecidesWhichOptionIsTheEffort() {
        XCTAssertEqual(
            AcpComposerMetrics.effortOption(CodexFixture.configOptions())?.id,
            "reasoning_effort"
        )
        // No category declared: the wording is the fallback, as before.
        XCTAssertEqual(
            AcpComposerMetrics.effortOption([
                AcpConfigOption(id: "preset", name: "Approval preset", currentValue: "a", choices: []),
                effortOption,
            ])?.id,
            "effort"
        )
        XCTAssertNil(AcpComposerMetrics.effortOption([]))
    }

    // MARK: - Submenus

    func testModelSubmenuChecksTheCurrentRowAndCaptionsAUsefulIdentifier() {
        let submenu = AcpComposerMenu.modelSubmenu(
            surface: AcpComposerSurface(
                models: [
                    AcpSessionInfo.Model(id: "gpt-5.6-sol", name: "GPT-5.6-Sol"),
                    AcpSessionInfo.Model(id: "claude-sonnet-4-5-20250929", name: "Sonnet 4.5"),
                ],
                currentModelID: "claude-sonnet-4-5-20250929"
            ),
            favorites: [],
            query: ""
        )
        XCTAssertEqual(submenu.title, "Model")
        XCTAssertEqual(submenu.options.map(\.isSelected), [false, true])
        XCTAssertNil(submenu.options[0].caption)
        XCTAssertEqual(submenu.options[1].caption, "claude-sonnet-4-5-20250929")
        XCTAssertTrue(submenu.options.allSatisfy(\.isEnabled))
    }

    /// Favourites survive the redesign only as a group that floats to the top.
    /// There is no star column, so nothing about the row says "favourite".
    func testModelSubmenuFloatsFavouritesWithoutMarkingThem() {
        let submenu = AcpComposerMenu.modelSubmenu(
            surface: AcpComposerSurface(models: models, currentModelID: "claude-opus-4-5"),
            favorites: ["claude-haiku-4-5"],
            query: ""
        )
        XCTAssertEqual(submenu.options.map(\.name), ["Haiku 4.5", "Opus 4.5", "Sonnet 4.5"])
        XCTAssertEqual(submenu.options.map(\.isSelected), [false, true, false])
    }

    func testModelSubmenuStillFiltersOnAQuery() {
        let submenu = AcpComposerMenu.modelSubmenu(
            surface: AcpComposerSurface(models: models), favorites: [], query: "haiku"
        )
        XCTAssertEqual(submenu.options.map(\.name), ["Haiku 4.5"])
    }

    /// Search is a cost, not a feature: it only appears once a submenu is long
    /// enough that scanning it stops working.
    func testSearchAppearsOnlyBeyondEightOptions() {
        func submenu(count: Int) -> AcpComposerSubmenu {
            AcpComposerMenu.modelSubmenu(
                surface: AcpComposerSurface(
                    models: (1...count).map { AcpSessionInfo.Model(id: "m\($0)", name: "Model \($0)") }
                ),
                favorites: [],
                query: ""
            )
        }
        XCTAssertFalse(submenu(count: 8).showsSearch)
        XCTAssertTrue(submenu(count: 9).showsSearch)
    }

    func testOptionSubmenuMarksTheChosenValue() {
        let submenu = AcpComposerMenu.optionSubmenu(effortOption)
        XCTAssertEqual(submenu.title, "Effort")
        XCTAssertEqual(submenu.note, "Applies to the next message in this chat.")
        XCTAssertEqual(submenu.options.map(\.name), ["Light", "Medium", "High"])
        XCTAssertEqual(submenu.options.map(\.isSelected), [true, false, false])
        XCTAssertFalse(submenu.showsSearch)
    }

    func testNonEffortOptionsDoNotInventTimingSemantics() {
        let submenu = AcpComposerMenu.optionSubmenu(AcpConfigOption(
            id: "approval_preset",
            name: "Approval preset",
            currentValue: "default",
            choices: [.init(value: "default", name: "Default")]
        ))
        XCTAssertNil(submenu.note)
    }

    // MARK: - Agent submenu

    private var registryAgents: [AgentProfile] {
        [
            AgentProfile(id: "claude-code", name: "Claude", launchCommand: "claude", symbol: "sparkle"),
            AgentProfile(id: "codex", name: "Codex", launchCommand: "codex", symbol: "chevron.left.forwardslash.chevron.right"),
            AgentProfile(id: "opencode", name: "OpenCode", launchCommand: "opencode", symbol: "curlybraces"),
        ]
    }

    private func chatCapable(_ id: String) -> Bool { id == "claude-code" || id == "codex" }

    func testAgentSubmenuChecksTheAgentDrivingThisChat() {
        let submenu = AcpComposerMenu.agentSubmenu(
            agents: registryAgents,
            currentAgentID: "codex",
            isChatCapable: chatCapable
        )
        XCTAssertEqual(submenu.title, "Agent")
        XCTAssertEqual(submenu.options.map(\.id), ["claude-code", "codex", "opencode"])
        XCTAssertEqual(submenu.options.map(\.isSelected), [false, true, false])
    }

    /// The one thing this menu must never do is imply the conversation moves.
    /// Every switchable row says, in its own caption, what pressing it does.
    func testEveryOtherAgentSaysItStartsANewChat() {
        let submenu = AcpComposerMenu.agentSubmenu(
            agents: registryAgents, currentAgentID: "codex", isChatCapable: chatCapable
        )
        XCTAssertNil(submenu.options[1].caption)
        XCTAssertEqual(submenu.options[0].caption, "Starts a new chat")
    }

    /// An agent with no ACP adapter cannot drive a chat at all. Hiding it would
    /// read as an omission; listing it disabled with the reason is the truth.
    func testAgentsWithoutAnAdapterStayVisibleButUnselectable() {
        let submenu = AcpComposerMenu.agentSubmenu(
            agents: registryAgents, currentAgentID: "claude-code", isChatCapable: chatCapable
        )
        let openCode = try? XCTUnwrap(submenu.options.first { $0.id == "opencode" })
        XCTAssertEqual(openCode?.isEnabled, false)
        XCTAssertEqual(openCode?.caption, "Terminal only — no chat adapter")
        XCTAssertEqual(submenu.options.filter(\.isEnabled).map(\.id), ["claude-code", "codex"])
    }

    // MARK: - Agent switch

    func testChoosingTheCurrentAgentDoesNothing() {
        XCTAssertEqual(
            AcpAgentSwitch.decision(agentID: "codex", currentAgentID: "codex", isChatCapable: chatCapable),
            .alreadyCurrent
        )
    }

    func testChoosingAnAgentWithoutAnAdapterIsRefused() {
        XCTAssertEqual(
            AcpAgentSwitch.decision(agentID: "opencode", currentAgentID: "codex", isChatCapable: chatCapable),
            .unavailable
        )
    }

    /// ACP binds a conversation to one adapter process for its whole life:
    /// there is no protocol move. So the honest switch is a new chat beside the
    /// old one, which stays open with its transcript intact.
    func testChoosingAnotherChatCapableAgentStartsANewChat() {
        XCTAssertEqual(
            AcpAgentSwitch.decision(agentID: "claude-code", currentAgentID: "codex", isChatCapable: chatCapable),
            .startNewChat("claude-code")
        )
    }

    // MARK: - Advanced disclosure

    func testAdvancedStatesWhatTheChipCannotHold() {
        let lines = AcpComposerMenu.advancedLines(
            usage: AcpUsage(used: 12_000, max: 1_000_000),
            surface: AcpComposerSurface(
                models: [AcpSessionInfo.Model(id: "claude-sonnet-4-5-20250929", name: "Sonnet 4.5")],
                currentModelID: "claude-sonnet-4-5-20250929"
            )
        )
        XCTAssertEqual(lines, ["Context used: 12k of 1M", "Model id: claude-sonnet-4-5-20250929"])
    }

    /// Nothing to disclose, no disclosure: the row is hidden rather than
    /// opening onto an empty panel.
    func testAdvancedDisappearsWhenThereIsNothingToSay() {
        XCTAssertTrue(AcpComposerMenu.advancedLines(usage: nil, surface: AcpComposerSurface()).isEmpty)
        XCTAssertTrue(AcpComposerMenu.advancedLines(
            usage: AcpUsage(used: 0, max: 0),
            surface: AcpComposerSurface(
                models: [AcpSessionInfo.Model(id: "sonnet", name: "Sonnet")],
                currentModelID: "sonnet"
            )
        ).isEmpty)
    }

    // MARK: - Keyboard navigation

    func testArrowKeysWrapAroundTheRows() {
        XCTAssertEqual(AcpComposerMenu.move(from: nil, by: 1, count: 3), 0)
        XCTAssertEqual(AcpComposerMenu.move(from: nil, by: -1, count: 3), 2)
        XCTAssertEqual(AcpComposerMenu.move(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(AcpComposerMenu.move(from: 0, by: -1, count: 3), 2)
        XCTAssertNil(AcpComposerMenu.move(from: nil, by: 1, count: 0))
    }

    /// Arrowing past a disabled row must not park the highlight on something
    /// Return cannot activate.
    func testArrowKeysSkipDisabledRows() {
        let enabled = [true, false, true]
        XCTAssertEqual(AcpComposerMenu.move(from: 0, by: 1, enabled: enabled), 2)
        XCTAssertEqual(AcpComposerMenu.move(from: 2, by: 1, enabled: enabled), 0)
        XCTAssertEqual(AcpComposerMenu.move(from: 0, by: -1, enabled: enabled), 2)
        XCTAssertNil(AcpComposerMenu.move(from: nil, by: 1, enabled: [false, false]))
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

    /// The pill reads `<primary> <secondary in grey> ⌄`: the model, then the
    /// setting most likely to have been changed since.
    func testPillReadsModelThenEffort() {
        let values = AcpComposerMenu.chipValues(
            agentName: "Codex",
            modelName: "GPT-5.6-Sol",
            option: effortOption
        )
        XCTAssertEqual(values.primary, "GPT-5.6-Sol")
        XCTAssertEqual(values.secondary, "Light")
    }

    func testPillFallsBackToTheAgentWhenNoModelIsDeclared() {
        let values = AcpComposerMenu.chipValues(agentName: "Claude", modelName: nil, option: nil)
        XCTAssertEqual(values.primary, "Claude")
        XCTAssertNil(values.secondary)
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

extension AcpComposerModelTests {
    func testBooleanConfigOptionBecomesAnAccessibleSwitchRowWithAdapterCopy() {
        let boolean = AcpConfigOption(
            id: "brave_mode",
            name: "Brave Mode",
            description: "Skip confirmation prompts and act autonomously",
            category: "model_config",
            currentBooleanValue: true
        )
        let surface = AcpComposerSurface.reconciled(
            models: [], currentModelID: nil, modes: [], configOptions: [boolean]
        )

        let row = AcpComposerMenu.rows(agentName: "Agent", surface: surface)[1]
        XCTAssertEqual(row.target, .option("brave_mode"))
        XCTAssertEqual(row.label, "Brave Mode")
        XCTAssertEqual(row.booleanValue, true)
        XCTAssertEqual(row.hint, "Skip confirmation prompts and act autonomously")
        XCTAssertEqual(row.accessibilityValue, "On")
    }

    func testBooleanCapabilityParsingAndMutationPreserveWireType() async throws {
        let transport = BooleanConfigWireTransport()
        let client = AcpClient(transport: transport)

        let info = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        XCTAssertEqual(info.configOptions.map(\.id), ["brave_mode"])
        XCTAssertEqual(info.configOptions.first?.booleanValue, false)
        XCTAssertNil(info.configOptions.first?.currentValue)
        let advertised = await transport.advertisedBooleanConfigSupport()
        XCTAssertTrue(advertised)

        let confirmed = try await client.setConfigOption(id: "brave_mode", value: .boolean(true))
        XCTAssertEqual(confirmed.first?.booleanValue, true)
        let recorded = await transport.lastConfigRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request["configId"]?.stringValue, "brave_mode")
        XCTAssertEqual(request["type"]?.stringValue, "boolean")
        XCTAssertEqual(request["value"]?.boolValue, true)
    }

    func testUnknownAndMalformedBooleanOptionTypesFailClosed() {
        let parsed = AcpBooleanConfigWire.parseOptions(.array([
            .object([
                "id": .string("known"), "name": .string("Known"),
                "type": .string("boolean"), "currentValue": .bool(true),
            ]),
            .object([
                "id": .string("future"), "name": .string("Future"),
                "type": .string("slider"), "currentValue": .integer(3),
            ]),
            .object([
                "id": .string("wrong-shape"), "name": .string("Wrong shape"),
                "type": .string("boolean"), "currentValue": .string("true"),
            ]),
        ]))

        XCTAssertEqual(parsed.map(\.id), ["known"])
        XCTAssertEqual(parsed.first?.booleanValue, true)
    }

    @MainActor
    func testRejectedBooleanChangeKeepsConfirmedValueAndReportsRollback() async throws {
        let transport = BooleanConfigConversationTransport(rejectChanges: true)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport)
        )
        await conversation.start()

        conversation.selectBooleanConfigOption("brave_mode", value: true)

        XCTAssertEqual(conversation.pendingConfigOptionID, "brave_mode")
        XCTAssertEqual(conversation.configOptions.first?.booleanValue, false)
        let deadline = ContinuousClock.now + .seconds(2)
        while conversation.pendingConfigOptionID != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(conversation.pendingConfigOptionID)
        XCTAssertEqual(conversation.configOptions.first?.booleanValue, false)
        XCTAssertTrue(conversation.statusMessage?.contains("Couldn’t change Brave Mode to On") == true)
    }

    @MainActor
    func testPersistedBooleanValueRestoresThroughAdapterConfirmation() async throws {
        let draftKey = "boolean-config-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        let firstTransport = BooleanConfigConversationTransport()
        let firstConversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: firstTransport), draftKey: draftKey
        )
        await firstConversation.start()
        firstConversation.selectBooleanConfigOption("brave_mode", value: true)
        let deadline = ContinuousClock.now + .seconds(2)
        while firstConversation.pendingConfigOptionID != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            AcpConversation.loadPersistedBooleanConfigValues(for: draftKey),
            ["brave_mode": true]
        )
        _ = await firstConversation.stop()

        let restoredTransport = BooleanConfigConversationTransport()
        let restoredConversation = AcpConversation(
            title: "Restored", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: restoredTransport), draftKey: draftKey
        )
        await restoredConversation.start()

        XCTAssertEqual(restoredConversation.configOptions.first?.booleanValue, true)
        XCTAssertEqual(restoredConversation.confirmedBooleanConfigValues, ["brave_mode": true])
        let restoredSetValues = await restoredTransport.setValues()
        XCTAssertEqual(restoredSetValues, [true])

        AcpConversation.removePersistedDraft(
            for: draftKey,
            currentDefaults: .standard,
            migratedDefaults: nil
        )
        XCTAssertTrue(AcpConversation.loadPersistedBooleanConfigValues(for: draftKey).isEmpty)
    }

    @MainActor
    func testBooleanConfirmationArrivingAfterStopCannotOverwriteDurableValue() async {
        let draftKey = "boolean-stale-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        let transport = BooleanConfigConversationTransport(holdChanges: true)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport), draftKey: draftKey
        )
        await conversation.start()

        conversation.selectBooleanConfigOption("brave_mode", value: true)
        await transport.waitForSetRequest()
        _ = await conversation.stop()
        await transport.resolveHeldChange()
        await Task.yield()

        XCTAssertNil(conversation.pendingConfigOptionID)
        XCTAssertEqual(conversation.configOptions.first?.booleanValue, false)
        XCTAssertEqual(conversation.confirmedBooleanConfigValues, ["brave_mode": false])
        XCTAssertEqual(
            AcpConversation.loadPersistedBooleanConfigValues(for: draftKey),
            ["brave_mode": false]
        )
    }

    /// A restart must not quietly demote "Full access" back to asking: the
    /// selected permission mode is a per-chat decision, persisted under the
    /// chat's draft key and re-applied to the fresh adapter session.
    @MainActor
    func testSelectedPermissionModeRestoresAcrossConversationLifetimes() async throws {
        let draftKey = "permission-mode-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        let firstConversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: PermissionModeConversationTransport()),
            draftKey: draftKey
        )
        await firstConversation.start()
        XCTAssertEqual(firstConversation.currentModeID, "default")

        firstConversation.selectMode("bypassPermissions")
        let persistDeadline = ContinuousClock.now + .seconds(2)
        while AcpConversation.loadPersistedModeID(for: draftKey) == nil,
              ContinuousClock.now < persistDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(AcpConversation.loadPersistedModeID(for: draftKey), "bypassPermissions")
        _ = await firstConversation.stop()

        let restoredTransport = PermissionModeConversationTransport()
        let restoredConversation = AcpConversation(
            title: "Restored", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: restoredTransport),
            draftKey: draftKey
        )
        await restoredConversation.start()

        XCTAssertEqual(restoredConversation.currentModeID, "bypassPermissions")
        let restoredRequests = await restoredTransport.modeRequests()
        XCTAssertEqual(restoredRequests, ["bypassPermissions"])

        AcpConversation.removePersistedDraft(
            for: draftKey,
            currentDefaults: .standard,
            migratedDefaults: nil
        )
        XCTAssertNil(AcpConversation.loadPersistedModeID(for: draftKey))
    }

    /// A remembered mode the adapter no longer declares is never sent: the
    /// adapter's own current mode stands rather than a guessed restoration.
    @MainActor
    func testRememberedModeAbsentFromAdapterKeepsAdapterCurrentMode() async throws {
        let draftKey = "permission-mode-gone-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        UserDefaults.standard.set(
            "vanished-mode",
            forKey: AcpConversation.persistedModeDefaultsKeys(for: draftKey).first!
        )
        let transport = PermissionModeConversationTransport()
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport),
            draftKey: draftKey
        )
        await conversation.start()

        XCTAssertEqual(conversation.currentModeID, "default")
        let requests = await transport.modeRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    /// A switch the adapter refuses must not stick: the chip rolls back to the
    /// confirmed mode and nothing is persisted, so the chip never claims "Ask"
    /// while the adapter quietly stays on full access (or the reverse).
    @MainActor
    func testRejectedModeChangeRollsBackTheChipAndPersistsNothing() async throws {
        let draftKey = "permission-mode-rejected-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        let transport = PermissionModeConversationTransport(
            rejectedModeIDs: ["bypassPermissions"]
        )
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport),
            draftKey: draftKey
        )
        await conversation.start()
        XCTAssertEqual(conversation.currentModeID, "default")

        conversation.selectMode("bypassPermissions")

        let deadline = ContinuousClock.now + .seconds(2)
        while conversation.currentModeID != "default", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            conversation.currentModeID,
            "default",
            "a refused switch must roll the chip back to the adapter-confirmed mode"
        )
        XCTAssertNil(
            AcpConversation.loadPersistedModeID(for: draftKey),
            "a refused mode must never be remembered"
        )
    }

    /// A remembered mode the adapter still declares but refuses to enter is
    /// not replayed on every launch: the adapter's current mode stands and the
    /// memory realigns to it.
    @MainActor
    func testRememberedModeTheAdapterRefusesFallsBackAndRealignsMemory() async throws {
        let draftKey = "permission-mode-refused-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        UserDefaults.standard.set(
            "bypassPermissions",
            forKey: AcpConversation.persistedModeDefaultsKeys(for: draftKey).first!
        )
        let transport = PermissionModeConversationTransport(
            rejectedModeIDs: ["bypassPermissions"]
        )
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport),
            draftKey: draftKey
        )
        await conversation.start()

        XCTAssertEqual(
            conversation.currentModeID,
            "default",
            "a refused restoration must keep the adapter's own current mode on screen"
        )
        let requests = await transport.modeRequests()
        XCTAssertEqual(requests, ["bypassPermissions"], "the restoration is attempted exactly once")
        XCTAssertEqual(
            AcpConversation.loadPersistedModeID(for: draftKey),
            "default",
            "memory realigns to the adapter's mode so the refusal is not retried every launch"
        )
    }

    /// The seconds right after a relaunch are exactly when someone re-opens a
    /// chat and flips its permission: the adapter is still spawning, there is
    /// no session to ask yet, and the choice must be kept — displayed,
    /// remembered, and applied by the connect handshake — not silently
    /// snapped back.
    @MainActor
    func testModeChosenWhileConnectingIsKeptAndAppliedOnConnect() async throws {
        let draftKey = "permission-mode-preconnect-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        let transport = PermissionModeConversationTransport()
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport),
            draftKey: draftKey
        )

        conversation.selectMode("bypassPermissions")

        let persistDeadline = ContinuousClock.now + .seconds(2)
        while AcpConversation.loadPersistedModeID(for: draftKey) == nil,
              ContinuousClock.now < persistDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            AcpConversation.loadPersistedModeID(for: draftKey),
            "bypassPermissions",
            "a choice made before the session exists is still a choice"
        )
        XCTAssertEqual(conversation.currentModeID, "bypassPermissions")

        await conversation.start()

        XCTAssertEqual(
            conversation.currentModeID,
            "bypassPermissions",
            "the connect handshake applies the kept choice"
        )
        let requests = await transport.modeRequests()
        XCTAssertEqual(requests, ["bypassPermissions"])
    }

    /// `session/load` replays historical notifications before its response. A
    /// replayed mode announcement is history, not a decision: it must not
    /// overwrite the remembered per-chat mode before the restore handshake
    /// has run, or the memory wipes itself on every relaunch.
    @MainActor
    func testConnectTimeModeAnnouncementDoesNotWipeTheMemory() async throws {
        let draftKey = "permission-mode-replay-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        UserDefaults.standard.set(
            "bypassPermissions",
            forKey: AcpConversation.persistedModeDefaultsKeys(for: draftKey).first!
        )
        let transport = PermissionModeConversationTransport(
            advertiseLoadSession: true,
            announceModeOnLoad: "default"
        )
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport),
            draftKey: draftKey,
            resumeSessionID: "mode-session"
        )
        await conversation.start()

        let deadline = ContinuousClock.now + .seconds(2)
        while (conversation.currentModeID != "bypassPermissions"
            || AcpConversation.loadPersistedModeID(for: draftKey) != "bypassPermissions"),
            ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            AcpConversation.loadPersistedModeID(for: draftKey),
            "bypassPermissions",
            "a replayed announcement must not rewrite the remembered mode"
        )
        XCTAssertEqual(
            conversation.currentModeID,
            "bypassPermissions",
            "the restore handshake wins over replayed history"
        )
        let requests = await transport.modeRequests()
        XCTAssertEqual(requests, ["bypassPermissions"])
    }

    /// A mode picked while the connect restore is still in flight must win
    /// over it: the restore's late continuation used to overwrite the display
    /// with the older mode, and the equality guard then discarded the
    /// accepted user choice — adapter on the new mode, UI and memory on the
    /// old one.
    @MainActor
    func testUserSelectionDuringConnectRestoreOutranksTheRestore() async throws {
        let draftKey = "permission-mode-race-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        UserDefaults.standard.set(
            "bypassPermissions",
            forKey: AcpConversation.persistedModeDefaultsKeys(for: draftKey).first!
        )
        let transport = PermissionModeConversationTransport(holdFirstSetModeUntilSecond: true)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport),
            draftKey: draftKey
        )

        let startTask = Task { await conversation.start() }
        // Wait for the restore's set_mode to be parked at the transport, so
        // the user selection genuinely races the in-flight handshake.
        let raceDeadline = ContinuousClock.now + .seconds(2)
        while await transport.modeRequests().count < 1, ContinuousClock.now < raceDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        conversation.selectMode("acceptEdits")
        await startTask.value

        let deadline = ContinuousClock.now + .seconds(2)
        while (conversation.currentModeID != "acceptEdits"
            || AcpConversation.loadPersistedModeID(for: draftKey) != "acceptEdits"),
            ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            conversation.currentModeID,
            "acceptEdits",
            "the user's mid-handshake choice stays on screen"
        )
        XCTAssertEqual(
            AcpConversation.loadPersistedModeID(for: draftKey),
            "acceptEdits",
            "the accepted choice is remembered even though the restore resolved after it"
        )
    }

    /// After the handshake, adapter-side switches (plan-mode exits, in-band
    /// slash commands) are the chat's mode and keep updating the memory.
    @MainActor
    func testAdapterModeSwitchAfterConnectIsStillRemembered() async throws {
        let draftKey = "permission-mode-adapter-switch-\(UUID().uuidString)"
        defer {
            AcpConversation.removePersistedDraft(
                for: draftKey,
                currentDefaults: .standard,
                migratedDefaults: nil
            )
        }
        let transport = PermissionModeConversationTransport()
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport),
            draftKey: draftKey
        )
        await conversation.start()
        XCTAssertEqual(conversation.currentModeID, "default")

        await transport.announceMode("acceptEdits")

        let deadline = ContinuousClock.now + .seconds(2)
        while AcpConversation.loadPersistedModeID(for: draftKey) != "acceptEdits",
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.currentModeID, "acceptEdits")
        XCTAssertEqual(
            AcpConversation.loadPersistedModeID(for: draftKey),
            "acceptEdits",
            "post-handshake adapter switches still update the memory"
        )
    }

    @MainActor
    func testRejectedEffortChangeKeepsTheAdapterConfirmedValueAndDraft() async throws {
        let transport = ReasoningEffortAcpTransport(rejectedValues: ["high"])
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport),
            initialDraft: "keep this unsent draft"
        )
        await conversation.start()
        XCTAssertEqual(conversation.configOptions.first?.currentValue, "low")

        conversation.selectConfigOption("reasoning_effort", value: "high")

        XCTAssertEqual(conversation.pendingConfigOptionID, "reasoning_effort")
        XCTAssertEqual(
            conversation.configOptions.first?.currentValue,
            "low",
            "the picker must not claim an unconfirmed effort while the adapter decides"
        )
        let deadline = ContinuousClock.now + .seconds(2)
        while conversation.statusMessage == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.configOptions.first?.currentValue, "low")
        XCTAssertNil(conversation.pendingConfigOptionID)
        XCTAssertTrue(conversation.statusMessage?.contains("Rejected reasoning effort") == true)
        XCTAssertEqual(conversation.loadDraft(), "keep this unsent draft")
        XCTAssertTrue(conversation.rows.isEmpty)
        XCTAssertFalse(conversation.isRunning)
    }

    @MainActor
    func testEffortChangesOnlyAfterAdapterConfirmation() async throws {
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: ReasoningEffortAcpTransport()),
            initialDraft: "another unsent draft"
        )
        await conversation.start()

        conversation.selectConfigOption("reasoning_effort", value: "high")

        XCTAssertEqual(conversation.pendingConfigOptionID, "reasoning_effort")
        XCTAssertEqual(conversation.configOptions.first?.currentValue, "low")
        let deadline = ContinuousClock.now + .seconds(2)
        while conversation.pendingConfigOptionID != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(conversation.pendingConfigOptionID)
        XCTAssertEqual(conversation.configOptions.first?.currentValue, "high")
        XCTAssertEqual(conversation.loadDraft(), "another unsent draft")
        XCTAssertTrue(conversation.rows.isEmpty)
    }

    func testConfirmedEffortRestoresFromTheAdapterSession() async throws {
        let transport = ReasoningEffortAcpTransport()
        let client = AcpClient(transport: transport)
        let opened = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        XCTAssertEqual(opened.configOptions.first?.currentValue, "low")
        let confirmed = try await client.setConfigOption(id: "reasoning_effort", value: "high")
        XCTAssertEqual(confirmed.first?.currentValue, "high")

        await client.stop()
        let restored = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [], resumeSessionID: opened.sessionID
        )
        XCTAssertEqual(restored.sessionID, opened.sessionID)
        XCTAssertEqual(
            restored.configOptions.first?.currentValue,
            "high",
            "restore must use the adapter-confirmed session value, not a local guess"
        )
    }
}

/// Narrow ACP fixture for reasoning-effort state. It persists the confirmed
/// value across a client stop/resume and can reject selected values without
/// spawning a process or sharing the broader AcpClientTests transport.
private actor ReasoningEffortAcpTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var effort = "low"
    private let rejectedValues: Set<String>

    init(rejectedValues: Set<String> = []) {
        self.rejectedValues = rejectedValues
    }

    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: trimmed(data)).objectValue else {
            return
        }
        let id = object["id"]
        switch object["method"]?.stringValue {
        case "initialize":
            reply(id: id, result: .object([
                "protocolVersion": .integer(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "sessionCapabilities": .object(["resume": .bool(true)]),
                ]),
            ]))
        case "session/new":
            reply(id: id, result: sessionResult(id: "effort-session"))
        case "session/load", "session/resume":
            let sessionID = object["params"]?.objectValue?["sessionId"]?.stringValue ?? "effort-session"
            reply(id: id, result: sessionResult(id: sessionID))
        case "session/set_config_option":
            guard let params = object["params"]?.objectValue,
                  params["configId"]?.stringValue == "reasoning_effort",
                  let value = params["value"]?.stringValue else {
                replyError(id: id, message: "Unknown config option")
                return
            }
            guard !rejectedValues.contains(value) else {
                replyError(id: id, message: "Rejected reasoning effort: \(value)")
                return
            }
            effort = value
            reply(id: id, result: .object(["configOptions": configOptions()]))
        default:
            if let id { reply(id: id, result: .null) }
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func terminate() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { 0 }

    private func sessionResult(id: String) -> JSONValue {
        .object([
            "sessionId": .string(id),
            "configOptions": configOptions(),
        ])
    }

    private func configOptions() -> JSONValue {
        .array([
            .object([
                "id": .string("reasoning_effort"),
                "name": .string("Reasoning effort"),
                "category": .string("thought_level"),
                "type": .string("select"),
                "currentValue": .string(effort),
                "options": .array([
                    .object(["value": .string("low"), "name": .string("Low")]),
                    .object(["value": .string("high"), "name": .string("High")]),
                ]),
            ]),
        ])
    }

    private func reply(id: JSONValue?, result: JSONValue) {
        guard let id else { return }
        enqueue(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func replyError(id: JSONValue?, message: String) {
        guard let id else { return }
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(-32602), "message": .string(message)]),
        ]))
    }

    private func enqueue(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }

    private func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}

/// Stateful boolean option fixture. Every successful set response is the
/// adapter's complete confirmed option list, matching ACP rather than letting
/// the conversation infer success from its own request.
private actor BooleanConfigConversationTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var enabled = false
    private var requestedValues: [Bool] = []
    private let rejectChanges: Bool
    private let holdChanges: Bool
    private var heldChange: (id: JSONValue?, value: Bool)?
    private var setWaiters: [CheckedContinuation<Void, Never>] = []

    init(rejectChanges: Bool = false, holdChanges: Bool = false) {
        self.rejectChanges = rejectChanges
        self.holdChanges = holdChanges
    }

    func start(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: trimmed(data)).objectValue else {
            return
        }
        let id = object["id"]
        switch object["method"]?.stringValue {
        case "initialize":
            reply(id: id, result: .object([
                "protocolVersion": .integer(1),
                "agentCapabilities": .object([:]),
            ]))
        case "session/new":
            reply(id: id, result: sessionResult)
        case "session/set_config_option":
            guard let params = object["params"]?.objectValue,
                  params["configId"]?.stringValue == "brave_mode",
                  params["type"]?.stringValue == "boolean",
                  let value = params["value"]?.boolValue else {
                replyError(id: id, message: "Malformed boolean config request")
                return
            }
            requestedValues.append(value)
            let waiters = setWaiters
            setWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            guard !rejectChanges else {
                replyError(id: id, message: "Rejected Brave Mode")
                return
            }
            if holdChanges {
                heldChange = (id, value)
                return
            }
            enabled = value
            reply(id: id, result: .object(["configOptions": configOptions]))
        default:
            if let id { reply(id: id, result: .null) }
        }
    }

    func setValues() -> [Bool] { requestedValues }

    func waitForSetRequest() async {
        if !requestedValues.isEmpty { return }
        await withCheckedContinuation { setWaiters.append($0) }
    }

    func resolveHeldChange() {
        guard let heldChange else { return }
        self.heldChange = nil
        enabled = heldChange.value
        reply(id: heldChange.id, result: .object(["configOptions": configOptions]))
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func terminate() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { 0 }

    private var sessionResult: JSONValue {
        .object(["sessionId": .string("boolean-session"), "configOptions": configOptions])
    }

    private var configOptions: JSONValue {
        .array([.object([
            "id": .string("brave_mode"),
            "name": .string("Brave Mode"),
            "description": .string("Skip confirmation prompts and act autonomously"),
            "type": .string("boolean"),
            "currentValue": .bool(enabled),
        ])])
    }

    private func reply(id: JSONValue?, result: JSONValue) {
        guard let id else { return }
        enqueue(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func replyError(id: JSONValue?, message: String) {
        guard let id else { return }
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(-32602), "message": .string(message)]),
        ]))
    }

    private func enqueue(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }

    private func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}

/// Declares two permission modes and records `session/set_mode` requests so
/// per-chat mode persistence is proven across two conversation lifetimes.
private actor PermissionModeConversationTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var requestedModeIDs: [String] = []
    private let rejectedModeIDs: Set<String>
    private let advertiseLoadSession: Bool
    private let announceModeOnLoad: String?
    private let holdFirstSetModeUntilSecond: Bool
    private var heldSetModeReplyID: JSONValue?

    init(
        rejectedModeIDs: Set<String> = [],
        advertiseLoadSession: Bool = false,
        announceModeOnLoad: String? = nil,
        holdFirstSetModeUntilSecond: Bool = false
    ) {
        self.rejectedModeIDs = rejectedModeIDs
        self.advertiseLoadSession = advertiseLoadSession
        self.announceModeOnLoad = announceModeOnLoad
        self.holdFirstSetModeUntilSecond = holdFirstSetModeUntilSecond
    }

    func start(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: trimmed(data)).objectValue else {
            return
        }
        let id = object["id"]
        switch object["method"]?.stringValue {
        case "initialize":
            reply(id: id, result: .object([
                "protocolVersion": .integer(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(advertiseLoadSession),
                ]),
            ]))
        case "session/new":
            reply(id: id, result: sessionPayload(sessionID: "mode-session"))
        case "session/load":
            let sessionID = object["params"]?.objectValue?["sessionId"]?.stringValue ?? "mode-session"
            // The real adapter replays session notifications BEFORE the load
            // response; a historical mode announcement arriving first is the
            // exact hazard the memory arming exists for.
            if let announceModeOnLoad {
                announceMode(announceModeOnLoad, sessionID: sessionID)
            }
            reply(id: id, result: sessionPayload(sessionID: sessionID))
        case "session/set_mode":
            let modeID = object["params"]?.objectValue?["modeId"]?.stringValue
            if let modeID { requestedModeIDs.append(modeID) }
            if let modeID, rejectedModeIDs.contains(modeID) {
                replyError(id: id, message: "mode unavailable for this account")
            } else if holdFirstSetModeUntilSecond, heldSetModeReplyID == nil, requestedModeIDs.count == 1 {
                // Park the FIRST set_mode (the connect restore) so a user
                // selection can race past it — the interleave the fix is for.
                heldSetModeReplyID = id
            } else {
                reply(id: id, result: .null)
                if let held = heldSetModeReplyID {
                    heldSetModeReplyID = nil
                    reply(id: held, result: .null)
                }
            }
        default:
            if let id { reply(id: id, result: .null) }
        }
    }

    func announceMode(_ modeID: String, sessionID: String = "mode-session") {
        deliver(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(sessionID),
                "update": .object([
                    "sessionUpdate": .string("current_mode_update"),
                    "currentModeId": .string(modeID),
                ]),
            ]),
        ]))
    }

    private func sessionPayload(sessionID: String) -> JSONValue {
        .object([
            "sessionId": .string(sessionID),
            "modes": .object([
                "availableModes": .array([
                    .object(["id": .string("default"), "name": .string("Ask")]),
                    .object(["id": .string("acceptEdits"), "name": .string("Accept Edits")]),
                    .object(["id": .string("bypassPermissions"), "name": .string("Bypass Permissions")]),
                ]),
                "currentModeId": .string("default"),
            ]),
        ])
    }

    func modeRequests() -> [String] { requestedModeIDs }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func terminate() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { 0 }

    private func reply(id: JSONValue?, result: JSONValue) {
        guard let id else { return }
        deliver(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id, "result": result,
        ]))
    }

    private func replyError(id: JSONValue?, message: String) {
        guard let id else { return }
        deliver(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .integer(-32000), "message": .string(message)]),
        ]))
    }

    private func deliver(_ payload: JSONValue) {
        guard var data = try? JSONEncoder().encode(payload) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }

    private func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}

/// Narrow fixture that retains decoded request objects so boolean negotiation
/// and mutation are proven at the JSON boundary rather than inferred from UI.
private actor BooleanConfigWireTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var initializeParams: [String: JSONValue]?
    private var configRequest: [String: JSONValue]?
    private var enabled = false

    func start(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: trimmed(data)).objectValue else {
            return
        }
        let id = object["id"]
        switch object["method"]?.stringValue {
        case "initialize":
            initializeParams = object["params"]?.objectValue
            reply(id: id, result: .object([
                "protocolVersion": .integer(1),
                "agentCapabilities": .object([:]),
            ]))
        case "session/new":
            reply(id: id, result: sessionResult)
        case "session/set_config_option":
            configRequest = object["params"]?.objectValue
            if let value = configRequest?["value"]?.boolValue { enabled = value }
            reply(id: id, result: .object(["configOptions": configOptions]))
        default:
            if let id { reply(id: id, result: .null) }
        }
    }

    func advertisedBooleanConfigSupport() -> Bool {
        initializeParams?["clientCapabilities"]?.objectValue?["session"]?
            .objectValue?["configOptions"]?.objectValue?["boolean"]?.objectValue != nil
    }

    func lastConfigRequest() -> [String: JSONValue]? { configRequest }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func terminate() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { 0 }

    private var sessionResult: JSONValue {
        .object(["sessionId": .string("boolean-session"), "configOptions": configOptions])
    }

    private var configOptions: JSONValue {
        .array([.object([
            "id": .string("brave_mode"),
            "name": .string("Brave Mode"),
            "description": .string("Skip confirmation prompts"),
            "type": .string("boolean"),
            "currentValue": .bool(enabled),
        ])])
    }

    private func reply(id: JSONValue?, result: JSONValue) {
        guard let id else { return }
        enqueue(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func enqueue(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }

    private func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}
