# Kaisola — Product Spec

> The Cursor for research. A controllable research cockpit that moves work from literature → hypotheses → experiments → results → paper, with a human reviewing and steering every transition.

## 1. Positioning

**Kaisola is a Research IDE — the "Cursor for research."** It turns a pile of papers into a reproducible experiment draft through a persistent, auditable research trajectory: `corpus → claim graph → questions → hypotheses → experiment plans → code/runs → results → figures → draft → reviewer sim → revisions`. Every agent action arrives as an inspectable **research diff** the human approves, edits, or rejects. The product is not a paper library (passive) and not a chat agent (amnesic) — it is a **research process you can see, steer, and trust.**

### The ONE opinionated philosophy rule
> **Every scientific claim must link to evidence — one of {citation, experiment result, derivation, dataset, human-authored note} — or it is flagged Unsupported.**

This is the product's spine, not a feature. The editor refuses to let an unsupported sentence sit silently: it is highlighted inline with *"Unsupported. Add citation, experiment result, or mark speculative."* The **provenance layer is the moat**; everything else is UI around it. In the domain model this is enforced by the type — every scientific entity mixes in `Provenanced` (`provenance: ProvenanceLink[]` + computed `trust: TrustLevel`); an empty `provenance` array literally IS `unsupported`.

### Target first user
**The computational AI/ML researcher** (grad student, industry research engineer, or independent researcher) who already lives in an IDE, runs experiments as code, has repos + datasets accessible, and produces numeric results. We start here because every link in the trajectory is *machine-checkable* in this domain: code runs, results are numbers, citations have DOIs/arXiv IDs, figures derive from scripts. This is the one field where evidence-grounded autonomy is verifiable today.

## 2. The Core Product Loop

The loop is the product. Nine steps, each with a **named agent**, a **named view**, and an explicit **human gate**. No transition is automatic; every one is a `Proposal` the human approves.

| # | Step | Agent (`AgentId`) | View (`TrajectoryStage`) | Human gate |
|---|------|-------|------|-------------|
| 1 | **Ask** | `literature` | Corpus + Claim Graph (`corpus`/`claims`) | User states a question / picks a paper cluster. Agent proposes a field map (claim graph) as a diff. Human approves which papers/claims enter scope. |
| 2 | **Propose** | `hypothesis` | Idea Generation (`ideas`) | Agent emits 3–5 idea cards (hypothesis + novelty-risk, feasibility, compute est, data needs, failure modes, MVP, closest related work). Human picks / merges / kills cards. |
| 3 | **Verify novelty** | `novelty` | Idea card → Claim Graph overlay | Agent searches corpus for prior art, returns "closest related work" with quotes + a novelty verdict as a diff. Human accepts or overrides with a note (which becomes provenance). |
| 4 | **Plan** | `planning` | Experiment Planning (`experiments`) | Agent drafts a spec: baselines, ablations, metrics, data plan, compute budget, success criteria, **reviewer-risk checklist**. Human edits + approves as the source of truth. |
| 5 | **Execute** | `coding` + `execution` | Execution IDE (`runs`) | Agent scaffolds repo/code, proposes run configs (seeds, env, GPU target). Human **approves compute** (`computeApproved`) before any run. Auto Lab Notebook timestamps every attempt. |
| 6 | **Analyze** | `analysis` | Analysis (`analysis`) | Agent builds tables/figures, runs significance tests, answers *"is this real or noise?"* and *"what changed vs last run?"* — each figure linked to script+data. Human approves which results are "true." |
| 7 | **Critique** | `reviewer` | Writing + Review (`manuscript`/`review`) | Agent simulates a reviewer: scores + weaknesses, each tied to evidence (or its absence). Human triages weaknesses into a fix list. |
| 8 | **Revise** | `hypothesis`/`planning`/`coding` | (loops to the relevant view) | Each reviewer weakness re-enters the loop as a new Proposal (more seeds, an ablation, a citation). Human approves the loop-back. |
| 9 | **Write** | `writing` + `citation` | Writing + Review | Agent drafts artifact-grounded prose; every paragraph links to claims+citations+results. Per-section **Trust Score** shows coverage. Human resolves every Unsupported flag before export. |

