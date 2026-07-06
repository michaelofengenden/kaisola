# Kaisola as the browser for AI agents — plan

> **Status (2026-07-04): Waves A and B are SHIPPED, plus Wave C's worktree
> sessions (v1).** Remaining: PTY daemon, session export. Two corrections
> from the completed verification run: (1) Warp demoted its auto-detecting
> Universal Input to "Legacy" — unified entry stays, but modes must be
> EXPLICIT (Kaisola's ⌘L uses explicit rows/prefixes, never auto-detection);
> (2) Warp shipped tab groups on Jul 3, 2026 — every browser-grammar feature
> now has a shipped precedent. Also verified: the "browser for AI agents"
> positioning is unclaimed — Warp brands "the Agentic Development
> Environment", Superset "the Code Editor for AI Agents". The metaphor is
> ours to take.

Deep-research synthesis (two runs, ~200 agents; Warp claims 3-vote verified
3-0, Zed config claims verified, Superset claims sourced from repo/docs but
only partially adversarially verified — rate-limit casualties; treat Superset
specifics as strong leads). Sources: warp.dev docs/changelog/blog,
github.com/superset-sh/superset + superset.sh, zed.dev docs/blog/releases.

## The positioning

"Chrome for AI agents": every agent session is a tab — cheap to open, obvious
to find, easy to group, safe to close. Three shipped competitors validate the
category and none owns the metaphor cleanly:

- **Warp 2.0** ("the first Agentic Development Environment", Jun 2025) ported
  Arc's sidebar tabs to an agent terminal: per-tab agent-status badges
  (working/blocked/failed/done/canceled), tab search keyed on cwd/branch/PR,
  a Universal Input omnibox, and TOML "Tab Configs". Since Apr 2026 it runs
  Claude Code/Codex/Gemini/OpenCode as managed first-class sessions.
- **Superset** ("The Code Editor for AI Agents", source-available Electron +
  React — our exact stack) is worktree-per-workspace with a browser-grade tab
  system (⌘⌥1-9, middle-click close, drag-to-split, Mosaic tiling), sidebar
  groups by project, an embedded browser with a Ports panel, and a PTY daemon
  so sessions survive app updates.
- **Zed** owns the config story: one schema-validated `settings.json`,
  `keymap.json` as `[{context, bindings}]`, `agent_servers` for custom
  agents, GUI and JSON coexisting ("raw JSON makes settings undiscoverable").

Kaisola's edge, unchanged: the research surfaces (checkpoints + blame +
provenance + reading layer) none of them have, plus true side-by-side cards —
a browser shows one tab at a time; our grid shows four.

## Already shipped (browser-metaphor scorecard)

| Chrome feature | Kaisola today |
|---|---|
| Tabs | Session rail rows (threads/terminals/panels) |
| Tab groups (color, collapse, rename) | Session groups ✓ (right-click to group) |
| ⌘1–9 | ✓ rail order |
| Ctrl+Tab cycling | ✓ (in-place card swap) |
| Tab search (⌘⇧A) | ✓ sessions in the ⌘K palette |
| New-tab menu | ✓ rail `+` (agents first) |
| Multiple tabs visible | ✓ card grid — beyond any browser |
| Session restore | ✓ store persists; ptys relaunch via `restart` |
| Embedded browser | ✓ browser cards + localhost capture |
| Extensions/registry | ✓ agent registry + custom agents |

## Wave A — small, this week (all S) — ✅ SHIPPED

1. **"Needs you" state** (Warp's `Blocked`, Superset's attention notify).
   A session with a pending permission card or a finished-unseen turn gets an
   amber dot and sorts to the top of the rail. The single biggest multi-agent
   QoL gap.
