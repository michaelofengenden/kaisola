# Competitor feature harvest — mid-2025 → mid-2026

Deep-research run (106 agents, 24 primary sources, 120 claims extracted, 25
top claims adversarially verified 3-vote: 24 confirmed, 1 refuted). Tier 1
survived verification against primary changelogs; Tier 2 is sourced from
primary pages but not 3-vote verified — treat as leads, confirm before citing.

Effort: S ≤ 1 day · M ≤ 1 week · L = multi-week. Recommendations honor
Kaisola's principles (minimalism, usability, automatability, configurability).

## Tier 1 — verified (Cursor + Zed primary changelogs)

### Agent orchestration
| # | Feature | Who shipped | Effort | Call |
|---|---|---|---|---|
| 1 | **Worktree-per-session isolation** — new session card can opt into its own `git worktree`; agents never collide on one tree. Zed: worktree picker (type-to-create) on the new-thread button; archiving a thread never deletes a user-created worktree. Cursor: `/worktree`, up to 8 parallel agents. | Cursor 2.0/3.0 · Zed v1.6.3–1.8.2 | M | **BUILD next** — highest-leverage item; Kaisola already has worktreeHandler.cjs, wire it into session creation |
| 2 | Best-of-N racing + automatic judging (same task, N models, N worktrees, LLM judge recommends winner) | Cursor 2.2 / 3.0 | L | LATER — v1 = same prompt in N worktree sessions + side-by-side checkpoint diffs, no judge |
| 3 | Plan-then-execute gate: agent emits an *editable Markdown plan* (file paths, todos), user edits, then "build from plan" | Cursor 1.7 | S | BUILD — plan artifact opens in the CodeMirror viewer; "run the plan" action on the card |
| 4 | Agent-centric UI (agents are the primary object, files demoted) | Cursor 2.0/3.0 · Zed May 2025 | — | ALREADY PASOLA'S THESIS — validation; polish per-agent status in the rail |
| 5 | Multibuffer review: one scrollable diff across every file a turn touched | Zed May 2025 | M | BUILD — upgrade checkpoint review from per-file to all-files-in-one-buffer |
| 6 | Agent following: viewer auto-opens the file the agent is touching | Zed May 2025 | S | SHIPPED (follow mode) — verify parity: Zed follows on cmd-submit too |

