# New session tab and transparent glass design

## Status

Approved direction: use a window-local draft tab. The draft lets someone choose a real session type before Kaisola creates any terminal, chat, or Mesh process.

This work starts from `origin/main` at `6cc396ea54657ebaa545cee3bee4fecf442bf669`. It lives on `codex/new-session-tab-glass` in a separate worktree. The broker migration branch and all broker runtime files are outside this change.

## Goal

Pressing the session `+` should select a temporary New Session tab instead of immediately opening a folder or showing a creation menu. The tab presents the session types available in the active project. Choosing one creates the real session and removes the draft.

At the same time, the left and right light Glass rails should show more of the desktop while the central workspace and terminal canvas stay white. Project and session tab outlines should be slightly easier to see without becoming thicker.

## Scope

The change covers:

- the `+` beside project tabs in top bar navigation;
- the `+` beside the active project in sidebar navigation;
- a temporary New Session tab in the top bar session strip;
- a matching temporary row in the sidebar project tree;
- a chooser for Terminal, Agent Terminal, Chat, and Mesh;
- the light Glass recipe used by the left and right rails;
- the outline treatment for project and session tabs;
- focused unit, rendering, accessibility, and visual checks;
- a local application build and replacement that preserves existing broker processes and sockets.

The change does not cover:

- broker protocols, broker startup, PTY ownership, or terminal persistence;
- a new durable session type;
- saving unfinished New Session drafts across relaunches;
- browser cards or document previews, which remain detail surfaces rather than sessions;
- a public release, version tag, or GitHub release.

## Chosen architecture

The draft is window-local SwiftUI state owned by `RootShellView`. It does not enter `AppModel`, `NativeSessionStore`, `SessionPaneLayout`, or the saved workspace archive. No terminal or agent process starts when the draft is created.

One draft may exist per open project. A small value type owns the rules:

```swift
struct NewSessionDraft: Identifiable, Equatable, Sendable {
    let id: String
    let projectID: String
}

struct NewSessionDraftState: Equatable, Sendable {
    private(set) var draftsByProject: [String: NewSessionDraft]
    private(set) var selectedDraftID: String?

    mutating func begin(projectID: String) -> NewSessionDraft
    mutating func selectDraft(_ id: String)
    mutating func selectRealSurface()
    mutating func cancel(projectID: String)
    mutating func complete(projectID: String)
    mutating func retainProjects(_ projectIDs: Set<String>)
}
```

`begin(projectID:)` reuses and selects an existing draft for that project. It creates a draft only when none exists. This prevents a row of abandoned blank tabs after repeated clicks.

`selectRealSurface()` deselects the draft but keeps it available. Selecting the New Session tab or row returns to the chooser. `cancel(projectID:)` and `complete(projectID:)` remove it. `retainProjects(_:)` removes drafts whose projects have closed.

The state and chooser belong in focused files under `Features/Sessions` rather than adding more private types to the already large `RootShellView.swift`:

- `NewSessionDraft.swift` owns the pure state and choice values.
- `NewSessionChooserView.swift` owns the chooser presentation.
- `RootShellView.swift` owns the state instance and dispatches existing commands.

## Session choices

The chooser uses the existing project launch vocabulary:

```swift
enum NewSessionChoice: Equatable, Sendable {
    case terminal
    case agentTerminal(String)
    case chat(String)
    case mesh
}
```

The first screen has four clear choices:

- Terminal starts a plain shell.
- Agent Terminal reveals the available terminal agents from `AgentRegistry.all`.
- Chat reveals agents with an ACP adapter.
- Mesh starts the existing all-agent Mesh.

Agent Terminal and Chat reveal their agent choices inline inside the chooser. They do not open a detached menu, so keyboard and VoiceOver focus remain in the New Session surface.

A category with no eligible agents is omitted rather than opening an empty second step.

The chooser dispatches the existing commands:

- `.newTerminal`
- `.newAgent(agentID)`
- `.newChat(agentID)`
- `.newMesh`

Before dispatch, `RootShellView` activates the draft's project. Once a choice is made, it removes the draft and runs the command. Existing account prompts, error messages, and creation behavior remain authoritative.

