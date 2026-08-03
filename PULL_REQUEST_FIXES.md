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

## Adding a fix

Each confirmed fix should include:

- the exact reproduction and expected behavior;
- the affected app/build and broker generation, when relevant;
- the smallest safe implementation boundary;
- a focused regression test;
- local verification, plus milestone-only distribution gates when needed.
