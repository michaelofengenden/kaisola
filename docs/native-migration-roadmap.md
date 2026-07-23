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
- **Terminal theming** offers a clean macOS Terminal palette by default plus the Electron-matched Kaisola xterm palette (`TerminalTheme.swift`).
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
| Project tabs (Chrome-style, drag-reorder, rename, color, activity badges) | DONE | P0 | open/rename/close/relocate, tint colors, aggregate terminal/chat/Mesh activity, pointer drag-reorder; every chat and Mesh run is nested under its project in both nav modes |
| Session tabs / dock-grid (draggable columns, split, close, pop) | DONE | P0 | in-window splits (up to 4 panes, each its own live subscription; owned panes fully interactive), tab bar with promote/close, Open in Split context menu, pop-out to window; pointer drag-reorder of panes deferred |
| Full macOS menu bar (App/File/Edit/View/Window/Help + accelerators) | DONE | P0 | App (Settings ⌘,)/File (Open Recent, reopen ⌘⇧T/⌘⌥T)/Edit/View (layout, appearance, font ⌘±)/Window (saved layouts, NSApp.windowsMenu)/Help |
| Session groups (named, tinted, collapsible; pinned) | PARTIAL | P1 | projects are the grouping: named (rename), tinted (colorHex), collapsible (persisted); session pinning shipped v0.1.99 (Pin/Unpin, pinned-first ordering); ad-hoc cross-project groups deferred |
| Reopen closed session/project (⌘⇧T / ⌘⌥T, 7-day stack) | DONE | P1 | both stacks bounded in `NativeSessionStore`; ⌘⌥T recreates the shell/agent in the same folder |
| Saved windows (persist/reopen/delete named states) | DONE | P1 | Window ▸ Save Window Layout… / Saved Windows (open/delete); `SavedWindowsStore` (frame + active project) |
| Project rename / relocate / recents | DONE | P1 | rename sheet; Relocate… carries name+color to the new path; File ▸ Open Recent (8, deduped) |
| Workspace rail (file tree, ⌘B) | DONE | P1 | lazy tree (ignored dirs skipped), click → preview/editor; `WorkspaceRailView` |
| Command palette (⌘K/⌘P, fuzzy files + actions) | DONE | P1 | ⌘K: fuzzy actions + jump-to + project FILE search (bounded walk, TTL cache) opening the preview |
| Detach project to new window / adopt | NEW | P2 | renderer-to-renderer transfer; complex |
| Focus vs Studio layout mode | NEW | P2 | Studio is legacy research surface |
| OmniBar (⌘L) | DONE | P2 | native ⌘L overlay: message the focused agent from anywhere (connect-poll deferred delivery) |
| Keymap overrides (`keymap.json`) | NEW | P2 | |
| Onboarding flow | DONE | P2 | first-run native walkthrough; can be reopened from Help |

## 2. Terminal features

| Feature | Status | Pri | Notes |
|---|---|---|---|
| PTY create/write/resize/kill/signal | DONE | P0 | |
| Observation (list/subscribe/diagnostics) | DONE | P0 | |
| PTY continuity across restart / detached broker | DONE | P0 | broker contract + reattach-on-relaunch + selection restore; retained-tail marker in the surface |
| Theming (dark/light/eco, tones, cursor color) | DONE | P1 | app-wide light/dark/system; clean macOS Terminal palette is default, Electron-matched Kaisola palette remains selectable and both live-switch with appearance |
| Fonts (family/size ⌘±/weight/line-height) | PARTIAL | P1 | size ⌘+/⌘−/⌘0 + family/weight pickers persisted (v0.1.99); line-height deferred |
| Search in scrollback | DONE | P1 | SwiftTerm ⌘F find bar (Edit ▸ Find) |
| Links: URLs + OSC 8 hyperlinks | DONE | P1 | implicit link detection + OSC 8; http(s) → browser, file:// → reveal in Finder |
| Rename / auto-name / prompt title | PARTIAL | P1 | manual rename + agent·folder auto-name + live OSC title auto-tracking until manually renamed (v0.1.99) |
| Agent detection / meta (process, cwd, branch, ports, exit) | PARTIAL | P0 | agent id + live activity + exit + git-branch + foreground process + listening ports on rows (TTL scans, v0.1.99) |
| Scroll pinning / bracketed paste / clipboard | DONE | P1 | deliberate-scroll follow intent, SwiftTerm bracketed-mode replay, native selection/copy/paste |
| File links in output → open in editor | DONE | P2 | OSC 8 and path citations open the confined file preview at the cited line; ⇧⌘O opens externally |
| Browser-card on localhost dev ports | DONE | P2 | confined WKWebView card; localhost links from terminals/chats open it (v0.1.99) |
| Blocks / OSC 133 prompt marks | NEW | P2 | |
| CLI draft survival (retype into resumed agent) | NEW | P2 | |
| Pop-out terminal to window | DONE | P2 | session context menu opens an independent native window on the same durable PTY |

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
| Permission mode / autonomy dial (plan/default/acceptEdits/bypass) | DONE | P0 | native ACP session modes: header picker → `session/set_mode`, `current_mode_update` handled, `SessionModeState` parsed from session/new (also fixed models parse to accept the nested `{availableModels,currentModelId}` shape real adapters use) |
| Steering + queued follow-ups | DONE | P1 | queue chips + Steer (bolt): promote to front + interrupt the running turn; drains in order |
| Optimistic dispatch + rollback | DONE | P1 | failed sends stay visible marked red with Retry (re-dispatch or queue) |
| Turn checkpoints / restore (pre-turn git snapshot) | DONE | P1 | git stash create/store before each turn (clean-tree skip); header clock menu restores with confirm |
| Slash commands / available commands | DONE | P1 | available_commands_update → '/' fuzzy autocomplete in the composer |
| ACP terminals (agent-spawned, watch/take over) | DONE | P1 | `AcpTerminalHost`: terminal/create…release answered, bounded live output rendered in tool cards; take-over n/a (app-scoped processes) |
| Kaisola Mesh (group agents: scout→contract→execute→review→integrate) | DONE | P1 | project-scoped fan-out, isolated worktrees, flat/staged/idea modes, role chips, diff review, summaries, and one-click Integrate (`git apply --3way`) |
| Transcript archive / paging | DONE | P2 | windowed transcript (120 rows + Show earlier), per-chat drafts persisted (v0.1.99) |
| @-mentions (project entities) | NEW | P2 | research-tied |
| Reasoning providers (domain research agents) | NEW | P2 | legacy |

