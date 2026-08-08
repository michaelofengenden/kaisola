# Native Kaisola: remaining bugs and reliability work

This tracker contains only unresolved fixes after v1.1.9. Completed audit fixes
and their verification history are recorded in [`CHANGELOG.md`](CHANGELOG.md).
Large product and architecture work remains ordered in
[`PULL_REQUEST_FEATURES.md`](PULL_REQUEST_FEATURES.md).

## Open audit fixes

### Preview correctness and interaction performance

- Keep installed-build performance gates for 1 MiB text, large structured data,
  PDFs, and image-heavy Markdown. This is also tracked as PR 11 acceptance.

### Terminal parity and failure feedback

- Keep the PR 8 physical-trackpad gate open until sub-row movement is genuinely
  continuous in the installed app; row-quantized SwiftTerm scrolling is not
  considered fixed by the repaint/geometry work alone.

### Checkpoint keep-alive ref collisions

- Checkpoint refs are named by stash-commit hash alone
  (`refs/kaisola/checkpoints/<hash>`, `GitService.checkpoint()`), so two
  conversations that snapshot an identical tree within the same second mint
  the same commit and share one ref; whichever conversation ages its
  checkpoint out first (`dropCheckpointRef`) deletes the ref and strands the
  other's restore point until git gc actually prunes it. Reproduction: two
  ACP chats in one project, both send a turn with the same dirty tree inside
  one second; age one conversation's checkpoint out of the menu; the other's
  Restore can fail after gc. Fix boundary: name refs by conversation and
  turn (`refs/kaisola/checkpoints/<conversation>/<turn>-<hash>`) and drop
  only the owning conversation's ref; regression test covers two owners of
  one snapshot hash. Found during the 2026-08-04 harvest-blueprint review
  (`notes/harvest-blueprint-2026-08.md`).

### Terminal input-path blast radius (2026-08-07 stuck-typing review)

Found while root-causing the empty-drain reconnect loop (fixed that night:
`detachedGenerationIDs` skip + retirement candidate iteration). These are the
remaining, verified defects in the typed-input path, none regressions:

- One failed `terminal.write` tears down the whole controller connection:
  `drainTerminalInputQueue`'s catch sets `controlAvailable = false`, clears
  `ownedTerminalIDs`, and calls `connectionLost` — a 5s RPC timeout on ONE
  terminal makes EVERY terminal read-only and forces a full two-lane
  reconnect. Fix boundary: retry once / scope the failure to that terminal,
  escalating to `connectionLost` only for connection-level errors; regression
  test drives one write failure and asserts other terminals stay owned.
- Aborted input drains leave queue residue: when the drain loop exits on an
  ownership flap, `terminalInputQueues[id]` keeps the unsent packets and the
  next keystroke after recovery flushes them late — stale bytes (possibly a
  carriage return) submitted into the CLI. Fix boundary: drop or explicitly
  re-offer queued packets when ownership is lost, never silently replay.
- An ownership flap rebuilds the whole surface: `TerminalSurfaceCache.claim`
  discards the parked view on an `isOwned` mismatch (deliberate security
  boundary), so a transient flap re-parses up to 8 MB of transcript on the
  main thread and can visually reset the pane. Mostly mitigated by fixing
  the teardown blast radius above; revisit only if flaps remain visible.
- Retirement sweep can still fixate: a candidate whose retirement is
  `.accepted` but whose `waitForRetirement` never completes consumes the
  one-retirement-per-heartbeat budget ahead of healthy candidates behind it
  (pre-existing; narrower than the starvation fixed 2026-08-07). Fix
  boundary: rotate the starting candidate or skip repeat offenders.

## Adding a fix

Each confirmed fix should include:

- the exact reproduction and expected behavior;
- the affected app/build and broker generation, when relevant;
- the smallest safe implementation boundary;
- a focused regression test;
- local verification, plus milestone-only distribution gates when needed.
