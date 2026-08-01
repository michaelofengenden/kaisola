# Native Kaisola: large feature and implementation PRs

This is the working order for substantial product and architecture pull
requests. Each slice must remain independently reviewable, preserve detached
broker sessions, and use the fast local lane during implementation. Full
distribution, visual, resource, and interaction gates belong at milestones
rather than every edit.

Bounded regressions, reliability work, and release-speed improvements live in
[PULL_REQUEST_FIXES.md](PULL_REQUEST_FIXES.md).

## PR 1 — Rich editor and workspace spine

Build the strongest remaining daily-use surface without recreating an Electron
application inside the native app.

Scope:

- Add a confined CodeMirror 6 `WKWebView` editor surface.
- Keep file reads/writes, path confinement, dirty state, save/revert, undo
  ownership, and permissions in Swift.
- Add transient preview tabs, persistent edited tabs, outline navigation,
  follow-the-agent, and safe rename/move/trash/reveal actions.
- Improve repository indexing and watcher invalidation for large workspaces.

Acceptance:

- Opening, editing, saving, reverting, and reopening preserve exact source.
- File citations route to the requested file and line.
- A web editor cannot access arbitrary files, navigation, credentials, or the
  network outside its explicit message bridge.
- Focused workspace/editor tests pass, with native light/dark interaction QA.

## PR 2 — Unified command and keymap architecture

Create one typed command registry shared by the menu bar, command palette,
context menus, toolbar actions, and future user keymaps.

Scope:

- Define command identifiers, availability, discoverability, default shortcuts,
  and typed execution context.
- Move duplicated actions out of `KaisolaMacAppDelegate`, `RootShellView`, and
  feature-specific menus.
- Add validated `keymap.json` overrides with conflict reporting and reset.

Acceptance:

- A command has one implementation regardless of invocation surface.
- Disabled commands explain why they are unavailable.
- Invalid or conflicting keymaps fail safely without breaking default menus.

## PR 3 — Page-oriented transcript persistence

Keep the current anchored auto-pagination behavior while replacing monolithic
JSON transcript persistence with a store designed for long-lived sessions.

Scope:

- Add an actor-backed SQLite/page API with bounded reads and atomic migration.
- Persist stable row order, usage rollups, drafts, attachments, and session
  identity without loading every row at launch.
- Preserve viewport anchors when earlier pages are inserted.

Acceptance:

- Repeated top-edge loading reaches the first retained message.
- Relaunch and migration preserve ordering, drafts, costs, and tool cards.
- Streaming and history insertion never override deliberate user scrolling.

## PR 4 — Quiescent rolling broker updates

Make the broker shipped by an app update current for all new work immediately,
without terminating PTYs that are still owned by an older broker process.

The immutable generation digest, parity reporting, authenticated empty-broker
shutdown, automatic empty-broker replacement, and active-PTY preservation guard
shipped in v1.0.0 and are recorded in [`CHANGELOG.md`](CHANGELOG.md). The
remaining feature is multi-generation routing and drain retirement.

Scope:

- Stage verified packages in a private, versioned Application Support location
  so an installed-app replacement cannot remove files needed by a draining
  broker.
- Replace the single broker rendezvous with an atomic private registry that
  identifies one current generation and zero or more draining generations,
  each with its own socket and metadata.
- Add a broker-authoritative quiescence handshake. A cutover is eligible only
  after every CLI agent reports `busy:false` for a stability window, there are
  no in-flight create/write/control operations, and the broker rechecks the
  same activity epoch atomically when committing the cutover.
- Treat quiet output as a signal, not proof that a session is disposable. An
  idle Claude, Codex, Gemini, or OpenCode process still owns a live PTY and must
  never be killed merely because its turn settled.
- When the old broker owns live PTYs, launch the verified bundled generation
  alongside it and route every new terminal to the new generation while
  existing terminals remain connected to the generation that owns them.
- Abort and retry the cutover if an agent becomes busy, a user sends terminal
  input, a Companion control lease changes, or broker identity changes during
  the quiescence window.
- Stop and garbage-collect a draining generation only after its terminal
  inventory is empty, its clients have detached, and its identity is rechecked.
- Surface app, current-broker, and draining-broker versions in diagnostics and
  make rollback select an already verified generation rather than mutating a
  running process.

Acceptance:

- Immediately after an update, the current generation matches the installed
  app's sealed broker manifest and owns every newly created terminal.
- Terminals created before the update retain their broker and PTY process IDs
  until the user ends them naturally.
- Synthetic quiet output, a late activity event, queued terminal input, and a
  Companion lease race all cancel the attempted cutover without losing data.
- Empty old generations retire automatically; live generations are never
  killed merely because a newer app launched.
- Crash, power-loss, tampered-registry, downgrade, and incompatible-protocol
  tests fail closed without orphaning or adopting an ambiguous terminal.

## PR 5 — Native Companion production hardening

