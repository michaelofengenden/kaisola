# New Session Tab and Transparent Glass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both visible `+` controls open one temporary New Session tab per project, present a Terminal, Agent Terminal, Chat, or Mesh chooser, make light rails more transparent without changing the white center, and strengthen project and session outlines slightly.

**Architecture:** `RootShellView` owns a pure window-local draft state. The draft never enters `AppModel`, pane layout, persistence, or broker state. Focused SwiftUI views present the chooser while the existing command registry remains the only path that creates real sessions. Rail glass gets a separate carrier value and a bounded mirrored tint, while the workspace and terminal recipes remain unchanged.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, XcodeGen, existing native visual fixtures.

**Spec:** `docs/superpowers/specs/2026-08-13-new-session-tab-glass-design.md`

## Global Constraints

- Work only in `/private/tmp/kaisola-new-session-tab-glass` on `codex/new-session-tab-glass`, based on `origin/main` commit `6cc396ea54657ebaa545cee3bee4fecf442bf669`.
- Do not modify any file under `runtime/`, `native/KaisolaMac/Kaisola/Broker/`, or any broker migration branch.
- The draft is window-local state. It must not enter `AppModel`, `NativeSessionStore`, `SessionPaneLayout`, saved workspace archives, Recently Closed, usage, attention, or broker inventory.
- One unfinished draft may exist per project. Repeated `+` presses reuse it.
- The existing `.newTerminal`, `.newAgent(String)`, `.newChat(String)`, and `.newMesh` command paths remain authoritative.
- Terminal and Agent Terminal are disabled while `model.controlAvailable` is false. Chat and Mesh stay available.
- The light workspace carrier, workspace wash, terminal canvas, and paper surfaces remain unchanged. Exact-white terminal and paper surfaces remain `#FFFFFF`.
- Only light Glass rails with Reduce Transparency off receive the new rail tint. Dark, Solid, Tinted, and Reduce Transparency branches keep their current behavior.
- Light rail carrier coverage is `0.58`. The light rail wash is `0.42 / 0.36 / 0.32` from top to base to bottom.
- Rail tint stops are cool `#5AA9FF` at `0.035`, white at `0.008`, and pearl `#FFC985` at `0.010`. Inactive-window tint is multiplied by `0.12`.
- Project selected stroke opacity is `0.38`, session selected stroke opacity is `0.30`, and inactive stroke opacity is `0.11`. Line width and fills do not change.
- No release tag or GitHub release is part of this plan. Local replacement must preserve live broker processes, descendants, sockets, and registry state.

---

### Task 1: Window-local draft state and choice catalog

**Files:**

- Create: `native/KaisolaMac/Kaisola/Features/Sessions/NewSessionDraft.swift`
- Create: `native/KaisolaMac/KaisolaTests/NewSessionDraftTests.swift`
- Regenerate: `native/KaisolaMac/KaisolaMac.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `AgentRegistry.all`, `AgentProfile.id`, `AgentProfile.name`, `AgentProfile.symbol`, and `AcpAdapter.forAgent(_:)`.
- Produces: `NewSessionDraft`, `NewSessionDraftState`, `NewSessionChoice`, `NewSessionAgentOption`, and `NewSessionChoiceCatalog` for Tasks 2 and 3.

- [ ] **Step 1: Write failing state and catalog tests**

Add tests that call real value types and prove the state transitions directly:

```swift
@MainActor
final class NewSessionDraftTests: XCTestCase {
    func testBeginCreatesOneSelectedDraftAndReusesItForTheProject() {
        var state = NewSessionDraftState()
        let first = state.begin(projectID: "project-a")
        let second = state.begin(projectID: "project-a")

        XCTAssertEqual(first, second)
        XCTAssertEqual(state.draft(for: "project-a"), first)
        XCTAssertEqual(state.selectedDraftID, first.id)
    }

