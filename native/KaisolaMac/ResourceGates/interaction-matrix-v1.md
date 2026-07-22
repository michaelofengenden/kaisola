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
| Cursor resume, truncation, and client replacement | `TerminalDocumentTests`, `AppModelReconnectTests`, and `native-broker-helper-probe.cjs` cover exact suffix resume and N → N+1 → rollback-N clients over one broker/PTY; 2026-07-22 packaged-swap gate ran five Developer ID N⇄N+1 swaps with real looping Claude and Codex CLIs streaming — broker/terminal PIDs, epochs, and offsets held on every leg and both numbered ladders arrived complete | PASS | 2026-07-22: real Sparkle update ran from the published appcast — installed 0.1.88 b101 verified the EdDSA-signed feed, downloaded the notarized v0.1.93 b11001 zip, installed, and relaunched with staple and Gatekeeper intact |
| Observer backpressure | Streaming decoder applies synchronous backpressure; Electron observer tests bound per-observer queues; helper probe uses real node-pty | AUTOMATED PASS | Confirm UI remains responsive under the streaming workload |
| Read-only ownership boundary | Typed Swift API and server allowlist exclude attach/create/write/resize/signal/kill/release; policy tests reject every mutation | AUTOMATED PASS | Confirm no keyboard/composer or ownership diagnostics change while both apps view one PTY |
| Packaged launch and read-only shell | Release preflight executes a side-effect-free launch probe; direct AppKit/accessibility inspection opened the exact universal `LocalRelease` artifact, exposed the named window/list/status/reconnect/sidebar controls, preserved the read-only state, and exercised sidebar hide/show | PASS (notarized + translocated) | 2026-07-22: the published notarized artifact launched quarantined via LaunchServices from an AppTranslocation mount without dialogs; a separate clean-user-account login test remains the only open variant |
| Resize/reflow | Headless SwiftTerm stress resizes 80×24 → 132×40 → 80×24 after scrollback trim and preserves the tail | AUTOMATED PASS | Resize windows while deliberately scrolled up and while following live output |
| Background, wake, and socket republication | `AppModelReconnectTests`, discovery tests, and broker socket-recovery tests cover reconnect without dropping visible scrollback | AUTOMATED PASS | Sleep/wake the packaged app with streaming Claude/Codex sessions |
| Selection and copy | 2026-07-22: the read-only view claims first responder on window entry, and `NativeTerminalInteractionTests` pins the Copy/Select All menu wiring; SwiftTerm's `copy(_:)` writes the general pasteboard directly | LOCAL MANUAL PASS (menu/keyboard path) | Mouse drag selection and large-copy paste into a safe editor on the notarized artifact |
| Search | 2026-07-22: Edit menu carries Find/Find Next/Find Previous/Use Selection with exact `NSFindPanelAction` tags targeting SwiftTerm's find bar; wiring pinned by unit test | LOCAL MANUAL PASS (wiring) | Exercise forward/backward search, no-result state, Unicode, and search while streaming on the notarized artifact |
| Accessibility | 2026-07-22: the terminal is now an AXTextArea element exposing the bounded retained tail as its value (unit-tested); before this it exposed no element at all | MANUAL OPEN | VoiceOver order/value updates, Full Keyboard Access, Reduce Motion, and increased contrast |
| Appearance | 2026-07-22: live system light→dark switch inspected against the sealed artifact while streaming — sidebar, status chrome, and terminal surface all reapplied semantic colors | LOCAL MANUAL PASS | Transparency/contrast, focus state, and inactive windows on the notarized artifact |
| Multiple windows | The Phase 1 native preview is deliberately single-window (no New Window command); broker/cursor identities are window-independent for later phases | NOT A PHASE 1 TARGET | Re-evaluate when the native shell grows multi-window support |
| Keyboard/IME and control mouse modes | Input is intentionally impossible in Phase 1 observe-only UI | DISTRIBUTION OPEN | Validate only when a later control-plane phase deliberately enables input |

The local packaged inspection used a live Electron-owned broker that predates
the terminal-observation capability. The preview correctly stayed offline and
read-only, explained that Electron remained the controller, exposed no
observable sessions, and did not try to replace the broker. That is useful
coexistence evidence, but it cannot substantiate selection, search, live-output
accessibility, or sustained-rendering rows; those remain open above.

A second local packaged inspection (2026-07-21) ran the same sealed artifact
against a live 0.1.86 broker under the development profile: the preview
connected, listed the live session row with its PID, subscribed as a
server-enforced observer, rendered the reattached scrollback, and streamed
live PTY output end to end while a non-owner `terminal.kill` was denied. The
paired idle-workload footprint capture from the same session is recorded in
the Phase 0/1 plan (native 62.1 MiB median versus Electron 197.6 MiB median,
candidate fraction 0.314). Selection, search, VoiceOver, appearance, and
multiple-window rows still require the packaged GUI judgments listed above.

The matrix is not a Phase 1 completion declaration. All `MANUAL OPEN` rows and
the real-update continuity row must be recorded against the exact distribution
artifact before the native preview ships.