Terminal and Agent Terminal are disabled when `model.controlAvailable` is false. Their help and accessibility hint explain that saved terminals are temporarily view-only. Chat and Mesh remain available because they do not depend on terminal control.

Cancel and Escape remove the draft without changing the real session that was selected before the draft opened.

## Navigation behavior

### Top bar

The `+` currently drawn by `ProjectTabStripView` becomes New Session for the active project. Its help text and accessibility label use `"New session in \(project.name)"`. If there is no active project with a directory, the control is disabled and explains that a project must be opened first.

Opening a project remains available through File > Open Folder, Command-O, the command palette, and the sidebar's Add Project row. This keeps project creation separate from session creation.

`SessionStrip` appends the draft as a selected New Session chip. The chip uses a plus glyph and the same geometry as real session tabs. Clicking a real chat, Mesh, or terminal calls `selectRealSurface()` before selecting that surface. Clicking the draft selects it and returns the canvas to the chooser.

### Sidebar

The active project's `+` changes from a `Menu` to a plain `Button` that calls the same `begin(projectID:)` action. Direct session commands remain in the project context menu for experienced users.

The active project draws its draft as a New Session row at the top of its surface list. It follows the same indent, selection traits, row height, and context as real surfaces. The row has a Cancel action and no destructive session commands.

Both navigation layouts consume the same `NewSessionDraftState`, choice list, and command dispatch. Switching layouts cannot lose or duplicate a draft.

## Canvas behavior

When a draft is selected for the active project, the chooser takes precedence over the current pane grid. The existing pane layout stays in memory and returns unchanged when the draft is canceled or another real surface is selected.

The chooser is a centered, compact surface on the white canvas:

- title: "Start a session";
- description: `"Choose what this tab should become in \(project.name)."`;
- four primary choices with familiar SF Symbols;
- inline agent choices after selecting Agent Terminal or Chat;
- a quiet Cancel button.

The first enabled primary choice receives keyboard focus. Tab navigation follows standard SwiftUI button behavior. Escape cancels. Every choice has a plain accessibility label and, where useful, a short hint.

The chooser uses existing type, radius, spacing, and control-surface tokens. It does not add another large tinted card to the canvas.

## Glass treatment

Only the left and right rails change. The workspace backdrop and terminal theme remain untouched.

`DesktopGlassLayer` gains a white-carrier coverage parameter whose default remains `LightGlassFrost.carrierWhiteCoverage`, currently `0.70`. `WorkspaceBackdropView` continues to use that default. `SidebarBackdropView` passes a new rail-only value:

```swift
LightGlassFrost.railCarrierWhiteCoverage = 0.58
```

The light rail wash changes from `0.51 / 0.45 / 0.41` to:

```swift
top: 0.42
base: 0.36
bottom: 0.32
```

This raises modeled desktop contribution from about 17 percent to about 27 percent while keeping the rail near `0.95` modeled luminance. The workspace retains its existing `0.70` carrier and `0.46 / 0.40 / 0.36` wash. Exact-white terminal and paper surfaces remain `#FFFFFF`; the rail change never enters their rendering path.

The installed Safari treatment returns as a thinner named layer:

- cool outer edge: `#5AA9FF` at `0.035` coverage;
- white midpoint: `0.008` coverage;
- pearl inner edge: `#FFC985` at `0.010` coverage;
- inactive-window multiplier: `0.12`.

The gradient mirrors between leading and trailing rails. The cool note stays at the outer window edge, while the almost neutral pearl note sits beside the white canvas. It renders only in light Glass when Reduce Transparency is off. Dark, Solid, Tinted, and Reduce Transparency behavior do not change.

The current neutral-only test from `cd97c60f5` is intentionally replaced. The new contract permits only this named, bounded rail tint. Its strongest stop covers no more than four percent, so at least 96 percent of the rail below it remains visible.

## Tab outlines

The tab fills and `0.5pt` line width stay unchanged. Only stroke opacity moves:

```swift
enum SurfaceTabChrome {
    static let projectSelectedStrokeOpacity = 0.38
    static let sessionSelectedStrokeOpacity = 0.30
    static let inactiveStrokeOpacity = 0.11
}
```

