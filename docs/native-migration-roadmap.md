# Kaisola native (Swift/macOS) migration roadmap

The Electron app is the daily driver. The native app grows by strangling it —
driving the shared `session-broker` first, porting surfaces one at a time. This
is the authoritative parity checklist: every user-facing Electron capability,
its status in native, and a migration priority.

**Status:** DONE (in native) · PARTIAL (scaffolding exists) · NEW (not started).
**Priority:** P0 core daily-driver · P1 important · P2 nice-to-have / legacy.

**Product-scope caveat:** the repo carries two identities — the **agent
workspace** (terminals, ACP Claude/Codex, Mesh) and an older **research
assistant** (papers, citations, hypotheses, campaigns). The native migration
prioritizes the agent workspace; the research pipeline (§9 legacy rows, most of
§4 annotations, §3 domain reasoning providers) is treated as explicitly
optional pending a scope decision.

---

## Already done / in-flight in native (baseline)

- Terminal **observation** — `broker.status`/`terminal.list`/`subscribe`/`diagnostics` (`ObserveOnlyBrokerClient.swift`).
- Native terminal **ownership**: create/type/resize/kill, durable across quit/update/crash, reattach on relaunch (`BrokerControlClient.swift`, `NativeTerminalSurface.swift`, `NativeSessionStore.swift`).
- **Agent CLI sessions**: one-click Claude/Codex/OpenCode/Gemini owned terminals with live working/idle status (`AgentRegistry.swift`, agent-activity via `terminal:observer-activity`).
- **ACP chat surface**: native conversational Claude/Codex over the Agent Client Protocol — streaming messages, thinking blocks, tool-call cards, live plan, usage, model picker, inline permission prompts (`Kaisola/Acp/*`: AcpClient/AcpConversation/AcpChatView). Adapters spawned via `npx @latest`. Proven end-to-end against a real spawned mock agent.
- **MCP**: per-workspace server registry producing the `session/new` mcpServers array with correct stdio/http/sse shapes, capability-filtered (`scripts/native-mcp-registry.cjs`).
- **Adapter/MCP version currency**: adapters + MCP packages resolved to latest and continuously updated (`scripts/agent-adapter-versions.cjs`, `agent-adapter-update.cjs`).
- **Terminal theming** matched to the Electron xterm palette (`TerminalTheme.swift`).
- Detached-broker **reconnect/backoff**, wake/foreground recovery (`BrokerStartupCoordinator.swift`, `BrokerReconnectBackoff.swift`).
- Distribution: Developer ID signing, notarization, stapling, Sparkle updates from a signed appcast (`NativeUpdateController.swift`, release pipeline).
- Companion **protocol + crypto** shared library (`KaisolaCore/{Protocol,Security,Domain}`) — already consumed by the iPhone app.
- Session persistence (partial): `NativeSessionStore.swift`, `TerminalCursorStore.swift`.

---

## 1. Window & workspace shell

