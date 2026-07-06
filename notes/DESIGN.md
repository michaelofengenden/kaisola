## Kaisola Design System (final)

Dark-first, minimalist, one restrained accent (olive `#8a9658`). Cursor / Linear / Raycast caliber. Provenance-forward: trust gets its own color ramp so a "verified" badge never reads as a generic success toast. Borders over shadows; motion budget 90-220ms with one 380ms exception for decisions (approve, gate-advance). All tokens are CSS custom properties (no Tailwind) and already live at `/Users/michaelofengenden/Documents/Kaisola/src/styles/tokens.css`.

### 1. Design tokens (full `:root` block — source of truth)

```css
:root,
:root[data-theme='dark'] {
  /* Background layers (deepest → highest) */
  --bg-0: #0a0b0d;   /* app frame */
  --bg-1: #0e1014;   /* main canvas */
  --bg-2: #14161c;   /* panels, rails */
  --bg-3: #1a1d25;   /* cards, inputs */
  --bg-4: #21252f;   /* hover / raised */
  --bg-inset: #07080a;/* code blocks, wells, notebook stream */

  /* Surfaces & borders */
  --surface: #14161c; --surface-hover: #1a1d25;
  --border: #23262f; --border-strong: #2f3340; --border-faint: #181b22;

  /* Text tiers */
  --text-0: #f3f4f6; --text-1: #c4c8d2; --text-2: #8b909d; --text-3: #5a5f6b;
  --text-on-accent: #ffffff;

  /* Accent — single, restrained olive */
  --accent: #8a9658; --accent-hover: #9aa866; --accent-press: #748046;
  --accent-soft: rgba(138,150,88,0.15); --accent-line: rgba(138,150,88,0.36);
  --accent-glow: rgba(138,150,88,0.26);

  /* Semantic */
  --success: #54c08a; --success-soft: rgba(84,192,138,0.14);
  --warn: #d8a44a;    --warn-soft: rgba(216,164,74,0.14);
  --danger: #e16a6a;  --danger-soft: rgba(225,106,106,0.14);
  --info: #5aa9e6;    --info-soft: rgba(90,169,230,0.14);

  /* Trust scale — first-class, own ramp (maps 1:1 to TrustLevel) */
  --trust-high: #54c08a;        --trust-high-soft: rgba(84,192,138,0.13);
  --trust-medium: #d8a44a;      --trust-medium-soft: rgba(216,164,74,0.13);
  --trust-low: #d77f4a;         --trust-low-soft: rgba(215,127,74,0.13);
  --trust-unsupported: #e16a6a; --trust-unsupported-soft: rgba(225,106,106,0.13);

  /* Diff coloring (research diff + code) — derived from semantic */
  --diff-add-bg: rgba(84,192,138,0.10);  --diff-add-text: #8fe0b6; --diff-add-gutter: rgba(84,192,138,0.45);
  --diff-del-bg: rgba(225,106,106,0.10); --diff-del-text: #f0a8a8; --diff-del-gutter: rgba(225,106,106,0.45);

  /* Agent identity tints (10 agents; desaturated so multiple agents ≠ rainbow) */
  --agent-literature: #5aa9e6; --agent-novelty: #a88752; --agent-hypothesis: #8a9658;
  --agent-planning: #5ec5c0;   --agent-coding: #82b366;  --agent-execution: #d8a44a;
  --agent-analysis: #e6915a;   --agent-writing: #e07aaa; --agent-reviewer: #e16a6a;
  --agent-citation: #54c08a;

  /* Typography */
  --font-ui: 'Inter', system-ui, -apple-system, 'Segoe UI', sans-serif;
  --font-serif: 'Source Serif 4', Georgia, 'Times New Roman', serif; /* manuscript reading only */
  --font-mono: 'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, monospace; /* ids, metrics, logs, time */
  --fs-9:9px; --fs-10:10px; --fs-11:11px; --fs-12:12px; --fs-13:13px; --fs-14:14px;
  --fs-15:15px; --fs-16:16px; --fs-18:18px; --fs-21:21px; --fs-24:24px; --fs-30:30px;
  --fw-regular:400; --fw-medium:500; --fw-semibold:600; --fw-bold:700;
  --lh-tight:1.2; --lh-snug:1.4; --lh-normal:1.55; --lh-relaxed:1.7;
  --tracking-tight:-0.01em; --tracking-wide:0.02em; --tracking-caps:0.06em;

  /* Spacing (4px base) */
  --sp-0:0; --sp-1:2px; --sp-2:4px; --sp-3:6px; --sp-4:8px; --sp-5:12px;
  --sp-6:16px; --sp-7:20px; --sp-8:24px; --sp-9:32px; --sp-10:40px; --sp-11:56px; --sp-12:72px;

  /* Radii */
  --r-1:4px; --r-2:6px; --r-3:8px; --r-4:10px; --r-5:14px; --r-full:999px;

  /* Shadows (subtle — depth from layering, not heavy drop shadows) */
  --shadow-1:0 1px 2px rgba(0,0,0,0.3); --shadow-2:0 4px 12px rgba(0,0,0,0.35);
  --shadow-3:0 12px 32px rgba(0,0,0,0.45); --shadow-pop:0 16px 48px rgba(0,0,0,0.55);
  --ring-accent:0 0 0 1px var(--accent-line), 0 0 0 4px var(--accent-soft);

  /* Motion — fast, confident. dur-4 reserved for DECISIONS (approve, gate-advance) */
  --ease-out: cubic-bezier(0.16,1,0.3,1); --ease-in-out: cubic-bezier(0.65,0,0.35,1);
  --ease-spring: cubic-bezier(0.34,1.56,0.64,1); /* meters only, sparingly */
  --dur-1:90ms; --dur-2:140ms; --dur-3:220ms; --dur-4:380ms;

  /* Layout */
  --rail-w:60px; --sidebar-w:244px; --inspector-w:340px; --topbar-h:44px; --statusbar-h:28px;

  /* Z-index */
  --z-base:1; --z-sticky:50; --z-rail:100; --z-inspector:110;
  --z-popover:500; --z-palette:800; --z-toast:900;
}

:root[data-theme='light'] {
  --bg-0:#f4f5f7; --bg-1:#fbfbfc; --bg-2:#f3f4f6; --bg-3:#ffffff; --bg-4:#eef0f3; --bg-inset:#f1f2f4;
  --surface:#ffffff; --surface-hover:#f3f4f6; --border:#e4e6eb; --border-strong:#d3d6dd; --border-faint:#eef0f3;
  --text-0:#16181d; --text-1:#3b3f48; --text-2:#6b7080; --text-3:#9aa0ad; --text-on-accent:#ffffff;
  --accent:#66743d; --accent-hover:#596735; --accent-press:#4d5b2e;
  --accent-soft:rgba(102,116,61,0.11); --accent-line:rgba(102,116,61,0.34); --accent-glow:rgba(102,116,61,0.22);
  --success:#2f9e6b; --warn:#b9842a; --danger:#cf4f4f; --info:#2f86c9;
  --trust-high:#2f9e6b; --trust-high-soft:rgba(47,158,107,0.12);
  --trust-medium:#b9842a; --trust-medium-soft:rgba(185,132,42,0.12);
  --trust-low:#c46a2a; --trust-low-soft:rgba(196,106,42,0.12);
  --trust-unsupported:#cf4f4f; --trust-unsupported-soft:rgba(207,79,79,0.12);
  --shadow-1:0 1px 2px rgba(16,18,22,0.06); --shadow-2:0 4px 12px rgba(16,18,22,0.08);
  --shadow-3:0 12px 32px rgba(16,18,22,0.12); --shadow-pop:0 16px 48px rgba(16,18,22,0.16);
}

/* Manuscript reading surface — serif, generous line-height. */
.reading-surface { font-family: var(--font-serif); font-size: var(--fs-16);
  line-height: var(--lh-relaxed); color: var(--text-0); font-feature-settings: "liga" 1, "onum" 1; }
```