**Invariant:** the agent never mutates the trajectory directly. It emits a `Proposal` with a fixed `ProposalRationale` schema — *Why this? What papers motivate it? What would make it fail? Minimal version? What would a reviewer complain about? What exactly is measured? What code? What compute?* — and the human approves, edits, or rejects. In code, `approve()` is the single chokepoint that calls `applyProposal`.

## 3. The "Research Sprint" Flagship UX

> **MVP promise:** "From a 20-paper literature cluster to a reproducible experiment draft in one focused research sprint" — **NOT** "publishable paper in 48h."

Dogfood project: **"Time-awareness in LLM agents"** (Do agents track wall-clock time? Infer elapsed time from tool latency? Do time-aware prompts improve budgeted-task performance? Experiment: deadline tasks, slow-accurate vs fast-approximate tools, timer-tool ablation, 3 models × 2 scaffolds × 50 tasks).

1. **Import corpus** → *Corpus view.* Filter the 2898-paper seed JSON to a ~20-paper cluster (topics: Agents + Reasoning + Evaluations). Papers land as typed `Paper` nodes.
2. **Build the field map** → *Claim Graph view.* `literature` agent proposes a claim graph (Paper/Claim/Method/Dataset/Metric/Result/Limitation/Assumption/Contradiction/OpenQuestion nodes; supports/contradicts/uses/measures/motivates edges). `contradiction` and `openQuestion` nodes surface the seams worth attacking.
3. **Generate 5 idea cards** → *Idea Generation view.* `hypothesis` agent emits 5 cards from the open questions.
4. **Pick one** → *Idea Gen → Novelty overlay.* User selects "time-aware prompts improve budgeted-task success." `novelty` agent overlays closest prior work with quotes. Human confirms the wedge.
5. **Plan the experiment** → *Experiment Planning view.* `planning` agent drafts the spec: 3 models × 2 scaffolds × 50 deadline tasks; baselines (no timer), ablation (timer-tool removed); metrics (success@deadline, overrun rate); success criteria; reviewer-risk checklist (n seeds? confound: model speed vs time-awareness?). Human edits + approves.
6. **Approve compute** → *Execution view (pre-run gate).* Agent proposes the run matrix + estimated cost/GPU-hours (`ComputeEstimate`) on the chosen backend (local / Modal / RunPod / Slurm / Docker). Human **explicitly approves the budget** — no run without this gate.
7. **Run + watch the notebook** → *Execution view + Auto Lab Notebook.* Runs execute with fixed seeds; logs/artifacts captured. Notebook auto-logs timestamped events ("10:42 tried Qwen3-8B timer prompts, failed tokenizer; 11:05 fixed; 12:50 reran 34%→49%"). Debug agent proposes fixes as diffs.
8. **Make figures** → *Analysis view.* `analysis` agent builds the success@deadline table + timer-ablation figure, runs significance ("real or noise?"), and a "what changed vs last run?" diff. Each figure carries a figure→script+data link. Human marks which results are trustworthy.
9. **Draft the paper** → *Writing + Review view.* `writing` agent drafts artifact-grounded sections; every paragraph links to claims/citations/results. `reviewer` agent simulates review (scores + evidence-tied weaknesses).
10. **Provenance review** → *Writing + Review (Trust panel).* Per-section Trust Score renders (*Intro: medium · Related work: high, citations verified · Results: medium, only 2 seeds · References: high, DOIs verified*). `citation` agent flags hallucinated/mismatched refs. Human resolves every Unsupported flag. Output: a **reproducible experiment draft** with full provenance.

## 4. Agent Layer (interface contract)

