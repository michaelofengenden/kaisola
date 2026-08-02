# Round 3 — ACP/MCP agent chat UI

Worktree `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a3b4f449829696f2c`,
branch `worktree-agent-a3b4f449829696f2c`, based on `backlog-integration` (`c273c3c`).

## Commits

| | |
|---|---|
| `fca2149` | `feat(acp): model the composer's chips as tested value transforms` |
| `7c5baaf` | `feat(acp): rebuild the chat composer as one card with a chip rail` |
| `d82fef9` | `chore(acp): register the new composer sources and settle one AX identifier` |

Files: `Acp/AcpComposerModel.swift`, `Acp/AcpComposerView.swift`,
`Acp/AcpModelPickerView.swift` (new), `Acp/AcpChatView.swift` (edited),
`KaisolaTests/AcpComposerModelTests.swift` (new, 33 cases).
Nothing under `Features/Sessions`, `Features/Workspace`, or
`App/NativePreviewSettings.swift` was touched.

## What shipped, per scope item

**1. Composer card.** One rounded surface at `KaisolaVisualSystem.panelRadius`
with a hairline border, a soft shadow, and a multi-line field on top; the chip
rail sits along the bottom edge inside the same card. Nothing inside gets a
second box — the field has no background of its own, and chips are naked text
that acquire a surface only under the pointer — so the eye reads one object
rather than a toolbar bolted to a text box. Chips are separated by hairline
rules, not gaps: they are peers on one rail, and a gap would imply grouping
that does not exist. The rail scrolls horizontally in a narrow pane while the
send disc stays pinned. Send/steer/stop/queue all call the existing
`AcpConversation` methods; enablement is `AcpComposerSendPolicy`, which
preserves the old rule exactly (a queued follow-up cannot carry attachments, so
mid-turn a staged file alone does not arm the button). The region has no bar
material and no divider — the card's own edge is the separation, and a second
edge a few points away would have fought it.

**2. Model chip + picker.** The chip shows the agent's own mark
(`QuietIdentityMarkView`, reused not redrawn), the model name, and a caret;
`AcpAgentIdentity.chipLabel` prefixes the brand only when the model name does
not already say it. The picker is T3 Code's shape: provider rail, search field,
⌘1–⌘9 rows, a star per row. Favourites float to the top keeping their declared
order among themselves, and ordering is stable rather than relevance-ranked —
a ⌘-digit that moves between keystrokes is worse than a perfect sort.
Favourites persist per agent in `acp-model-favorites-v1.json` beside the
permission rules (atomic write, corrupt → empty, capped).

The rail holds favourites and *this chat's* agent, and nothing else. An ACP
conversation is bound to one adapter process, so a rail of every vendor would
be four-fifths dead buttons; the footer links to Settings ▸ Agents instead of
implying a switch that does not exist. An adapter that advertised no models
gets a sentence saying so.

**3. Permission chip.** `AcpPermissionPostureMap` folds an ACP mode's id and
name to letters and digits and maps them onto four rungs — Read only / Ask each
time / Accept edits / Full access — with `eye`, `lock.fill`, `lock.open`,
`lock.open.fill`. Only the top rung is coloured (`KaisolaStatusTone.needsYou`);
amber on a mode that merely accepts edits would spend the composer's one colour
on the wrong state. A mode we cannot read is never relabelled: it keeps the
adapter's own wording and the cautious rung.

**4. `+` menu.** "Add files or photos" with ⌘U, wired to the existing
`prepareAttachment` path; "Slash commands" appears only once the adapter has
advertised any (verified appearing mid-session in the dev run below).

**5. Empty state.** "What should we build in *Project*?" at 28pt regular, the
project name dotted-underlined via `Text.LineStyle(pattern: .dot)`, one spoken
string for VoiceOver. It sits about two thirds down the vacated transcript
space rather than dead-centre, so it groups with the composer and does not
visibly leap when the first message pushes it away.

**6. Preserved.** Transcript rendering, steering/queueing, the permission bar,
attachments, drop/paste, and Reduce Motion behaviour are unchanged. Model,
mode, and adapter options left the header rather than existing twice; the
header keeps checkpoints and live usage, which belong to the session rather
than to the next message.

## Deliberately omitted

- **"Add folder"** — `AcpAttachmentClassifier.classify` rejects directories, so
  the row would fail every time it was clicked.
- **"Import GitHub issue"** — nothing in the app turns an issue into a prompt.
  The reference shows it disabled with explanatory subtext; a greyed row that
  advertises a capability the app does not have is worse than its absence.