    func testProjectsKeepIndependentDraftsAndRealSelectionOnlyDeselects() {
        var state = NewSessionDraftState()
        let first = state.begin(projectID: "project-a")
        let second = state.begin(projectID: "project-b")

        XCTAssertNotEqual(first.id, second.id)
        state.selectRealSurface()
        XCTAssertNil(state.selectedDraftID)
        XCTAssertEqual(state.draft(for: "project-a"), first)
        XCTAssertEqual(state.draft(for: "project-b"), second)
        state.selectDraft(first.id)
        XCTAssertEqual(state.selectedDraftID, first.id)
    }

    func testCancelCompleteAndRetainRemoveOnlyTheIntendedDrafts() {
        var state = NewSessionDraftState()
        _ = state.begin(projectID: "project-a")
        _ = state.begin(projectID: "project-b")
        _ = state.begin(projectID: "project-c")

        state.cancel(projectID: "project-a")
        state.complete(projectID: "project-b")
        state.retainProjects(["project-c"])

        XCTAssertNil(state.draft(for: "project-a"))
        XCTAssertNil(state.draft(for: "project-b"))
        XCTAssertNotNil(state.draft(for: "project-c"))
    }

    func testCatalogSeparatesTerminalAgentsFromChatCapableAgents() {
        let catalog = NewSessionChoiceCatalog.make(
            agents: [
                .init(id: "claude", name: "Claude", symbol: "sparkles"),
                .init(id: "shell-only", name: "Shell Only", symbol: "terminal"),
            ],
            supportsChat: { $0 == "claude" }
        )

        XCTAssertEqual(catalog.terminalAgents.map(\.id), ["claude", "shell-only"])
        XCTAssertEqual(catalog.chatAgents.map(\.id), ["claude"])
    }
}
```

The test fixture uses `NewSessionAgentOption` values rather than constructing `AgentProfile`. The production `live` catalog maps `AgentRegistry.all` into those values.

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
KAISOLA_NATIVE_DERIVED_DATA=/private/tmp/kaisola-new-session-derived npm run native:test:focus -- NewSessionDraftTests
```

Expected: compilation fails because the new types do not exist. This is the required RED evidence.

- [ ] **Step 3: Implement the pure state and catalog**

Create these exact public-to-the-module shapes:

```swift
struct NewSessionDraft: Identifiable, Equatable, Sendable {
    let id: String
    let projectID: String
}

struct NewSessionDraftState: Equatable, Sendable {
    private(set) var draftsByProject: [String: NewSessionDraft] = [:]
    private(set) var selectedDraftID: String?

    var selectedDraft: NewSessionDraft? { get }
    func draft(for projectID: String) -> NewSessionDraft?
    @discardableResult mutating func begin(projectID: String) -> NewSessionDraft
    mutating func selectDraft(_ id: String)
    mutating func selectRealSurface()
    mutating func cancel(projectID: String)
    mutating func complete(projectID: String)
    mutating func retainProjects(_ projectIDs: Set<String>)
}

enum NewSessionChoice: Equatable, Sendable {
    case terminal
    case agentTerminal(String)
    case chat(String)
    case mesh
}

struct NewSessionAgentOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
}

struct NewSessionChoiceCatalog: Equatable, Sendable {
    let terminalAgents: [NewSessionAgentOption]
    let chatAgents: [NewSessionAgentOption]

    static func make(
        agents: [NewSessionAgentOption],
        supportsChat: (String) -> Bool
    ) -> NewSessionChoiceCatalog

    static var live: NewSessionChoiceCatalog { get }
}
```

`begin` uses an ID prefixed with `new-session-` and a UUID. `selectDraft` only accepts an ID already present. Removal clears `selectedDraftID` only when it removes the selected draft. `retainProjects` filters the dictionary and clears a selection whose draft no longer exists.

- [ ] **Step 4: Regenerate the Xcode project and run GREEN**

Run:

