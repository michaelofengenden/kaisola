# Round 5 — the doubled effort, and what a mid-conversation switch can carry

Worktree `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a24045e75445b251a`,
branch `round5-effort-and-switching`, off `backlog-integration` (`07e4d79`).

- `a45bdfb` feat(acp): keep the category ACP puts on a config option
- `e5f2e12` fix(acp): say the model and its effort once each

---

## 1. What the Codex adapter actually advertises

Captured from a live `initialize` + `session/new` against
`@agentclientprotocol/codex-acp` **1.1.8** (2026-08-02, this repo as cwd), not
from a fixture.

`models.availableModels` — **33 rows**, a model × effort cross product, with the
effort in the id *and* again in the name:

```json
{ "modelId": "gpt-5.6-sol[low]",   "name": "GPT-5.6-Sol (low)"   }
{ "modelId": "gpt-5.6-sol[medium]","name": "GPT-5.6-Sol (medium)"}
{ "modelId": "gpt-5.6-sol[high]",  "name": "GPT-5.6-Sol (high)"  }
{ "modelId": "gpt-5.6-sol[xhigh]", "name": "GPT-5.6-Sol (xhigh)" }
{ "modelId": "gpt-5.6-sol[max]",   "name": "GPT-5.6-Sol (max)"   }
{ "modelId": "gpt-5.6-sol[ultra]", "name": "GPT-5.6-Sol (ultra)" }
…gpt-5.6-terra[…], gpt-5.6-luna[…], gpt-5.5[…], gpt-5.4[…],
  gpt-5.4-mini[…], gpt-5.3-codex-spark[…]
"currentModelId": "gpt-5.6-sol[max]"
```

`modes` — `read-only` / `agent` / `agent-full-access`, current `agent`.

`configOptions` — **five**, each with an ACP `category`:

| id | name | category | currentValue | choices |
|---|---|---|---|---|
| `mode` | Mode | `mode` | `agent` | read-only, agent, agent-full-access |
| `collaboration_mode` | Collaboration mode | `collaboration_mode` | `default` | default, plan |
| `model` | Model | `model` | `gpt-5.6-sol` | the **7 base models**, effort-free |
| `reasoning_effort` | Reasoning effort | `thought_level` | `max` | low, medium, high, xhigh, max, ultra |
| `fast-mode` | Fast mode | `model_config` | `off` | off, on |

So the same three settings are each declared twice: model (cross product *and*
base-model option), mode (`modes` *and* `mode` option), effort (in both halves of
every model row *and* its own option).

### The behaviour that makes it a correctness bug, not a tidiness one

Follow-up probes on the same live session:

```
baseline                          currentModelId=gpt-5.6-sol[max] | model=gpt-5.6-sol, reasoning_effort=max
set_config_option effort=low   →  model=gpt-5.6-sol, reasoning_effort=low     ← currentModelId NOT updated, no notification
set_model gpt-5.6-terra[high]  →  {}  then model=gpt-5.6-terra, reasoning_effort=high   ← sets BOTH
set_config_option model=luna   →  model=gpt-5.6-luna, reasoning_effort=high   ← leaves effort alone
set_config_option effort=ultra →  -32602 Invalid params                       ← Luna has no `ultra`
```

The adapter never pushes a model update when the effort moves. A menu built from
the raw payload therefore shows `Model: GPT-5.6-Sol (max)` beside `Effort: Low`
and is **wrong about what the next message will cost**.

Before this change the composer rendered, for that payload:

```
pill:  GPT-5.6-Sol (max)  Max
menu:  Agent  Codex
       Model  GPT-5.6-Sol (max)      ← effort #1
       Mode   Agent                  ← duplicate of the permission chip
       Collaboration mode  Default
       Model  GPT-5.6-Sol            ← model #2
       Effort Max                    ← effort #2
       Fast mode  Off
model submenu: 33 rows, every one ending in an effort
```

## 2. The fix

