# Native Kaisola: ordered implementation PRs

This is the working order for the next coherent pull requests. Each slice must
remain independently reviewable, preserve detached broker sessions, and use the
fast local lane during implementation. Full distribution, visual, resource,
and interaction gates belong at milestones rather than every edit.

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

## PR 4 — Native Companion production hardening

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

## PR 5 — Extensions and customization

Add safe registries for language grammars, previews, MCP packages, custom
agents, and editor themes after the command/editor boundaries are stable.

Acceptance:

- Extensions declare capabilities and cannot silently gain filesystem or secret
  access.
- Invalid packages degrade to a disabled state with an actionable explanation.
- Installation and removal are reversible and workspace/account scoped.

## PR 6 — Project and session ergonomics

Add project detach/adopt, ad-hoc cross-project session groups, richer task
ledger views, and workflow automation only after the daily editor and Companion
paths are dependable.

## Cross-cutting speed work

Land alongside the feature PRs when the touched boundary makes it natural:

1. Keep `native:fast` and focused `--run-only` tests as the edit loop.
2. Split the largest Swift files into feature models/coordinators and smaller
   views, measuring cold and warm build timing before and after.
3. Add deterministic changed-file-to-focused-test selection.
4. Build/test/sign/notarize one immutable candidate after a green main commit.
5. Make public release a provenance-checked promotion of that candidate so the
   tag, GitHub assets, and Sparkle appcast publish in one to two minutes.

## Explicitly deferred

- A wholesale Rust rewrite.
- A general web renderer or React shell.
- Legacy Studio/research pipelines unless product scope is explicitly reopened.
- Retiring the detached broker before Companion, accessibility, clean-account,
  signing, coexistence, and sustained daily-use gates pass.
