# Kaisola

**The research IDE that's a browser for AI agents.** Every agent is a tab:
group them, pin them, ⌘1–9 between them, ⌘L to talk to any of them — your
CLIs, your auth, your files, side by side on glass. Underneath: a Research
IDE — the "Cursor for research."

Kaisola is a workspace where AI agents help you move from a literature corpus to a
reproducible experiment draft, with a **human reviewing and steering every
transition**. The primitive is not the paper. It is the **research trajectory**:

```
corpus → claim graph → questions → hypotheses → experiments
       → runs → results → manuscript → review → revisions
```

A paper library is passive. A chat agent is amnesic. Kaisola's object is a
**persistent, auditable research process** — and two ideas make it different
from "AI notes for papers":

1. **Provenance is the moat.** Every scientific claim must link to one of:
   a citation, an experiment result, a derivation, a dataset, or a human note.
   Every artifact carries its evidence and a computed **trust** level. An
   *unsupported* claim is a modeled state the editor flags inline — not an
   oversight.

2. **Human-in-the-loop is the safety layer.** Every transition is an agent
   **Proposal** rendered as a **research diff** (old → new + reason + evidence).
   Nothing mutates the trajectory until you approve it. This is the controllable
   *research cockpit*, not "press button → publishable paper."

> This is a **Phase-0 scaffold / outline** — a working, clickable skeleton of the
> full product, seeded with a real demo project so every view is alive. It is
> meant to be iterated on. See [`docs/ROADMAP.md`](docs/ROADMAP.md).

---

## Download

