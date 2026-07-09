# Six-Feature Round Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three S-tier quick wins (AGENTS.md template, numbered blank tabs, word-level diffs) and the endorsed trio (per-session $ chip, hunk-level accept/reject, cross-project inbox), all customizable via a new Settings → Interface section.

**Architecture:** Five new persisted boolean flags mirror `automationsEnabled` (store decl/default/setter + GLOBAL_KEYS + applySettings + SETTINGS_TEMPLATE). A shared hand-rolled LCS differ (`src/lib/wordDiff.ts`) powers both word-level marks (ResearchDiff) and hunk splitting (ProposalCard). A new `usage:claudeSession` IPC reuses usageHandler's JSONL walker per session id. The inbox is a pure-renderer rollup over existing signals.

**Tech Stack:** as the repo — React/zustand/plain CSS, Electron CJS main, probe-based verification (`npm run smoke`, electron/*probe.cjs pattern with isolated userData).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-09-six-features-design.md` (read first).
- NO AI attribution in commits. Every commit: `npm run build` green; smoke at tasks 3, 6, 7.
- Probes: isolated userData; scratchpad probes absolute-path repo natives; `backgroundThrottling:false` + `invalidate()` before captures; no osascript; `perl` not `sleep`.
- Flag pattern (exact anchors from the seam map): decl near `store.ts:934`, default near `:1673`, setter near `:3391`, `GLOBAL_KEYS` at `:484`, `applySettings` at `userConfig.ts:91-127`, `SETTINGS_TEMPLATE` at `:13-28`.

---

### Task 1: Flags + Settings → Interface section

**Files:** `src/store/store.ts`, `src/lib/userConfig.ts`, `src/components/Settings.tsx` (SECTIONS `:126-134`, SECTION_DESC `:137-144`, new pane block before `:770`).

- [ ] Add five booleans `wordDiffs / showCosts / inbox / draftRestore / wallpaperTint` (all default `true`) + setters, GLOBAL_KEYS entries, persistSnapshot lines (mirror `automationsEnabled` everywhere).
- [ ] userConfig: five `applySettings` lines + five commented SETTINGS_TEMPLATE lines.
- [ ] Settings: new section `{ id: 'interface', name: 'Interface', icon: <match neighbors> }` + desc; pane with five On/Off Dropdown rows (labels: "Word-level diff highlights", "Session cost chips", "Cross-project inbox", "Restore CLI drafts on restart", "Wallpaper-tinted chrome"). Row shell + Dropdown shapes exactly as `Settings.tsx:401-420`.
- [ ] Wire the two existing behaviors to their flags: `Terminal.tsx` retype arm (`armDraftRetypeRef` guard: bail unless `getState().draftRestore`) and `glassWash.ts` `apply()` (skip retint + wallpaper-img when `!wallpaperTint`; still cache screen geometry for painted mode — painted needs the image, so `wallpaperTint` OFF only pins veil COLORS to theme constants, the painted layer keeps working).
- [ ] Verify: build; quick probe — flip each flag via store, assert dataset/behavior anchor per flag (draft: arm returns early; tint: `--wash-strip-color` inline var stays unset after refresh). Commit `settings: an Interface section — five switches for the new conveniences`.

### Task 2: Quick wins

**Files:** `src/components/shell/WorkspaceRail.tsx` (`:496-553` menu, `:358-376` create pattern), `src/store/store.ts` (`newProject` `:3845`), `src/components/shell/ProjectTabs.tsx` (label uses stay as-is), new `src/lib/agentsTemplate.ts`.

- [ ] AGENTS.md: template string (name/commands/conventions/context skeleton, human-edit comments). Menu item on dir/root rows: exists(dir/AGENTS.md) ? "Open AGENTS.md" : "New AGENTS.md"; write via `bridge.fs.write` + `requestFile(..., 'edit', { pinned: true })`.
- [ ] Numbered tabs in `newProject`: when `!opts.path`, `title: blanks ? \`New Project ${blanks + 1}\` : undefined` where `blanks = projectTabs.filter(t => !t.workspacePath && !t.title).length`... note titled blanks count too — count `projectTabs.filter(t => !t.workspacePath).length`.
- [ ] Verify: probe — 3 blank tabs → labels New Project / New Project 2 / New Project 3; AGENTS.md action writes + opens pinned; second use opens existing. Commit `shell: AGENTS.md scaffolding + blank tabs learn to count`.

### Task 3: Word-level diffs

**Files:** new `src/lib/wordDiff.ts`, `src/components/ResearchDiff.tsx` (entity branch `:38-68`, patch branch `:14-36`), `src/styles/views.css` or wherever rdiff styles live (grep `rdiff-line`).

- [ ] `wordDiff.ts`: `export function diffTokens(a: string[], b: string[]): Array<{ type: 'same'|'del'|'add'; a?: [number,number]; b?: [number,number] }>` — O(nd) Myers or simple LCS DP capped (inputs > 400 tokens → bail to whole-changed). `export const words = (s: string) => s.split(/(\s+)/)` (keep separators). `export function lineHunks(before: string, after: string): Hunk[]` with `Hunk = { aStart, aLines, bStart, bLines, del: string[], add: string[] }` (shared with Task 5).
- [ ] ResearchDiff entity branch: when flag on and both before/after, render each side with `<mark className="rdiff-word">` around changed word ranges. Patch branch: within a hunk, pair i-th `-` with i-th `+`; word-mark pairs; leftovers plain. Flag off → exactly today's DOM.
- [ ] CSS: `.rdiff-word` (soft background tint per add/del side, no layout shift — `border-radius: 2px; padding: 0`).
- [ ] Verify: probe evaluates the differ via `window.__kaisolaLib` (export it there in main.tsx like other libs) on fixed cases (equal, single-word swap, add-only, 500-token bail) + DOM check: a seeded proposal change renders `mark.rdiff-word` when on, none when off. Screenshot eyeball. Smoke. Commit `diffs: changed words light up (ResearchDiff; MergeView already did)`.

### Task 4: $ cost chip

**Files:** `electron/ipc/usageHandler.cjs` (add `usage:claudeSession`), `src/lib/bridge.ts` (+ types/fallback), new `src/components/shell/CostChip.tsx`, session-card head mount point (grep `pane-head` render in `SessionCards.tsx`), `src/lib/prices.ts` (rate table).

- [ ] Main: `usage:claudeSession` — `{ configDir?, sessionId }`; walk the SAME projects/*.jsonl files but only the file(s) whose name is `<sessionId>.jsonl`; reuse dedupe; return `{ ok, models: Array<{ model, input, output, cacheRead, cacheWrite }> }`.
- [ ] `prices.ts`: per-Mtok table keyed by model-family regex (claude-fable-5 / opus / sonnet / haiku current published rates; add a comment to update with model releases), `estimate(models[]) -> { usd, known }`.
- [ ] CostChip: given a terminal record with `singletonKey === 'agent:claude-code'` and a session id from `claudeSessions`, fetch on mount + on Claude hook `Stop` events for that session (there's a hook-event subscription — grep `claude.onEvent`/agentFeed intake in App.tsx); render `~$0.42` (or `12.3k tok` when unknown model); `title` = per-model breakdown. Hidden when `!showCosts` or no data.
- [ ] Verify: probe seeds a fake `<tmp configDir>/projects/x/<sid>.jsonl` with 3 usage messages (one duplicate id to prove dedupe, two models), asserts IPC sums + chip text renders in DOM with flag on, absent with flag off. Smoke. Commit `sessions: a quiet $ chip — what this claude session actually cost`.

### Task 5: Hunk-level accept/reject

**Files:** `src/components/ProposalCard.tsx` (stub `:72-74`, actions `:68-78`), `src/store/store.ts` (`approveProposal` `:2866`, new `approveProposalPartial`), `src/domain/types.ts` (no type change needed — status `'edited'` exists), styles nearby.

- [ ] ProposalCard: for changes with `before && after && entityType !== 'file'`, compute `lineHunks(before, after)`; render hunk list with checkboxes (default checked) in an expandable "Edit" area replacing the stub button; header shows `n of m hunks`.
- [ ] Store: `approveProposalPartial(id, keep: Record<changeId, number[]>)` — derive `after'` per change (apply only kept hunks over `before`; helper `applyHunks(before, hunks, keepIdx)` in wordDiff.ts), clone proposal changes with derived `after`, run the existing `applyProposal` fold, set status `'edited'`, checkpoint + activity like `approveProposal` (reuse its body via shared internal fn — read it first and extract).
- [ ] Approve button routes: any unchecked hunk → partial path; else legacy.
- [ ] Verify: probe seeds a two-hunk update proposal (before/after fixtures), unchecks hunk 2 via DOM, approves, asserts entity text contains hunk-1 edit + NOT hunk-2 edit, status `'edited'`, checkpoint pushed. Smoke. Commit `proposals: accept the hunks you mean — Phase 2 lands`.

### Task 6: Cross-project inbox

**Files:** new `src/components/shell/InboxButton.tsx`, mount in `ProjectTabs.tsx` tools cluster (`.tabstrip-tools`), store selector helpers, styles in shell.css near `.tabstrip-tools`.

- [ ] Rollup selector (pure fn over state): active project `needsYou` keys → session rows (name via terminals/threads lookup); live `pendingPermissions` → rows; `Object.entries(projectSlices)` background `pendingPermissions` + `projectTabs` with `activity` set → rows; `bridge.ledger.list()` tasks with status review|blocked (fetch on open, not reactive). Row: `{ pid, label, detail, kind }`.
- [ ] InboxButton: hidden when count 0 or `!inbox` flag; badge count; dropdown (mirror an existing `.drop-menu` in the strip — reuse Dropdown patterns or the tab context-menu portal style); click row → `switchProject(pid)` then for active-project session rows the existing reveal action (grep how SessionTabs focuses a session — reuse).
- [ ] Verify: probe seeds `markNeedsYou` on a session + a background slice pendingPermission (write directly into projectSlices via setState) + posts a ledger task with status review; asserts badge count 3, rows render, clicking a background row switches project. Smoke. Commit `shell: one inbox for everything that needs you, across every tab`.

### Task 7: Sweep + release

- [ ] `grep -rn "wordDiffs\|showCosts\|draftRestore\|wallpaperTint" src/ | wc` sanity; all probes PASS; full smoke PASS; settings.json round-trip (write keys to the file, loadUserConfig applies).
- [ ] Release: push → `npm version patch` → commit `vX.Y.Z — …` → tag → push → gh watch → assets. Update memory (Interface flags list).
