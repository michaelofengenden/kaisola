# Best-of-breed harvest blueprint (2026-08-04, v4, at Michael's gate)

Michael's ask: take the best of Zed, t3code, Cline, and Kaisola itself (plus
the wider field) and combine them into one outstanding agent IDE. This doc
turns that into a stack decision, a license-checked harvest map, and proposed
PR slices. It sits one level above `notes/app-improvements-2026-08.md`, which
stays the feature-tier list; this doc adds the architecture moves and the
Cline/license research from 2026-08-04.

Revision history: v2 corrected two stale slice scopes (checkpoints and the
mode picker already exist) and added the license baseline. v3 restructures
the core proposal around Codex's round-2 findings: the PTY broker stays
untouched and a separate core service is introduced instead of growing the
broker; state ownership is now specified per domain; acceptance criteria
that were impossible as written (concurrent-edit-exact diffs, single-
transaction rewind) are replaced with honest ones. v4 folds in the final
round's capability corrections: conversation rewind is spike-gated (ACP
has no transcript-seeded fork), MCP approval is advisory without a host
proxy, untracked-file snapshots need a commit-tree design, MCP fallback
gets a cutover epoch, and the core's trust boundary keeps credential
authority in Swift. Codex's final verdict was REVISE narrowed to those
items; the two-round review cap is spent, so they are folded in here and
the doc stands at Michael's gate.

Everything here is a proposal until Michael's review gate.

## 1. Stack decision

**One shell, three languages, each where it is strongest.**

