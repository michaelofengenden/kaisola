# Round 6 — steering, and the prompts a resumed chat had been losing

Branch `round6-steering`, cut from `backlog-integration` (`bce2743`).
Worktree `.claude/worktrees/agent-ade8dc3e245f28856`.

    d77ddc4 chore(acp): make steering and a resumed replay inspectable
    80ce054 feat(acp): steer a queued message into the running turn
    55c7006 fix(acp): show the user's own prompts in a resumed chat

---

## 1. The wire, discovered rather than assumed

Both installed adapters were read directly:
`~/.npm/_npx/b555b4fead8494dc/…/claude-agent-acp/dist/acp-agent.js` and
`~/.npm/_npx/a81fa54699a25c5d/…/codex-acp/dist/index.js`.

**Method** — `_session/steering`, identical constant in both
(`acp-agent.js:56`, `index.js:23561`).

**Advertised** at `InitializeResponse._meta.steering.supported` — the response's
OWN `_meta`, a *sibling* of `agentCapabilities`, not a member of it
(`acp-agent.js:656-663`, `index.js:28664-28668`). Kaisola's capability parser
read only `agentCapabilities`, so this had to be read separately; had it been
read from inside the block the action would have stayed permanently hidden.

**Request** implemented:

```json
{"jsonrpc":"2.0","id":7,"method":"_session/steering","params":{
  "sessionId":"019fc1b3-…",
  "prompt":[{"type":"text","text":"actually use tabs"}],
  "_meta":{"steering":{"idleBehavior":"promptRequired"}}}}
```

`prompt` is the relevant subset of a `PromptRequest`, which is exactly what both
adapters parse (`parseSteerRequest` `acp-agent.js:66-91`;
`parseSessionSteerParams` `index.js:29395-29405`). Both require a non-empty
array. Kaisola's queue is text-only by design, so one text block is always it.

**Response**:

| outcome | who says it | what it means |
| --- | --- | --- |
| `{"outcome":"injected"}` | both | joined the turn already running |
| `{"outcome":"startedNewTurn"}` | both | no turn was running; the adapter started one |
| `{"outcome":"promptRequired","reason":"noRunningTurn"}` | Claude only | no turn was running; content stayed host-owned |
| `{"outcome":"failed"}` | Codex only | the adapter could not apply it |

**The `_meta` opt-in is load-bearing, not decoration.** Without it, an adapter
that finds no running turn calls `this.prompt(...)` *detached* — `.catch` only
logs (`acp-agent.js:963-966`) — and returns `startedNewTurn`. That turn's
`session/prompt` response goes nowhere Kaisola can see, so `turnEnded` never
arrives and the composer sits pinned on a turn nobody is awaiting. With the
opt-in Claude returns `promptRequired` and touches nothing
(`acp-agent.js:956-960`). Codex ignores the field entirely — its parser reads
only `sessionId` and `prompt` — so `startedNewTurn` remains reachable there and
is handled as its own outcome rather than pretended away.

**Errors**, all mapped to the same conservative reading: Claude throws
`Session not found` (→ `-32603`) and `-32603` + `SESSION_ENDED_MESSAGE` for a
closed query; Codex throws `-32600` for an image on a text-only model, for a
closing session, and for a cancel that beat the steer turn, and answers
`{"outcome":"failed"}` for anything else it swallowed
(`index.js:29230-29240`). `AcpSteering.parseOutcome` treats every unrecognized
outcome, empty body, and transport error as `.rejected` — the only safe reading
of "we do not know what happened" is that nothing was delivered.

**No echo.** Neither adapter emits a `user_message_chunk` for an injected
message. Claude's consumer sees an echo whose uuid matches no queued turn and
drops it as an unrelated replay (`acp-agent.js:920-925`, `:2607`); Codex returns
`null` for live `userMessage` items in both halves of its event handler
(`index.js:23854`, `:23919`). So the transcript row is the host's job — and is
written locally, then recorded so a later replay recognizes it.

## 2. What the queued row does

Sending mid-turn still queues. That default is untouched. What changed is the
row: when the adapter advertises steering **and** a turn is actually running, it
offers to send that one message into the turn in flight. Otherwise it is a plain
queued row with only Remove — a button whose request can only fail is worse than
no button.

The message stays queued for the whole round trip (`injectingQueuedIDs`), and
Remove is disabled while it is in flight, so a double tap cannot send it twice
and an impatient Remove cannot delete a message the adapter has already taken.

