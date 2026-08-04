# Native Kaisola: remaining feature and implementation PRs

This tracker contains only unfinished product and architecture work after
v1.1.9. Completed PRs and their shipped behavior are recorded in
[`CHANGELOG.md`](CHANGELOG.md). Bounded regressions and reliability work live in
[`PULL_REQUEST_FIXES.md`](PULL_REQUEST_FIXES.md).

Each slice must remain independently reviewable, preserve detached broker
sessions, and use the fast local lane during implementation. Full distribution,
visual, resource, and interaction gates belong at milestones rather than every
edit.

## Completion snapshot — 2026-08-04

The 2026-08-03–04 backlog iteration completed roughly **40–45% of the remaining
tracker scope** on a simple, unweighted section-by-section estimate. This is a
progress indicator, not an engineering-effort estimate. None of the six retained
PR sections is fully closable yet: five were advanced, four gained substantive
feature or acceptance completion, and PR 8 was untouched.

| PR | Completion in the iteration | Remaining state |
| --- | --- | --- |
| PR 5 | Simulator/build blockers removed | Final real-device and production acceptance remains open |
| PR 6 | Core registry and custom-agent process slices shipped | Consolidated settings UI remains; stronger process sandboxing is optional future work |
| PR 7 | 2 of 4 major slices shipped | Cross-project groups need a design decision; workflow automation is deferred |
| PR 8 | No new completion | Pixel-smooth viewport implementation and physical-trackpad acceptance remain open |
| PR 11 | 2 of 4 explicit acceptance gates completed | Bounded-PDF and installed-app momentum gates remain |
| PR 12 | 2 of 3 explicit acceptance gates completed | Installed-app sustained-history acceptance remains |

The independently runnable evidence for PRs 6, 7, 11, and 12 currently passes
60 of 60 focused tests. That does not close device-only, signed-installed-app,
physical-trackpad, accessibility, or sustained-interaction gates.

## PR 5 — Native Companion production hardening

Status: Simulator enablement shipped; final production acceptance remains open.

Close the remaining cutover evidence for the Swift desktop Companion host.

Scope:

- Real iPhone pairing, resume, revoke, account isolation, and capability grants.
- Nearby-to-Link network switching and reconnect behavior.
- Observe, agent-control, and terminal-control lease expiry and authentication.
- VoiceOver, Full Keyboard Access, clean-account, and signed update continuity.

Most of this is reachable on the **Simulator**, which shares the Mac's network
stack and therefore sees the `_kaisola._tcp` advertisement. `npm run
companion:sim` builds, installs and launches it; the Companion now runs there
and reaches its sign-in screen cleanly.

Two blockers were in the way and are fixed:

- The project declared no `SUPPORTED_PLATFORMS`, so Xcode derived device-only
  support from `SDKROOT` and the scheme offered *zero* eligible destinations.
  This is why the whole matrix read as needing hardware.
- Building with `CODE_SIGNING_ALLOWED=NO` yields an app with no entitlements,
  which fails at launch with "a required entitlement isn't present". A signed
  simulator build carries `application-identifier` and works. Not a product
  bug; the harness signs.

Acceptance:

- Pairing, resume, revoke, account isolation, capability grants and lease
  expiry — reachable on the Simulator, gated only on signing in to the account
  and enabling the Companion host on the Mac.
- Nearby-to-Link switching and Face ID genuinely need a device: a simulator
  never leaves the LAN, and Face ID there is synthetic.
- A real-device matrix passes across LAN and Link routes.
- Revocation and account changes invalidate old access immediately.
- GUI replacement preserves authorized sessions without widening capabilities.

## PR 6 — Extensions and customization

Status: core data registries and the custom-agent process slice shipped;
settings consolidation remains.

Spec: `notes/pr6-extensions-spec.md` (v2, revised after an adversarial Codex
review). Shipped 2026-08-04:

- **Terminal themes** are a registry: shipped pair plus validated custom
  themes (JSON import, hex palettes, 16 ANSI slots), invalid entries listed
  disabled with the exact failing field named, removal one click, stored
  choice migrated for free.
- **Language grammars** are a registry: custom grammars (extensions + fence
  tokens + regex rules over the five fixed roles) run through the same
  never-crash scanner as shipped languages behind an mtime-checked cache;
  shipped extensions cannot be taken over.
- **Preview mappings** are a registry: unknown extensions can route to the
  preview's *text* kinds only — image/PDF/docx loaders are deliberately
  unreachable, and every built-in classification (binary sniff, size caps)
  runs first.
- MCP packages were already the reference registry; unchanged.

The process slice shipped 2026-08-04 against all four review findings:
custom agents reach chat only through `AdapterInstallManager` — enable
resolves the npm package into an app-owned install with scripts disabled,
pins the full dependency graph by lockfile hash, and spawns the resolved
executable itself (never `npx`); any drift refuses chat by name until
re-approved. Credential contexts are declared roster data
(claude/codex/none — `.none` chats open bindingless), built-in ids and
adapters are untouched, legacy specs decode chat-disabled, and the enable
sheet states plainly that the adapter runs with the user's ordinary
access. Remaining niceties: a consolidated Extensions settings tab
(grammar/mapping rosters still have stores but no UI), and sandboxing the
adapter process if the stronger promise is ever wanted.

## PR 7 — Project and session ergonomics

Status: 2 of 4 major slices shipped; groups are gated on a design decision and
workflow automation is deferred.

Spec: `notes/pr7-ergonomics-spec.md`. Shipped 2026-08-04:

- The needs-you inbox is the all-agents center — grouped by project
  (resolved live, never persisted), filterable by kind, gone targets dimmed
  to clear-only — with per-event notification delivery rules beside it.
- Terminal **Move to Project** via the adoption overlay: presentation
  regroups, the broker keeps addressing the real project, the adopter's
  workspace snapshot enrolls the pane under its own id (proven against the
  persistence normalizer), provenance is named in the row tooltip, and
  Return is deleting one row.

Remaining: the cross-project-groups design gate (ephemeral vs first-class
group store — Michael's call), and workflow automation stays deferred.

## PR 8 — Pixel-smooth terminal viewport parity

Status: open; no completion in the 2026-08-03–04 backlog iteration.

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

Status: implementation shipped; 2 of 4 explicit acceptance gates are complete.

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

Status: implementation shipped; 2 of 3 explicit acceptance gates are complete.

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
- ~~Prove history search remains responsive under streaming output.~~ Done:
  `TranscriptSearchBudgetTests` searches an ~8 MB retained history inside
  1.5 s, holds six keystrokes over a ~4 MB buffer to 2 s, requires the cost to
  stay roughly linear so a saturated 16 MiB document does not stall, and
  requires an empty query — what the field holds most of the time — to cost
  nothing.
- Re-run the sustained interaction and memory gate on the installed optimized
  app alongside PR 8's physical-trackpad gate. Blocked on a signed installed
  build; the in-process half above is what can be checked without one.

## Explicitly deferred

- A wholesale Rust rewrite.
- A general web renderer or React shell.
- Legacy Studio/research pipelines unless product scope is explicitly reopened.
- Retiring the detached broker before Companion, accessibility, clean-account,
  signing, coexistence, and sustained daily-use gates pass.