### Attention & notifications
| # | Feature | Who | Effort | Call |
|---|---|---|---|---|
| 7 | **Actionable OS notifications** — approve/reject a permission ask straight from the macOS notification; turn-complete notes | Cursor 2.2 | S-M | **BUILD next** — maps 1:1 onto Kaisola's permission cards; differentiator: don't steal focus (Cursor's does, users complain) |
| 8 | Menubar/tray agent monitor — per-session status without switching apps | Cursor 1.7 | S | BUILD — Electron Tray, hue dots per session |
| 9 | ⌘F in-thread search over the agent conversation (skips collapsed tool output) | Zed v1.9.0 | S | BUILD — terminals already have ⌘F; add to ACP threads |

### Git
| # | Feature | Who | Effort | Call |
|---|---|---|---|---|
| 10 | Full in-editor git: staging, commits, side-by-side diffs | Zed 2025 (v0.177→) | M | **SHIPPED THIS WAVE** (commit panel card) |
| 11 | Word-level (intra-line) diff highlighting | Zed Nov 2025 | S | BUILD — one option in @codemirror/merge config; big readability win in checkpoint review |
| 12 | Commit & per-file history views | Zed Nov 2025 | M | LATER — a small `git log -- file` view over checkpoints |

### Sandboxing & permissions
| # | Feature | Who | Effort | Call |
|---|---|---|---|---|
| 13 | Sandboxed agent commands by default (Seatbelt on macOS; no network unless granted) | Cursor 1.7/2.0 | M-L | LATER — macOS `sandbox-exec` wrapper surfaced as "run sandboxed" on permission cards |
| 14 | Host-scoped network grants ("allow api.github.com only") + prompts show the exact command | Zed v1.8.2 | M-L | LATER — the harvestable part now: always show the exact command on permission cards (S) |

### Browser
| # | Feature | Who | Effort | Call |
|---|---|---|---|---|
| 15 | Embedded browser as a first-class surface | Cursor 1.7→2.0 GA | M | **SHIPPED THIS WAVE** (browser cards + localhost link capture) |
| 16 | Element picker → forward DOM snippet/selector into agent context | Cursor 2.0 | M | LATER — strong pairing with browser cards |
| 17 | Visual design editor (component tree, live CSS edits applied by agent) | Cursor 2.2 | L | SKIP — violates minimalism, low research-IDE value |

### Agent registry / protocol
| # | Feature | Who | Effort | Call |
|---|---|---|---|---|
| 18 | Declarative custom agents (`agent_servers` JSON: command/args/env) | Zed | S | **SHIPPED THIS WAVE** (custom agents in Settings; consider also *reading Zed's agent_servers format* for zero-cost compatibility) |
| 19 | In-app ACP Registry (shared with JetBrains since Jan 2026) | Zed | L | LATER — watch whether the shared registry becomes a standard; then read it directly |
| 20 | ACP embedded resources in tool calls (images render inline in the thread) | Zed v1.9.0 | S | BUILD — track the spec addition; render image blobs in tool-call cards |

## Tier 2 — sourced, not 3-vote verified (confirm before relying)

### From the closest peers (Kairn, Conductor, Sculptor, Warp)
- **Agent-state awareness without polling** — Kairn shows working / waiting-on-you / done per session. Kaisola has running/failed dots; add an explicit **"waiting on you"** state (permission pending or prompt empty after turn end). S — BUILD.
- **Review-and-merge flow** — Conductor: per-task glance diff → merge button when the agent's branch is ready. Pairs with worktree sessions. M — LATER.
- **Container-isolated agents** (Sculptor's pitch: worktrees still share your env; containers don't). L — SKIP for now (macOS-first, Docker optional).
- **Agent Management Panel** — Warp 2025.06.20: one surface listing every active agent, jump-to-the-one-needing-input. Kaisola's rail is close; add a "needs input" filter/sort. S — BUILD.

### From the CLIs Kaisola hosts
- **Background subagents with completion notify** (Claude Code v2.1.198). Surface subagent activity in the hooks feed. S — BUILD (feed already exists).
- **Session snapshots + revert-to-message** including file changes (OpenCode v1.17.11) — Kaisola's checkpoints already do this per turn; parity check only.
- **Bang mode** — Crush v0.78: `!` in the composer runs a shell command and injects output into context. Neat, matches automatability. S — BUILD in ACP composer.
- **Session export/import to file** (Gemini CLI v0.43) — portable session handoff. M — LATER.
- **Auto-compaction + /compact** (Zed Agent v1.7.2) — context-window management; ACP agents own their context, so surface *their* compaction controls when exposed. S — WATCH.

### Remote / mobile (feeds the companion plan)
- Cursor iOS/web: push on turn-complete/needs-input, **Live Activities on the lock screen tracking up to 8 agents**, PWA install. → v1 companion = PWA + WS (see docs/mobile-companion-plan.md); Live-Activities-style glance is the phase-4 push tier.
- Omnara / Happy: session keeps running **locally**, phone monitors and steers remotely — exactly the companion plan's architecture (local ptys, phone as attention surface).

### Refuted (do not cite)
- "Zed sends turn-complete notifications with thread titles + collapsed-header indicators" — failed verification 1-2. Zed's notification specifics are unclear; design our own.

## Suggested next-wave order

1. Worktree-per-session (M) — unlocks parallel agents on one repo without collisions, and later best-of-N.
2. Actionable notifications + tray monitor + "waiting on you" state (S+S+S) — the attention stack.
3. Word-level diffs + ⌘F in threads + exact-command permission cards (S each) — polish trio.
4. Plan artifact gate (S-M).
5. Companion phase 1-2 (M) — see mobile-companion-plan.md.

*Caveat: only Cursor and Zed claims survived 3-vote verification; the
orchestrator/CLI/mobile tiers rest on primary pages fetched but not
adversarially verified. Zed ship dates are sometimes PR-merge dates.*