| Feature | Status | Pri | Notes / key files |
|---|---|---|---|
| Multi-window (independent workspaces, ⌘⇧N) | DONE | P0 | each window its own AppModel + broker observer connection (`KaisolaMacAppDelegate.makeWindow`) |
| Two navigation layouts (Left tree vs Top bar), live-switchable | DONE | P0 | `NativePreviewSettings.navigationLayout`; View menu; persisted |
| Project tabs (Chrome-style, drag-reorder, rename, color, activity badges) | PARTIAL | P0 | explicit open (⌘O / "+")/rename/close persisted in `NativeSessionStore` (`OpenProject`); tabs survive with no live sessions; drag-reorder/color/activity badges still to add |
| Session tabs / dock-grid (draggable columns, split, close, pop) | PARTIAL | P0 | top-bar layout has a session strip; dock-grid/split/pop to add |
| Full macOS menu bar (App/File/Edit/View/Window/Help + accelerators) | PARTIAL | P0 | App/File/Edit/View done (New Window/Chat/Agent/Terminal, layout+appearance); Window/Help to add |
| Session groups (named, tinted, collapsible; pinned) | NEW | P1 | `SessionGroup` |
| Reopen closed session/project (⌘⇧T / ⌘⌥T, 7-day stack) | NEW | P1 | `closedStack` |
| Saved windows (persist/reopen/delete named states) | NEW | P1 | `SavedWindows.tsx` |
| Project rename / relocate / recents | PARTIAL | P1 | rename done (`AppModel.renameProject` + Rename Project sheet); relocate/recents still to add |
| Workspace rail (file tree, ⌘B) | NEW | P1 | `WorkspaceRail.tsx` |
| Command palette (⌘K/⌘P, fuzzy files + actions) | NEW | P1 | `CommandPalette.tsx` |
| Detach project to new window / adopt | NEW | P2 | renderer-to-renderer transfer; complex |
| Focus vs Studio layout mode | NEW | P2 | Studio is legacy research surface |
| OmniBar (⌘L) | NEW | P2 | `OmniBar.tsx` |
| Keymap overrides (`keymap.json`) | NEW | P2 | |
| Onboarding flow | NEW | P2 | |

## 2. Terminal features

| Feature | Status | Pri | Notes |
|---|---|---|---|
| PTY create/write/resize/kill/signal | DONE | P0 | |
| Observation (list/subscribe/diagnostics) | DONE | P0 | |
| PTY continuity across restart / detached broker | PARTIAL | P0 | broker contract done; continuity UX to port |
| Theming (dark/light/eco, tones, cursor color) | PARTIAL | P1 | terminal palette matches Electron; app-wide light/dark/system done (`NativePreviewSettings`); eco/tones/cursor to add |
| Fonts (family/size ⌘±/weight/line-height) | NEW | P1 | |
| Search in scrollback | NEW | P1 | native ⌘F wired to SwiftTerm find bar |
| Links: URLs + OSC 8 hyperlinks | NEW | P1 | (OSC 8 landed in Electron; native has the terminal find/link groundwork) |
| Rename / auto-name / prompt title | NEW | P1 | native has manual rename for owned sessions |
| Agent detection / meta (process, cwd, branch, ports, exit) | PARTIAL | P0 | native has agent id + activity; meta poller to add |
| Scroll pinning / bracketed paste / clipboard | NEW | P1 | |
| File links in output → open in editor | NEW | P2 | `terminalFileLinks.ts` |
| Browser-card on localhost dev ports | NEW | P2 | |
| Blocks / OSC 133 prompt marks | NEW | P2 | |
| CLI draft survival (retype into resumed agent) | NEW | P2 | |
| Pop-out terminal to window | NEW | P2 | |

## 3. Agent surfaces

| Feature | Status | Pri | Notes |
|---|---|---|---|
| Agent CLI sessions (prepared terminal: Claude/Codex/…) | DONE | P0 | owned terminal booting the CLI + activity status |
| ACP chat threads (structured, streaming) | DONE | P0 | `Kaisola/Acp/*`; adapter spawned via npx @latest; app-scoped session |
| Tool-call cards / artifacts | DONE | P0 | cards + rich artifacts: expandable LCS inline file diffs (red/green), text/output blocks, affected-files line; `AcpToolContent`, `AcpDiff`, `ToolCallCard`/`DiffView` |
| Thinking / thought blocks | DONE | P0 | streaming thought disclosure |
| Live plan (todo list) | DONE | P1 | ACP `plan` rendered as a checklist card |
| Context-window usage | DONE | P1 | `usage_update` shown in the chat header |
| Model selection (per-session picker) | DONE | P1 | `current_model_update` + session/set_model; effort levels still to add |
| Permissions / gates (inline allow/reject) | DONE | P0 | inline bar + standing allow-rules (workspace-scoped, wildcard, always-allow), sensitive globs that always prompt and can never be rule-covered, auto-answer of matched asks; `AcpPermissionRules`/`PermissionRuleStore` mirror `permissionRules.ts` |
| MCP servers carried into sessions | DONE | P1 | `native-mcp-registry.cjs` → session/new mcpServers |
| Adapter/MCP version currency + continuous update | DONE | P1 | `agent-adapter-versions/update.cjs`; npx @latest |
| Permission mode / autonomy dial (plan/default/acceptEdits/bypass) | NEW | P0 | |
| Steering + queued follow-ups | NEW | P1 | |
| Optimistic dispatch + rollback | NEW | P1 | |
| Turn checkpoints / restore (pre-turn git snapshot) | NEW | P1 | |
| Slash commands / available commands | NEW | P1 | |
| ACP terminals (agent-spawned, watch/take over) | NEW | P1 | |
| Kaisola Mesh (group agents: scout→contract→execute→review→integrate) | NEW | P1 | signature feature, large; worktrees |
| Transcript archive / paging | NEW | P2 | |
| @-mentions (project entities) | NEW | P2 | research-tied |
| Reasoning providers (domain research agents) | NEW | P2 | legacy |

