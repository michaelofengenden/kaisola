# Round 4 — composer settings menu + agent switching

Worktree `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a4a121c11ae6155de`,
branch `round4-composer-menu`, based on `backlog-integration` (`e030365`).

## Commits

| | |
|---|---|
| `caa8c3f` | `feat(acp): model the composer's nested settings menu` |
| `0e7f691` | `feat(acp): give the composer one settings pill and a nested menu` |
| `f304096` | `feat(acp): let the composer change which agent this chat runs on` |
| (this) | `chore(acp): retire the picker machinery the menu replaced` |

Files: `Acp/AcpComposerModel.swift`, `Acp/AcpComposerView.swift`,
`Acp/AcpModelPickerView.swift` → `Acp/AcpComposerMenuView.swift` (rewritten),
`KaisolaTests/AcpComposerModelTests.swift`, plus two additive seams in
`App/AppModel.swift` (`openChat(initialDraft:)`) and
`App/KaisolaMacAppDelegate.swift` (`openAgentSettings`). Nothing under
`Features/Sessions`, `Features/Workspace`, or `App/NativePreviewSettings.swift`
was touched.

## 1. The menu

The composer's bottom row now reads the way the reference does: `+` and the
permission chip on the left — permission is the answer with a *wrong* value, so
it keeps its place and its one orange — and a rounded pill on the right, beside
send, because that is what the message gets spent on. The pill reads
`<model> <effort in grey> ⌄` behind the agent's brand mark. The separate
effort·context chip is gone; its contents moved into the menu.

The pill opens a compact popover of disclosure rows, `Label … value ›`:

```
Agent    Claude    ›
Model    Sonnet 4.5 ›
Effort   High      ›
─────────────────────
Advanced          ⌃
```

Nothing at that level is a control. Hovering or pressing a row opens a panel
beside it: a grey section header, plain rows, a checkmark on the one in force,
and a small grey caption under a row that needs a sentence. `Advanced` is a
muted disclosure over a hairline holding what the pill cannot and no row can
change — the context window, and the raw model identifier when it says something
the name does not. It is hidden outright when there is nothing to say.

Both panels live in **one** popover rather than two floating cards. A submenu
drawn in the composer's own coordinate space is clipped by the chat pane, and a
nested `NSPopover` dismisses its parent as soon as the pointer enters it. One
popover that grows a second column keeps the parent row on screen beside its
choices, which is what the nesting was for.

**Retired with the old picker:** the provider rail (one live button and one
filter toggle), the always-present search field, the ⌘1–⌘9 column, and the star
column. Search now appears only when a submenu passes eight options.
Favourites survive as a group that floats to the top of the model submenu,
toggled from the row's context menu — a star on every row would put a second
control in a menu whose whole point is that it has none.

Option labels are shortened to the word that varies (`Reasoning effort` →
`Effort`), matching the reference's one-word rows.

## 2. What agent switching actually does

**Investigated first.** An ACP conversation is one adapter process holding one
session: `AcpConversation` fixes `command`, `arguments`, `environment`, and
`cwd` as `let` at construction, `AcpAdapter.forAgent` resolves the package once
per chat, and the protocol has no session-transfer method. There is no mid-
session handoff to implement, and faking one would mean throwing away a
transcript that belongs to the process that produced it.

So the honest behaviour, implemented: choosing another agent **opens a new chat
with it in the same project** and hands over the unsent draft
(`AppModel.openChat(initialDraft:)`). The old chat stays open with its
transcript, and the source keeps its own copy of the draft — a navigation action
must never be the reason typed text disappears. Every switchable row says
`Starts a new chat` in its caption *before* it is pressed.

The list is `AgentRegistry.all` (built-ins + custom agents), each with its
`QuietIdentityMarkView` mark and a checkmark on the current one. Agents with no
ACP adapter — OpenCode, Gemini, every `custom-…` — are listed rather than
filtered out, greyed and captioned `Terminal only — no chat adapter`. Their
absence would read as a bug; the reason reads as the truth. A `Manage agents…`
row closes the menu and opens Settings on the **Agents** pane.

## 3. Keyboard

Arrows walk both columns (the submenu walk skips rows Return cannot activate),
Right enters a submenu, Left steps back out, Return commits, Escape closes the
submenu and then the menu.

This had to be an **AppKit local event monitor**, not `onKeyPress`. A SwiftUI
popover's window never becomes the app's key window here, so neither
`onKeyPress` nor a modifier-less `keyboardShortcut` is ever dispatched — proved
against the running app, where Escape did not even close the menu, and an
`NSView` taking first responder inside the popover did not help because the
press is delivered to the key window. (⌘-shortcuts *do* work; those go through
the main menu. That is why the old picker's ⌘-digits appeared to.) The monitor
is installed on appear, removed on disappear, **and refuses every press while
the popover is closed** — that gate, not the teardown, is what keeps a stray
monitor from swallowing arrow keys across the app.

The menu is also given a fresh identity on every open, because SwiftUI keeps
popover content alive between presentations and without it the menu reopened
mid-drilldown on the last session's row.

## AX evidence (dev profile, pid 68185, `KAISOLA_ACP_ADAPTER_OVERRIDE` →
`tests/fixtures/acp/nativeAcpMock.cjs`)

