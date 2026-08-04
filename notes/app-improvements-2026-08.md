# App improvements from T3code / Cursor / Zed / ChatGPT-app research (2026-08-04)

Four web sweeps (sources in the session's research outputs), merged and
ranked by fit with Kaisola's architecture and standing asks. Each item names
its origin and the seam it lands on.

## Tier 1 — high value, seams already exist

1. **All-Agents attention center.** (Cursor Agents Window, ChatGPT Activity
   view, t3code status badges.) One cross-project list of every session —
   running / needs-input / done — with jump-to. Kaisola already has
   `AttentionCenter` and per-row status derivation; this is PR 7 D2 grown one
   step: grouping, filters, and live status rather than event history only.
2. **Model + reasoning pickers in the composer.** (Cursor model dropdown,
   t3code per-turn model/effort/mode controls, T3 Chat keyboard switcher.)
   The account menu shipped tonight is the pattern; a model picker beside it
   (feeding the ACP session's model selection) plus a keyboard path completes
   the "switch anything mid-conversation" story.
3. **Diff-review surface for agent edits.** (Zed AgentDiffPane, ChatGPT
   three-level stage/revert, Cursor per-file review bar.) One aggregated
   diff view per turn/session — per-file keep/discard backed by git, opened
   from the chat. Kaisola's biggest missing surface; multi-day build.
4. **Per-turn cost/usage ledger.** (Cursor per-model breakdown, T3 Chat
   reserve-then-settle bar.) Attach tokens/cost per turn in the usage center
   instead of only account-level meters.
5. **Session-scoped environment marker.** (Cursor sets `CURSOR_AGENT`.) Set
   `KAISOLA=1` + `KAISOLA_SESSION_ID` on every hosted PTY and ACP process so
   shells and agents can detect the host. Trivial; do immediately.

## Tier 2 — strong, needs design

6. **Global companion hotkey window.** (ChatGPT Option+Space.) A floating
   panel bound to the last-active chat; natural sibling of the phone
   Companion.
7. **Per-event notification settings.** (ChatGPT: completion / permission /
   question each Never / when-backgrounded / Always.) Kaisola's attention
   kinds map 1:1.
8. **Branch a chat to compare models, keep the winner.** (T3 Chat
   branching.) Transcript restoration + per-chat accounts tonight make the
   fork mechanically cheap; the UX needs care.
9. **Graduated autonomy with an always-confirm floor.** (Cursor Run Modes +
   sensitive-file carve-out.) `defaultAutonomy` + `sensitiveGlobs` already
   exist; add the fixed floor list and a middle tier.
10. **Follow-the-agent toggle surfaced per chat.** (Zed crosshair.)
    `followsSelectedAgentFiles` exists; give it a visible per-session toggle
    and extend it to terminals.
11. **Rules with scopes.** (Cursor .mdc activation modes.) Glob-scoped
    instruction snippets composed onto CLAUDE.md at spawn.

## Tier 3 — noted, not scheduled

12. Typed tool-call cards per kind (Zed) — transcript rendering upgrade.
13. Block-level markdown memoization during streaming (T3 Chat) — measure
    first; AcpConversation already coalesces chunks.
14. Reserve-then-settle usage accounting (T3 Chat) — depends on 4.
15. Worktree-per-thread (t3code/Cursor) — Mesh already does worktrees;
    extending to plain chats is a scope call.
16. Voice dictation on every composer (ChatGPT).
17. CLAUDE.md staleness nudge (Theo's "prompts are technical debt").
18. Independent second-pass reviewer bot on agent diffs (Cursor Bugbot) —
    Michael's dual-review habit, automated; needs the diff surface (3).
19. Multi-repo projects with cross-repo diff review (ChatGPT/Codex).
20. Extension capability manifests + hot-reloaded JSON themes in a user
    folder (Zed) — PR 6 already goes this way; hot-reload is a nice add.

## Immediate actions taken

- (5) shipped: `KAISOLA=1` / `KAISOLA_SESSION_ID` on hosted sessions.
- (1) folded into the PR 7 D2 design.
- (2) queued as the next composer feature after PR 6 slices.