Grab the latest macOS build (Apple Silicon) from
[**Releases**](https://github.com/michaelofengend/kaisola/releases) — download the
`.dmg`, drag Kaisola to Applications.

> **First launch:** the build is not notarized yet, so macOS Gatekeeper will
> object. Either **right-click the app → Open → Open**, or run
> `xattr -cr /Applications/Kaisola.app` once. Terminals, agents (bring your own
> CLIs: `claude`, `codex`, `opencode`), checkpoints, and the glass shell all
> work out of the box — keys and logins stay in your OS keychain.

Multi-window: **⌘⇧N** opens a second window with its own workspace and layout
(great for using Kaisola to work on Kaisola); the pop-out button on any terminal
card moves it to its own window.

---

## Quick start

```bash
npm install
npm run electron:dev # the desktop IDE — real terminal + live assistant
# or browse the UI only (no terminal / model):
npm run dev          # web app at http://localhost:5173
npm run smoke        # headless test: 9 views + terminal + model wiring
```

The renderer is a plain Vite + React app, so the UI runs **in a browser**;
Electron wraps the *same* build and adds the privileged capabilities behind a
locked-down preload bridge.

**Live, in the desktop app:**
- **Terminals** (bottom dock, `⌘J`) — real **node-pty** pseudo-terminals: the
  shell draws its own prompt, `cd` works, colors & interactive programs work. Open
  as many as you want with `+`.
- **Agent registry** (Zed's `agent_servers` pattern) — built-in presets for the
  main agent CLIs: **Claude Code**, **Codex**, **OpenCode**, **Gemini CLI**,
  **Qwen Code**, **Kimi**, **Amp**, **Aider**, **Goose**, **Crush**. Each runs as
  the official CLI with **your existing install and auth** — Kaisola never proxies
  a model. Add any other agent as a **custom entry** (name + command, ACP-over-stdio
  or terminal) in Settings; pick which agents live in the `+` menu.
- **Git, without leaving the window** — a **commit panel card**: browse changes,
  **stage/unstage**, review **side-by-side diffs** (HEAD vs working tree), and
  **commit** — beside the terminals that made the changes. Checkpoints keep their
  own shadow store; the panel is the only surface that touches your real index.
- **Browser cards** — a real Chromium `<webview>` as a session card. Click a
  `localhost` link in any terminal and the dev server opens **beside** it; URL
  bar, back/forward, and the **Web Inspector** included.
- **Workspace** — connecting an agent asks for a **folder** to work in (the agent's
  session cwd); shown as a chip and remembered.
- **Sign in (CLI-owned auth, the Zed way)** — each CLI owns its login. **Sign in**
  runs the CLI's login command (`codex login`, `gemini`, `claude /login`) in a real
  Kaisola **terminal** — a true TTY, so the **browser OAuth opens correctly** (the
  programmatic ACP `authenticate` can't reliably drive that). Then **Connect** —
  the ACP adapter reuses the cached credentials. Env API keys also work
  (`OPENAI_API_KEY`, `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`).
- **Claude (direct API)** — Settings has a model picker: **Fable 5 · Opus 4.8 · Opus
  4.7 · Sonnet 4.6 · Haiku 4.5**.
- **Composer controls** — the agent's own controls as dropdowns: **approval mode**
  (Read-Only / Default / Full-Access), **model**, **thinking level** (low → max),
  populated live (`session/set_mode` / `set_model` / `set_config_option`) so they
  differ per agent. The agent's **thinking** & **tool calls** are viewable inline;
  when it runs a command it opens a **live terminal tab** you can watch & take over.
- **Settings** (`⌘,`) — connect/manage multiple ACP agents, **sign in** to each,
  assign agents to tasks, and store the Anthropic key in the **OS keychain**
  (Electron `safeStorage`). **Reset** disconnects all agents & clears assignments.
- **It remembers** — your selected agent, theme, autonomy, layout, and project
  persist across launches (localStorage); `⌘K → Clear project` / Settings → Reset
  start fresh.

> Native module: the terminal uses node-pty. `npm install` runs a postinstall
> rebuild for Electron; if it's skipped, run `npm run rebuild` once.

Keys: `⌘J` terminal · `⌘K` palette · `⌘,` settings.

**Codex (default):** authenticate Codex once — `codex login` (ChatGPT) or export
`OPENAI_API_KEY` — then open the Assistant and Connect. The adapter is fetched via
`npx @zed-industries/codex-acp` (first run downloads the binary). Kaisola's ACP
`initialize` handshake is verified against the real codex-acp.
Other agents: `npm i -g @google/gemini-cli` (Gemini), Claude Code, or the mock.

---

## Bare by default

Kaisola opens **almost empty** — calm, content-forward, in the spirit of Obsidian
/ Zed / Codex. The **Corpus** is the entry point: **post a link** (arXiv, DOI,
any URL) and the Literature agent *observes* it — fetching metadata and adding
the paper. Every other stage shows a quiet empty state until there's something
to show. `⌘K → “Load demo project”` fills it with a worked example to explore;
`⌘K → “Clear project”` returns to empty.

The **left sidebar is the agent panel**: quiet stage navigation on top, then the
**Agents**, the **Review** inbox (pending changesets — opening one shows the
actual research *diff* in a centered surface, never a generic modal), and a thin
**Activity** log of decision receipts. The top bar carries the **autonomy ladder**
— Observe · Propose · Execute · Sprint (default **Propose**) — which gates what
agents may do without you.

## The nine stages

| Stage | What it is |
|---|---|
| **Corpus** | Post a link → an agent observes it. Papers/repos/datasets/notes |
| **Claim Graph** | Typed claims/methods/metrics/limitations/contradictions + relations |
| **Questions** | Open research questions, tied to hypotheses & evidence |
| **Workbench** | Ideas · Experiments · Runs in one tab — the home base. Hypotheses (novelty/feasibility), the experiment plan + **compute gate**, and the **auto lab notebook** |
| **Analysis** | Results table, figures, "real or noise?" |
| **Manuscript** | Artifact-grounded prose; per-section **trust**; unsupported claims flagged |
| **Review** | Simulated peer review, every critique tied to its evidence |

---

## Codebase map

```
electron/                 Desktop shell (CommonJS, contextIsolation on)
  main.cjs                window + lifecycle + handler registration
  preload.cjs             the ONLY bridge the renderer can touch (window.kaisola)
  ipc/modelHandler.cjs    direct Claude — claude-opus-4-8, streaming, key stays in main
  ipc/settingsHandler.cjs API key in the OS keychain (safeStorage)
  ipc/terminalHandler.cjs real terminals via node-pty
  ipc/acp.cjs             ACP client (JSON-RPC over stdio) — the Zed agent protocol
  ipc/acpHandler.cjs      agent registry + connect/prompt/stream
  ipc/toolHandler.cjs     workspace fs + runExperiment (stubbed)
  acp-mock-agent.cjs      built-in ACP agent for testing the wiring
  smoke.cjs               headless test (views + pty `cd` + ACP round-trip)

src/
  domain/types.ts         ★ the typed research trajectory + provenance (source of truth)
  domain/trust.ts         computeTrust: best-leg per claim, weakest-claim per section
  store/store.ts          Zustand store + the proposal lifecycle (approve = the only mutation)
  agents/                 typed Agent layer + mock registry (seam for the API)
  lib/                    stages, provenance resolution, formatting, bridge (web fallback),
                          observe.ts (post-a-link → fetch metadata)
  components/             Icon, TrustBadge, RiskMeter, ProvenanceChip/Popover,
                          ResearchDiff, ProposalCard, ReviewFocus, EmptyState,
                          Terminal (xterm), Assistant (live), Settings,
                          shell/* (TopBar, AgentSidebar, Dock, StatusBar, CommandPalette)
  views/                  the nine stage views
  data/                   corpus.seed.json + seed.ts (the demo trajectory)
  styles/                 tokens.css (design system) + global/components/shell/signature/views

scripts/build-seed.mjs    derives the corpus subset from ResearchPubs/data/papers.json
docs/                     SPEC.md · ARCHITECTURE.md · DESIGN.md · ROADMAP.md (the blueprint)
ResearchPubs/             the original static tracker — kept only as the data source
```

## Where the moat lives

- **`src/domain/types.ts`** — `Provenanced` is mixed into every scientific
  entity (`provenance: ProvenanceLink[]` + computed `trust`). Empty provenance
  *is* the unsupported state. Five — and only five — `ProvenanceKind`s.
- **`src/store/store.ts`** — `approveProposal()` is the single path from a
  Proposal to a trajectory mutation. Agents never touch the store; they return
  `Proposal[]`. This is the auditability chokepoint.
- **`src/components/ResearchDiff.tsx` / `ProposalCard.tsx`** — the signature UI.
- **`src/components/Provenance.tsx`** — click any evidence chip → see exactly
  what supports the claim, and jump to the source.

## The demo project (⌘K → “Load demo project”)

A complete, internally consistent trajectory — **"Time-awareness in LLM
agents"**: questions → hypotheses → the timer-ablation experiment → runs 001–003
with a real lab notebook → results → a draft manuscript with an intentionally
*unsupported* claim → simulated reviews → pending research-diff proposals. Open a
pending decision from the **Review** inbox and watch the manuscript change when
you approve it. It does not load on launch — Kaisola starts empty.

## Status & next steps

Phase 0 ships the shell + all nine views + the provenance/trust model + the
proposal/research-diff gate, with mock agents. Next: real corpus import & claim
extraction (Phase 1), Claude-backed agents producing live research diffs
(Phase 2), the execution sandbox & streamed lab notebook (Phase 3), and the
citation/trust verification layer (Phase 4). Full plan in
[`docs/ROADMAP.md`](docs/ROADMAP.md); positioning, the core loop, and anti-goals
in [`docs/SPEC.md`](docs/SPEC.md).