- **Swift owns the window.** The native shell, glass identity, terminals,
  and platform feel stay. This is the Zed philosophy already paid for, and
  the market wedge: every major competitor (Cursor, Devin Desktop, t3code,
  opencode's desktop app) is web-rendered.
- **TypeScript owns the headless agent services.** Not by growing the PTY
  broker (v1's proposal, withdrawn; see §2) but as a separate core
  service. The agent ecosystem (ACP adapters, MCP servers, Claude Agent
  SDK, Cline's packages) is npm; the app already bundles Node.
- **C/Rust libraries slot in as primitives.** tree-sitter (MIT) is the
  recorded direction for syntax/outline machinery; no adoption slice is
  scheduled yet, and nothing below depends on it. libghostty-vt (MIT,
  build-from-source) stays a future terminal option, same status.

**Rejected paths, with reasons on record:**

- *Fork Zed.* GPL codebase (a fork stays GPL and abandons 136k lines of
  Swift), over a million lines of Rust on a UI framework one company
  understands, no stable fork seam or extension ecosystem to inherit, and
  the features we would add are exactly the ones we would have to rewrite
  from scratch in the hardest environment. No significant Zed fork exists.
- *Rewrite in TypeScript/Electron.* Forfeits the glass identity, the
  43k-line Swift test estate, and the shared-Swift iPhone core, to enter
  the most crowded lane (t3code, opencode) six months behind.
- *Rewrite in Rust/Tauri.* Webview UI anyway, reuses neither existing
  codebase, still bundles Node for the adapter ecosystem.
- *Grow the PTY broker into the core (v1 of this doc).* Withdrawn on
  review: the broker's continuity guarantee rests on being a tiny process
  whose lifetime tracks terminal inventory and whose uncaught-exception
  path is destructive shutdown (`session-broker.cjs:186,779`). Loading it
  with registry I/O, usage scans, and an event log raises both event-loop
  contention and crash surface on the one process that must never die.

The Electron-to-Swift rationale was never written down (history was
squashed at "Initialize native Kaisola"). This section is now that record,
extended.

## 2. The architecture move: a second service beside the broker

Two detached processes, each with the lifecycle its job demands:

- **The PTY broker stays exactly what ARCHITECTURE.md says it is**: a
  deliberately small island owning durable PTYs, sealed generations,
  rolling upgrades, wire implementation 2, no new responsibilities. The
  roadmap's "replace it with Swift" item is retired either way (§5 Q1).
- **`kaisola-core` is a new, separately restartable TypeScript service**
  owning the non-PTY headless domains. It can crash, restart, and upgrade
  freely without touching a single terminal. It runs single-instance
  behind a single-writer lease (no rolling-generation multi-writer
  problem: on upgrade it drains requests, releases the lease, and the new
  build takes over; nothing durable lives only in its memory).

```
Swift app (flagship client)              future thin clients (gated, §4 end)
     |            \                              /
     |             kaisola-core (TS, restartable, single-writer)
     |             - session/event log (SQLite, its own schema)
     |             - usage service (today: native-usage-service.cjs)
     |             - MCP registry (today: native-mcp-registry.cjs)
     |             - checkpoint bookkeeping (only if/when ACP hosting moves)
     |             - ACP hosting (last, gated on reattach proof)
     |
  PTY broker (unchanged: durable terminals, sealed generations)
```

**State-domain ownership** (the decision finding 1 asked for; "source of
truth" is where a disagreement is resolved):

| Domain | Owner today | Owner after | Source of truth | Migration/rollback |
| --- | --- | --- | --- | --- |
| PTYs, spools | Broker | Broker (unchanged) | Broker | n/a |
| Terminal sessions/layout | Swift (`NativeSessionStore`) | Swift | Swift store | n/a |
| Usage snapshots | Swift store + per-request JS helper | Core computes, Swift caches for display | Core's store | PR 13b; old-core fallback runs the helper in-app as today |
| MCP registry | Swift `McpConfigStore` (`mcp/<digest>.json`) | Core | Core's store | PR 13b explicit migration; the JS registry's `mcp/workspaces/<digest>.json` schema differs from the Swift store's and neither is currently packaged into the sealed broker (`native-broker-package.cjs`), so this is a migration, not a relocation |
| ACP transcripts | Swift SQLite (`AcpTranscriptStore`) | Swift, until ACP hosting moves | Swift store | untouched by PR 13 |
| Checkpoint refs | Swift via `GitService` | Swift; stays Swift-owned until the ACP-hosting slice | The git repo itself | refs are inspectable/recoverable with plain git |
| Credentials (accounts, API keys, MCP headers) | Swift/Keychain | Swift/Keychain (unchanged); core receives only scoped, per-request material | Keychain | never migrated; core never stores secrets at rest |
| Event log | does not exist | Core (new, PR 13a) | Core's SQLite | new surface, no migration |

**Recorded-policy reconciliation.** PR 13 amends `docs/ARCHITECTURE.md` as
a named architecture decision, not a one-sentence tweak: (a) the broker
paragraph stands unchanged; (b) a new layer entry defines kaisola-core,
its owned domains (table above), lease semantics, and the rule that core
never owns UI and Swift feature services remain the app's only UI-facing
interfaces; (c) the "Runtime JavaScript never owns UI or product state
outside its terminal/usage protocol boundary" sentence is replaced by a
reference to the ownership table. The same change coordinates every
authoritative document: README's broker paragraph (which still records
the eventual Swift replacement), the native-migration roadmap, and the
PR tracker. Until that amendment lands, no code moves.

**Wire and compatibility.** The broker wire is untouched: implementation
2, existing compatibility fixture still passes verbatim. kaisola-core gets
its own protocol document (`protocol/core/compatibility-v1.json`) with
capability negotiation from the first release; when the Swift app finds no
core or an old core lacking a method, it falls back to today's in-app
execution path (the helper scripts stay shipped through at least one
release overlap). No flag day.

**Dependency honesty:** PR 13 exists only on this two-service path. PRs
14 through 18 do not depend on it and land against the current
architecture; only the thin-client future (deferred) requires the core.

## 3. Harvest map, license-verified

Licenses verified against the actual repos/registries on 2026-08-04 (full
audit in the session research; key gotchas repeated here).

| Source | License | Reuse form |
| --- | --- | --- |
| Zed (editor, rope, collab crates) | GPL-3.0-or-later | Ideas only. Never translate GPL source. |
| Zed GPUI, zed-sum-tree | Apache-2.0 | Rust-only; ideas for us. |
| agent-client-protocol (spec, TS/Rust SDKs, JSON schema) | Apache-2.0 | Depend (npm) in core; generate/write Swift client from the schema. No official Swift SDK exists; community ones are young. |
| tree-sitter | MIT | Link from Swift as a C library; grammars individually MIT (check each). No slice scheduled. |
| t3code (incl. effect-acp, ghostty canvas renderer) | MIT, root | Vendor only (packages are private, not on npm). Keep their notice. |
| Ghostty / libghostty-vt | MIT | Build-from-source library; API unstable, Zig toolchain required. Adopt only when SwiftTerm pain justifies it. |
| Cline monorepo + @cline/llms, @cline/agents, @cline/core | Apache-2.0 | Depend or vendor with NOTICE. SDK packages are v0.0.x and churning; treat as beta. |
| opencode | MIT | Reference architecture; sdk/server usable at arm's length. |
| @pierre/diffs, @pierre/trees | Apache-2.0 | npm dep for web-view diff surfaces; no public source repo (registry-only). |
| xterm.js, node-pty, CodeMirror 6 | MIT | Already using node-pty and CodeMirror. |
| Warp | AGPL-3.0 (warpui MIT) | Ideas only, from docs/behavior, never source. |
| Sourcegraph Amp | Proprietary | UX inspiration only. |

**What each source actually contributes:**

- **From t3code (patterns, plus small MIT vendoring):** the topology
  argument for a headless service with thin clients; per-turn checkpoint
  brackets giving per-turn diffs and one-click revert; an event-sourced
  command log where commands, events, and read-model updates commit in one
  SQLite transaction so retries are idempotent (this becomes PR 13a's
  design, and is what makes core-side mutations safe to retry); one
  provider-driver contract hiding three transports; remote access layered
  at the connection rather than in product code (with the §4 caveat that
  Kaisola's broker token model means thin clients need a scoped gateway).
- **From Cline (Apache code + patterns):** the approval-category model
  with safe-command classification and a fixed always-confirm floor,
  adopted with an enforcement matrix (PR 16); Plan/Act per-mode model
  selection (PR 17); checkpoint restore semantics (ignored paths
  untouched, three-way restore choice) adapted to ACP hosting (PR 14);
  optionally `@cline/llms` if Kaisola ever needs small in-house model
  calls (titles, summaries) rather than a hosted agent.
- **From Zed (ideas + Apache protocol):** the review UX north star: follow
  the agent live, then per-hunk accept/reject in an aggregated diff
  (app-improvements items 3 and 10). ACP we already speak; deepen it.
- **From the wider field:** verification artifacts attached to each turn
  as review objects (Antigravity; PR 18 spike); automated pre-merge
  adversarial review (Cursor Bugbot; app-improvements item 18, unlocked
  by PR 15); scheduled/triggered background runs in worktrees (Codex
  Automations) as the eventual revival of PR 7's deferred workflow
  automation.

**What Kaisola keeps as its own crown jewels:** broker continuity (sealed
generations, reattach), the glass identity, multi-account isolation with
usage meters, Mesh worktree fan-out, the iPhone Companion with the Noise XX
channel, and the validated extension registries from PR 6.

## 4. Proposed PR slices

Continuing the tracker numbering (existing open: PR 5-8, 11, 12). Each
stays independently reviewable and preserves detached-broker sessions.
PRs 14-18 do not depend on PR 13.

**Precondition for any vendoring: a license baseline.** The repository
tracks no root LICENSE or NOTICE file today. Before the first line of
Apache/MIT code is vendored: Michael picks the project license, it lands
at the root, and third-party notices get a process recording upstream
revision, copied paths, and local modifications (the CodeEditor bundle's
`THIRD_PARTY_NOTICES.md` is the pattern to generalize).

**Bounded bug, filed 2026-08-04 in PULL_REQUEST_FIXES.md:** checkpoint
keep-alive refs are named by commit hash alone, so two conversations
snapshotting an identical tree in the same second share one ref, and one
conversation's cleanup (`dropCheckpointRef`) can strand the other's
restore point. Name refs by conversation and turn. Independent of
everything else here.

**PR 13a: kaisola-core scaffolding.** The prerequisites finding 10 named:
TypeScript build configuration (the repo has none), sealed packaging and
digest verification mirroring the broker's (`native-broker-package.cjs`
pattern), the service process with socket, hello, single-writer lease and
drain-on-upgrade, its SQLite store, the event-log/command-receipt schema
(t3code pattern: command, events, projection in one transaction, retries
idempotent by command id), and `protocol/core/compatibility-v1.json` with
capability negotiation. The trust boundary is part of the slice, not an
afterthought: authenticated client identity on the socket (sealed code
identity does not authenticate callers), 0600 socket/store permissions, a
security epoch, payload size limits, and path scoping; credential
authority stays in Swift/Keychain, with the core receiving only scoped
per-request material and never persisting secrets. Ships dark: nothing
user-visible depends on it. Acceptance: kill -9 the core mid-command and
replay converges; broker continuity gates unaffected (core absent,
crashed, or upgrading); an unauthenticated peer on the socket gets
nothing.

**PR 13b: usage and MCP migrate into core.** Explicit migrations, not
relocation: MCP registry schema reconciliation (Swift `mcp/<digest>.json`
vs JS `mcp/workspaces/<digest>.json`), account-scoped credential inputs
for the now-persistent usage process, cache isolation per account, secret
redaction in core logs, request cancellation, and in-app fallback when
core is absent or older. The fallback must not recreate two sources of
truth: migration sets a cutover epoch, after which the Swift path is a
client of the core store's canonical schema; if the core is absent, MCP
edits either queue against the epoch or are refused with a named reason,
never silently written to the old store. Acceptance: behavior parity
against the fixture contracts; edits attempted during core absence and
the subsequent recovery are tested, not just read fallback; a stalled
usage scan cannot starve MCP requests (per-domain workers).

**PR 14: checkpoint extensions.** The existing mechanism is a pre-turn
`git stash create` commit over tracked files, kept alive by a hidden ref
(`GitService.swift:189`, `AcpConversation.recordCheckpoint`). Extensions:
(a) include untracked files; note `git stash create` cannot do this (no
`--include-untracked`; that flag belongs to the worktree-mutating `stash
push`), so the snapshot moves to a non-mutating temporary-index plus
`commit-tree` design, same ignored-paths-untouched rule as Cline; (b)
post-turn snapshots so a turn has a frozen before/after pair; (c)
per-turn diffs derived from that pair; (d) files-plus-conversation
rewind, split honestly in two: files-only rewind ships unconditionally
(the snapshot restore is sound); conversation rewind is capability-gated
and spike-gated, because ACP's `session/new` has no transcript-seeding or
fork parameter and replaying history as a prompt is not an equivalent
fork (roles are lost and the agent may act on historical instructions).
Where an adapter offers a real resume/fork capability, use it; otherwise
the UI offers a visibly branched new chat whose reconstructed context is
labeled non-equivalent. Queued prompts are dropped with notice, pending
permission requests are cancelled. Rewind is journaled with compensating
steps, not claimed to be one transaction: on failure the journal names
what was and wasn't applied. **Honest limits stated in the UI and
tests:** in a shared worktree, a turn's diff describes what changed
during the turn, not who changed it; exact attribution exists only in
worktree-isolated sessions (Mesh). Staged/index state, renames, binaries,
and unsaved editor buffers get defined, tested behavior even where that
behavior is "excluded, and says so".

**PR 15, stage A: read-only diff review.** The aggregated per-turn and
per-session diff surface (app-improvements item 3), rendered natively
(reusing the PR 6 grammar scanner), fed by PR 14b's snapshot pairs, or
degraded to git-status diffs until 14 lands, and in that mode the surface
says so: a working-tree diff cannot truthfully present per-turn or
per-session history, so degraded provenance is labeled in the UI, not
implied away. Read-only: no keep/discard. Can land before everything
except its data source.

**PR 15, stage B: mutating review actions.** Per-file and per-hunk
discard (defined as: revert the hunk in the worktree), with stale-hunk
detection against the live file, single-step undo, and conflict refusal
with a named reason. "Keep" is explicitly a no-op acknowledgment, not a
git stage. Gated on PR 14's baseline semantics.

**PR 16: approval taxonomy with an enforcement matrix.** Builds on the
four existing ACP permission postures (`AcpComposerModel`), not a binary.
Adopt Cline's category model where the host can actually observe the
action, and publish the matrix: which categories are *enforced*
(host-mediated filesystem/terminal calls) versus *advisory* (an adapter's
internal tools, vendor CLIs in bypass modes, and MCP tools: the registry
only hands server configs to the adapter at `session/new`, and the
adapter invokes those servers itself, so MCP stays advisory unless a
later, separately scoped slice adds a host-mediated MCP proxy). Fail
closed means refusing to start the adapter or mode whose actions cannot
be observed, not merely withholding an auto-approve rule; the
sensitive-glob floor applies to every enforced path. The
safe-command classifier replaces, rather than builds on, the current
first-word wildcard rule (`AcpPermissionRules.swift:151`). The 30-second
long-runner notification rides the attention center.

**PR 17: Plan/Act polish.** The composer already surfaces ACP session
modes. The delta: per-mode model selection (reasoning model in plan, fast
model in act, swapped on toggle) with defined failure semantics: the
mode/model setters become acknowledged rather than optimistic
(`AcpConversation.selectMode` today is optimistic), unavailable models
fall back with a visible notice, per-mode choices persist per
project+agent, and adapters whose modes are not plan-shaped simply don't
get the pairing UI. Transitions stay user-controlled.

**PR 18: verification artifacts (design spike).** Attach evidence (test
runs, command exit codes, screenshots from hosted browser cards) to turns
beside the PR 15 diff. Required spike outputs, per review: provenance
labeling (host-captured versus agent-claimed), truncation and storage
limits, secret redaction, retention, and invalidation of artifacts that
postdate a rewind. No implementation before the spike answers those.

**Deferred, with constraints recorded now:** thin clients (web/Linux/
Windows and eventually the Companion as a plain client) require a scoped
gateway with per-client capabilities, revocation, and projection
redaction; the broker socket and its token are never exposed beyond the
machine (an authenticated controller can claim owner scope today, so
transport tunnels alone are not authorization). Automations/triggers;
LSP-diagnostics feedback into hosted agents; tree-sitter adoption; edit
prediction is out of scope entirely.

## 5. Open questions for Michael

1. **The §2 topology**: bless the two-service design (PTY broker
   untouched, new restartable kaisola-core)? This retires both the
   roadmap's replace-broker-with-Swift item and v1's grow-the-broker
   proposal. PRs 14-18 proceed regardless; PR 13 and the thin-client
   future exist only on this path.
2. **Checkpoint mechanism**: keep the existing stash-commit-plus-hidden-
   ref mechanism and extend it (PR 14), or move to plain hidden-ref
   commits? Proposal: keep and extend; the mechanism works and the git
   repo stays the source of truth.
3. **Effect-ts**: t3code builds everything on it. Proposal: vendor
   patterns, never adopt the framework (it would colonize the whole
   core). Agree?
4. **License choice**: no root LICENSE is tracked today, so this is a
   required action: pick the project license (MIT or Apache-2.0
   proposed) and commit it, which also locks the GPL sources (Zed core,
   Warp) to ideas-only forever.
5. **Slice order**: proposed: the ref-naming bugfix and license baseline
   immediately; then PR 15 stage A (behind git-status diffs), PR 14, PR
   15 stage B, PR 16, PR 17 interleaved with the existing PR 5-8/11/12
   work; PR 13a/13b whenever the topology decision lands, since nothing
   user-facing waits on them. Objections?
