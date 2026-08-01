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
- Large read-only text uses TextKit 2 with native Find and retained viewport;
  CSV/JSON parsing is cached by content identity (`1ff191d`, `cf697a5`,
  `e33150b`, `770acb9`).
- Observer terminals subscribe tail-first, the legacy grid is gone, focus tracks
  AppKit's first responder, and transcript font, Clear, Jump to Bottom, and
  consented OSC 52 copy are implemented (`dd8097e`, `3365d32`, `bf733ad`,
  `fa44da2`, `facc171`, `d5d12d1`).
- The Git panel refreshes from filesystem events and PR creation is split into
  an inspectable review followed by explicit execution (`81a59cb`).
- Status indicators expose shape and accessible names, and the user-facing copy
  pass removed several implementation terms (`50e00aa`, `949c4ef`).
- Bounded PDF files now open in a native PDFKit surface with selection,
  scrolling, magnification, and accessibility; parsing stays off the main actor.
- Truncated Markdown tables now state the exact number of rows not shown instead
  of silently stopping after the bounded 100-row preview.
- Rendered Markdown now blocks custom schemes, credential-bearing web links,
  scheme-relative URLs, and filesystem escapes; project files route back into
  Kaisola through one symlink-safe policy shared with HTML previews.

## Open audit fixes

### Preview correctness and interaction performance

- Finish the typed informational recovery banner.
- Split the preview monolith into bounded content units and keep installed-build
  performance gates for 1 MiB text, large structured data, PDFs, and image-heavy
  Markdown.

### Terminal parity and failure feedback

- Make transcript sanitization incremental and move cached history search off
  the main actor.
- Add throttled VoiceOver output announcements and terminal-themed pane chrome.
- Keep the PR 8 physical-trackpad gate open until sub-row movement is genuinely
  continuous in the installed app; row-quantized SwiftTerm scrolling is not
  considered fixed by the repaint/geometry work alone.

### Shell, Git, and session recovery

- Make pop-out failure explicit; the current-window preference for an already
  visible local surface is implemented.
- Finish reversible Recently Closed/Restore/Delete behavior and persisted,
  inspectable Mesh staged prompts.

### Accessibility, copy, and readiness

- Replace remaining low-contrast attention badges; honor Reduce Motion outside
  the covered toast, onboarding, restoration, palette, and rail paths; and
  expose truthful keyboard focus and button traits throughout the AX tree.
- Finish Title Case and project terminology, remove background-service jargon
  from user surfaces, align menu/palette shortcuts, and replace developer Help
  and feature-marketing onboarding with operational guidance.
- Add a real provider API-key connectivity probe and complete the Accounts
  information architecture.

## Adding a fix

Each confirmed fix should include:

- the exact reproduction and expected behavior;
- the affected app/build and broker generation, when relevant;
- the smallest safe implementation boundary;
- a focused regression test;
- local verification, plus milestone-only distribution gates when needed.
