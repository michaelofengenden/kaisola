# Agent-UI implementation brief — research pass 2026-07-09 (night shift)

Cross-checked against Zed acp_thread/agent_ui source, VS Code chat/browser
source + release notes v1.99-1.109, Cursor/Claude Code/OpenCode/Aider docs,
and Kaisola's shipped code. Shared notes for both agents (claude + codex).

KEY FACT: Kaisola handles only 7 sessionUpdate variants and silently drops
`plan`, `available_commands_update`, and tool-call `content`/`locations`.
Zed's UI is a reference renderer for the exact protocol we speak.

Ranked (value × dock-fit ÷ effort):

1. RICH TOOL-CALL CARDS (HIGH/LOW) — collapsed one-line row (today's) +
   disclosure when the frame carries content. content[{type:'diff', path,
   oldText, newText}] → reuse PermissionCard's hunk renderer (extract it);
   content[{type:'terminal', terminalId}] → "running in terminal" + Open →
   setDockView(terminalId) (ptys are real Kaisola terminals via acp.cjs).
   Failed calls auto-expand (VS Code chat.tools.autoExpandFailures). Fields:
   toolCallId, title, kind, status, content[], locations[], rawInput/Output —
   all already forwarded verbatim; change confined to Assistant.tsx.
2. PLAN CHECKLIST (HIGH/LOW) — sessionUpdate:'plan', entries[{content,
   priority, status: pending|in_progress|completed}]. WHOLE-ARRAY REPLACE per
   frame (Zed-confirmed) → store as runtime.plan, never as turns. UI: pinned
   collapsible strip above transcript: "Plan · 2/7" + current item collapsed;
   ◇/◐(pulse)/✓ expanded. Mirror count into session tab tooltip.
3. REAL CONTEXT METER (HIGH/MED) — ACP `usage_update` frame (claude-code-acp
   emits; verify per agent) → runtime.usage; fallback usage:claudeSession via
   acpSessionId. UI: context-ledger row "Context · 34% of 200k" + thin bar,
   amber past ~70% (auto-compact fires ≈77-80% in Claude). Head % beside
   CostChip when >50%.
4. PER-PROMPT CHECKPOINTS + RESTORE ON TURN RAIL (HIGH/MED) — snap the
   existing git checkpoint in sendText before each session/prompt; turn-rail
   hover gains "Restore files" (git reset, thread intact, inject a one-line
   note next prompt) and "Restore files & trim thread" (also truncate
   runtime.turns; ACP can't truncate server history — preamble correction,
   VS Code's approach). Claude Code's three-way /rewind is the model.
5. FILES-CHANGED REVIEW RAIL → PROPOSAL GATE (HIGH/HIGHER) — slim bar between
   transcript and composer: "3 files changed · +120 −14 · Review"; per-file
   Keep/Undo (VS Code strings); Review assembles pending edits into a
   file-patch Proposal so ProposalCard's approve/partial/reject is THE review
   surface for both worktree and in-place agents. Data: acp.cjs executes
   fs/write_text_file itself — record {path, oldText, newText} there.
6. SLASH-COMMAND TYPEAHEAD (MED/LOW) — available_commands_update
   {availableCommands:[{name,description,input?}]} → runtime; '/' at pos 0
   opens the @-mention-style menu; commands sent as plain text.
7. STEER VS QUEUE (MED/LOW-MED) — keep Enter=queue; add Cmd+Enter "Send now" =
   acp.cancel → await cancelled → re-prompt with "(Steering: supersedes the
   interrupted work — keep what's done.)". Per-chip "▶ next" priority. No true
   mid-turn injection over ACP (turn-scoped session/prompt) — cancel+resend is
   the honest version (Zed's Steer does the same).
8. NEEDS-INPUT PRESENCE (MED/LOW) — three states everywhere: running /
   needs-input / done-unread. Push markNeedsYou(threadId) the moment a
   permission lands (today only turn-finish on hidden cards fires it); badge
   InboxButton with the permission title; optional Zed-style OS notification +
   done-sound as two Interface booleans.
9. THINKING POLISH (LOW/TRIVIAL) — <details open> while streaming, collapsed
   once thinkMs settles, remember manual toggle per turn.

SKIPS: editor-gutter hunk review (not editor-first), conversation forking (no
ACP fork), cloud-agent fleet UI, true mid-turn injection, auto model routing,
tool risk badges, /compact controls, thread archive search.

CODEX REVIEW FINDINGS (its composer work, v0.1.26 — verified good overall):
#1 MEDIUM queue pause never auto-lifts while connected (queuePausedRef only
resets on connected-transition) → stuck queues. #2 MEDIUM Stop drains the
queue (cancelActive flips busy → drain effect auto-fires next prompt).
#4 LOW omni prompt lost on busy-flip race with misleading toast. Fix package
(claude, in flight): Stop pauses queue; new enqueue resumes; successful manual
send resumes; omni failure enqueues instead of dropping.