2. **Undo close tab — ⌘⇧Z/⌘⇧T.** Closing a terminal keeps its pty alive for
   60s (Warp's grace-period pattern); reopen restores scrollback and process.
3. **Pinned sessions.** Pin to the top of the rail, close button hidden
   (Chrome pinned tabs). One boolean + sort.
4. **Group colors.** Groups currently derive a hue from the name; add an
   8-color picker on the group head (Chrome group colors / Warp tab colors).

## Wave B — the identity wave (M each) — ✅ SHIPPED

5. **Omnibox (⌘L).** One input: plain text → prompt the focused agent;
   leading `$`/`!` → run in the focused terminal; URL → browser card;
   otherwise fuzzy-jump to a session. Warp's Universal Input proves the
   pattern in an agent shell; this is the "Chrome" moment.
6. **`settings.json` + `keymap.json`** (Zed's pattern, verbatim shapes).
   Schema-validated file in userData, `⌘K → Open settings file`, keymap as
   `[{context, bindings}]` with null-to-disable. GUI Settings stays — file
   and GUI coexist, Zed-style. Read Zed's `agent_servers` key as-is for
   zero-cost agent-config compatibility.
7. **Session templates** (Warp Tab Configs / Superset presets). Save a
   session as a named profile — agent, folder, boot command, group; the `+`
   menu lists profiles. Declarative in settings.json, so it's automatable.
8. **Ports panel-lite.** We already catch clicked localhost links; also scan
   terminal output for "listening on / localhost:N" and show a small port
   chip on the card that opens/re-points the browser card (Superset's Ports
   panel, minimalist form).

## Wave C — the platform wave (L, ordered)

9. ✅ **Worktree-per-session** (v1 shipped: + menu / ⌘K "agent in a fresh
   worktree", ⎇ branch in the rail, right-click merge-back / remove). The full convergence point (Cursor, Zed,
   Superset, Conductor all landed here): new session card → optional fresh
   worktree under `~/.kaisola/worktrees/<repo>/…`, agent works isolated,
   commit panel reviews/merges back. `worktreeHandler.cjs` already exists —
   this is wiring, not research.
10. **PTY daemon.** Superset ships pty survival across app restarts (May
    2026). Ours die with the app. A small detached broker process adopted on
    relaunch = sessions that truly never die. Pairs with the companion plan.
11. **Session handoff/export** — write a session (agent, cwd, transcript
    pointer, checkpoint sha) to a file; import on another machine (Gemini CLI
    pattern; pairs with the mobile companion).

## Wave D — project tabs (the user's Chrome-window model)

The idea: a strip at the top like Chrome's tab bar, but each tab is a
**project folder** (Finder-style); terminals/agents live *inside* a project;
projects tear off into their own macOS windows and merge back — exactly how
browser tabs move between windows.

Why the architecture is already 70% there:
- **Tear-off exists in primitive form**: slot windows (⌘⇧N) are separate
  persisted stores, and pop-out terminals already prove sessions can MOVE
  between windows — ptys live in one main-process manager keyed by id, so a
  card re-attaches wherever it lands (`termRemounts` + `terminal:attach`).
- **What's missing is the partition**: today one window = one `workspacePath`
  and one flat session set. Project tabs need sessions tagged by project.

Phases:
1. **Project strip (M)** — `projects: {id, path, name, color}[]` in the store;
   every session carries `projectId`; the strip switches the ACTIVE project,
   which filters the rail/grid and repoints the file tree + LaTeX + git
   surfaces. Sessions keep running in background projects (ptys don't care);
   the "needs you" dots aggregate up to the project tab — Chrome's favicon
   badge, project-sized.
2. **Tear off (M-L)** — drag a project tab out (or context menu → "Move to
   new window"): main opens a slot window with `?adopt=<projectId>`, the
   source store serializes that project's slice (sessions, grid, groups,
   pins) over a `window:adopt` IPC, target rehydrates it, source drops it.
   Terminals re-attach by id — the running agent never notices.
3. **Merge back (M)** — the same handoff in reverse (a "Move to window…"
   menu listing open windows; drag-onto-window can come later).

Sequencing note: do this AFTER the PTY daemon if possible — tear-off with
daemon-owned ptys is trivially safe; without it, it still works (manager is
per-app, not per-window) but quitting the app still kills everything.

## Explicit skips

- Arc-style Spaces/profiles — slot windows already partition workspaces.
- Base-keymap emulation (VSCode/Emacs presets) — not worth it for a shell.
- Theme marketplace / theme builder — `theme_overrides`-style tokens in
  settings.json are enough; authoring stays outside the app (Zed's lesson).
- Cloud settings sync — local-first; the store already persists per window.
- A "mission control" dashboard page — the rail + groups + needs-you state
  covers it at our scale; revisit only if users run 10+ concurrent agents.

## Marketing line (README/site)

> **Kaisola — the browser for AI agents.** Every agent is a tab. Group them,
> pin them, ⌘L to talk to any of them. Your CLIs, your auth, your files —
> side by side on glass.