### 2. Overall layout — the shell

Five regions. The **trajectory rail is the spine** (9 stages, always visible, collapsible 60px ↔ 244px). The right inspector is context-sensitive (Proposals / Provenance / Agents). The bottom strip is the live Auto Lab Notebook + run status. The command palette (⌘K) floats above everything.

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ◫ Kaisola   Time-awareness in LLM agents ▾    ⌘K Search/Run…     ◷ 2 runs  ◐ ⚙ ⊙        │ TOP BAR 44px (drag region)
├────┬─────────────────────────────────────────────────────────────────┬─────────────────┤
│ ┃● 1│  STAGE HEADER  03 · Hypotheses    Trust ◐ medium   3 proposals  │  INSPECTOR 340px │
│ ┃● 2│ ──────────────────────────────────────────────────────────────  │  [Proposals]     │
│ ┃◉ 3│                                                                  │  [Provenance]    │
│ ╎○ 4│   MAIN CANVAS — current stage view                              │  [Agents]        │
│ ╎○ 5│   (claim graph / idea cards / diff stream / IDE / editor)       │                  │
│ ╎○ 6│                                                                  │  context-        │
│ ╎○ 7│                                                                  │  sensitive       │
│ ╎○ 8│                                                                  │  (resizable,     │
│ ╎○ 9│                                                                  │   collapsible)   │
│  52 │                                                                  │                  │
├────┴─────────────────────────────────────────────────────────────────┴─────────────────┤
│ ◷ NOTEBOOK  12:50 reran timer-prompt eval 34%→49%  ·  11:05 fixed tokenizer  ▸ expand   │ STATUS/NOTEBOOK 28px → 40vh
└──────────────────────────────────────────────────────────────────────────────────────┘
```

| Region | Size | Notes |
|---|---|---|
| Top bar | `--topbar-h` 44px | Project switcher, centered ⌘K field, run counter, theme toggle, settings. `-webkit-app-region: drag` except controls. `--bg-0`, bottom `--border-faint`. |
| Trajectory rail | `--rail-w` 60px ↔ `--sidebar-w` 244px | 9 stages numbered; each shows status glyph (done ●, active ◉, locked ○), a 2px trust spine on its left edge, an open-proposal count badge. Bottom: corpus size. `--z-rail`. |
| Main canvas | flex, `--bg-1` | Sticky stage header (no., name, aggregate trust, proposal count). Crossfade+slide on stage change (`--dur-3`). |
| Inspector | `--inspector-w` 340px, resizable, collapsible | Tabs: Proposals (diff queue) / Provenance (evidence for selection) / Agents (activity feed). `--z-inspector`. |
| Status / notebook | `--statusbar-h` 28px → 40vh drawer | Latest notebook line + run dots; `▸ expand` slides up the full stream. `--z-sticky`. |
| Command palette | 560px centered modal | ⌘K fuzzy actions/stage-jumps/agent-triggers/paper-search. `--z-palette`, blur scrim. |

### 3. Signature components

#### (a) Research Diff Card — the hero primitive (`components/signature/ResearchDiff.tsx` + `ProposalCard.tsx`)
Agent proposes a `Proposal`; human approves/edits/rejects. Renders `ProposalChange.before/after` as a diff and the `ProposalRationale` fields.

```
┌─────────────────────────────────────────────────────────────────┐
│ ◧ Hypothesis Agent · proposes · 2m ago            ◐ medium trust │ header: agent hue, type, time, trust
├─────────────────────────────────────────────────────────────────┤
│ Revise claim: time-awareness vs task budget                     │ ProposalChange.label
│ ┌─ was ───────────────────────────────────────────────────────┐ │
│ │ − Agents cannot track elapsed wall-clock time during tool use│ │ before  (--diff-del-*)
│ └──────────────────────────────────────────────────────────────┘│
│ ┌─ now ───────────────────────────────────────────────────────┐ │
│ │ + Agents do not spontaneously track elapsed time, but can    │ │ after   (--diff-add-*)
│ │   infer it from tool-call latency when prompted.            │ │
│ └──────────────────────────────────────────────────────────────┘│
│ Why  Latency is observable; weaker claim, matches Sato '24 §4.2.│ rationale.why
│ Evidence  📄 Sato 2024 §4.2 ▸   🧪 run #18 +15pp ▸              │ evidence chips → provenance popover
│ Fails if  models ignore latency under load — see ablation A3.   │ rationale.failureConditions
│ ┌──────────┐ ┌────────┐ ┌────────┐            ⌥ view full diff  │
│ │ ✓ Approve│ │ ✎ Edit │ │ ✕ Reject│                            │ actions (A / E / R accelerators)
│ └──────────┘ └────────┘ └────────┘                            │
└─────────────────────────────────────────────────────────────────┘
```
States: pending (border `--border`, left accent bar in agent hue) · hover (`--surface-hover`, `--shadow-1`, actions to full opacity from 0.85) · focused (`--ring-accent`; A/E/R keys) · editing (the "now" block becomes an editable `--bg-inset` field, Approve → "Approve edited") · approved (`--dur-4` collapse: "was" strikes through + fades, "now" flashes `--success-soft`, card shrinks out, leaves a notebook receipt) · rejected (desaturate + inline "Rejected — reason?", `--danger`-tinted receipt) · stale (amber top stripe "Source changed — re-run agent", Approve disabled). Enter: slide-in `translateY(8px)+opacity` `--dur-3`. CSS: `.diff-block--del{background:var(--diff-del-bg);color:var(--diff-del-text);box-shadow:inset 2px 0 0 var(--diff-del-gutter)}` and `--add` analog; font `--font-mono` `--fs-13`.

#### (b) Provenance Popover (`components/signature/ProvenanceChip.tsx` + popover)
Opens on click of any evidence chip, trust badge, or inline Unsupported marker. The moat made visible. Variant per `ProvenanceKind`.

```
   claim text… ┄┄ [📄 supports ▾]
   ┌──────────────────────────────────────────┐
   │ PROVENANCE                      ◐ medium  │ this link's trust
   │ 📄 CITATION                               │ kind row (icon + agent/accent stripe)
   │ Sato et al. 2024 — "Implicit timing…"     │
   │ ┌────────────────────────────────────┐    │
   │ │ "…latency between tool calls was a │    │ exact quote span (serif, --accent-soft bg)
   │ │  reliable proxy for elapsed time." │    │
   │ └────────────────────────────────────┘    │
   │ §4.2 · p.7 · arXiv:2407.xxxxx · DOI ✓     │ locator + verification.status
   │ Links to: claim c-12 · run #18            │ graph backlinks
   │  Open paper ↗   Copy citation   Unlink ✕  │
   └──────────────────────────────────────────┘