`AcpComposerSurface.reconciled(models:currentModelID:modes:configOptions:)` in
`native/KaisolaMac/Kaisola/Acp/AcpComposerModel.swift` — one pure function,
adapter payload → the model list and option list the menu renders, plus a
`modelTarget` saying how a model choice must be delivered. Three rules:

1. **An option that restates `modes` is dropped.** Only when its choice values
   *are* the declared mode ids, so a differently-scoped approval option keeps its
   row. The permission chip already says it.
2. **A base-model option supersedes a model list it covers** (every model id
   starts with one of its choice values). The option names each model once;
   choosing through `session/set_config_option` leaves the effort alone. This is
   also where ACP itself has gone — `session/set_model` was retired in SDK 1.3.0
   in favour of `set_config_option` with `category: "model"`, and `codex-acp`
   keeps the old method only as a compat shim.
3. **Otherwise the `<model> × <effort>` rows fold back into one row per model.**
   The effort suffix is split off using the effort option's *own* choice values
   (so `[xhigh]` is never read as a stray `high`, and a model that merely rhymes
   with a level keeps its name), and the surviving id is the variant at the
   effort in force — so picking a model preserves the effort and `Advanced`
   quotes a true id. When no variant exists at that effort (Luna stops short of
   `ultra`) the row still resolves rather than vanishing.

   **When the effort lives only in the model names, nothing is stripped.** With
   no second row to contradict, the model row is the right place for it.

`AcpConfigOption` now carries ACP's `category`, parsed in `AcpClient`. The
category decides alone when declared — which is why Codex's `collaboration_mode`
is never mistaken for its `mode` despite the shared word — with the old name
heuristics kept as the fallback for adapters that omit the field.

`AcpComposerMenu.rows` / `modelSubmenu` / `advancedLines` now take the surface
rather than a raw payload, so a caller cannot skip the reconciliation.

### After

Live in the running app against a fixture of the real payload (AX, pid-exact):

```
acp.composer.settings          "Chat settings: GPT-5.6-Sol, Max"
acp.composer.permission        "Permission: Agent"
acp.composer.menu.row.agent                      "Agent: Codex"
acp.composer.menu.row.model                      "Model: GPT-5.6-Sol"
acp.composer.menu.row.option.collaboration_mode  "Collaboration mode: Default"
acp.composer.menu.row.option.reasoning_effort    "Effort: Max"
acp.composer.menu.row.option.fast-mode           "Fast mode: Off"
model submenu: GPT-5.6-Sol (selected) · GPT-5.6-Terra · GPT-5.6-Luna
```

and after choosing Effort → Low, with the adapter still reporting
`currentModelId = gpt-5.6-sol[max]`:

```
acp.composer.settings                         "Chat settings: GPT-5.6-Sol, Low"
acp.composer.menu.row.model                   "Model: GPT-5.6-Sol"
acp.composer.menu.row.option.reasoning_effort "Effort: Low"
```

No row still says max. Verification: build warning-clean;
`native:test:focus AcpComposerModelTests AcpClientTests` 80/80;
`native:test:changed --include-working-tree` 156/156. Fixtures cover the Codex
shape, the effort-only-in-names shape, and Claude's flat list as a control.

---

## 3. Investigation: switching mid-conversation

### Same agent, different model — **live, context intact. Not a restart.**

`AcpComposerView.choose(.model)` → `AcpConversation.selectModel(_:)`
(`AcpConversation.swift:600`) → `AcpClient.setModel(_:)`
(`AcpClient.swift:313`), which sends

```
session/set_model { sessionId: <the live id>, modelId: … }
```

on the already-open connection. Nothing calls `stop()`, `start()`, or
`session/new`; the child process, the `sessionID`, and the transcript are the
same objects before and after. Confirmed on a real adapter: `set_model
gpt-5.6-terra[high]` returned `{}` and a subsequent read showed
`model=gpt-5.6-terra, reasoning_effort=high` on that same session. So
Codex 5.6-Sol → 5.6-Terra keeps the whole conversation; the next turn replays the
existing history to the new model. **No bug here.**