```
AXGroup #acp.composer
  AXTextField  #acp.composer.field      d="Message the agent"
  AXMenuButton #acp.composer.attach     d="Add attachments"
  AXMenuButton #acp.composer.permission d="Permission: Ask each time"
  AXButton     #acp.composer.settings   d="Chat settings: Mock Model Pro, High"
    AXPopover > AXGroup #acp.composer.menu d="Chat settings"
      AXButton #acp.composer.menu.row.agent                    d="Agent: Codex"
      AXButton #acp.composer.menu.row.model                    d="Model: Mock Model Pro"
      AXButton #acp.composer.menu.row.option.mode              d="Approval preset: Default"
      AXButton #acp.composer.menu.row.option.reasoning_effort  d="Effort: High"
      AXButton #acp.composer.menu.advanced                     d="Advanced" v="Collapsed"
      AXGroup  #acp.composer.menu.submenu d="Effort"
        AXHeading #acp.composer.menu.submenu.title d="Effort"
        AXButton  #acp.composer.menu.option.low    d="Low"
        AXButton  #acp.composer.menu.option.high   d="High, selected" SELECTED
  AXButton     #acp.composer.send        d="Send message"
```

Driven pid-exact through `AXUIElementCreateApplication`:

- **Submenus and checkmarks** — Model panel showed `Mock Model Pro, selected`
  `SELECTED` beside `Mock Model Fast`; pressing Fast committed and the pill
  became `Chat settings: Mock Model Fast, High`. Effort panel showed
  `High, selected`; pressing `Low` made the pill `Mock Model Fast, Low`.
- **Agent submenu** — `Claude, selected` `SELECTED`, and `Codex` / `OpenCode` /
  `Gemini` each captioned `Starts a new chat`, plus
  `#acp.composer.menu.manageAgents d="Manage agents in Settings"`. (Every agent
  is chat-capable *under the mock override*, which resolves an adapter for any
  id; the greyed `Terminal only — no chat adapter` state is covered by
  `testAgentsWithoutAnAdapterStayVisibleButUnselectable`.)
- **Advanced** — absent while the adapter had declared no usage; after one turn
  it appeared and expanded to
  `#acp.composer.menu.advancedLine v="Context used: 128 of 4.1k"`.
- **Keyboard, end to end** — with the panel open: Down → `submenu.title d="Agent"`
  listing all four agents; Down → `d="Model"`; Right → into the option column;
  Down → next option; Return → committed and closed. Escape once closed the
  submenu, Escape twice closed the menu.
- **Agent switch (by keyboard alone)** — before: one chat
  `#chat-38cc2b52 "Claude · Kaisola"`, draft `carry me over`. Down → Agent,
  Right, Down, Return → after: `#chat-38cc2b52` still present **and**
  `#chat-dfd89914 "Codex · Kaisola"` created and selected, its composer field
  carrying `carry me over`. Re-selecting the Claude chat showed it had kept its
  own copy of the draft and its own model/effort.
- **Manage agents…** — opened `AXWindow t="Settings"` with
  `AXButton d="Agents" SELECTED` and the ACP Adapters section visible.

Screenshots are TCC-blocked, so appearance is stated by construction: the panel
uses the popover's own chrome; rows highlight with `.quaternary.opacity(0.7)` in
`RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius)` inset from
the panel edge; values and captions are `.secondary`, chevrons `.tertiary`; the
pill is a `Capsule` with a resting `.quaternary` fill that deepens on hover and
skips the fade under Reduce Motion; the card fill still flips to
`NSColor.textBackgroundColor` under Reduce Transparency. The only colour is
still `KaisolaStatusTone.needsYou` on a permissive permission mode.

## Verification

- `npm run native:test:focus -- AcpComposerModelTests AcpClientTests
  AcpPermissionRulesTests` — green.
- `npm run native:test:changed -- --base e030365 --include-working-tree` — green
  (141 Node contract tests + the focused native classes). The default
  no-argument invocation reports "no changed files"; the branch base has to be
  named. The worktree also needs `node_modules` symlinked from the main checkout
  or the CodeMirror bundle test fails on a missing `rollup`.
- `npm run native:fast:build` — warning-clean.
- Dev-profile launch only, `KAISOLA_NATIVE_BROKER_PROFILE=development`,
  stopped with `kill -TERM`. The pinned arm64 Node runtime had to be downloaded
  into this worktree first.

## Concerns

- **Hover beats the keyboard.** Because a row arms its submenu on hover, a
  pointer resting on the panel re-arms that row after every arrow press. Real
  menus behave the same way, but it made the AX keyboard probe unreliable until
  the pointer was warped off the panel.
- **One popover, two columns** is not the reference's two overlapping cards. The
  reasons are in the source comment; if Michael wants the literal look it needs
  a real `NSPanel`, which is a bigger change than this round.
- **`isPresented` gate.** The key monitor is app-wide while installed, so it is
  gated on the parent's `menuPresented`. If a future refactor drops that
  closure, a closed menu would start eating arrow keys everywhere.
- **Config-option rows are unbounded.** Every declared option becomes a row, so
  an adapter advertising six of them would make a tall menu. Moving the
  secondary ones under `Advanced` is the obvious next step if that ever happens;
  today Claude and Codex declare at most two.