Current selected values are `0.32` for project tabs and `0.22` for session tabs. Current inactive tabs use `0.075`. The new values make the outline readable without turning it into a heavy border.

`ProjectTabStripView` and `SessionStrip` both consume these tokens. Their existing fills, corner radius, tint source, and selected semantics stay unchanged. The New Session chip uses the session values.

## Accessibility and system settings

- Both `+` buttons are real buttons with a 26 point visual frame and the existing enlarged hit behavior where applicable.
- The New Session chip and sidebar row expose `.isSelected` only while the draft owns the canvas.
- The chooser exposes a heading, one concise description, labeled buttons, disabled explanations, and a Cancel action.
- Increased Contrast keeps its existing rail overlay. It may make the requested glass less transparent because the system preference takes priority.
- Reduce Transparency removes the rail tint and keeps the existing solid semantic background.
- Reduce Motion uses the existing root transaction policy. No new animation is required to understand state changes.
- Switching navigation layouts preserves the draft because the state belongs to `RootShellView`, not either layout.

## Edge cases

- Repeated `+` presses in one project select its existing draft.
- Different projects may each keep one draft during the life of the window.
- Closing a project removes its draft.
- A project whose directory becomes unavailable cannot start a new draft.
- Canceling an account prompt after choosing Chat or Agent Terminal leaves no draft. The user can press `+` again.
- If an existing creation command reports an error, its current toast or failure surface remains the error authority.
- Drafts do not appear in Recently Closed, session ordering files, saved windows, restoration archives, attention counts, usage calculations, or broker inventory.
- Quitting the window discards unfinished drafts without prompting because they contain no text, process, or durable work.

## Test plan

### Pure state tests

Add tests for `NewSessionDraftState` that prove:

- `begin` creates and selects one draft;
- a second `begin` reuses the same ID;
- separate projects receive separate drafts;
- selecting a real surface deselects without deleting;
- selecting a draft restores it;
- cancel and complete remove only the target project's draft;
- pruning removes drafts for closed projects;
- the choice list includes Terminal, Agent Terminal, Chat, and Mesh without reading broker state.

### View and routing tests

Extend `RootShellLayoutsTests` and the quiet rail tests to prove:

- both layouts expose a New Session action;
- the top bar `+` no longer routes to Open Folder;
- the sidebar `+` is a button rather than a menu;
- the draft chip and row expose selected semantics;
- existing real-surface selection deselects the draft;
- terminal choices disable when control is unavailable while Chat and Mesh remain enabled;
- project context menus keep their direct launch commands.

### Appearance tests

Extend `NativePreviewSettingsTests` to prove:

- the workspace carrier and wash are unchanged;
- the modeled workspace remains at least `0.96` luminance;
- the rail remains at least `0.94` luminance;
- modeled rail desktop contribution is at least `0.25`;
- the light tint peaks at or below `0.04` coverage;
- the tint passes at least `0.96` of the rail beneath it;
- leading and trailing directions mirror correctly;
- dark, Solid, Tinted, Reduce Transparency, and Increased Contrast keep their existing branches;
- project and session tab strokes use the declared values.

Keep the exact-white assertions in `TerminalThemeRegistryTests`. No terminal palette value changes.

### Visual checks

Capture isolated broker-free fixtures for top bar and sidebar navigation in light Glass. Inspect:

- the white center against both rails;
- the mirrored cool outer edge and quiet pearl inner edge;
- desktop visibility through each rail;
- project, session, and New Session outlines at selected and inactive states;
- chooser spacing, focus, and disabled terminal explanation;
- dark appearance and Reduce Transparency fallbacks.

Run the focused test classes first, then the full native macOS test suite. Record any pre-existing warnings separately from failures.

## Delivery and session safety

Implementation happens only in `/private/tmp/kaisola-new-session-tab-glass`. Staging and commits use explicit UI and test paths. Broker, runtime, and migration files are excluded.

Before replacing the local application, capture the live GUI, broker, descendant-process, socket, and registry fingerprints. Build and preflight the app without a normal production-profile launch. Replace the application atomically, keep the previous bundle as a recoverable backup, and verify every protected process and socket against the before snapshot.

The implementation may be committed and pushed for review after its tests and visual checks pass. It does not create a release tag or publish a new release.