Close the remaining cutover evidence for the Swift desktop Companion host.

Scope:

- Real iPhone pairing, resume, revoke, account isolation, and capability grants.
- Nearby-to-Link network switching and reconnect behavior.
- Observe, agent-control, and terminal-control lease expiry and authentication.
- VoiceOver, Full Keyboard Access, clean-account, and signed update continuity.

Acceptance:

- A real-device matrix passes across LAN and Link routes.
- Revocation and account changes invalidate old access immediately.
- GUI replacement preserves authorized sessions without widening capabilities.

## PR 6 — Extensions and customization

Add safe registries for language grammars, previews, MCP packages, custom
agents, and editor themes after the command/editor boundaries are stable.

Acceptance:

- Extensions declare capabilities and cannot silently gain filesystem or secret
  access.
- Invalid packages degrade to a disabled state with an actionable explanation.
- Installation and removal are reversible and workspace/account scoped.

## PR 7 — Project and session ergonomics

Add project detach/adopt, ad-hoc cross-project session groups, richer task
ledger views, and workflow automation only after the daily editor and Companion
paths are dependable.

## PR 8 — Pixel-smooth terminal viewport parity

The v1.0.0 build 1002002 fix removes repaint snap-back, preserves native
momentum routing, and adds an always-visible AppKit scrollbar. The remaining
difference from Terminal.app is SwiftTerm's row-quantized viewport.

Scope:

- Add a narrow SwiftTerm viewport API or maintained patch that exposes a
  continuous macOS scroll origin without duplicating terminal protocol parsing.
- Back normal-buffer history with native `NSScrollView` momentum, rubber-band,
  scrollbar, keyboard, and accessibility behavior while leaving alternate-screen
  mouse reporting and application-owned scrolling untouched.
- Preserve terminal selection, links, semantic prompt navigation, paged history,
  live-bottom following, retained surfaces, and broker cursor continuity.

Acceptance:

- Trackpad deltas smaller than one terminal row move continuously without a
  synthetic one-row jump, flutter, or snap to live output.
- Claude Code repaint traffic and Codex streaming remain stable during gesture,
  momentum, scrollbar drag, resize, tab switch, and return-to-bottom cases.
- Light/dark visual fixtures, VoiceOver, 120 Hz cadence, and deep-history memory
  gates pass on the installed optimized app.

## PR 9 — Review and control workbench

Turn the human review loop into a first-class project surface shared by Chat,
Mesh, files, Git, and permissions.

Scope:

- Build one cached block-transcript renderer for Chat and Mesh with fenced,
  syntax-highlighted code, copy controls, tables, clickable file-and-line
  references, and expandable tool artifacts. Keep streaming updates bounded so
  a growing answer does not reparse the whole transcript on every token.
- Promote Git from a terminal-attached sheet into a project-level live
  inspector driven by workspace and `.git` changes. Add stage/unstage-all and
  pull controls.
- Replace the opaque “Push & Create PR” action with an explicit composer that
  previews base, branch, commits, files, title, body, remote, and destination
  before any push or PR creation.
- Expand permission cards into a decision-grade inspector showing the raw
  command or resource, every affected path, and the exact scope of a proposed
  persistent rule. Preserve Deny, Allow Once, and Create Rule as distinct
  choices.

Acceptance:

- Reviewing agent output never requires interpreting raw Markdown or trusting
  hidden permission scope.
- Large streaming answers and diffs remain responsive and expose an explicit
  expand path instead of silently truncating data.
- No push, PR, or standing permission rule occurs without a complete preview
  and an explicit confirmation.

## PR 10 — Reversible session and Mesh lifecycle

The immediate audit pass adds non-destructive Chat stop controls, per-column
and global Mesh stop, active-run close confirmation, and draft-safe sending.
Complete the lifecycle model without overloading “close” to mean deletion.

Scope:

- Distinguish Hide, Stop Current Turn, Stop All, Close to Recently Closed,
  Restore, and permanently Delete for Chat and Mesh.
- Persist staged Mesh prompts across window close and app restart; expose their
  order and allow individual removal before dispatch.
- Preserve transcripts, drafts, queued prompts, and recoverable worktrees for
  every non-delete action, with Undo for recently closed surfaces.
- Add ACP restart queue recovery so a crashed adapter can resume without users
  manually reconstructing pending work.

Acceptance:

- Ordinary close and stop operations never destroy history, drafts, queued
  prompts, or recoverable Git work.
- A running Mesh cannot disappear without a clear confirmation even when no
  worktree file has changed.
- Relaunch restores Recently Closed entries and staged prompt order exactly.

## PR 11 — Native preview performance, safety, and file coverage