```bash
cd native/KaisolaMac
xcodegen generate
cd ../..
KAISOLA_NATIVE_DERIVED_DATA=/private/tmp/kaisola-new-session-derived npm run native:test:focus -- NewSessionDraftTests
```

Expected: all `NewSessionDraftTests` pass.

- [ ] **Step 5: Commit Task 1**

Stage only the new state, test, and generated project file. Commit as Michael:

```bash
git add native/KaisolaMac/Kaisola/Features/Sessions/NewSessionDraft.swift native/KaisolaMac/KaisolaTests/NewSessionDraftTests.swift native/KaisolaMac/KaisolaMac.xcodeproj/project.pbxproj
git -c user.name='Michael Ofengenden' -c user.email='mofengenden@berkeley.edu' commit -m 'feat(sessions): add window-local new session drafts'
```

---

### Task 2: Chooser and navigation integration

**Files:**

- Create: `native/KaisolaMac/Kaisola/Features/Sessions/NewSessionChooserView.swift`
- Create: `native/KaisolaMac/KaisolaTests/NewSessionChooserTests.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/RootShellLayouts.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/ProjectTabStripView.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/QuietProjectRail.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift`
- Modify: `native/KaisolaMac/Kaisola/App/KaisolaMacAppDelegate.swift`
- Modify: `native/KaisolaMac/KaisolaTests/RootShellLayoutsTests.swift`
- Modify: `native/KaisolaMac/KaisolaTests/QuietIdentityMarkTests.swift`
- Regenerate: `native/KaisolaMac/KaisolaMac.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: every type from Task 1 and the existing `AppCommandID` creation commands.
- Produces: `NewSessionChooserView`, one shared `beginNewSession` route, a draft chip in top-bar navigation, a draft row in sidebar navigation, and a deterministic `new-session` visual fixture.

- [ ] **Step 1: Write failing chooser and shell-routing tests**

Add pure presentation tests for a `NewSessionChooserPresentation` value produced by the chooser file:

```swift
func testTerminalChoicesDisableWithoutControlButChatAndMeshStayEnabled() {
    let catalog = NewSessionChoiceCatalog(
        terminalAgents: [.init(id: "claude", name: "Claude", symbol: "sparkles")],
        chatAgents: [.init(id: "claude", name: "Claude", symbol: "sparkles")]
    )
    let options = NewSessionChooserPresentation.primaryOptions(
        catalog: catalog,
        terminalControlAvailable: false
    )

    XCTAssertEqual(options.map(\.choice), [.terminal, .agentTerminalCategory, .chatCategory, .mesh])
    XCTAssertFalse(options[0].isEnabled)
    XCTAssertFalse(options[1].isEnabled)
    XCTAssertTrue(options[2].isEnabled)
    XCTAssertTrue(options[3].isEnabled)
}