```
Variants: `📄 citation` FileText (quote + DOI verify), `🧪 result` FlaskConical (run id, metric, seeds, log link), `∑ derivation` Sigma (steps), `▦ dataset` Database (license badge, split), `✎ note` PenLine (author, "authored by you"). States: loading (shimmer quote lines) · verified (✓ `--trust-high`) · unverified (? `--warn`) · failed (✕ `--danger`, "source not found / DOI failed"). For an `unsupported` claim the popover flips to an action prompt: "No evidence linked. → Attach citation · Attach result · Mark speculative." Motion: scale `0.96→1`+opacity `--dur-2`, origin at the 6px arrow (flips above/below). `.provenance-pop{background:var(--bg-3);box-shadow:var(--shadow-pop);border:1px solid var(--border);border-left:2px solid var(--trust-medium);width:320px;z-index:var(--z-popover)}`.

#### (c) Trust Score Badge + Unsupported Flag (`components/signature/TrustScoreBadge.tsx` + `UnsupportedFlag.tsx`)
Maps to `TrustLevel` (`high`/`medium`/`low`/`unsupported`). Appears in section headers, the editor gutter, and aggregated in the rail.

```
 high         ◉ high         ████████░  citations verified
 medium       ◐ medium       █████░░░░  only 2 seeds
 low          ◌ low          ███░░░░░░  partial support
 unsupported  ○ unsupported  ░░░░░░░░░  3 unsupported claims