The audit pass adds live-file reconciliation, dirty conflict banners, encoding
detection, binary sniffing, safe dead-end actions, notebook JSON rendering, and
off-main cached Markdown images. A bounded native PDFKit preview now covers PDF
selection, scrolling, magnification, and accessibility while parsing off the
main actor, and bounded Markdown tables visibly disclose omitted rows. Finish
the remaining large-document architecture. Rendered Markdown links now fail
closed to explicit http(s) destinations or symlink-confined project files, and
navigation flushes the latest Markdown draft before switching documents.

Scope:

- Use TextKit 2 for read-only text and Markdown-source views, preserving
  viewport position and providing native Find without entering edit mode.
- Parse CSV, JSON, and HTML readiness once per content/mtime and cache those
  results off the main thread.
- Split the preview monolith into recovery, tabs, editors, Markdown, assets, and
  content-preview units with typed notice/error channels.

Acceptance:

- A 1 MiB text file, a large CSV/JSON file, and image-heavy Markdown retain
  native momentum without main-thread parse or decode spikes.
- External edits remain truthful, dirty edits are never overwritten, and every
  unsupported state offers Finder and external-editor recovery.
- Rendered Markdown cannot launch an unapproved URL scheme, and truncated
  tables always disclose omitted rows.

## PR 12 — Terminal lifecycle, deep history, and accessibility

Build on PR 8 and the audit pass's ownership-safe surfaces, controller-lane
recovery, serialized input, strict resize acknowledgements, and retained
geometry reconciliation. The same pass now forwards replay-safe BEL attention,
matches Shift-Enter modifiers exactly, warns when Claude did not receive a
dropped image, and shows accessible ended/reconnecting state in the pane.

Scope:

- Incrementally sanitize transcript pages and move cached search off the main
  thread; subscribe tail-first and page older observer history on demand.
- Synchronize pane focus rings with AppKit first responder, add keyboard pane
  cycling, and provide throttled VoiceOver output announcements.
- Add target-specific Reopen from an ended pane, safe oversized-image
  downscaling, OSC 52 copy with consent, and Clear/Jump-to-Bottom commands.
- Remove the dead legacy terminal grid, use the active terminal theme for card
  chrome, and make the transcript viewer inherit the configured terminal font.

Acceptance:

- Twelve long retained sessions stay within a documented memory ceiling and
  history search remains responsive while output streams.
- Keyboard and VoiceOver users can identify, focus, operate, and recover every
  terminal state without a mouse.
- An exited pane, failed attachment, clipboard request, or attention bell is
  never silently ignored.

## PR 13 — Native accessibility, design-system adoption, and readiness

The immediate audit pass makes transient toasts VoiceOver-actionable and
announced, adds Reduce Motion behavior to those toasts and onboarding, and
improves terminal and permission labels. Complete the same floor app-wide.

Scope:

- Introduce shared labeled, colorblind-safe status indicators; semantic diff
  colors; app-wide Reduce Motion fallbacks; and truthful focus state.
- Adopt the existing radius, motion, palette, hairline, and compact-type tokens
  across Chat, Git, Mesh, files, Settings, badges, and terminal chrome.
- Complete the menu/command registry work from PR 2, including palette button
  traits, shortcut parity, Mesh and Settings coverage, and standard macOS
  close/window behavior.
- Replace feature-marketing onboarding and the migration-roadmap Help link with
  an operational readiness checklist and real user troubleshooting.

Acceptance:

- Accessibility inspection finds no unnamed controls, color-only status, low-
  contrast diff text, unannounced consequential toast, or mandatory motion.
- Menu shortcuts and palette hints come from one registry and cannot drift.
- Onboarding ends with a verified project, background session service, agent
  adapter/account state, and runnable first session.

## PR 14 — Durable failure visibility and core scaling

The audit pass moves Unix socket work to dedicated queues, makes close wake
blocked I/O, bounds Git branch probes, reconnects after repeated inventory
failures, orders menu-window targeting, and cleans completed teardown tasks.
Finish the remaining failure and scaling seams.

Scope:

- Surface workspace-archive corruption and session-store disk-write failures in
  a recoverable degraded-state UI, including rename-aside recovery and retry.
- Replace eager 64 MiB observer restoration with bounded tail-first paging and
  explicit memory budgets for retained terminal surfaces.
- Batch idle process metadata probes, harden bootstrap process output draining,
  and ensure all long-lived tasks remove their completion bookkeeping.
- Make failed pop-out targets show the standard missing-session recovery card
  instead of an empty window.

Acceptance:

- No data-affecting persistence or restoration failure is silent.
- Reconnect, wake, and repeated open/close cycles cannot leak executor threads,
  tasks, sockets, or unbounded terminal documents.
- Corrupt state and unavailable sessions fail closed while preserving a clear
  recovery path.

## Explicitly deferred

- A wholesale Rust rewrite.
- A general web renderer or React shell.
- Legacy Studio/research pipelines unless product scope is explicitly reopened.
- Retiring the detached broker before Companion, accessibility, clean-account,
  signing, coexistence, and sustained daily-use gates pass.