func testEmptyAgentCategoriesAreOmitted() {
    let options = NewSessionChooserPresentation.primaryOptions(
        catalog: .init(terminalAgents: [], chatAgents: []),
        terminalControlAvailable: true
    )
    XCTAssertEqual(options.map(\.choice), [.terminal, .mesh])
}
```

Extend `RootShellLayoutsTests` so its inert action model exposes `beginNewSession`, and mount both shell layouts with controls that invoke it. Extend `QuietIdentityMarkTests` with a pure draft-row semantic assertion that selected draft rows carry selected state and use the stable `new-session-` identifier.

- [ ] **Step 2: Run the affected focused tests and confirm RED**

Run:

```bash
KAISOLA_NATIVE_DERIVED_DATA=/private/tmp/kaisola-new-session-derived npm run native:test:focus -- NewSessionChooserTests RootShellLayoutsTests QuietIdentityMarkTests
```

Expected: compilation fails because the chooser presentation and new action interface do not exist.

- [ ] **Step 3: Build the chooser view**

Create a centered chooser with these inputs:

```swift
struct NewSessionChooserView: View {
    let projectName: String
    let catalog: NewSessionChoiceCatalog
    let terminalControlAvailable: Bool
    let choose: (NewSessionChoice) -> Void
    let cancel: () -> Void
}
```

Use `NewSessionChooserPresentation.primaryOptions` for the first screen. The visible copy is:

- Heading: `Start a session`
- Description: `Choose what this tab should become in \(projectName).`
- Primary choices: `Terminal`, `Agent Terminal`, `Chat`, `Mesh`
- Disabled terminal explanation: `Saved terminals are view-only right now.`
- Secondary action: `Cancel`

Agent Terminal and Chat reveal their available agent rows inline. Back returns to the primary choices. Escape calls `cancel`. Apply a real heading trait, plain labels and hints, and keyboard focus to the first enabled primary choice. Keep the surface compact and centered on the existing canvas without adding a full-canvas tint.

- [ ] **Step 4: Replace both visible plus routes with one draft action**

Change `RootShellActionModel` to remove `openProject` and `projectLaunchMenu`, and add:

```swift
let beginNewSession: (AppModel.ProjectGroup) -> Void
let selectRealSurface: () -> Void
```

Keep `projectLaunchMenu(_:)` inside `RootShellView` for the project context menu.

Change `ProjectTabStripView` from `openFolder: () -> Void` to `newSession: (AppModel.ProjectGroup) -> Void`. Resolve the selected active project, disable the button when it has no directory, and use the help and accessibility label `New session in \(project.name)`. The Add Project row, File menu, Command-O, and command palette keep opening folders.

Change `QuietProjectRail` and `QuietProjectGroup` so the active header uses a plain `Button`, not a `Menu`, and invokes the same `beginNewSession` closure. Pass the draft state and selection callbacks into the rail. Add the New Session row at the top of the expanded surface list. Give it the same row height and indent as real surfaces, a plus glyph, selected semantics only when its ID equals `selectedDraftID`, a Cancel context action, and a named accessibility Cancel action.

- [ ] **Step 5: Integrate draft ownership and command dispatch in RootShellView**

Add:

```swift
@State private var newSessionDrafts = NewSessionDraftState()

private func beginNewSession(in project: AppModel.ProjectGroup)
private func selectNewSessionDraft(_ id: String)
private func selectRealSurface()
private func cancelNewSession(in projectID: String)
private func chooseNewSession(_ choice: NewSessionChoice, draft: NewSessionDraft)
```

`beginNewSession` activates a project only when it has a directory, then calls `begin`. `chooseNewSession` activates the draft project, calls `complete`, and dispatches exactly one existing command. Do not call a broker, model creation method, or store method directly.

Every real chat, Mesh, and terminal selection in `SessionStrip` and `QuietProjectRail` calls `selectRealSurface()` before its existing selection path. The draft chip and row call `selectDraft`. While the active draft owns the canvas, real rows and chips do not keep selected styling even if `AppModel` still remembers their IDs. Closing projects triggers `retainProjects(Set(model.projects.map(\.id)))` through an `onChange` on project IDs.

Keep `unifiedSessionPaneGrid` mounted inside `detailContent`. When `selectedDraft` belongs to the active project, overlay an opaque `Color(nsColor: .windowBackgroundColor)` and then the chooser. This keeps live terminal and chat views mounted, gives the light chooser canvas exact `#FFFFFF`, and leaves the real pane layout untouched beneath it.

- [ ] **Step 6: Add deterministic visual fixture entry points**

Teach the visual fixture to recognize `new-session` for sidebar navigation and `new-session-topbar` for top-bar navigation. Add `new-session-topbar` to the app delegate's exact top-bar surface mapping. These launches remain isolated and broker-free. On fixture appearance, begin the first available project's draft on the next main-queue turn. Keep the Files rail hidden for these two surfaces so the chooser and both navigation forms are legible.