## 4. Editor / docs / files

| Feature | Status | Pri | Notes |
|---|---|---|---|
| File tree + fuzzy search + index + watch | NEW | P1 | `fsHandler.cjs` |
| Code editor (syntax, save, dirty, cursor restore) | NEW | P1 | `CodeEditor.tsx` |
| Document preview (Markdown/HTML/CSV/JSON) | NEW | P1 (md) / P2 | `DocumentPreview.tsx` |
| Preview tabs (Zed-style transient) | NEW | P2 | |
| PDF viewer + LaTeX synctex | NEW | P2 | |
| Research/word diffs | NEW | P2 | |
| Outline / cursor follow | NEW | P2 | |
| Quote annotations | NEW | P2 | research |
| Follow-the-agent (auto-open touched files) | NEW | P2 | |
| Asset import/rename/trash/reveal | NEW | P2 | |

## 5. Settings & configuration

| Section | Status | Pri | Notes |
|---|---|---|---|
| General (theme, updates, onboarding) | NEW | P0 (theme) / P1 | |
| Guardrails (sensitive globs, permission rules, autonomy) | PARTIAL | P0 | sensitive globs + permission rules done (`AcpPermissionRules`); autonomy dial still to add |
| Terminal (font/size/weight/line-height/tone/cursor) | NEW | P1 | |
| Agents (add custom terminal/ACP, enable presets, models) | NEW | P1 | |
| Models & keys (API keys keychain, provider, base URLs) | NEW | P1 | |
| Usage (Codex/Claude/OpenCode gauges, limits) | NEW | P1 | |
| Interface (cost chips, inbox, diffs, drafts, nav, perf) | NEW | P1 | |
| Companion (pairing/devices) | NEW | P2 | |
| Extensions (languages/grammars/previews/MCP) | NEW | P2 | |
| Advanced (settings.json/keymap.json editing) | NEW | P2 | |
| Literature (OpenAlex/GROBID) | NEW | P2 | research legacy |

## 6. Providers, accounts, auth

| Feature | Status | Pri | Notes |
|---|---|---|---|
| Claude accounts (isolated CLAUDE_CONFIG_DIR, per-project) | NEW | P1 | |
| Codex accounts (isolated CODEX_HOME, per-project) | NEW | P1 | |
| Device-code sign-in card | NEW | P1 | |
| API keys (Anthropic/OpenAI keychain) | NEW | P1 | |
| MCP servers (per-workspace, add/probe/import, carried into agents) | NEW | P2 | |
| Extensions | NEW | P2 | |
| App account (Google/Firebase, for companion rendezvous) | NEW | P2 | |

## 7. Companion / mobile

Protocol + crypto already shared in `KaisolaCore`; the desktop **host** side is
what a native app would provide. All PARTIAL/P2 — the iPhone app already works
against the Electron host.