## 4. Editor / docs / files

| Feature | Status | Pri | Notes |
|---|---|---|---|
| File tree + fuzzy search + index + watch | PARTIAL | P1 | rail tree + palette fuzzy index + live FSEvents watching (debounced auto-refresh, v0.1.99) |
| Code editor (syntax, save, dirty, cursor restore) | PARTIAL | P1 | editor: ⌘S save, revert, dirty dot + native regex syntax highlighting with read/edit toggle (v0.1.99); rich editing still arrives via the WKWebView phase |
| Document preview (Markdown/HTML/CSV/JSON) | PARTIAL | P1 (md) / P2 | markdown styled + Source toggle; images; CSV/TSV tables, JSON tree, confined JS-off HTML preview (v0.1.99) |
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
| General (theme, updates, onboarding) | DONE | P0 (theme) / P1 | Settings ⌘, General tab: layout, appearance, Glass/Solid sidebar, System/Glass/Tinted workspace backdrop, notifications, external editor, updates; first-run onboarding |
| Guardrails (sensitive globs, permission rules, autonomy) | DONE | P0 | sensitive globs + permission rules (`AcpPermissionRules`) + ACP session-mode picker (plan/default/acceptEdits/bypass) |
| Terminal (font/size/weight/line-height/tone/cursor) | PARTIAL | P1 | font-size slider + family/weight and macOS Terminal/Kaisola palette pickers; line-height remains deferred |
| Agents (add custom terminal/ACP, enable presets, models) | PARTIAL | P1 | adapter roster + account isolation (app-wide AND per-project) + custom agent registration + device-code sign-in card (v0.1.99) |
| Models & keys (API keys keychain, provider, base URLs) | PARTIAL | P1 | Anthropic/OpenAI keys in the login keychain, injected into agent env (v0.1.99); provider/base-URL config deferred |
| Usage (Codex/Claude/OpenCode gauges, limits) | PARTIAL | P1 | per-chat context usage + session-wide usage center (per-chat gauges, turn counts, Settings tab + footer chip, v0.1.99) |
| Interface (cost chips, inbox, diffs, drafts, nav, perf) | PARTIAL | P1 | inbox (bell + dock badge + native notifications), word-level diffs with unified/split toggle, drafts, toasts, nav layouts (v0.1.99); cost chips deferred |
| Companion (pairing/devices) | NEW | P2 | |
| Extensions (languages/grammars/previews/MCP) | NEW | P2 | |
| Advanced (settings.json/keymap.json editing) | NEW | P2 | |
| Literature (OpenAlex/GROBID) | NEW | P2 | research legacy |

## 6. Providers, accounts, auth

| Feature | Status | Pri | Notes |
|---|---|---|---|
| Claude accounts (isolated CLAUDE_CONFIG_DIR, per-project) | PARTIAL | P1 | app-wide override + per-project scoping (project wins per key; plain shells carry the env too, v0.1.99) |
| Codex accounts (isolated CODEX_HOME, per-project) | PARTIAL | P1 | app-wide override + per-project scoping (project wins per key; plain shells carry the env too, v0.1.99) |
| Device-code sign-in card | DONE | P1 | one-click command card launches sign-in in a project/account-scoped native terminal |
| API keys (Anthropic/OpenAI keychain) | DONE | P1 | data-protection keychain store, Settings tab, env injection (v0.1.99) |
| MCP servers (per-workspace, add/probe/import, carried into agents) | PARTIAL | P2 | per-workspace registry in Settings, exact Electron wire shapes, carried into chats+Mesh (v0.1.99); probe/import deferred |
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
| Liquid Glass / vibrancy (NSGlassEffectView + fallback) | DONE | P1 | persisted Glass/Solid project sidebar and file rail, selectable Glass workspace backdrop, opaque terminal contrast surface |
| Perf/energy mode (glass vs eco) | PARTIAL | P1 | n/a natively at preview scale — no web renderer to throttle; revisit if profiling says otherwise |
| Wallpaper tint sampling | NEW | P2 | |
| Window mode / traffic lights / relaunch | PARTIAL | P1 | |