- [ ] **Step 7: Regenerate and run GREEN**

Run:

```bash
cd native/KaisolaMac
xcodegen generate
cd ../..
KAISOLA_NATIVE_DERIVED_DATA=/private/tmp/kaisola-new-session-derived npm run native:test:focus -- NewSessionDraftTests NewSessionChooserTests RootShellLayoutsTests QuietIdentityMarkTests
```

Expected: all listed classes pass.

- [ ] **Step 8: Commit Task 2**

Stage only the new chooser, the named SwiftUI integration files, tests, and generated project. Commit as Michael:

```bash
git -c user.name='Michael Ofengenden' -c user.email='mofengenden@berkeley.edu' commit -m 'feat(sessions): open session chooser from plus tabs'
```

---

### Task 3: Transparent Safari-like rails and clearer tab outlines

**Files:**

- Modify: `native/KaisolaMac/Kaisola/App/NativeVisualTokens.swift`
- Modify: `native/KaisolaMac/Kaisola/App/NativeAppearanceViews.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/ProjectTabStripView.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Workspace/WorkspaceRailView.swift`
- Modify: `native/KaisolaMac/KaisolaTests/NativePreviewSettingsTests.swift`

**Interfaces:**

- Consumes: `LightGlassFrost`, `GlassBackdropWash`, `DesktopGlassLayer`, and both `SidebarBackdropView` call sites.
- Produces: `SidebarRailPlacement`, `LightRailTint`, and `SurfaceTabChrome` values shared by the mounted views and tests.

- [ ] **Step 1: Replace the neutral-only rail test with failing bounded-tint and transmission tests**

Delete `testLightGlassRailsMountNoDecorativeChromaticOverlay`. Update `testLightGlassIsWhiteAndCoherentAcrossRailsCanvasAndPanel` so the workspace remains at least `0.96`, the rail remains at least `0.94`, and the rail may sit about `0.018` below the workspace. Add tests that assert behavior rather than source text:

```swift
func testLightRailFrostPassesMoreDesktopWithoutChangingWorkspaceWhite() {
    let rail = GlassBackdropWash.sidebar(isDark: false)
    let workspace = GlassBackdropWash.workspace(isDark: false)

    XCTAssertEqual(LightGlassFrost.railCarrierWhiteCoverage, 0.58, accuracy: 0.0001)
    XCTAssertEqual(rail.topOpacity, 0.42, accuracy: 0.0001)
    XCTAssertEqual(rail.baseOpacity, 0.36, accuracy: 0.0001)
    XCTAssertEqual(rail.bottomOpacity, 0.32, accuracy: 0.0001)
    XCTAssertEqual(workspace.topOpacity, 0.46, accuracy: 0.0001)
    XCTAssertEqual(workspace.baseOpacity, 0.40, accuracy: 0.0001)
    XCTAssertEqual(workspace.bottomOpacity, 0.36, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual(LightGlassFrost.modeledRailLuminance(rail), 0.94)
    XCTAssertGreaterThanOrEqual(LightGlassFrost.modeledRailDesktopContribution(rail), 0.25)
}

func testLightRailTintIsDelicateAndMirroredAtWindowEdges() {
    XCTAssertEqual(SidebarRailPlacement.leading.tintStartPoint, .topLeading)
    XCTAssertEqual(SidebarRailPlacement.trailing.tintStartPoint, .topTrailing)
    XCTAssertLessThanOrEqual(LightRailTint.maximumCoverage, 0.04)
    XCTAssertGreaterThanOrEqual(LightRailTint.minimumTransmission, 0.96)
    XCTAssertEqual(LightRailTint.inactiveMultiplier, 0.12, accuracy: 0.0001)
    XCTAssertGreaterThan(LightRailTint.cool.blue, LightRailTint.cool.green)
    XCTAssertGreaterThan(LightRailTint.pearl.red, LightRailTint.pearl.green)
}

func testSurfaceTabOutlinesAreVisibleButRemainHairlines() {
    XCTAssertEqual(SurfaceTabChrome.projectSelectedStrokeOpacity, 0.38)
    XCTAssertEqual(SurfaceTabChrome.sessionSelectedStrokeOpacity, 0.30)
    XCTAssertEqual(SurfaceTabChrome.inactiveStrokeOpacity, 0.11)
    XCTAssertEqual(KaisolaVisualSystem.hairline, 0.5)
}
```

