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

## Explicitly deferred

- A wholesale Rust rewrite.
- A general web renderer or React shell.
- Legacy Studio/research pipelines unless product scope is explicitly reopened.
- Retiring the detached broker before Companion, accessibility, clean-account,
  signing, coexistence, and sustained daily-use gates pass.
