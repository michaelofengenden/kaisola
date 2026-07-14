# Kaisola experience audit — July 14, 2026

This document is the implementation contract for the `0.1.66` experience pass. It combines a live audit of the current Electron app with current primary-source guidance from OpenAI, Apple, VS Code, Zed, and GitHub.

## What is already strong

- The full smoke suite passes: terminal continuity, persisted viewport and drafts, prompt queue draining, mid-turn steering, permission rules, sensitive-action gates, model changes, and SQLite restoration.
- The session rail already keeps one stable project/thread hierarchy, supports pinning and groups, and hibernates hidden renderers instead of retaining every xterm and transcript.
- Native Liquid Glass is confined to window chrome. The final paired two-round measurement showed Live Glass at 476.9 MiB versus Eco at 476.25 MiB: a 0.7 MiB / 0.1% delta.
- Mesh already has the hard safety mechanics: independent scouting, bounded negotiation, explicit role contracts, isolated worktrees, cross-review, integration ownership, recovery journals, and timestamp-based stage boundaries.

## Confirmed pre-change failures

1. Creating any session appends another visible column. Four ordinary sessions already squeeze the content; a terminal, Mesh, and Files canvas make Mesh narrow enough to wrap one or two words per line.
2. Mesh exposes its correct protocol as a stack of dashboard cards and approval buttons. It reads like a control form rather than a fast group conversation.
3. The group probe completes the full worktree pipeline but fails its final archive/delete lifecycle assertions. This must be green before release.
4. Settings has a good information architecture but no search, large unused areas, weak appearance previews, and too many layout variants presented with equal weight.
5. Screenshot and memory harnesses omit a few production IPC handlers (`shell:window-mode`, `window:popped`, and `assistant-archive:info`), adding noise and leaving those paths under-tested.
6. The website explains mechanisms before giving the product a clear, restrained identity. Its translucent gradients and dense feature inventory compete with the product screenshot.

## Current-source synthesis

