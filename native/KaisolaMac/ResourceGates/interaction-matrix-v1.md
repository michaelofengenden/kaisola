# Native terminal interaction matrix v1

Status is deliberately evidence-scoped:

- `AUTOMATED PASS` means a repeatable repository test currently covers the
  claim without a human GUI judgment.
- `LOCAL MANUAL PASS` means the named interaction was inspected against the
  exact sealed `LocalRelease` artifact; it is intentionally narrower than a
  Developer ID/notarized distribution result.
- `MANUAL OPEN` means the implementation exists but a packaged GUI inspection
  is still required.
- `DISTRIBUTION OPEN` requires a Developer ID/notarized update artifact or real
  provider process and cannot be inferred from a local build.

| Area | Automated evidence | Current status | Required packaged check |
|---|---|---|---|
| 56 MiB legal framing and bounded decoder memory | `BrokerWireTests` covers the cap, split/coalesced frames, >56 MiB batches of small frames, malformed UTF-8, partial frames, and synchronous backpressure | AUTOMATED PASS | None beyond release regression run |
| At least 8 MiB retained terminal output | `TerminalDocumentTests.testRetainedOutputStaysBoundedAtAUnicodeBoundary` constructs the boundary and preserves the exact byte cursor | AUTOMATED PASS | Inspect truncation marker wording in the packaged UI |
| Sustained output and large scrollback | `SwiftTermStressTests` streams 8,192 Unicode lines through a capped scrollback and proves trimming | AUTOMATED PASS | Run the streaming workload for 15 minutes and inspect frame pacing/energy |
| ANSI/application modes | `SwiftTermStressTests` toggles alternate screen, application cursor, bracketed paste, and mouse tracking | AUTOMATED PASS | Inspect colors, inverse/bold/dim, progress output, and full-screen CLI rendering |
| Split UTF-8 and wide characters | Broker decoder tests and `SwiftTermStressTests` split a four-byte scalar, then verify terminal width across CJK/emoji and resize | AUTOMATED PASS | Inspect combining marks, emoji sequences, CJK, RTL samples, and font fallback |
| Cursor resume, truncation, and client replacement | `TerminalDocumentTests`, `AppModelReconnectTests`, and `native-broker-helper-probe.cjs` cover exact suffix resume and N → N+1 → rollback-N clients over one broker/PTY | AUTOMATED PASS | Real Sparkle update with real Claude and Codex remains distribution-open |
| Observer backpressure | Streaming decoder applies synchronous backpressure; Electron observer tests bound per-observer queues; helper probe uses real node-pty | AUTOMATED PASS | Confirm UI remains responsive under the streaming workload |
| Read-only ownership boundary | Typed Swift API and server allowlist exclude attach/create/write/resize/signal/kill/release; policy tests reject every mutation | AUTOMATED PASS | Confirm no keyboard/composer or ownership diagnostics change while both apps view one PTY |
| Packaged launch and read-only shell | Release preflight executes a side-effect-free launch probe; direct AppKit/accessibility inspection opened the exact universal `LocalRelease` artifact, exposed the named window/list/status/reconnect/sidebar controls, preserved the read-only state, and exercised sidebar hide/show | LOCAL MANUAL PASS | Repeat from the Developer ID/notarized, translocated artifact on a clean user account |
| Resize/reflow | Headless SwiftTerm stress resizes 80×24 → 132×40 → 80×24 after scrollback trim and preserves the tail | AUTOMATED PASS | Resize windows while deliberately scrolled up and while following live output |
| Background, wake, and socket republication | `AppModelReconnectTests`, discovery tests, and broker socket-recovery tests cover reconnect without dropping visible scrollback | AUTOMATED PASS | Sleep/wake the packaged app with streaming Claude/Codex sessions |
| Selection and copy | SwiftTerm native selection remains enabled; terminal input/reporting is overridden | MANUAL OPEN | Keyboard and mouse selection, multiline copy, Unicode copy, and large-copy paste into a safe editor |
| Search | SwiftTerm Command-F remains available in the native view | MANUAL OPEN | Forward/backward search, no-result state, Unicode, and search while streaming |
| Accessibility | Terminal has a read-only accessibility label and native AppKit/SwiftUI controls | MANUAL OPEN | VoiceOver order/value updates, Full Keyboard Access, Reduce Motion, and increased contrast |
| Appearance | Native semantic colors are reapplied by the terminal surface | MANUAL OPEN | Light/dark/live switch, transparency/contrast, focus state, and inactive windows |
| Multiple windows | Broker/cursor identities are window-independent | MANUAL OPEN | Three restored windows, independent selection/search, reconnect, and close/reopen |
| Keyboard/IME and control mouse modes | Input is intentionally impossible in Phase 1 observe-only UI | DISTRIBUTION OPEN | Validate only when a later control-plane phase deliberately enables input |

The local packaged inspection used a live Electron-owned broker that predates
the terminal-observation capability. The preview correctly stayed offline and
read-only, explained that Electron remained the controller, exposed no
observable sessions, and did not try to replace the broker. That is useful
coexistence evidence, but it cannot substantiate selection, search, live-output
accessibility, or sustained-rendering rows; those remain open above.

The matrix is not a Phase 1 completion declaration. All `MANUAL OPEN` rows and
the real-update continuity row must be recorded against the exact distribution
artifact before the native preview ships.