| outcome | queue | transcript | user told |
| --- | --- | --- | --- |
| `injected` | leaves | user row at that point in the turn | — |
| `startedNewTurn` | leaves (it was sent) | user row | yes — "the turn ended first, so the agent started a new turn" |
| `promptRequired` | **stays put** | nothing | yes — "still queued" |
| `failed` / unknown / RPC error | **stays put** | nothing | yes — with the adapter's own message |

The end-of-turn flush is held while any injection is in flight and re-run when
the answer arrives. Without that hold, a turn finishing mid-request would
dispatch the very message the adapter was about to inject and the user would say
it twice. With it, a refused injection is simply sent as its own turn a moment
later — the failure mode is "it went one line lower than you wanted", never
"it vanished".

This replaces the cancel-based steer. That one reached the goal by interrupting
the turn: it discarded every permission ask the turn had raised and threw away
the work in progress. Injection joins the turn, so both survive — see the AX run
below, where the permission card is still standing after the injection lands.

## 3. The bug: resumed chats lost the user's own prompts

`handleSessionUpdate` dropped `user_message_chunk` through `default: break`.

The reason it mattered in practice is worth writing down. Kaisola prefers
`session/resume` when the adapter advertises it, and falls back to
`session/load`. Both adapters advertise `sessionCapabilities: { resume: {} }` —
an **object**. `boolValue` on an object is nil, so `capabilities.resumeSession`
parses `false` and **every restore takes the load path**. And `loadSession` is
the one that replays: `loadSession` awaits `replaySessionHistory`
(`acp-agent.js:703`) / `streamThreadHistory` (`index.js:28924`), while
`resumeSession` does neither. So every restored chat received the full history —
and threw away exactly the half the user had written.

(The capability parse is left alone deliberately. Correcting it would silently
switch every restore onto a route this branch has not exercised, and the load
path now works. Worth its own change.)

The chunk is now a user row. Rendering it naively would double every prompt,
since Kaisola restores the same history from its own store, so rows are
reconciled first — against the identity the store already keys on:

1. **Row id.** A replayed message the store has never seen is appended under
   `acp:<messageId>`. Both adapters' ids come out of their persisted transcript
   (Claude: the SDK message uuid, `acp-agent.js:5420-5431`; Codex: the thread
   item id, `index.js:29697-29707`), so they are stable across loads and the
   *next* load recognizes this replay by id.
2. **Text, consumed one-for-one.** Rows this client wrote carry local ids the
   adapter never heard of, so its replay of them can only be matched by text —
   as a multiset take, not set membership. Three sends of "continue" leave three
   rows and absorb exactly three replayed copies, no more.

A multi-block prompt replays as several chunks sharing one messageId — Claude
turns an attached file into a link block plus a trailing `<context>` dump
(`promptToClaude`, `acp-agent.js:5350-5362`) — so the message is decided once,
on its first chunk, whose text is exactly what Kaisola shows for its own sends.
Later chunks follow that decision instead of leaking the file's contents into
the transcript as their own user row.

The same ledger covers Claude's live echo, which fires for any prompt carrying
more than one content block (its skip at `acp-agent.js:2668` only catches a
single text block) — i.e. every attachment send.

## 4. `session/set_model` — left alone

It is live, and deleting it would have broken model switching.
`AcpComposerView.swift:320` → `AcpConversation.selectModel` → `AcpClient.setModel`
is the path taken whenever `AcpComposerSurface` keeps `modelTarget == .setModel`,
which is every adapter whose surviving model list came from `models` rather than
from a `model` config option. Codex serves it as
`LEGACY_SET_SESSION_MODEL_METHOD` (`index.js:23560`, routed `:31462`, dispatched
`:28682`). Claude does not — it has no `session/set_model` registration at all
and routes model changes through `session/set_session_config_option`
(`acp-agent.js:3189-3273`) — which is exactly the case `AcpComposerSurface`
already resolves to `.configOption`. Item 3 skipped.

## 5. AX evidence

Dev profile, `KAISOLA_NATIVE_BROKER_PROFILE=development`, adapter overridden to
`tests/fixtures/acp/nativeAcpMock.cjs`, driven pid-exact through
`AXUIElementCreateApplication`. Production `/Applications/Kaisola.app` was never
touched and no shared defaults were written.

**(a) The action appears only when it can work.** Same running turn, two
adapters:

```
# steering advertised (pid 59076)          # KAISOLA_MOCK_STEERING=off (pid 62014)
#acp.queued.q1 d="Queued follow-up: …"     #acp.queued.q1 d="Queued follow-up: …"
#acp.queued.q1.steer d="Steer this …"      #acp.queued.q1.remove d="Remove this …"
#acp.queued.q1.remove d="Remove this …"    MATCHES=2
MATCHES=3
```