- OpenAI describes the Codex app as a project-organized command center for parallel threads, with steering, progress state near the composer, worktrees, and in-thread review. Kaisola should keep background sessions visible in the hierarchy while focusing one readable conversation by default. ([Codex app](https://openai.com/index/introducing-the-codex-app/), [working with Codex](https://openai.com/academy/working-with-codex/), [Codex settings](https://openai.com/academy/codex-settings/))
- VS Code separates tabs from editor groups: opening an item does not imply creating a split, while pinning, overflow, scrolling, and explicit groups handle high counts. ([VS Code user interface](https://code.visualstudio.com/docs/editing/userinterface))
- Zed separates agentic and classic layouts and makes settings searchable. Kaisola should expose one calm default and keep secondary layout controls discoverable without making six variants the first decision. ([Zed docs](https://zed.dev/docs/), [agent settings](https://zed.dev/docs/ai/agent-settings))
- Apple recommends materials sparingly on navigation and controls, adapting sidebars and split views across widths, keeping status beside the affected object, and limiting settings to stable preferences. It also says to respect reduced transparency and increased contrast. ([Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [split views](https://developer.apple.com/design/human-interface-guidelines/split-views), [settings](https://developer.apple.com/design/human-interface-guidelines/settings), [feedback](https://developer.apple.com/design/human-interface-guidelines/feedback))
- GitHub's agent-session UI treats simultaneous sessions as isolated jobs with live state, logs, steering, stop, and archive controls. Status belongs on each participant or thread, not only in a global banner. ([Agent sessions](https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/github-copilot-app/agent-sessions), [manage and track agents](https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/copilot-on-github/use-copilot-agents/manage-and-track-agents))
- Messages uses inline conversational structure to preserve context in group threads. Mesh should borrow grouping, participant presence, stage dividers, and system receipts without pretending agents are people. ([Reply inline in Messages](https://support.apple.com/en-ng/guide/messages/icht4a6d29fb/mac))

## Interaction contract

### Sessions and panels

- New thread, terminal, browser, or Mesh: create it and focus it in the primary card.
- Split: only an explicit Split action adds a simultaneous column. Existing intentional splits survive focus changes.
- High counts: all sessions remain in a scrollable/searchable rail; only visible cards mount full renderers. Active and attention states remain adjacent to their session names.
- Width pressure: protect a readable primary card before preserving secondary chrome. Collapse optional navigation before compressing content below its usable minimum.
- Resizers: pointer capture, keyboard arrows, Home reset, visible focus, and clamped minimums. Double-click restores the balanced default.

### Mesh

- Name the surface **Mesh**. Provider names remain participant labels, not part of the product name or composer placeholder.
- Present the run as a single conversation timeline: mission bubble, stage dividers, participant messages, compact status, role-contract receipt, execution receipts, review messages, and final integration receipt.
- Keep the safety protocol. Scouting and role comparison may flow automatically; worktree creation and integration remain explicit gates because they mutate the repository.
- Optimize the default for two to four agents and remain legible at the minimum supported card width. Never use side-by-side response cards inside a narrow panel.
- Pause/stop is local, durable, and shown beside the current stage. Recovery actions describe exactly what they retry.

### Settings

- Stable left navigation, remembered pane, and global search.
- Appearance choices are visual: System/Light/Dark and Live Glass/Eco. Live Glass is the native chrome treatment; Eco is the lowest-memory static treatment.
- Keep task-specific panel actions beside the workspace, not buried in Settings. Advanced layout variants remain compatible but visually subordinate to the recommended default.
- Every setting row has a useful label, supporting sentence when needed, predictable control alignment, and strong keyboard focus.

### Glass and memory

- One native sampling layer for window chrome. Content cards remain opaque or paint-contained.
- No stacked `backdrop-filter` on scrolling or streaming surfaces.
- Reduced-transparency/high-contrast environments receive solid chrome and stronger separators.
- Release gate: Live Glass overhead stays below 5% in the paired probe; hidden-session residency stays bounded as session count grows.

## Red-team matrix

- 1, 4, 12, and 30 sessions; long duplicate names; pinned and grouped sessions; running, needs-attention, and completed states.
- 1, 2, 3, and 5 explicit panes, bounded to at most two columns; 820, 1080, 1180, 1440, and 1560 px windows; sidebar shown/hidden; Files rail shown/hidden.
- Mesh with 2, 4, and 6 participants; long model names; a 5,000-character mission; long Markdown responses; permissions; pause/restart; one failure; archive/delete after completion.
- Project tabs beyond viewport capacity; active tab retained through overflow; keyboard-only navigation; 200% text zoom; reduced motion; increased contrast.
- Settings search with zero, one, and many matches; narrow window; every theme/performance combination.
- Live/Eco paired memory rounds, full smoke, layout matrix, group lifecycle, build/typecheck, and visual screenshot review.

## Release gates

1. No automatic pane multiplication.
2. Mesh is readable at the minimum card width and the full lifecycle probe passes, including archive/delete teardown ordering.
3. Full smoke and layout probes remain green.
4. Live Glass overhead remains under 5%, with no blur layer on streaming content.
5. Website screenshots and copy describe the shipped `0.1.66` behavior.
6. Published Git refs contain no Claude/Anthropic author, committer, or co-author attribution.

## Final verification

- Production build and typecheck pass. The Node suite passes all 126 tests; the two localhost wire-boundary cases were rerun outside the restricted command sandbox because binding `127.0.0.1` is intentionally denied inside it.
- The full Electron smoke suite passes, including terminal continuity, viewport/draft persistence, permissions, prompt queues, project moves, panels, worktrees, settings, and the focus-versus-split contract.
- The layout matrix passes at wide, medium, compact, and across-top sizes. The visual matrix captures 44 states, including 30 sessions with search, five explicit panes in two columns, and six long-form Mesh participants in one conversational stream.
- Mesh passes both manual and Fluid progression. The final Fluid run covered stop, persisted reload, selective resume, parked-adapter reconnect, role negotiation, double-activation protection, two isolated worktrees, automatic cross-review, explicit integration, cleanup, close/reopen, permanent delete during a project switch, archive clearing, and exact cancel → close → disconnect teardown.
- The website passes desktop light, desktop dark, Mesh-section, and mobile probes with no overflow, backdrop blur, language curtain, broken imagery, or hidden primary CTA.
- Live Glass measured 476.9 MiB against Eco at 476.25 MiB in two paired rounds (0.7 MiB / 0.1%). Test-only brokers now self-terminate after an abrupt harness exit; the continuity probe proves production brokers still preserve sessions across UI restarts.
- GitHub's live contributor endpoint lists only `michaelofengenden`. The current published branch and tags contain no Claude/Anthropic author, committer, or co-author attribution.
