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

## Adding a fix

Each confirmed fix should include:

- the exact reproduction and expected behavior;
- the affected app/build and broker generation, when relevant;
- the smallest safe implementation boundary;
- a focused regression test;
- local verification, plus milestone-only distribution gates when needed.