Retain every exact-white terminal test and the workspace carrier assertions.

Update the existing appearance contracts that depend on the old shared carrier or old light rail wash:

- `testGlassBackdropWashIsWhiteLedInLightAndNearBlackInDark` expects the new light rail values.
- `testGlassBackdropWashLightsFromAboveAndSeatsTheWorkspaceDeeper` uses modeled composite luminance for the light ordering while retaining its dark wash ordering.
- `testLiveGlassPassesFarMoreOfTheMaterialInDarkThanItDid` models the light rail with the rail carrier and accepts the `0.25` to `0.30` contribution band.
- The render helper takes a carrier argument that defaults to `0.70`; sidebar cases pass `0.58`, while workspace and panel cases retain the default.
- Every sidebar contrast, texture, hue, and structure fixture passes the rail carrier explicitly. The neutral stack is measured before the named tint unless a test says it includes the tint.

- [ ] **Step 2: Run the appearance test and confirm RED**

Run:

```bash
KAISOLA_NATIVE_DERIVED_DATA=/private/tmp/kaisola-new-session-derived npm run native:test:focus -- NativePreviewSettingsTests
```

Expected: compilation fails because the new tokens and rail model functions do not exist.

- [ ] **Step 3: Add rail-only carrier, placement, tint, and tab tokens**

In `NativeVisualTokens.swift`:

```swift
enum LightGlassFrost {
    static let carrierWhiteCoverage = 0.70
    static let railCarrierWhiteCoverage = 0.58
}

enum SidebarRailPlacement: Equatable, Sendable {
    case leading
    case trailing
    var tintStartPoint: UnitPoint { get }
    var tintEndPoint: UnitPoint { get }
}

enum LightRailTint {
    static let cool = (red: 90.0 / 255, green: 169.0 / 255, blue: 1.0)
    static let pearl = (red: 1.0, green: 201.0 / 255, blue: 133.0 / 255)
    static let coolCoverage = 0.035
    static let midpointCoverage = 0.008
    static let pearlCoverage = 0.010
    static let inactiveMultiplier = 0.12
    static var maximumCoverage: Double { get }
    static var minimumTransmission: Double { get }
}

enum SurfaceTabChrome {
    static let projectSelectedStrokeOpacity = 0.38
    static let sessionSelectedStrokeOpacity = 0.30
    static let inactiveStrokeOpacity = 0.11
}
```

Add rail-specific modeled luminance and desktop contribution functions that use `railCarrierWhiteCoverage`. Keep the existing workspace model using `carrierWhiteCoverage`.

- [ ] **Step 4: Mount the rail recipe without changing the workspace**

Add `carrierWhiteCoverage` to `DesktopGlassLayer` with a default of `LightGlassFrost.carrierWhiteCoverage`. Use it for the light white carrier. `WorkspaceBackdropView` keeps the default. `SidebarBackdropView` passes `LightGlassFrost.railCarrierWhiteCoverage`.

Require `placement` in `SidebarBackdropView`. Pass `.leading` from `RootShellView` and `.trailing` from `WorkspaceRailView`. After the neutral rail wash, render the named `LightRailTint` gradient only when the color scheme is light. Mirror it through the placement points. Scale its three coverages by `1` while the window is key and `0.12` while inactive. Keep the Increased Contrast overlay above it.