```
Compact header form: `Results  ◐ medium · 2 seeds`. Gutter form: a 3px vertical bar colored by trust; hover → breakdown tooltip. Bar = supported/total claims, animates `width` `--dur-3`; on improvement a brief `--trust-high` pulse. Click → trust-breakdown popover listing each claim's status with "fix" links. CSS: `.trust-badge[data-level="high"]{color:var(--trust-high);background:var(--trust-high-soft)}` (medium/low/unsupported analogs).
Inline **Unsupported** flag (prose editor): a dotted `--trust-unsupported` underline; hover shows *"Unsupported. Add citation, experiment result, or mark speculative."* with three quick actions. Restrained — never red-squiggle aggressive (gaps are honest, not failures).

#### (d) Hypothesis / Idea Card (`views/IdeasView.tsx` card)
Surfaces every `Hypothesis` field at a glance; expandable.

```
┌──────────────────────────────────────────────────────────────┐
│ H-04  Latency-as-clock prompting               ◐ medium trust│ id + title + trust
│ Novelty ●●●●○ high-risk   Feasibility ●●●○○   Compute ~38 GPU·h│ THREE METERS (noveltyRisk/feasibility/computeEstimate)
│ If agents are told tool latency encodes elapsed time, budget- │ claim (one-line thesis)
│ task success improves without an explicit timer tool.        │
│ Data  2 deadline-task suites · 50 tasks   License ✓          │ dataNeeds
│ MVP   3 models × 1 scaffold × 20 tasks, single seed          │ mvp (collapsible)
│ Fails if  models ignore latency · latency too noisy          │ failureModes
│ Closest   Sato '24 · ReAct-timer · 🔗 3 papers               │ closestRelatedWork
│ ┌────────────┐ ┌─────────────┐               ◴ est. 1 sprint │
│ │ → Plan expt│ │ ⌘ Generate ↻│                              │
│ └────────────┘ └─────────────┘                              │
└──────────────────────────────────────────────────────────────┘
```
Three meters (signature): noveltyRisk 5-dot (risk dots shade toward `--warn` — risk is flagged, not "bad"), feasibility 5-dot `--accent`, compute numeric `GPU·h` (turns `--warn` past budget). Meters fill on mount with staggered dot pops (`--ease-spring`, 30ms stagger) — a small satisfying "scoring" beat. Selected card: `--accent-line` border + `--accent-soft` wash. Collapsed (3 lines + meters) ↔ expanded; height `--dur-3`.

#### (e) Auto Lab Notebook Stream (`components/layout` status strip + `views/NotebookView.tsx`)
Append-only `NotebookEntry[]`. Bottom strip (latest line) → drawer.

```
┌─ AUTO LAB NOTEBOOK ─────────────────────  Today ▾  ⤓ export ⊗ ─┐
│ 12:50  🧪  reran timer-prompt eval     34% → 49%   run #19 ↗   │ result delta (▲ --success)
│ 12:14  ⚙   started run #19  Qwen3-8B · seed 7 · 50 tasks       │
│ 11:05  🔧  fixed tokenizer special-token mismatch              │ fix
│ 10:42  ⚠   Qwen3-8B timer prompts failed — tokenizer error ↗log│ error (--warn/--danger)
│ 10:31  ✓   approved diff: revise claim c-12 (you)              │ human decision (--accent)
│ 10:28  ◧   Hypothesis Agent proposed H-04                      │ agent action (agent hue)
│  ▸ filter: all · runs · agents · decisions · errors            │
└────────────────────────────────────────────────────────────────┘
```
Row: `time(mono,--text-2) · type-icon(hue) · message · [delta chip] · [↗] · [actor]`. Delta chips: `34% → 49%` with ▲ `--success` / ▼ `--danger` from `NotebookEntry.delta`. New lines insert at top `translateY(-6px)+opacity` `--dur-2`; collapsed ticker rolls one line; never autoscroll if user scrolled up (sticky "▾ N new").

#### (f) Approval Gate (`StageGate`, between stages)
The human checkpoint at every transition; locked until criteria met.

```
┌──────────────────────────────────────────────────────────────────┐
│                       ⬡  STAGE GATE                               │
│          03 Hypotheses  ───────▶  04 Experiment Plan             │
│  ✓  At least one hypothesis selected            (H-04)           │ GateCriterion status='met'
│  ✓  Novelty + feasibility scored                                │
│  ⚠  3 open proposals not yet resolved           review ▸        │ status='warn' (blocking)
│  ○  Compute budget acknowledged                 confirm         │ status='ack-required'
│  Aggregate trust entering stage 04:  ◐ medium                   │
│  ⌫ Stay in 03        ┌──────────────────────────────────┐      │
│                      │  Advance to Experiment Plan  →    │      │ disabled until ready
│                      └──────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────┘
```
Blocked: primary `--text-3`, no fill, tooltip "Resolve 3 proposals first." Ready (`StageGate.ready`): button fills `--accent` + `--accent-glow` ring. Advancing: `--dur-4` unlock — connecting line draws across, destination rail node brightens ○→◉, notebook logs "advanced 03→04 (you, 12:55)." The app's one moment of pronounced motion. `.gate-line{stroke-dasharray:200;stroke-dashoffset:200} .gate[data-advancing] .gate-line{animation:draw var(--dur-4) var(--ease-in-out) forwards}`.

#### (g) Agent Activity Feed (`components/layout/AgentActivityRail.tsx`, Inspector "Agents" tab)
Each agent's identity + status + recent emissions. Calm, not chatty — workers reporting in, not a chat.

```
┌─ AGENTS ───────────────────────────────────┐
│  ◧ Hypothesis     ● working   42%  ▱▱▱▰     │ AgentActivity state + progress (agent hue dot)
│     drafting H-05 from claim cluster        │
│  ◧ Literature     ◌ idle                    │
│  ◧ Novelty        ✓ done · 2 proposals ▸    │ → diff queue
│  ◧ Citation Check ⚠ 1 broken DOI    fix ▸   │ flags a trust issue
│  ◧ Experiment Plan ○ waiting (gate 03)      │ blocked by gate
│  Recent emissions                           │
│   2m  Hypothesis → proposal "revise c-12"   │
│   1h  Citation → verified 14 / flagged 1    │
└─────────────────────────────────────────────┘
```
Each agent has a fixed hue (`--agent-*` tokens). States map to `AgentActivityState`: working (pulsing `--accent` dot + `--agent-progress` bar) / idle / done / waiting / error. Every working agent is interruptible — `⊗ Stop` on hover (controllable cockpit, not autopilot).

### Feel rules (the 9 that keep it slick)
1. **Motion budget 90-220ms; one 380ms exception for DECISIONS** (approve, gate-advance). Non-decisions feel instant. Never animate scroll or layout thrash.
2. **Hover reveals, never jumps.** Affordances rest at 0.0-0.85 opacity, fade in on hover; layout never reflows on hover.
3. **One accent, earned.** Accent = selection/focus/primary/links only. Trust has its own ramp; semantic colors only for true semantics. If everything is accented, nothing is.
4. **Linear-tight but breathable.** 28-32px rows, 12-16px gutters, cards 12-16px padding; generous whitespace around headers, tight within lists.
5. **Borders over shadows.** 1px alpha hairlines separate; shadows only for true overlays (popover, palette, modal).
6. **Keyboard-first.** ⌘K palette; A/E/R on focused diff; ⌘1…9 jump stages; ⇧⌘G next gate; J/K traverse proposals; ⌘↵ approve. Shortcuts shown on hover.
7. **Typography carries hierarchy, not weight-spam.** Three text tiers + tracking + the serif/mono switch. Mono = machine-truth (ids, metrics, timestamps, logs). Serif = manuscript reading only. Bold is rare.
8. **Provenance is one click, never a detour.** Any number/claim/figure is a chip opening its source popover in place. The user never leaves to ask "says who?".
9. **Honest, calm trust signaling.** Gaps are amber and quiet, not red and loud; verified is a soft teal check, not a celebration. Emotional register: "rigorous lab," not "gamified app."

### Iconography (lucide-react)
Stages: Corpus `Library` · Claims `Network` · Questions `HelpCircle` · Ideas `Lightbulb` · Experiments `ClipboardList` · Runs `Terminal` · Analysis `BarChart3` · Manuscript `PenLine` · Review `MessageSquareWarning`. Provenance: citation `FileText` · result `FlaskConical` · derivation `Sigma` · dataset `Database` · note `PenLine`. Diff actions: approve `Check` · edit `Pencil` · reject `X` · full diff `GitCompareArrows`. Agents: `Hexagon`; working `Loader`; done `CircleCheck`; blocked `CircleDashed`; warn `TriangleAlert`. Notebook/runs: `NotebookPen` · `Play` · `ScrollText` · `Wrench` · `Clock`. Shell: `Command` · `Search` · `Moon`/`Sun` · `Settings2` · `ArrowUpRight`. Sizing: 14px dense, 16px default, 1.5px stroke, color via `currentColor` (never colored icons).
