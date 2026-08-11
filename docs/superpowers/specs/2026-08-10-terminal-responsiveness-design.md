# Terminal responsiveness for CLI agent sessions

Date: 2026-08-10
Status: revised after Codex plan-review, ready for user review
Base: `3a5aca1f3` (merge of PR #800, tagged `v0.1.114`)
Branch: `perf/terminal-responsiveness`

## Problem

Kaisola does not feel quick, and it is worst in the surface people use most:
a terminal running a CLI coding agent. Claude Code and Codex emit high-frequency
partial repaints, and every layer between the PTY and the screen does redundant
work on each chunk.

This has been felt for a long time and never diagnosed, because nothing in the
repository measures latency. Nine performance harnesses exist. All measure
throughput, cadence, or memory. None timestamps a keyboard event and the frame
that answers it.

### The output stream is produced twice and one copy has no reader

`terminal.create` calls `manager.setSender(id, owner)`
(`runtime/node-broker/ipc/terminalCreateRoute.cjs:389`), which sets
`rendererVisible = true` (`runtime/node-broker/ipc/terminalManager.cjs:991`).
Every attach does the same (`terminalCreateRoute.cjs:288-323`). Nothing ever
calls `terminal.detachRenderer`; the app's only reference to it is the observer
deny-list at `native/KaisolaMac/Kaisola/Broker/ObserveOnlyBrokerPolicy.swift:25`.

So the broker accumulates and delivers `terminal:data:<id>` for every visible
terminal this controller owns, and the app discards all of it at
`native/KaisolaMac/Kaisola/Broker/BrokerControlClient.swift:873`, whose own
comment says the controller connection carries no streams.

Scope, stated precisely: this affects every visible terminal owned by the
connected controller, until primary delivery is paused or the owner detaches. It
is not literally every terminal in every state.

### The path the app actually reads has no coalescing

The 16 ms and 100 ms flush windows (`terminalManager.cjs:171-172`) gate only
`rec.pending` → `deliverPrimaryOutput`, which is the discarded path above.

The app consumes `terminal:observer-output`, broadcast synchronously inside the
`node-pty` data callback at `terminalManager.cjs:852-855`, once per piece
returned by `splitUtf8` per raw chunk. Each broadcast costs a JSON encode, a
socket write, three parse passes in Swift, two actor hops, and three `Task`
allocations, before waiting a further 16 ms in the app's coalescer at
`native/KaisolaMac/Kaisola/App/AppModel.swift:7577`.

The consumed path therefore has exactly one coalescing stage today, in the app.
This design adds one at the broker and removes the app's, rather than moving an
existing one.

### Agent token streaming redraws the whole shell

`AppModel` forwards `objectWillChange` from every ACP conversation and Mesh
session into its own: `AppModel.swift:3512` for conversations, `:2987`, `:4092`,
`:4285`, `:4845` for Mesh, and `Mesh/MeshSession.swift:1513` per column.

`AcpConversation` publishes twice per chunk, once for `rows`
(`Acp/AcpConversation.swift:2216`) and once because the `rows` `didSet` bumps
`contentVersion`, itself `@Published` (`:229-241`). At the 50 ms flush interval
(`:418`) one streaming agent is 40 invalidations a second and four Mesh columns
is roughly 160.

Each invalidation re-evaluates `RootShellView` (`Features/Sessions/RootShellView.swift:51`)
and `SessionStrip`, whose body reads the uncached `AppModel.projects` twelve times
(`RootShellView.swift:4520-4532`), each call building six dictionaries and a sort
(`AppModel.swift:595-677`).

## Goals

1. Keystroke-to-glyph latency in a terminal is measured, attributed by stage, and
   defended by CI.
2. A CLI agent streaming output does not redraw unrelated UI.
3. The broker does not serialize output nobody reads.
4. No existing gate regresses: the continuous-scroll receipt (80 Hz floor, 25 ms
   p95), the frame-cadence gate, the resource gates.

## Non-goals

- The session tick rail and inline native scrollback. Both need turn boundaries
  addressable in the scroll surface. Separate projects.
- Terminal default geometry and margins. Polish, not speed.
- The shared atomic writer and registry quarantine refactors. Queued separately.

## Design

Three layers. Layer 0 is the instrument. Layer 1 is the broker and transport.
Layer 2 is SwiftUI invalidation.

### Layer 0 — Input latency probe

A keystroke fixture in the style of the continuous-scroll fixture
(`App/KaisolaMacAppDelegate.swift:2785`), running under
`.github/workflows/native-visual.yml`.

**The responder.** Not `cat`. A PTY in default mode echoes through the line
discipline *and* through `cat`, so every keystroke produces two glyphs and the
correlation is ambiguous. The fixture runs `stty -echo` first and uses a small
responder that emits one known byte per input byte. Deterministic, single echo,
no prompt, no OSC 133, no repaints.

**Timestamps.** All on one time base; `NSEvent.timestamp` and
`ProcessInfo.systemUptime` already share it (`Features/Sessions/TerminalInputPolicy.swift:478`).

| Stage | Captured at |
|---|---|
| `t0` event | `keyDown` in the terminal surface |
| `t1` send | immediately **before** the broker write is issued |
| `t2` feed | echoed bytes handed to `view.feed()` |
| `t3` opportunity | first display-link callback after that feed |

`t1` is taken before the send, not when the write RPC returns. The write response
and the observer output travel different sockets, so the echo can arrive before
the RPC resolves and a post-return `t1` yields negative stage times.

**What `t3` is and is not.** It is the first display opportunity after the feed,
not proof that the glyph reached the panel. Real presentation would need
`CADisplayLink` plus a surface-present callback the app does not currently have.
`t3` is reported as *display opportunity*, and the spec does not claim otherwise.
It is stable enough to detect regressions, which is what it is for.

**Two workloads, both required.**

- *Idle*: keystrokes 250 ms apart into a quiet terminal. Establishes the floor.
- *Loaded*: the same keystrokes while a generator streams output at a rate
  matched to an agent TUI. This is the case people actually complain about, so it
  is part of the deliverable rather than future work.

**Statistics.** Five runs of 120 samples each, with the first run discarded as
warm-up. p50 and p95 are reported per run and aggregated across runs; p99 is
recorded but explicitly not used for gating, since 120 samples cannot support it.
CI gates on the median of per-run p95 with a stated tolerance, set from baseline.

The probe records only until Layers 1 and 2 land. Thresholds come from the
measured baseline, not from a guess.

### Layer 1 — Broker and transport

#### 1.1 Separate ownership, detachment, and primary-stream enablement

**This is a prerequisite, not an optimization.** Today one pair of fields carries
three meanings:

- `rec.sender` is *authorization*. Access checks compare the request owner
  against it (`runtime/node-broker/session-broker.cjs:348-371`), inventory filters
  records without an owner, and Swift rejects inventory rows lacking an
  owner-derived project identity (`Broker/BrokerModels.swift:246-255`).
- `rec.rendererVisible` is *detachment accounting*. It gates `detachedBytes`,
  sets `exitedWhileDetached` on exit, and is reset by attach
  (`terminalManager.cjs:829-1016`).
- Between them they also mean *the primary stream is on*.

Unbinding `sender` to silence the stream, which is what the previous draft
proposed, makes terminals fail authorization and disappear from inventory.
Repurposing `rendererVisible = false` corrupts detach accounting: visible output
counts as detached and a visible exit reports `exitedWhileDetached`.

The fix is a third field, `primaryStreamEnabled`, defaulting to true. `sender` and
`rendererVisible` keep their current meanings untouched. `deliverPrimaryOutput`
and the `rec.pending` accumulation additionally require `primaryStreamEnabled`.

#### 1.2 Negotiate observer-only output

A client that reads the observer stream declares it, and the broker stops
producing the primary copy for terminals that client owns.

This is a negotiated feature, not silent suppression. `brokerWire.cjs:22-49` has
no feature flag for it and the generation handshake
(`Broker/BrokerControlClient.swift:275-289`) does not negotiate behavior, so an
older primary-only client against a newer broker that silently stopped sending
`terminal:data` would get a blank terminal. The feature is advertised in the
handshake and requested per terminal on create and attach, so an old client never
triggers it.

`primaryStreamEnabled` is set from that request, and because it is set on both
create and attach, it survives reconnect, input recovery, and startup restore.
The previous draft's acceptance test covered only create and would have missed
every reattach path.

`terminal:data:<id>` remains a supported contract. Existing tests that assert on
it (`tests/node/terminalManager.test.cjs:467-553`,
`tests/node/brokerUpgradeIntegration.test.cjs:678`) keep passing by not requesting
the feature.

#### 1.3 Coalesce observer output

Give observers their own buffer and timer. **Not `rec.pending`.** `setSender` and
`detachRenderer` both clear `rec.flushTimer` and `rec.pending`
(`terminalManager.cjs:980-1008`) with a comment explaining the discard is safe
because the reattaching renderer replays the snapshot. That reasoning does not
hold for observers: the cursor has already advanced
(`ipc/terminalCursor.cjs:323-335`), so discarded observer bytes are lost with no
discontinuity surfaced to any client. A control-socket disconnect can detach the
renderer while independent app and Companion observer sockets stay live, so this
is reachable, not theoretical.

**Mandatory synchronous flush** of the observer buffer before each of: observer
exit, snapshot-required and gap boundaries, release and record deletion, stream
epoch change, activity events, and controller attach or detach. The exit path
already does exactly this for the primary buffer at `terminalManager.cjs:867`,
with the comment "the tail of the stream must land before the exit signal". The
observer path needs the same treatment or the exit event overtakes the terminal's
final output. This is data loss, and it is the single most dangerous thing in
this design.

**Focus.** The 100 ms blurred window stays out of the broker. `terminal.setFocused`
is a global per-record flag with no production wiring, and moving the blurred
delay broker-side would make Companion output inherit the desktop app's focus
state while someone is driving the terminal from their phone. Focus-aware
throttling, if wanted later, belongs per subscriber. For now: one 16 ms window,
applied uniformly.

**Overflow.** Larger coalesced frames raise the odds of hitting the observer queue
cap, which forces one `terminal:observer-snapshot-required` and then pauses the
subscriber until it resubscribes, deleting it if the marker itself fails
(`ipc/terminalObservers.cjs:50-81`). Queue acceptance uses encoded frame size plus
`socket.writableLength`, not payload length, and JSON escaping expands ESC-dense
agent output several times over. The coalescer therefore caps on *encoded*
estimated size, not accumulated payload bytes, and the cap is set below the
default 256 KiB queue budget.

**Then remove the app-side window** at `AppModel.swift:7577-7593`, draining on the
same runloop turn instead. Note the app batcher is not pure overhead: it merges
contiguous offsets and triggers gap recovery on discontinuity
(`AppModel.swift:7537-7593`, recovery at `:7621-7643`). That merge and recovery
logic stays; only the 16 ms sleep goes. A coalescer bug surfaces as gap recovery,
which is visible and loud, not as silently dropped output.

#### 1.4 Fast-path the UTF-8 repair

`runtime/node-broker/companion/terminalCursor.cjs:158-170` rebuilds every chunk
one UTF-16 code unit at a time with `repaired += value[index]`, then encodes, and
the caller decodes again at `:332`. This runs on valid input, which is nearly all
input.

Early-exit scan: if the string contains no lone surrogate, return it unchanged.
Take the rebuild path only when a repair is needed.

#### 1.5 Replace the JS frame re-scan with a native size check

`runtime/node-broker/ipc/brokerWire.cjs:232-236` calls `JSON.stringify`, then
`inspectBrokerFrame` (`:132-212`) walks the produced string character by character
in JS to validate size.

The size cannot be derived from the pre-JSON payload: escaping, envelopes, and
channel names all change the encoded length, and queue enforcement uses encoded
bytes (`brokerWire.cjs:258-267`). The previous draft proposed validating from the
input and was wrong.

The fix is narrower. `Buffer.byteLength(encoded)` is native and already computed
at `:221`; the JS character walk is what costs. Enforce the cap from the native
byte length and keep the structural inspection only where it guards untrusted
inbound frames. Outbound frames the broker just built are not untrusted.

#### 1.6 Reduce Swift-side passes and allocations

Per inbound frame today: `KaisolaCore/Sources/KaisolaBrokerProtocol/BrokerWire.swift:351`
allocates and discards a full `String` copy to test UTF-8 validity,
`BrokerEnvelopeScanner.scan` (`:175-222`) walks the same bytes again, and a
freshly allocated `JSONDecoder` (`Broker/ObserveOnlyBrokerClient.swift:606`) walks
them a third time.

Drop the String probe, since `JSONDecoder` rejects invalid UTF-8 anyway. Hold one
`JSONDecoder` per client. And `Broker/UnixBrokerTransport.swift:91-105` allocates
a zero-filled 64 KiB buffer per `read(2)`; use one reusable buffer per connection.

#### 1.7 Stop the per-frame accessibility allocation

`Features/Sessions/NativeTerminalCoordinator.swift:266` calls
`updateAccessibilityValue(from:)` unconditionally before every early return
including the no-op at `:309-311`, building an 8,000-character tail
(`Features/Sessions/TerminalDocument.swift:146-156`) regardless of whether
VoiceOver is running.

Move it after the early returns and gate it on VoiceOver being enabled. Because
VoiceOver can be switched on at any time, enabling it must repopulate the value
from the current scrollback rather than waiting for the next output, or a user
turning it on mid-session hears stale text. The existing gate at
`Features/Sessions/TerminalAccessibilityAdapter.swift:107-112` is the model.

#### 1.8 Smaller items

- `AppModel.swift:8039-8055` creates and cancels a `Task` per output batch for a
  250 ms debounce. Use a deadline.
- `Features/Sessions/NativeTerminalSurface.swift:270` resolves the font on every
  `updateNSView`. Cache by family and size.
- `NativeTerminalSurface.swift:1248-1252` runs `updateSemanticDecorations()`
  twice per feed. Once.
- `terminalManager.cjs:850` `splitUtf8` does a `Buffer.from` then `toString` round
  trip for chunks that are a single piece under the 64 KiB cap. Return the input
  when no split is needed.

`armAgentQuiet` timer churn is **dropped from this design.** Re-arming on a
coarser schedule would declare quiet earlier than 4,500 ms after the last output,
which is a real behavior change to agent turn detection, and the previous draft's
claim that the contract was unchanged was wrong. The saving does not justify it.

#### 1.9 Actor hop — investigate, do not assume

The previous draft proposed forwarding inline through
`Broker/BrokerGenerationRouting.swift:222` to remove one hop. That router owns
mutable state and is entered via `Task` for isolation
(`BrokerGenerationRouting.swift:167-176`, `:405-408`), so "forward inline" is a
synchronization redesign, not a deletion.

This is demoted to an investigation item, scheduled after the probe exists so we
can see whether the hop is worth the redesign. If the measured cost is small, it
is dropped.

### Layer 2 — SwiftUI invalidation

#### 2.1 Publish narrow projections, then cut the forwarding

The forwarding cannot simply be deleted. Three consumers read nested conversation
state *through* `AppModel`:

- `SessionStrip` observes only `AppModel` but reads conversation title, running
  state, usage, and Mesh state (`RootShellView.swift:4510-4617`).
- The Companion projection subscribes to `AppModel.objectWillChange` to rebuild
  what the phone shows (`App/KaisolaMacAppDelegate.swift:2056-2090`).
- Mesh overview and permission state depend on the same nesting
  (`Mesh/MeshSession.swift:1513-1515`, `Mesh/MeshView.swift:615-683`).

Order, and it matters:

1. Add narrow `@Published` projections on `AppModel` for what those three
   actually read: per-chat title, running state, and usage totals. These update
   on change, not per token.
2. Repoint `SessionStrip`, the Companion projection, and Mesh overview at the
   projections.
3. Only then remove the five forwards, one at a time, each with a visual fixture.

Step 3 before steps 1 and 2 breaks Mesh state and the phone's view of a session,
and neither failure shows up in a unit test.

The end state matches what terminals already do: `publishTerminalSurfaceDocument`
(`AppModel.swift:5249`) writes a plain dictionary and calls `feed.replace(...)` on
a separate `TerminalSurfaceFeed` (`TerminalDocument.swift:429`), isolated by
`TerminalSurfaceFeedView` (`NativeTerminalSurface.swift:46-61`). Terminal bytes at
60 Hz already do not redraw the shell. ACP bytes at 40 Hz do.

#### 2.2 Memoize `projects`

Two steps, measured between them.

1. Hoist to one `let projects = model.projects` in `SessionStrip.body` and pass it
   down. Removes eleven of twelve calls, with no invalidation risk.
2. If still needed, cache behind an invalidation token. The token must cover
   everything `projects` reads (`AppModel.swift:595-677`): sessions, chats,
   meshes, pins, session order, attention entries, **persisted project metadata,
   persisted owned sessions, recently-closed panes, and session-store closure
   state.** The previous draft's list omitted the last four, which would have
   produced a cache that goes stale on project rename and on session close.

#### 2.3 Guard the unguarded publishes

- `applyActivity` (`AppModel.swift:7908-7931`) writes `sessions[index].agentActivity`
  with no equality check, republishing the array on every busy/idle flap.
- `metaByTerminalID` (`:6855`) reassigned every 5 s regardless of change.
- `branchesByCwd` (`:6893`) every 10 s, same.

Add `if new != old`. The inventory path already does this at `:6719`.

#### 2.4 Narrow the over-observers

- `Features/Sessions/TerminalTranscriptView.swift:11` declares
  `@ObservedObject var model: AppModel` and reads no `@Published` in `body`; its
  three uses are inside `async` closures. A plain `let` is equivalent.
- `Acp/AcpComposerView.swift:25` observes all of `AppModel` for one lookup at
  `:496`, and is mounted per chat card. Pass the value in.

#### 2.5 Drop the second publish per chunk

`AcpConversation.rows`'s `didSet` (`Acp/AcpConversation.swift:229-241`) bumps
`contentVersion`, itself `@Published`, so every chunk publishes twice, and runs
`rows.filter(\.isDurable)` over the whole transcript 20 times a second to feed
`enqueueTranscriptSave` (`AppModel.swift:3428`).

`contentVersion` is derived and does not need to be `@Published`. The durable
filter moves behind the save debounce.

`.toolCallUpdate` (`AcpConversation.swift:2021-2031`) writes `rows[index]`
directly, bypassing the 50 ms coalescer, so a tool streaming output publishes at
raw event rate. Route it through the coalescer.

## Testing

**Acceptance.** The Layer 0 probe, idle and loaded, baselined before any change
and re-measured after each layer.

**Regression.** Continuous-scroll receipt at the 80 Hz floor and 25 ms p95
(`KaisolaMacAppDelegate.swift:652`, `:658`, `:670`), the frame-cadence gate
(`scripts/native-frame-cadence-gate.cjs:66-71`), the broker-free fixture gate at
512 MiB p95 (`scripts/native-resource-fixture-gate.cjs:226`).

**Protocol and lifecycle.**

| Area | Test |
|---|---|
| 1.2 | Feature not requested: `terminal:data:<id>` still delivered, existing broker tests pass unchanged |
| 1.2 | Feature requested: no `terminal:data:<id>` after create, **and after reconnect attach, input-recovery attach, and startup restore** |
| 1.2 | Old app against new broker, and new app against old broker, both render output |
| 1.2 | Broker upgrade with live terminals |
| 1.3 | Final chunk immediately followed by exit: the output lands before `terminal:observer-exit`, including with a slow or paused observer |
| 1.3 | Attach during a pending observer batch does not discard it |
| 1.3 | Control-socket loss while observer sockets survive does not discard observer bytes |
| 1.3 | Encoded-size cap keeps frames under the observer queue budget; overflow still produces exactly one snapshot-required and a resubscribable subscriber |
| 1.3 | Companion: multiple subscribers, resubscription after snapshot-required, exit ordering |
| 1.4 | Property test: fast path equals slow path for valid UTF-8 including astral-plane characters; lone surrogates still repair |
| 1.5 | A frame over its method cap is still rejected; malformed inbound frames still rejected |
| 1.7 | Value updates with VoiceOver on, is not built with it off, and repopulates when VoiceOver is enabled mid-session |
| 2.1 | Per removed forward: a visual fixture covering `SessionStrip`, Mesh overview and permissions, and the Companion projection |
| 2.2 | Cache invalidates on project rename and on session close, not only on session add |
| 2.3 | Assignment skipped when unchanged |

## Risk

**1.2 and 1.3 are one atomic app-and-broker change, not two revertable items.**
A new app against an old broker would remove the only observer coalescer and pipe
raw chunks to the MainActor; an old app against a new broker keeps two windows.
Reverting the broker side alone while the app side stays applied is a severe
regression. They ship together, behind the negotiated feature, and revert
together.

The rest of Layer 1 and all of Layer 2 are independently revertable.

Layer 1 and Layer 2 both touch `AppModel.swift` in non-overlapping regions
(Layer 1 at `:7577`, `:8039`; Layer 2 at `:3512`, `:595`, `:6855`, `:6893`,
`:7908`). They will conflict if developed on parallel branches. Develop in
sequence on one branch.

Every push ships a release, so mixed versions are real, and a broker
incompatibility is what broke terminals in `v0.1.114`. The negotiated feature
exists specifically so no old client changes behavior.

## Sequence

0. **Dependency, outside this spec.** Ship the `v0.1.114` terminal hotfix, which
   is uncommitted on `codex/fix-terminal-legacy-attach-0114`. `v0.1.114` is the
   broken build, so the fix is not in the base of this branch. Broken beats slow.
1. Layer 0 probe, idle and loaded, baseline recorded.
2. Mechanical waste, no wire changes: 1.4, 1.5, 1.6, 1.7, 1.8.
3. Cheap SwiftUI wins: 2.3, 2.2 step 1, 2.4.
4. Re-measure. Everything so far is independently revertable.
5. Wire change, atomic: 1.1 state separation, then 1.2 negotiation, then 1.3
   coalescing with lifecycle flushes.
6. Re-measure.
7. Layer 2 invalidation: 2.1 projections, then repointing, then forward removal;
   2.5; 2.2 step 2 if still needed.
8. Final measurement. Set the CI latency threshold from the baseline.

Wire changes now come after the mechanical ones, which is what the risk section
always intended. The previous draft's sequence contradicted its own risk section
by putting the wire change at step 2.

## Open items

- Whether 2.2 needs the caching step. Decided by measurement after the hoist.
- Whether the router hop in 1.9 is worth a synchronization redesign. Decided by
  the probe's stage breakdown.
- Focus-aware throttling per subscriber. Out of scope here; revisit if the loaded
  workload shows blurred windows would help.