Agents are typed interfaces (`Agent` in the domain model), not background daemons. In the scaffold they return **mock Proposals**; the seam to plug `claude-opus-4-8` is a single adapter (`electron/ipc/modelHandler.cjs`). Agents: **Literature, Novelty, Hypothesis, ExperimentPlanning, Coding, Execution/Debug, Analysis, Writing, Reviewer, CitationChecking** (`AgentId` values `literature` `novelty` `hypothesis` `planning` `coding` `execution` `analysis` `writing` `reviewer` `citation`).

Every agent emits a `Proposal` whose `rationale: ProposalRationale` answers: **Why this?** (motivation) · **What papers motivate it?** (`motivatingPapers`) · **What would make it fail?** (`failureConditions`) · **Minimal version?** (`minimalVersion`) · **What a reviewer would complain about?** (`reviewerComplaint`) · **What is measured? / What code? / What compute?** (for experiment proposals). Each `Proposal.changes[]` is a typed `ProposalChange` whose `DiffPayload.op` is one of: *claim.change* (old/new + reason + evidence), *limitation.add* (text + evidence), *citation.remove* (reason it doesn't support the sentence), *node.add/edge.add*, *hypothesis.add*, *experiment.add/edit*, *run.queue*, *result.record*, *figure.add*, *section.write*, *review.add*. The human acts on each: **approve / edit / reject.**

## 5. Risks & Mitigations (grounded in prior art)

| Risk (with evidence from prior art) | Kaisola mitigation |
|---|---|
| **Agents can't actually replicate experiments.** PaperBench: best agent ~21% replication of ICML spotlights. | We never promise replication-on-autopilot. The human approves the spec and compute; the Auto Lab Notebook + figure→code links make *partial* progress legible and reusable. Success = a reproducible draft, not a finished paper. |
| **Experiments fail on coding errors.** ~42% of AI-Scientist experiments failed on code errors. | Execution/Debug agent surfaces failures as diffs, not silent retries; the notebook timestamps every failed attempt and its fix. Compute is gated, so failures are cheap. |
| **Hallucinated citations** (arXiv now bans them). | CitationChecking agent + citation verifier run before export; the philosophy rule blocks unsupported claims; a `failed` `VerificationState` caps trust at `low`; References gets a Trust Score with DOI/arXiv verification. |
| **Novelty mis-judgment** (agent declares novel what isn't). | Novelty is a *Proposal with quotes from closest related work*, not a verdict. The human gate at step 3 requires accepting or overriding with a note — and the override becomes provenance. |
| **Result provenance rot** (figure no longer matches code/data). | Result provenance checker + figure→code linker (`Artifact.producedBy` + `contentHash`); "what changed vs last run?" (`ResultRecord.comparedTo`); results tagged with `seeds` so a 2-seed result reads *medium*, not *high*. |
| **Autonomy theater** (looks impressive, isn't trustworthy). | Every transition is a human gate (`StageGate`). No step is automatic. The value is *control + evidence*, positioned against "press button → publishable paper." |
| **Dataset license violations.** | Dataset license checker (`Dataset.licenseStatus`) in the trust layer; license surfaced on Dataset nodes. |

## 6. Anti-Goals (explicit)

- **Don't replace Zotero/Overleaf first.** We interoperate (import corpus, export draft); we win on the *trajectory + provenance*, not on being a better reference manager or LaTeX editor on day one.
- **Don't promise autonomous publication.** The deliverable is a *reproducible experiment draft* with provenance.
- **Don't be a "chat with your papers" summarizer.** Chat is amnesic; we build a persistent, auditable research object. Summaries without provenance are exactly what we reject.
- **Don't hide agent steps.** Every agent action is an inspectable Proposal / research diff with a rationale. No invisible background mutation of the trajectory.
- **Don't ship unsupported claims silently.** The editor flags them; export is gated on resolution.
- **Don't over-automate the human out of the loop.** The human gate at every transition is the feature, not friction to be optimized away.