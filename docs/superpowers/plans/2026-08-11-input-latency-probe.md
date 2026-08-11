# Implementation plan: keystroke-to-glyph probe

Date: 2026-08-11
Spec: `docs/superpowers/specs/2026-08-10-terminal-responsiveness-design.md`, Layer 0
Branch to cut: `perf/input-latency-probe`, off `perf/terminal-hot-path`

## Why this is now the blocking item

Three items from the design were attempted and withdrawn because each needed a
number that does not exist:

- Dropping the `String(data:encoding:)` UTF-8 probe in
  `KaisolaCore/Sources/KaisolaBrokerProtocol/BrokerWire.swift:373` changes a
  typed error that `BrokerWireTests.swift:151` asserts on. Replacing it with a
  hand-written validator puts a bespoke UTF-8 state machine at a security
  boundary to save an allocation nobody has shown matters.
- Unpublishing `AcpConversation.contentVersion` (`Acp/AcpConversation.swift:253`)
  breaks `.onChange` handlers at `Acp/AcpChatView.swift:570` and
  `Mesh/MeshView.swift:1142`.
- Debouncing `onTranscriptChanged` reorders it against the
  tombstone-before-cleanup fence established in the PR #799 wave-30 union.
- Draining the app's output window on the leading edge broke the
  one-publish-per-interval invariant in `AppModelReconnectTests`, and was
  reverted for exactly this reason.

Each is a real cost with a real risk attached. Without measurement the honest
answer to all of them is no. With it, each becomes a decision instead of a
guess.

## What exists to build on

- `KaisolaMacMain.main()` (`App/KaisolaMacAppDelegate.swift:713`) already
  branches into fixture modes on `KAISOLA_NATIVE_VISUAL_FIXTURE`,
  `KAISOLA_NATIVE_RESOURCE_WORKLOAD` and `KAISOLA_NATIVE_PDF_PREVIEW_BUDGET`
  rather than constructing the IDE.
- `VisualTerminalContinuousScrollReceipt` (`:580`) is the receipt shape to copy:
  a `Codable` struct with the thresholds as static constants, printed behind a
  prefix and parsed by a `scripts/native-*.cjs` gate.
- `TerminalInputPolicy.swift:478` documents that `NSEvent.timestamp` and
  `ProcessInfo.systemUptime` share a time base, which is what makes an
  event-to-frame interval computable at all.
- `PDFPreviewBudgetRunner` is the closest structural precedent: a phase-driven
  runner owned by the delegate, emitting one machine-readable receipt.

## Tasks

### 1. The responder

A terminal running `cat` echoes through the line discipline *and* through `cat`,
so one keystroke produces two glyphs. `stty -echo` is not enough either:
canonical mode still buffers until newline, so `read(1)` blocks.

Ship a tiny responder script the fixture launches instead of a shell:

- `stty raw -echo` on the pty, then read one byte and write one known byte back.
- Deterministic, single echo, no prompt, no OSC 133, no repaint.
- Verify by asserting the byte count out equals the byte count in.

### 2. Four timestamps

| Stage | Where |
|---|---|
| `t0` | `keyDown` in the terminal surface, from `NSEvent.timestamp` |
| `t1` | immediately **before** the broker write is issued |
| `t2` | when the echoed bytes reach `view.feed()` in `NativeTerminalCoordinator` |
| `t3` | first display-link callback after that feed |

`t1` is taken before the send, not on the response: the write reply and the
observer output travel different sockets, so the echo can arrive before the RPC
resolves and a post-return `t1` produces negative stage times.

Correlate by content. Each keystroke uses a distinct character from a
non-repeating sequence so the echo is matched by value, not by assumed ordering.

`t3` is a display *opportunity*, not proof of presentation. Report it under that
name. Real presentation needs a surface-present callback the app does not have,
and overclaiming here would make every later comparison dishonest.

### 3. Two workloads

- **Idle**: keystrokes 250 ms apart into a quiet terminal. The floor.
- **Loaded**: the same keystrokes while a generator streams output at agent-TUI
  rate. This is the case people actually complain about, so it is part of the
  deliverable rather than future work.

### 4. Statistics

Five runs of 120 samples, first discarded as warm-up. Report p50, p95 and max
per run, and the median of per-run p95 across runs. Record p99 but do not gate
on it: 120 samples cannot support it.

**Do not copy the PDF gate's mistake.** `subsequentPagingP95LatencyMs` computes a
"p95" from six samples, which makes it a maximum, and gates it at a fixed
threshold with under 25% headroom. That gate now fails on unmodified code. Take
enough samples that the percentile means something.

### 5. Record before gating

Land the probe recording only. Set the CI threshold from the measured baseline
after Layer 1 and Layer 2 have landed, and state the tolerance explicitly.
Inventing a threshold first is how a gate ends up either useless or flaky.

## What to measure once it works

In priority order, each currently blocked:

1. Whether the `objectWillChange` forwarding from every ACP conversation and Mesh
   session (`App/AppModel.swift:3512`, `:2987`, `:4092`, `:4285`, `:4845`) is
   worth the narrow-projection refactor across its five consumers. Code reading
   put this at 20-160 whole-shell invalidations a second; it is the largest
   remaining item and the least safe to do blind.
2. Whether the app-side output window still costs anything now that the broker
   coalesces, and whether the leading-edge drain is worth its invariant.
3. Whether the `String(data:)` probe and the 64 KiB per-read zero-fill are
   measurable at all, before anyone writes unsafe code for them.
4. Whether `AppModel.projects` still needs memoizing after the `SessionStrip`
   hoist removed eleven of its twelve calls per render.

## Risks

The fixture drives real input through a real terminal, so it is the most
timing-sensitive harness in the repo. Two specific traps, both already paid for
elsewhere in this codebase:

- A test that asserts a wall-clock bound flakes under machine load. See
  `AccountSignInControllerTests.testCancellingStopsTheShellInsteadOfServingOutTheTimeout`,
  which runs in 0.27 s alone and exceeded a 5 s bound under concurrent builds.
- A harness that leaves work in flight races its own teardown. See the
  `ENOTEMPTY` failure fixed in PR #802 by awaiting `release()`.

Budget for both: no unawaited async work in teardown, and no assertion whose
failure mode is "the machine was busy".