| Feature | Status | Pri |
|---|---|---|
| Pairing (QR/phrase, Noise-XX, account rendezvous) | PARTIAL | P2 |
| Projection publishing (redacted state to phone) | PARTIAL | P2 |
| Device management (list/rename/revoke, capabilities) | NEW | P2 |
| Capability tiers (observe / agent-control / terminal-control) | PARTIAL | P2 |
| Relay / transport (Bonjour LAN + Cloudflare relay) | PARTIAL | P2 |

## 8. Updates, releases, glass / visual effects

| Feature | Status | Pri | Notes |
|---|---|---|---|
| Auto-updates (Sparkle) | DONE | P1 | signed appcast, real update verified |
| Theme / dark-mode invariant (dark/light/system) | DONE | P0 | `NativePreviewSettings.appearance` drives SwiftUI colorScheme + NSApp appearance; View menu |
| Liquid Glass / vibrancy (NSGlassEffectView + fallback) | NEW | P1 | SwiftUI materials natural fit |
| Perf/energy mode (glass vs eco) | NEW | P1 | |
| Wallpaper tint sampling | NEW | P2 | |
| Window mode / traffic lights / relaunch | PARTIAL | P1 | |

## 9. Cross-cutting capabilities

| Feature | Status | Pri | Notes |
|---|---|---|---|
| Attention / notifications (dock badge, native Notification, needs-you) | NEW | P1 | |
| Cross-project inbox (one bell across tabs) | NEW | P1 | |
| Git panel (status/stage/commit/diff/log/restore) | PARTIAL | P1 | native backend service done (`scripts/native-git-service.cjs`, 11 tests); panel UI to add |
| Working-tree checkpoints (pre-turn git snapshots) | NEW | P1 | |
| Git worktree sessions (isolated checkout per agent; Mesh) | NEW | P1 | |
| Whole-app local persistence (layouts, drafts, metadata) | PARTIAL | P0 | native has session store; broaden |
| Agent task ledger | NEW | P2 | |
| Embedded browser cards | NEW | P2 | |
| LaTeX mode | NEW | P2 | |
| Workflows / automations | NEW | P2 | research legacy |
| Cost / usage chips | NEW | P2 | |
| Sandboxed experiments (mock/docker/e2b) | NEW | P2 | research legacy |
| Research pipeline (papers/citations/hypotheses/campaigns) | NEW | P2 | large legacy; likely out of scope |
| Toasts | NEW | P2 | |

---

## Suggested phase ordering

- **Phase A — shell & session spine (P0):** multi-window; project tabs; the two navigation layouts; session tabs / dock-grid; full macOS menu bar; theme (dark/light/system live); broaden persistence to whole-app state; PTY-continuity UX + terminal meta poller.
- **Phase B — agent chat depth (P0):** ACP chat UI with tool-call cards, thinking blocks, plans, streaming; permissions/guardrails + gates; model/effort/permission-mode selection; steering + queued follow-ups; optimistic dispatch/rollback.
- **Phase C — terminal polish + workspace (P1):** terminal theming/fonts/search/links/rename; file tree + search + code editor + git panel; working-tree checkpoints + worktree sessions; attention/notifications + cross-project inbox.
- **Phase D — Mesh + accounts + appearance (P1):** Kaisola Mesh; Claude/Codex accounts + device-code sign-in + API keys; usage/limits; glass/eco appearance + wallpaper tint; command palette + saved windows + reopen-closed.
- **Phase E — integrations & long tail (P2):** companion host; MCP + extensions; markdown/PDF/LaTeX preview; browser cards; ledger; workflows; OmniBar; keymap; project detach/adopt.
- **Phase F — research legacy (P2, evaluate need):** OpenAlex/GROBID/citations/provenance/hypotheses/experiments/proposals, Studio layout, research diffs/annotations, sandboxes. Confirm scope before investing.
