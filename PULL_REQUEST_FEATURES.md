# Native Kaisola: remaining feature and implementation PRs

This tracker contains only unfinished product and architecture work after
v1.1.9. Completed PRs and their shipped behavior are recorded in
[`CHANGELOG.md`](CHANGELOG.md). Bounded regressions and reliability work live in
[`PULL_REQUEST_FIXES.md`](PULL_REQUEST_FIXES.md).

Each slice must remain independently reviewable, preserve detached broker
sessions, and use the fast local lane during implementation. Full distribution,
visual, resource, and interaction gates belong at milestones rather than every
edit.

## PR 5 — Native Companion production hardening

Status: open.

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

Status: open.

Add safe registries for language grammars, previews, MCP packages, custom
agents, and editor themes after the command/editor boundaries are stable.

Acceptance:

- Extensions declare capabilities and cannot silently gain filesystem or secret
  access.
- Invalid packages degrade to a disabled state with an actionable explanation.
- Installation and removal are reversible and workspace/account scoped.

## PR 7 — Project and session ergonomics

Status: open.

Add project detach/adopt, ad-hoc cross-project session groups, richer task
ledger views, and workflow automation only after the daily editor and Companion
paths are dependable.

## PR 8 — Pixel-smooth terminal viewport parity

Status: open.

The v1.0.0 build 1002002 fix removes repaint snap-back, preserves native
momentum routing, and adds an always-visible AppKit scrollbar. The remaining
difference from Terminal.app is SwiftTerm's row-quantized viewport.

Scope:

- Add a narrow SwiftTerm viewport API or maintained patch that exposes a
  continuous macOS scroll origin without duplicating terminal protocol parsing.
- Back normal-buffer history with native `NSScrollView` momentum, rubber-band,
  scrollbar, keyboard, and accessibility behavior while leaving
  alternate-screen mouse reporting and application-owned scrolling untouched.
- Preserve terminal selection, links, semantic prompt navigation, paged
  history, live-bottom following, retained surfaces, and broker cursor
  continuity.

Acceptance:

- Trackpad deltas smaller than one terminal row move continuously without a
  synthetic one-row jump, flutter, or snap to live output.
- Claude Code repaint traffic and Codex streaming remain stable during gesture,
  momentum, scrollbar drag, resize, tab switch, and return-to-bottom cases.
- Light/dark visual fixtures, VoiceOver, 120 Hz cadence, and deep-history memory
  gates pass on the installed optimized app.

## PR 11 — Native preview installed-build performance gates

Status: implementation shipped; installed-build acceptance remains open.

TextKit 2 read mode, off-main structured-data preparation, PDFKit, bounded
Markdown images, truthful external-edit handling, safe navigation, and explicit
truncation all shipped in v1.1.9. The remaining work is performance evidence on
the installed optimized app.

Acceptance remaining:

- ~~Preparation budgets for 1 MiB text and large CSV/JSON data.~~ Done:
  `PreviewPreparationBudgetTests` holds a >1 MiB CSV and a >500 KB JSON to a
  3 s budget, asserts CSV parsing stays roughly linear rather than passing one
  size and stalling on a real file, requires malformed JSON to be rejected in
  under a second, and holds delimiter detection to a sample rather than a full
  scan.
- ~~Image-heavy Markdown.~~ Done: a 1,500-figure document parses inside the
  same budget, and image sizing — called per image per layout pass — is held to
  200,000 calls in under a second, which is what keeps it arithmetic rather
  than something that touches the file.
- Bounded PDFs still need an equivalent budget. PDFKit does its own paging and
  decoding, so a meaningful gate has to measure the *surface*, not a parser,
  and that needs the installed app.
- Confirm those surfaces retain native momentum on the **installed optimized
  app**. The in-process budgets above are what can be measured without one;
  momentum under gesture needs the signed build and a physical trackpad, which
  is the same gate PR 8 is waiting on.

## PR 12 — Terminal sustained-history acceptance

Status: implementation shipped; sustained-history acceptance remains open.

Incremental transcript sanitizing, cached search, tail-first paging, AppKit
focus, keyboard pane cycling, OSC 52 consent, terminal commands, focused
VoiceOver output, palette-matched chrome, exact-pane reopen, and bounded image
downscaling shipped in v1.1.9.

Acceptance remaining:

- ~~Prove the twelve-surface retained deck stays within the documented 96 MiB
  ceiling.~~ Done: `RetainedTerminalDeckAtScaleTests` drives the real constants
  at full deck size, including twelve saturated terminals, the two cases the
  budget's own comment promises, a thirty-terminal tour that crosses the bound
  repeatedly, and the mounted-surface exemption.
- Prove history search remains responsive under streaming output.
- Re-run the sustained interaction and memory gate on the installed optimized
  app alongside PR 8's physical-trackpad gate. Blocked on a signed installed
  build; the in-process half above is what can be checked without one.

## Explicitly deferred

- A wholesale Rust rewrite.
- A general web renderer or React shell.
- Legacy Studio/research pipelines unless product scope is explicitly reopened.
- Retiring the detached broker before Companion, accessibility, clean-account,
  signing, coexistence, and sustained daily-use gates pass.
