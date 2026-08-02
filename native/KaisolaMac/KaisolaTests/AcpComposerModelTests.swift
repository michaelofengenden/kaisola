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
        XCTAssertEqual(submenu.options.map(\.name), ["Light", "Medium", "High"])
        XCTAssertEqual(submenu.options.map(\.isSelected), [true, false, false])
        XCTAssertFalse(submenu.showsSearch)
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