And with a turn no longer running — the adapter killed under a preserved queue
(pid 62609) — the same row drops back to Remove only, message intact:

```
#acp.queued.q1 d="Queued follow-up: wait for the adapter to die"
#acp.queued.q1.remove d="Remove this queued follow-up"
MATCHES=2
```

**(b) Injecting moves it into the running turn.** Pressing
`acp.queued.q1.steer` (pid 59076):

```
before:  #acp.transcript.user-1 d="You said: cancel: audit the release checklist"
         #acp.queued.q1 …steer …remove
         #acp.composer.stop  #acp.composer.send d="Queue follow-up" DISABLED

after:   #acp.transcript.user-1 d="You said: cancel: audit the release checklist"
         #acp.transcript.user-2 d="You said: actually use tabs"
         (no acp.queued.* at all)
         #acp.composer.stop  #acp.composer.send d="Queue follow-up" DISABLED
         AXStaticText v="Steered: actually use tabs."
         AXGroup d="Permission request: Apply deterministic mock change"
```

The turn is still the same turn — Stop still offered, Send still "Queue
follow-up" — the adapter's reply to the steered message is inside it, and the
permission ask that turn had already raised is **still standing**, which is
precisely what the old cancel-based steer destroyed.

**(c) A resumed session shows the user's own prompts.** The fixture's thread was
persisted, a third message the local store never had was added to it, and the app
was relaunched (pid 61201) — the restore took `session/load` and replayed all
three:

```
#acp.transcript.user-1            d="You said: cancel: audit the release checklist"
#acp.transcript.user-2            d="You said: actually use tabs"
#acp.transcript.user-acp:mock-msg-3 d="You said: asked before the local store was pruned"
MATCHES=3
```

The two the store already held stayed single, under their **local** ids; the one
only the adapter had arrived through the new `user_message_chunk` path under its
**adapter-derived** id. A second relaunch (pid 61691) produced the identical
three rows — the replay is idempotent, because the appended row was persisted
under `acp:mock-msg-3` and rule 1 recognized it.

## 6. Verification

- `npm run native:test:focus -- AcpClientTests AcpComposerModelTests
  AcpTranscriptStoreTests AcpPermissionRulesTests` — green.
- `node --test tests/node/nativeAcpMock.test.cjs` — 9/9, including the three new
  fixture contracts (`injected` into a live turn with no user echo, the
  `promptRequired` opt-in vs. `startedNewTurn` without it, and `session/load`
  replaying user prompts while `session/resume` does not).
- Build warning-clean after forcing a full recompile of every changed file.
- `npm run native:test:changed -- --include-working-tree` — went green (144/144,
  exit 0) mid-session on this tree. It later began failing on
  `brokerUpgradeIntegration.test.cjs` ("rolling cutover preserves an idle PTY…",
  `'rolling'` vs `'pending'`), which this branch does not touch — the diff is
  nine ACP files. `/tmp/kaisola-broker-upgrade-*` spawn-helper processes from
  other sessions, some predating this one, are still resident and contend with
  it. Called out rather than papered over.
- The worktree needs `node_modules` symlinked from the main checkout, or
  `codeEditorBundle.test.cjs` fails looking for rollup.

## 7. Concerns

- **Replayed rows land at the end.** `session/load` streams the whole thread
  after the restored rows are already in place, so a user prompt only the
  adapter still has appends below rather than in its original position. Assistant
  rows from the same replay have always had this shape; user rows now share it.
  Ordering the replay against a paged transcript is a larger change than this
  one.
- **Assistant replay is still undeduped.** Only user messages are reconciled.
  A load replays agent chunks and tool calls too, and those still append beside
  the copies the store restored. It is the same bug wearing different clothes and
  the same ledger shape would fix it; it was out of scope here.
- **`resumeSession` parses an object capability as false.** Named above. It is
  why the load path — and therefore this bug — was reachable at all.
- **`startedNewTurn` is honest but not clean.** Codex ignores the idle opt-in, so
  a turn ending inside the round trip can leave it running a turn Kaisola never
  awaits. The message is shown and the user is told, but that turn's end does not
  reach `isRunning`. The window is one round trip wide and only opens when the
  turn was already over.
- **Steering was exercised against the fixture, not a live account.** The wire
  contract was read out of both shipping adapters and the fixture was built to
  match them outcome for outcome, but no real Claude or Codex turn was steered —
  that spends a real account, and the brief's own guardrails make that a
  deliberate choice rather than an oversight.
