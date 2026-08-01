# Native Kaisola: bugs, reliability, and iteration fixes

The 2026-07-30 native audit's P0 input-path and principal P1 data-loss fixes are
implemented. This list was reconciled against v1.1.8 on 2026-08-01 so work that
has shipped is no longer presented as open merely because the broader
architecture remains in the feature plan.

Large product and architecture work remains ordered in
[`PULL_REQUEST_FEATURES.md`](PULL_REQUEST_FEATURES.md).

## Landed since the audit

- Persistence failures are visible and recoverable: corrupt or newer workspace
  archives are preserved, retryable, and never silently overwritten; session
  store write failures retain the cached payload (`2f9a9b9`, `3b10449`).
- AppModel now prunes completed shutdown, split, and closed-surface bookkeeping
  instead of growing it for the life of the app (`0dda009`, `3b10449`).
- Idle session metadata now shares one bounded process-table snapshot and
  batched port probes, repeated refreshes cannot overlap, and direct helper
  startup drains bounded stdout and stderr concurrently instead of waiting on
  full kernel pipes.
- Large read-only text uses TextKit 2 with native Find and retained viewport;
  CSV/JSON parsing is cached by content identity (`1ff191d`, `cf697a5`,
  `e33150b`, `770acb9`).
- Observer terminals subscribe tail-first, the legacy grid is gone, focus tracks
  AppKit's first responder, and transcript font, Clear, Jump to Bottom, and
  consented OSC 52 copy are implemented (`dd8097e`, `3365d32`, `bf733ad`,
  `fa44da2`, `facc171`, `d5d12d1`).
- The Git panel refreshes from filesystem events, stages or unstages every
  change in one reversible action, and fast-forwards only a clean branch with a
  configured upstream. PR creation is split into review and execution; the
  review discloses every changed path plus a credential-safe
  remote/repository/base destination, and invalidates itself if that target
  changes (`81a59cb`).
- Status indicators expose shape and accessible names, and the user-facing copy
  pass removed several implementation terms (`50e00aa`, `949c4ef`).
- Bounded PDF files now open in a native PDFKit surface with selection,
  scrolling, magnification, and accessibility; parsing stays off the main actor.
- Truncated Markdown tables now state the exact number of rows not shown instead
  of silently stopping after the bounded 100-row preview.
- Rendered Markdown now blocks custom schemes, credential-bearing web links,
  scheme-relative URLs, and filesystem escapes; project files route back into
  Kaisola through one symlink-safe policy shared with HTML previews.
- Markdown navigation now flushes immediately, waits for an in-flight snapshot,
  and saves a newer draft again before committing the file switch; conflicts
  and failures return to an explicit user decision.
- Preview recovery now uses a dismissible typed notice row: an ordinary restored
  draft is informational, a restored draft with a disk change is a warning, and
  editor, recovery, or save failures remain errors with accessible labels.
- Preview ownership is split into bounded content-policy, recovery, tab,
  editor, Markdown-rendering, and asset-loading units; the changed-file runner
  maps every extracted source back to the complete preview contract lane.
- CSV, JSON, and HTML readiness now prepare through a view-lifetime actor cache
  keyed by path, modification date, and explicit reload revision; a near-limit
  structured-data contract pins bounded first preparation and single parsing.
- Retained terminal pages now filter control strings chunk by chunk before
  replay, while debounced transcript matching and attributed highlights prepare
  in a cancellable actor cache keyed by page generation and appearance.
- The focused terminal now coalesces rendered, bounded VoiceOver output at an
  800 ms cadence without replaying background backlog; terminal pane chrome
  derives from the same opaque native/Kaisola palette as its SwiftTerm canvas.
- An ended owned pane can recreate that exact agent/account/title/draft recipe
  in place with a fresh PTY, while oversized valid ACP images downscale off-main
  through a 2048 px/128 MB-bounded ImageIO path instead of being rejected.
- Failed pop-out targets now retain a standard missing-session recovery card
  with Try Again and Back to Main Window; window/model construction failures also
  surface an explicit error toast.
- Waiting staged Mesh prompts now persist in exact FIFO order, restore paused,
  and remain inspectable, removable one at a time, and explicitly resumable
  from both standalone and embedded Mesh headers.
- Chat and Mesh now distinguish Hide, Stop, Close to Recently Closed, Restore,
  and confirmed permanent Delete. Relaunch keeps closed transcripts, drafts,
  queued prompts, and Mesh worktree manifests; Undo Last Close and per-entry
  Restore/Delete controls are available from each project rail.
- ACP follow-up queues now persist in exact FIFO order. A fresh adapter resumes
  only never-dispatched entries after Restart; the interrupted prompt remains a
  visible explicit Retry so ambiguous delivery cannot duplicate side effects.
- Settings now gives sign-ins, named accounts, app defaults, and per-project
  overrides one Accounts tab. Saved or newly pasted direct-API keys can be
  verified through a bounded, no-prompt provider request that refuses redirects
  and never displays the credential or an upstream response body.
- First run is now a live readiness checklist for the project, terminal
  continuity, selected agent account, update policy, and runnable first session.
  Help opens a user guide with shortcuts and recovery steps; buttons use Title
  Case, project surfaces use project terminology, and session failures no longer
  expose broker or app-server implementation vocabulary.
- Menu items, the command palette, project launch menus, and workspace controls
  now share one typed command registry. Palette hints and AppKit shortcuts use
  the same validated keymap snapshot; conflicts preserve every default and stay
  actionable from the Keyboard Settings tab.
- Attention, working, completion, and failure indicators now use distinct
  shapes plus contrast-tested filled colors instead of raw orange/green text or
  color-only dots. The workspace and Settings roots enforce Reduce Motion for
  every descendant animation, while Chat and Mesh participate in keyboard pane
  cycling through real composer focus targets.

## Open audit fixes

### Preview correctness and interaction performance

- Keep installed-build performance gates for 1 MiB text, large structured data,
  PDFs, and image-heavy Markdown.

### Terminal parity and failure feedback

- Keep the PR 8 physical-trackpad gate open until sub-row movement is genuinely
  continuous in the installed app; row-quantized SwiftTerm scrolling is not
  considered fixed by the repaint/geometry work alone.

## Adding a fix

Each confirmed fix should include:

- the exact reproduction and expected behavior;
- the affected app/build and broker generation, when relevant;
- the smallest safe implementation boundary;
- a focused regression test;
- local verification, plus milestone-only distribution gates when needed.