## 9. Cross-cutting capabilities

| Feature | Status | Pri | Notes |
|---|---|---|---|
| Attention / notifications (dock badge, native Notification, needs-you) | DONE | P1 | `AttentionCenter`: permission asks + finished turns + responded sessions land as inbox entries; dock badge; bell popover jumps + clears |
| Cross-project inbox (one bell across tabs) | DONE | P1 | one AttentionCenter across every project/window; footer bell popover |
| Git panel (status/stage/commit/diff/log/restore) | DONE | P1 | panel: status/stage/unstage/commit + inline tinted diffs + history + confirmed Discard (git restore) |
| Working-tree checkpoints (pre-turn git snapshots) | DONE | P1 | per-turn stash snapshots + restore (chat header) |
| Git worktree sessions (isolated checkout per agent; Mesh) | DONE | P1 | Mesh columns each get a kaisola-mesh-* worktree; namespace-guarded cleanup |
| Whole-app local persistence (layouts, drafts, metadata) | DONE | P0 | layout/appearance/sidebar/backdrop/terminal palette/font/rail/globs/accounts (UserDefaults), projects/colors/order/recents/closed-stacks/selection (`NativeSessionStore`), saved windows, window frames |
| Agent task ledger | NEW | P2 | |
| Embedded browser cards | DONE | P2 | `BrowserCardView` confined WKWebView (v0.1.99) |
| LaTeX mode | NEW | P2 | |
| Workflows / automations | NEW | P2 | research legacy |
| Cost / usage chips | NEW | P2 | |
| Sandboxed experiments (mock/docker/e2b) | NEW | P2 | research legacy |
| Research pipeline (papers/citations/hypotheses/campaigns) | NEW | P2 | large legacy; likely out of scope |
| Toasts | DONE | P2 | `ToastCenter` + overlay: saves, checkpoint restores, PR results, attachment rejections (v0.1.99) |

---

## Suggested phase ordering

**Status 2026-07-23 (v0.1.99): Phases A–E are substantively COMPLETE in the native preview.** The v0.1.99 parity campaign (25 subagents across three waves) closed every previously named deferral — pointer drag-reorder, staged Mesh pipeline + idea mode, per-project account scoping, FS watching, syntax highlighting (native interim), device-code sign-in card, API-key keychain, MCP settings, onboarding, OmniBar, browser cards, transcript paging + drafts, session pinning, usage center, native notifications, toasts, font family/weight, live titles, process/ports meta — and added prompt attachments (files + images as real ACP blocks), word-level diffs with a unified/split toggle, one-click Commit→Push→Create-PR, per-project Quick Actions, custom agent registration, Shift+Enter newline, ⇧⌘O open-in-external-editor, and an AGENTS.md scaffold. Remaining: the WKHTML rich-editing phase, provider/base-URL config, MCP probe/import, pane pointer-drag, cost chips, CLI draft retype, and the Phase F research legacy (scope unconfirmed).

- **Phase A — shell & session spine (P0):** multi-window; project tabs; the two navigation layouts; session tabs / dock-grid; full macOS menu bar; theme (dark/light/system live); broaden persistence to whole-app state; PTY-continuity UX + terminal meta poller.
- **Phase B — agent chat depth (P0):** ACP chat UI with tool-call cards, thinking blocks, plans, streaming; permissions/guardrails + gates; model/effort/permission-mode selection; steering + queued follow-ups; optimistic dispatch/rollback.
- **Phase C — terminal polish + workspace (P1):** terminal theming/fonts/search/links/rename; file tree + search + code editor + git panel; working-tree checkpoints + worktree sessions; attention/notifications + cross-project inbox.
- **Phase D — Mesh + accounts + appearance (P1):** Kaisola Mesh; Claude/Codex accounts + device-code sign-in + API keys; usage/limits; glass/eco appearance + wallpaper tint; command palette + saved windows + reopen-closed.
- **Phase E — integrations & long tail (P2):** companion host; MCP + extensions; markdown/PDF/LaTeX preview; browser cards; ledger; workflows; OmniBar; keymap; project detach/adopt.
- **Phase F — research legacy (P2, evaluate need):** OpenAlex/GROBID/citations/provenance/hypotheses/experiments/proposals, Studio layout, research diffs/annotations, sandboxes. Confirm scope before investing.