Two true caveats:

- The adapter sends no `current_model_update` back, so the app's belief is
  optimistic. It happens to be right, but nothing verifies it.
- Post-fix, Codex model choices go through `set_config_option` (`category:
  "model"`) instead, which is equally live and additionally leaves the effort
  alone. Adapters with no base-model option still use `session/set_model`.

### Different provider (Claude ↔ Codex) — **the transcript cannot move. Verified.**

Checked against the vendored ACP schema
(`@agentclientprotocol/sdk` 1.3.0, `schema/schema.json` +
`schema/v2/schema.unstable.json`):

- The complete `session/*` inventory is `new, load, resume, prompt, cancel, list,
  delete, fork, close, set_mode, set_config_option` (+ agent→client
  `request_permission`, `update`). There is **no** export, import, transfer,
  move, or clone.
- `session/fork` — the nearest thing — is explicitly intra-agent: *"Creates a new
  session based on the context of an existing one"*, taking a `sessionId` the
  same agent already owns.
- `SessionId` is *"a unique identifier for a conversation session between a
  client and agent"*; the agent mints it and persists it (`session/list` is how a
  client discovers the agent's own stored sessions). A Claude id is meaningless
  to Codex.
- **No request accepts message content** except `session/prompt`. `load`,
  `resume`, `fork`, `close` carry only `sessionId` + `cwd` + `mcpServers`.

So the previous agent's conclusion is right, and now cited. Today
`AcpAgentSwitch.decision` returns `.startNewChat`, `switchAgent` calls
`openChat` with only the draft carried over, and the old chat stays open — which
is honest, and the agent submenu says so ("Starts a new chat").

**The three options, assessed:**

**(a) ACP resume/replay — does not apply.** `session/load` *does* replay history,
but only *the agent's own*: *"Stream the entire conversation history back to the
client via notifications"*, and `claude-agent-acp` implements it by walking its
own on-disk store. It replays **to the client**, never **into another agent**.
(v2 draft folds this into `session/resume` + `replayFrom`; same constraint.)
Cost: n/a. Not a path.

**(b) Seed the new session with the transcript.** The only in-protocol route: the
first `session/prompt` to the new agent carries the old chat's transcript as ACP
content. We already have every piece — `AcpTranscriptStore.rows(for:)` holds the
full history in SQLite, `AcpClient.promptBlocks` already builds `resource` /
`resource_link` blocks and gates them on the agent's advertised
`promptCapabilities.embeddedContext`, and `openChat` already accepts an
`initialDraft`. Work: a transcript → Markdown serializer, a token-budget policy
(full below a threshold, head+tail or an agent-written summary above it), an
`initialContext` parameter through `openChat`, and a submenu affordance
distinguishing "start fresh" from "carry this conversation over". Roughly
**400–500 LOC including tests, about a focused day**, ~3 files of mine plus
`AppModel`.

Its honest limit, worth saying to the user in the UI rather than in a changelog:
this is transcript *seeding*, not context transfer. The new agent reads the
conversation as user-supplied text. Prompt caching is lost, the first message is
expensive, and none of the old agent's tool state, file handles, plan, or
permission grants come with it.

**(c) Nothing** — today's behaviour. Cost: zero. Defensible: the two agents
disagree about tools and permissions anyway, and a new chat beside the old one
never destroys a transcript.

**Recommendation: (b), in its bounded form** — a "Continue this conversation
with <agent>" row alongside the plain switch, seeding the transcript as an
embedded resource under a token budget and falling back to a summary above it.
It is the only thing that answers the question actually being asked, the
building blocks all exist, and keeping it as a *separate* row means the cheap
switch stays one click away. I would not make it the default behaviour of
choosing an agent.

If the day is too much: a summary-only variant (ask the current agent to
summarize, seed that) is roughly half the work, but adds a round trip and fails
when the old agent is wedged — which is one of the times you most want to switch.