Change only the light sidebar wash to `0.42 / 0.36 / 0.32`. Keep dark and workspace values unchanged.

- [ ] **Step 5: Consume the shared outline tokens**

Replace inline stroke opacities in `ProjectTabStripView.chipLabel` and `SessionStrip.surfaceTabBackground` with `SurfaceTabChrome`. Keep fills, radii, and `KaisolaVisualSystem.hairline` unchanged. The New Session chip uses the same session background helper.

- [ ] **Step 6: Run GREEN**

Run:

```bash
KAISOLA_NATIVE_DERIVED_DATA=/private/tmp/kaisola-new-session-derived npm run native:test:focus -- NativePreviewSettingsTests RootShellLayoutsTests NewSessionChooserTests
```

Expected: all listed classes pass and the exact-white tests remain unchanged.

- [ ] **Step 7: Commit Task 3**

Stage only the appearance, call-site, and test files. Commit as Michael:

```bash
git -c user.name='Michael Ofengenden' -c user.email='mofengenden@berkeley.edu' commit -m 'style(native): refine transparent rail glass and tab outlines'
```

---

### Task 4: Full verification, visual inspection, review, and safe local replacement

**Files:**

- Verify all files changed by Tasks 1 through 3.
- Do not modify broker or runtime files.

**Interfaces:**

- Consumes: the complete branch implementation.
- Produces: test evidence, broker-free visual captures, code-review findings, and a safely replaced local application bundle.

- [ ] **Step 1: Verify scope and formatting**

Run:

```bash
git diff --check origin/main..HEAD
git diff --name-only origin/main..HEAD
```

Reject the branch if any path is under `runtime/` or `native/KaisolaMac/Kaisola/Broker/`.

- [ ] **Step 2: Run changed-test selection and the full native suite**

Run:

```bash
npm run native:test:changed -- --base origin/main
KAISOLA_NATIVE_DERIVED_DATA=/private/tmp/kaisola-new-session-full npm run native:test
```

Record exit codes, test totals, and warnings. Failures block delivery.

- [ ] **Step 3: Capture broker-free light and fallback fixtures**

Build the Debug app through the tested derived data. Capture at least:

- `new-session` in light Glass
- `new-session-topbar` in light Glass
- `new-session` in dark Glass
- one light Reduce Transparency capture if the fixture supports the environment override

Use isolated `CFFIXED_USER_HOME` directories and `KAISOLA_NATIVE_VISUAL_FIXTURE=1`. Do not launch the normal production profile. Inspect that the center remains white, both rails show mirrored cool outer edges and nearly neutral pearl inner edges, the desktop remains visible through the rails, the draft row or chip is selected, and the chooser fits without clipping.

- [ ] **Step 4: Run dual code review and fix material findings**

Generate one whole-branch diff package. Dispatch a Codex `MODE: code-review` review and perform an independent local review against the spec. Any material finding gets one test-first fix and a scoped re-review.

- [ ] **Step 5: Build and preflight the local app without launching it**

Build a `LocalRelease` application from the verified commit, then run the repository's native preflight against that exact bundle. Do not use a normal production-profile launch as a smoke test because it can perform broker maintenance.

- [ ] **Step 6: Snapshot and preserve live session authority**

Immediately before replacement, record the installed GUI state, every live session-broker PID, descendant PID, PGID, executable, start time, socket path and inode, plus the registry hash. Abort if the installed GUI owns active child processes.

- [ ] **Step 7: Replace the local bundle atomically and verify continuity**

Move the old app bundle to a recoverable backup, install the verified bundle at the canonical application path, and do not launch it. Re-run the process, descendant, socket, and registry checks. Every protected process and socket must match the before snapshot.

- [ ] **Step 8: Report exact delivery state**

Report the branch, final commit, test commands and exits, capture paths, installed bundle version/build/source commit, and whether the app was intentionally left unlaunched to preserve live sessions. Do not claim a public release.
