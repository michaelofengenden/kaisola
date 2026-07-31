# Native Kaisola: bugs, reliability, and iteration fixes

The 2026-07-30 native audit's P0 input-path and principal P1 data-loss fixes are
implemented in the current local iteration. The following bounded issues remain
open; they are not silently treated as completed merely because the broader
architecture is tracked in the feature plan.

Large product and architecture work remains ordered in
[`PULL_REQUEST_FEATURES.md`](PULL_REQUEST_FEATURES.md).

## Open audit fixes

### Persistence and restoration visibility

- Reproduce a corrupt/unsupported workspace archive and a disk-full session
  store write; show a persistent, recoverable degraded-state notice rather than
  restoring an unexplained empty workspace or reverting silently on relaunch.
- Add rename-aside/export and retry actions without overwriting the protected
  archive.
- Verify that AppModel's chat-shutdown, split-intent, and explicitly-closed ID
  bookkeeping is pruned after completion.

### Preview correctness and interaction performance

- Move large read-only text to TextKit 2 and cache CSV/JSON/HTML preparation by
  content identity so hover, zoom, and navigation never repeat full parsing.
- Add native Find to read mode, autosave-flush Markdown before navigation, a
  visible “more rows” marker for truncated Markdown tables, and an explicit
  http/https/workspace-file link policy.
- Add PDFKit and a typed informational recovery banner; keep performance gates
  for 1 MiB text and image-heavy Markdown on an installed optimized build.

### Terminal parity and failure feedback

- Page older observer history instead of eagerly retaining 64 MiB per cold
  selection; make transcript sanitization incremental and search cached/off-main.
- Add focus/VoiceOver synchronization, configured transcript font, terminal-
  themed chrome, clear/jump commands, consented OSC 52 copy, and remove the
  obsolete terminal-grid implementation.
- Keep the PR 8 physical-trackpad gate open until sub-row movement is genuinely
  continuous in the installed app; row-quantized SwiftTerm scrolling is not
  considered fixed by the repaint/geometry work alone.

### Shell, Git, and session recovery

- Make pop-out failure explicit and prefer the current window when a surface is
  already visible locally.
- Drive the Git panel from workspace/Git filesystem events rather than only its
  bounded timer, and split PR creation into review then execution.
- Finish reversible Recently Closed/Restore/Delete behavior and persisted,
  inspectable Mesh staged prompts.

### Accessibility, copy, and readiness

- Replace remaining color-only status dots and low-contrast attention badges;
  honor Reduce Motion outside the now-covered toast/onboarding paths; and expose
  truthful keyboard focus and button traits throughout the AX tree.
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
