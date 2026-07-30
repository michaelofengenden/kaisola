# Native Kaisola: bugs, reliability, and iteration fixes

There are no open release-blocking fixes after v1.0.0. The completed broker
parity, fast-test selection, release-promotion, terminal, Markdown, navigation,
and file-routing work has moved to [`CHANGELOG.md`](CHANGELOG.md).

Large product and architecture work remains ordered in
[`PULL_REQUEST_FEATURES.md`](PULL_REQUEST_FEATURES.md).

## Adding a fix

Each confirmed fix should include:

- the exact reproduction and expected behavior;
- the affected app/build and broker generation, when relevant;
- the smallest safe implementation boundary;
- a focused regression test;
- local verification, plus milestone-only distribution gates when needed.