- **Connectors / Plugins submenus** — `McpConfigStore` exists, but exposing it
  here would have been a second, read-only copy of a Settings surface another
  agent owns.
- **The `[robot] Build` chip** from reference A — that is Claude Code's
  subagent selector; ACP declares no equivalent, and inventing one would mean
  inventing a catalog.

## AX evidence (dev profile, pid 41741, `KAISOLA_ACP_ADAPTER_OVERRIDE` →
`tests/fixtures/acp/nativeAcpMock.cjs`)

```
AXStaticText #acp.emptyState v="What should we build in TimeAblations?" @427,600 292x66
AXGroup #acp.composer @364,880 418x91
  AXTextField  #acp.composer.field      d="Message the agent"
  AXMenuButton #acp.composer.attach     d="Add attachments"
  AXButton     #acp.composer.model      d="Model: Claude Mock Model Pro"
  AXMenuButton #acp.composer.effort     d="Agent effort and context window: High · 4.1k"
  AXMenuButton #acp.composer.permission d="Permission: Ask each time"
  AXButton     #acp.composer.stop       d="Stop the current turn"        (only mid-turn)
  AXButton     #acp.composer.send       d="Send message" / "Queue follow-up"
```

Driven pid-exact through `AXUIElementCreateApplication`:

- **Picker opens** — `AXPopover > #acp.modelPicker` with
  `#acp.modelPicker.favoritesFilter`, `#acp.modelPicker.provider` ("Claude"),
  `#acp.modelPicker.search`, two `#acp.modelPicker.model.*` rows (the current
  one carrying `v="Current model"`), two `#acp.modelPicker.favorite.*`
  toggles, and `#acp.modelPicker.settings`.
- **Favourites** — pressing `favorite.mock-model-fast` flipped its label to
  "Unfavourite …", floated the row to position 1, and wrote
  `{"byAgent":{"Claude":["mock-model-fast"]}}` to disk.
- **⌘1** — typed into the open popover, the chip became
  `Model: Claude Mock Model Fast`.
- **Permission menu** — `Ask each time` (`lock.fill`) and `Read only` (`eye`),
  mapped from the mock's `default` / `read-only`.
- **Effort menu** — every `configOption` (Approval preset, Reasoning effort)
  reachable; the chip face read `High`, then `High · 4.1k` once the adapter's
  `usage_update` arrived.
- **`+` menu** — `Add files or photos` alone before the adapter advertised
  commands, `Add files or photos` + `Slash commands` after.
- **Send gating** — disabled with an empty draft, armed on typed text,
  became a disabled "Queue follow-up" beside `#acp.composer.stop` while the
  turn ran, back to "Send message" when it ended.
- **Transcript intact** — user bubble, Thinking disclosure, Plan card with
  checkboxes, assistant Markdown, tool card with `fixture/notes.txt`, and the
  permission bar all rendered under the new composer; Allow Once completed the
  turn normally.

Screenshots are TCC-blocked, so appearance is stated by construction: the card
fill is `Color(light: 0xFFFFFF, dark: 0x1D1D1F)` and turns
`NSColor.textBackgroundColor` under Reduce Transparency; the border is
`NSColor.separatorColor`; the only brand colour is the reused starburst/knot;
the chip hover animation is skipped under Reduce Motion.

## Verification

- `npm run native:test:focus -- AcpComposerModelTests AcpClientTests
  AcpPermissionRulesTests AcpTranscriptStoreTests` — green.
- `npm run native:test:changed -- --include-working-tree` — green
  (KaisolaCore 25 tests + 11 focused native classes).
- Full recompile of all four touched sources, warning-clean.

## Concerns

- The **`transcript` view is destroyed while the empty state shows**, so its
  `.onAppear` scroll setup runs on the first message rather than at chat open.
  This behaves correctly in the dev run, but any future scroll-restoration work
  should know the transcript is now conditionally mounted.
- **`AcpComposerCard` derives the agent from `conversation.title`.** That is
  correct for `"<Agent> · <folder>"` titles and for renamed chats that still
  mention the agent, and it avoided touching `AcpConversation`/`AcpChatHandle`
  (owned elsewhere this round). A conversation-level `agentID` would be
  strictly better and is a small follow-up.
- **`AcpChatView` is now 1,180 lines** and still holds the transcript, tool,
  diff, and permission views. Splitting `TranscriptRowView` and below into
  `AcpTranscriptViews.swift` is the obvious next cleanup; it was out of scope
  here and would have made the diff much harder to review.
- The worktree needed `node_modules` symlinked from the main checkout before
  `--refresh-helper` could package the broker helper (`node-pty` lookup).
