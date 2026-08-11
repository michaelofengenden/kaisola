# Terminal responsiveness for CLI agent sessions

Date: 2026-08-10
Status: approved, ready for planning
Base: `3a5aca1f3` (merge of PR #800)
Branch: `perf/terminal-responsiveness`

## Problem

Kaisola does not feel quick, and it is worst in the surface people use most:
a terminal running a CLI coding agent. Claude Code and Codex emit high-frequency
partial repaints, and every layer of the stack between the PTY and the screen
does redundant work on each of those chunks.

This has been felt for a long time and never diagnosed, because nothing in the
repository measures latency. Nine performance harnesses exist. All of them
measure throughput, cadence, or memory. None of them timestamps a keyboard event
and the frame that answers it.

Three problems are large enough to state without further measurement.

### The output stream is produced twice and one copy has no reader

`terminal.create` binds `sender: owner` (`runtime/node-broker/ipc/terminalCreateRoute.cjs:377`)
and `rec.rendererVisible` defaults to `true`
(`runtime/node-broker/ipc/terminalManager.cjs:714`). Nothing in the Swift app
ever calls `terminal.detachRenderer`; the method exists only in the observer
deny-list at `native/KaisolaMac/Kaisola/Broker/ObserveOnlyBrokerPolicy.swift:25`.

So every 16 ms the broker JSON-encodes each terminal's full output, re-scans the
encoded string to validate its size, and writes it to the control socket. The app
receives it, decodes it, and discards it: `BrokerControlClient.handle` reaches
`case "event": break` at `native/KaisolaMac/Kaisola/Broker/BrokerControlClient.swift:876`.

A full serialize on the broker and a full parse in the app, per terminal, for
nobody.

### The path the app actually reads has no coalescing

The 16 ms and 100 ms flush windows (`terminalManager.cjs:171-172`) apply only to
`rec.pending` → `deliverPrimaryOutput` → `terminal:data:<id>`, which is the dead
path above.

The app consumes `terminal:observer-output`, which is broadcast synchronously
inside the `node-pty` data callback at `terminalManager.cjs:852-855`, once per
raw PTY chunk. An agent TUI produces hundreds of small chunks per second, and
each one costs a JSON encode, a socket write, three full parse passes in Swift,
two actor hops, and three `Task` allocations, before waiting a further 16 ms in
the app's own coalescer at `native/KaisolaMac/Kaisola/App/AppModel.swift:7577`.

### Agent token streaming redraws the whole shell

`AppModel` forwards `objectWillChange` from every ACP conversation and every Mesh
session into its own:

- `native/KaisolaMac/Kaisola/App/AppModel.swift:3512` (ACP conversations)
- `native/KaisolaMac/Kaisola/App/AppModel.swift:2987`, `:4092`, `:4285`, `:4845` (Mesh)
- `native/KaisolaMac/Kaisola/Mesh/MeshSession.swift:1513` (per column into the session)

`AcpConversation` publishes twice per chunk: once for `rows`
(`native/KaisolaMac/Kaisola/Acp/AcpConversation.swift:2216`) and once because the
`rows` `didSet` bumps `contentVersion`, itself `@Published` (`:229-241`). The
flush interval is 50 ms (`:418`), so one streaming agent is 40 invalidations per
second and four Mesh columns is roughly 160.

Each invalidation re-evaluates `RootShellView` (a 5,837-line file observing
`AppModel` via `@EnvironmentObject` at `Features/Sessions/RootShellView.swift:51`)
and `SessionStrip`, whose body reads the uncached `AppModel.projects` twelve
times per pass (`RootShellView.swift:4520-4532`). Each `projects` call builds six
dictionaries and does a `localizedStandardCompare` sort
(`AppModel.swift:595-677`).

## Goals

1. Keystroke-to-glyph latency in a terminal is measured, attributed by stage, and
   defended by CI.
2. A CLI agent streaming output does not redraw unrelated UI.
3. The broker does not serialize output nobody reads.
4. No existing gate regresses: the continuous-scroll receipt (80 Hz floor, 25 ms
   p95), the frame-cadence gate, and the resource gates.

## Non-goals

- The session tick rail (vertical marks per prompt, click to jump). Depends on
  turn boundaries being addressable in the scroll surface. Separate project.
- Inline native scrollback replacing `TerminalTranscriptView`. Depends on the same
  addressability plus solving escape-sequence replay. Separate project.
- Terminal default geometry and margins. Visual polish, not speed.
- The shared atomic writer and shared registry quarantine refactors. Queued
  separately; they change no user-visible behavior.

## Design

Four layers. Layer 0 is the instrument. Layers 1 and 2 are independent of each
other and can be verified separately.

### Layer 0 — Input latency probe

A keystroke fixture built in the same style as the existing continuous-scroll
fixture (`native/KaisolaMac/Kaisola/App/KaisolaMacAppDelegate.swift:2785`), so it
runs under `.github/workflows/native-visual.yml` alongside what is already there.

The fixture types a known character sequence into a terminal running `cat`. `cat`
echoes deterministically with no prompt, no OSC 133 traffic, and no repaints, so
the correlation between a keystroke and its echo is unambiguous.

Four timestamps per keystroke, all on one time base (`NSEvent.timestamp` and
`ProcessInfo.systemUptime` already share it, noted at
`native/KaisolaMac/Kaisola/Features/Sessions/TerminalInputPolicy.swift:478`):

| Stage | Captured at |
|---|---|
| `t0` event | `keyDown` in the terminal surface |
| `t1` write | the broker `terminal.write` call returns |
| `t2` feed | the echoed bytes are handed to `view.feed()` |
| `t3` present | the first display-link callback after that feed |

Reported: p50, p95, p99, and max of `t3 - t0`, plus the three stage deltas. The
stage breakdown is the point. One end-to-end number says it is slow; four say
which fix to make.

Correlation is by content. Each keystroke uses a distinct character from a
non-repeating sequence, so the echo is matched by value rather than by guessing
at ordering.

Keystrokes are spaced 250 ms apart, which is an order of magnitude above the
worst latency this stack could plausibly produce, so no two are ever in flight at
once. That keeps correlation trivial. It also means the probe measures an idle
terminal, which is the floor rather than the felt case: an agent dumping output
while you type is worse and is not covered here. A sustained-load variant is
future work, and the 250 ms figure is the first thing to revisit if the baseline
comes back near it.

Sample count is 120, matching the continuous-scroll fixture, giving a defensible
p95 and a weak p99. The p99 is recorded but not used for gating.

The probe records only. It does not gate. Thresholds are set from the baseline
after Layer 1 and Layer 2 land, so we do not invent a number we cannot justify.

### Layer 1 — Byte pipeline

#### 1.1 Delete the duplicate primary stream

Stop producing output nobody reads. Two options were considered:

- **(a)** Do not bind `sender` on `terminal.create` when the creating client is
  observer-capable, so the stream is never produced.
- **(b)** Have the app call `terminal.detachRenderer` after it subscribes.

**Chosen: (a).** Not producing beats producing and detaching, and (b) leaves a
window between create and detach where the duplicate still flows. (b) remains the
fallback if (a) turns out to break the Companion or Mesh paths, which also create
terminals.

Acceptance: with a terminal created and streaming, zero `terminal:data:<id>`
frames are written when no renderer is attached.

#### 1.2 Coalesce observer output, and stop stacking two windows

Give `terminal:observer-output` the same coalescing the dead path had: 16 ms
focused, 100 ms blurred, with the existing 64 KiB `FLUSH_CAP` so bursts bypass
the timer.

Then remove the app-side 16 ms sleep at `AppModel.swift:7577-7593`. Coalescing in
both places costs up to two frames of latency and buys nothing. One coalescer, at
the broker, where it also removes the socket writes and the per-frame parse cost
rather than merely deferring them.

Constraint: `TerminalOutputBatch.merge` requires exact offset contiguity
(`native/KaisolaMac/Kaisola/Features/Sessions/TerminalDocument.swift:60`). The
coalescer must preserve byte order and produce contiguous offsets, or the app
silently drops batches. This is the one place in Layer 1 where a mistake is
invisible rather than loud, so it gets a dedicated property test.

#### 1.3 Fast-path the UTF-8 repair

`runtime/node-broker/companion/terminalCursor.cjs:158-170` rebuilds every chunk
one UTF-16 code unit at a time with `repaired += value[index]`, then encodes it,
and the caller decodes it again at `:332`. This runs on valid input, which is
almost all input.

Replace with an early-exit scan: if the string contains no lone surrogate, return
it unchanged. Take the rebuild path only when a repair is actually needed.

#### 1.4 Stop re-parsing frames we just serialized

`runtime/node-broker/ipc/brokerWire.cjs:232-236` calls `JSON.stringify`, then
`inspectBrokerFrame` (`:132-212`) walks the produced string character by character
in JS to validate its size, then `Buffer.byteLength` walks it again, then
`socket.write` encodes it.

The payload size is known before serializing. Validate the input frame, not the
output string. Inbound validation stays as-is: that input is untrusted and the
scan is the security boundary.

#### 1.5 Stop the redundant Swift-side passes

Per inbound frame today:

- `KaisolaCore/Sources/KaisolaBrokerProtocol/BrokerWire.swift:351` allocates and
  discards a full `String` copy purely to test UTF-8 validity
- `BrokerEnvelopeScanner.scan` (`:175-222`) walks the same bytes again
- a freshly allocated `JSONDecoder` (`ObserveOnlyBrokerClient.swift:606`) walks
  them a third time

Drop the String-validity probe, since `JSONDecoder` rejects invalid UTF-8 anyway.
Hold one `JSONDecoder` per client rather than allocating per frame.

Separately, `UnixBrokerTransport.swift:91-105` allocates a zero-filled 64 KiB
buffer per `read(2)` and then copies out of it. Use one reusable buffer per
connection.

#### 1.6 Collapse an actor hop

An event crosses three isolation boundaries with a `Task` allocation at each:
`ObserveOnlyBrokerClient` actor → `BrokerGenerationObserverRouter` actor
(`native/KaisolaMac/Kaisola/Broker/BrokerGenerationRouting.swift:222`) → MainActor
(`AppModel.swift:7284`).

The router hop is the removable one: forward inline when the generation matches,
which is the steady-state case. The MainActor hop stays; it is required.

#### 1.7 Stop the per-frame accessibility allocation

`native/KaisolaMac/Kaisola/Features/Sessions/NativeTerminalCoordinator.swift:266`
calls `updateAccessibilityValue(from: scrollback)` unconditionally, before every
early return including the no-op at `:309-311`. It builds an 8,000-character tail
(`TerminalDocument.swift:146-156`) via `suffix` plus `reversed().map(String.init).joined()`,
whether or not VoiceOver is running.

Move it after the early returns and gate it on VoiceOver being enabled. The
existing downstream check in `TerminalAccessibilityAdapter.swift:107-110` proves
the signal is available; it is just consulted too late.

#### 1.8 Smaller items

- `AppModel.swift:8039-8055` creates and cancels a `Task` per output batch for a
  250 ms debounce. At 60 Hz that is 60 create/cancel pairs a second, one of which
  ever writes. Use a deadline, not a task.
- `NativeTerminalSurface.swift:270` resolves the font on every `updateNSView`,
  hitting `NSFontManager` for non-system families. Cache by family and size.
- `NativeTerminalSurface.swift:1248-1252` runs `updateSemanticDecorations()`
  twice per feed. Once.
- `terminalManager.cjs:850` `splitUtf8` does a `Buffer.from` then `toString` round
  trip for chunks that are a single piece under the 64 KiB cap, which is nearly
  all of them. Return the input when it does not need splitting.
- `terminalManager.cjs:863` `armAgentQuiet()` clears and re-arms a 4,500 ms
  timeout per chunk. Re-arm only when the remaining time has fallen below half
  the window, so a busy agent arms roughly every 2,250 ms instead of per chunk.
  The observable contract is unchanged: quiet is still declared no earlier than
  4,500 ms after the last output.

### Layer 2 — SwiftUI invalidation

#### 2.1 Cut the objectWillChange forwarding

Remove the five forwards listed under Problem. Views that need a conversation's
updates observe that conversation directly.

This is not a new pattern for this codebase. Terminal output already works this
way: `publishTerminalSurfaceDocument` (`AppModel.swift:5249`) writes a plain
dictionary and calls `feed.replace(...)` on a separate `TerminalSurfaceFeed`
object (`TerminalDocument.swift:429`), and `TerminalSurfaceFeedView`
(`NativeTerminalSurface.swift:46-61`) is the isolation boundary that keeps the
rest of the IDE out of it. Terminal bytes at 60 Hz already do not redraw the
shell. ACP bytes at 40 Hz do. Layer 2.1 makes the second match the first.

Removed one forward at a time, each with a visual fixture, because the failure
mode is a view quietly not updating and no unit test catches that.

#### 2.2 Memoize `projects`

`AppModel.projects` (`AppModel.swift:595-677`) builds six dictionaries, runs three
`filter().count` passes, unions a `Set` over all surface IDs, filters
`attentionCenter.entries`, and sorts. It is called twelve times per `SessionStrip`
body pass because `SessionStrip.project` is an uncached computed property read
transitively by `sessions`, `chats`, `meshes`, and `recentlyClosed`
(`RootShellView.swift:4520-4532`). Roughly sixteen more calls exist elsewhere.

Two steps, in order:

1. Hoist to a single `let projects = model.projects` in `SessionStrip.body` and
   pass it down. Removes eleven of the twelve, and is a local change with no
   invalidation risk.
2. Cache the result behind a token bumped by the writes that affect it: sessions,
   chats, meshes, pins, order, attention entries.

Step 1 alone may be enough. We measure after it before doing step 2.

#### 2.3 Guard the unguarded publishes

- `applyActivity` (`AppModel.swift:7908-7931`) writes `sessions[index].agentActivity`
  with no equality check, so every busy/idle flap republishes the array.
- `metaByTerminalID` (`:6855`) is reassigned every 5 seconds regardless of change.
- `branchesByCwd` (`:6893`) every 10 seconds, same.

Add `if new != old` before assigning. The inventory path already does exactly this
at `:6719`, so this applies an existing pattern rather than introducing one.

#### 2.4 Narrow the over-observers

- `TerminalTranscriptView` (`Features/Sessions/TerminalTranscriptView.swift:11`)
  declares `@ObservedObject var model: AppModel` and reads no `@Published` property
  in `body`; its three uses are inside `async` closures. A plain `let` is
  functionally identical and stops unrelated model changes from re-resolving a
  font and re-laying out a `ForEach` over 512 KiB pages.
- `AcpComposerView` (`Acp/AcpComposerView.swift:25`) observes all of `AppModel` to
  answer one lookup at `:496`. It is mounted per chat card, so the instance count
  scales with open chats. Pass the value in.

#### 2.5 Drop the second publish per chunk

`AcpConversation.rows`'s `didSet` (`Acp/AcpConversation.swift:229-241`) bumps
`contentVersion`, which is itself `@Published`, so every chunk publishes twice.
The same `didSet` runs `rows.filter(\.isDurable)` over the entire transcript, 20
times a second, to feed `enqueueTranscriptSave` (wired at `AppModel.swift:3428`).

`contentVersion` is derived, so it does not need to be `@Published`. The durable
filter moves behind the save debounce rather than running per chunk.

Also: `.toolCallUpdate` (`AcpConversation.swift:2021-2031`) writes `rows[index]`
directly, bypassing the 50 ms coalescer, so a tool streaming output publishes at
raw event rate. Route it through the coalescer.

## Data flow after the change

```
node-pty onData
  └─ spool.push (unchanged, disk, 750 ms debounce)
  └─ UTF-8 fast path (1.3)
  └─ observer coalescer, 16 ms focused / 100 ms blurred, 64 KiB cap  (1.2)
       └─ one JSON frame per window, size-validated from the input   (1.4)
            └─ unix socket
                 └─ reusable read buffer, one JSONDecoder            (1.5)
                      └─ ObserveOnly actor ─inline→ MainActor        (1.6)
                           └─ TerminalOutputBatch, drained same turn (1.2)
                                └─ TerminalSurfaceFeed.replace
                                     └─ SwiftTerm feed → present
```

`terminal:data:<id>` is not produced (1.1). Nothing observing `AppModel` is
invalidated by any of this, which is already true today for terminal bytes and
becomes true for ACP bytes under 2.1.

## Testing

**Acceptance.** The Layer 0 probe. Baseline recorded before any change, then after
Layer 1, then after Layer 2. Every claim in this document is checked against it.

**Regression.** The existing gates must hold: continuous-scroll receipt at the
80 Hz floor and 25 ms p95 (`KaisolaMacAppDelegate.swift:652`, `:658`, `:670`),
the frame-cadence gate (`scripts/native-frame-cadence-gate.cjs:66-71`), the
broker-free fixture gate at 512 MiB p95
(`scripts/native-resource-fixture-gate.cjs:226`).

**Per-item.**

| Item | Test |
|---|---|
| 1.1 | No `terminal:data:<id>` frames written when no renderer is attached |
| 1.2 | Property test: for random chunk sequences, the coalesced stream is byte-identical and offsets are contiguous |
| 1.3 | Property test: fast path output equals slow path output for valid UTF-8, including astral-plane characters; lone surrogates still repair |
| 1.4 | A frame exceeding its method cap is still rejected, from the input side |
| 1.5 | Malformed UTF-8 and malformed JSON are still rejected |
| 1.7 | Accessibility value still updates when VoiceOver is on; is not built when it is off |
| 2.1 | One visual fixture per removed forward, proving the view still updates |
| 2.3 | Assignment is skipped when the value is unchanged |

**Not covered.** Mixed-version broker compatibility has no automated test today
and this design does not add one. It is handled by sequencing instead: see below.

## Risk

The two wire-behavior changes are 1.1 and 1.2. Every push ships a release
(`v*` tag on merge to main), so an app talking to a broker from a different
version is a real situation, and a broker compatibility mismatch is what broke
terminals in 0.1.114.

Mitigations:

- Both land behind the existing broker generation handshake.
- Both land after the mechanical items, so a bisect during Layer 1 has fewer
  candidates.
- Each item in this spec is independently revertable. None depends on another
  within its layer.

Layer 1 and Layer 2 both touch `AppModel.swift`, so they are not file-disjoint:
Layer 1 edits the coalescer at `:7577`, the router hop at `:7284`, and cursor
persistence at `:8039`; Layer 2 edits the forwards at `:3512`, `projects` at
`:595`, and the guards at `:6855`, `:6893`, `:7908`. The regions do not overlap,
but they will conflict if the layers are developed on separate branches in
parallel. Develop them in sequence on one branch.

## Sequence

0. **Dependency, outside this spec.** Ship the 0.1.114 terminal hotfix currently
   uncommitted on `codex/fix-terminal-legacy-attach-0114`. Broken beats slow.
1. Layer 0 probe, baseline recorded.
2. 1.1 duplicate stream.
3. 1.5, 1.7, 1.8, 1.3, 1.4 mechanical waste.
4. 1.2 coalescing, and removal of the stacked app-side window.
5. 1.6 actor hop.
6. 2.3, 2.2 step 1, 2.4 cheap SwiftUI wins.
7. 2.1, 2.5, 2.2 step 2 if still needed.
8. Re-measure. Set the CI latency threshold from the new baseline.

## Open items

None blocking. Two decisions deferred to implementation on purpose:

- Whether 2.2 needs the caching step, decided by measurement after the hoist.
- Whether 1.1 uses option (a) or falls back to (b), decided by whether Companion
  and Mesh terminal creation tolerate the unbound sender.
