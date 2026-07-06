/**
 * Seed trajectory for the flagship demo project:
 *   "Time-awareness in LLM agents"
 *
 * Hand-authored so every view has real, internally-consistent content —
 * corpus → claim graph → questions → hypotheses → experiment → runs →
 * results → manuscript → reviews → pending proposals (research diffs).
 *
 * Corpus papers come from the real tracker dataset (corpus.seed.json) and are
 * referenced by index so provenance survives reselection of the subset.
 */
import type {
  Paper,
  Project,
  ProvenanceLink,
  GraphNode,
  GraphEdge,
} from '../domain/types'
import { computeTrust, sectionTrust } from '../domain/trust'
import corpusRaw from './corpus.seed.json'

const corpus = corpusRaw as Paper[]
const P = (i: number) => corpus[Math.min(i, corpus.length - 1)]

// ── provenance helpers ──────────────────────────────────────────────────────
let pn = 0
const pid = () => `prov_${(pn += 1)}`

function cite(paperIdx: number, quote: string, locator: string, verified = true): ProvenanceLink {
  return { id: pid(), kind: 'citation', sourceId: P(paperIdx).id, quote, locator, verified }
}
function fromResult(resultId: string, runId: string, summary: string): ProvenanceLink {
  return { id: pid(), kind: 'result', resultId, runId, summary }
}
function note(text: string): ProvenanceLink {
  return { id: pid(), kind: 'note', text, author: 'you' }
}
function derive(text: string): ProvenanceLink {
  return { id: pid(), kind: 'derivation', text }
}

// add `trust` to a Provenanced-shaped object
const T = <X extends { provenance: ProvenanceLink[] }>(x: X) => ({
  ...x,
  trust: computeTrust(x.provenance),
})

// ── claim graph ─────────────────────────────────────────────────────────────
const gnodes: GraphNode[] = [
  T({
    id: 'g_claim_success',
    type: 'claim',
    label: 'Agent benchmarks measure task success but under-model wall-clock constraints',
    detail:
      'Most agent evals score final success/failure and ignore elapsed time, tool latency, and deadlines.',
    sourceIds: [P(3).id, P(5).id],
    provenance: [
      cite(3, 'Evaluation focuses on final outcome quality across episodes.', '§2'),
      cite(5, 'Robot time budgets are treated as a fixed resource, not a reasoned-about quantity.', '§1'),
    ],
    position: { x: 0, y: 0 },
  }),
  // an UNVERIFIED citation whose quote is literally in P(0)'s abstract — so the
  // "Verify citations" action corroborates it (false → true) and the node's trust
  // upgrades medium → high. The rest of the seed is pre-verified against full text.
  T({
    id: 'g_long_horizon',
    type: 'claim',
    label: 'Agents link actions and consequences across spans of time',
    sourceIds: [P(0).id],
    provenance: [cite(0, 'link actions and consequences across spans of time', '§1', false)],
    position: { x: 0, y: 170 },
  }),
  T({
    id: 'g_q_track',
    type: 'question',
    label: 'Do agents track wall-clock time at all?',
    sourceIds: [],
    provenance: [note('Spun out of the gap above — May 18 reading notes.')],
    position: { x: 360, y: -120 },
  }),
  T({
    id: 'g_method_timer',
    type: 'method',
    label: 'Timer-observation tool',
    detail: 'Surface elapsed/remaining time to the agent after each tool call.',
    sourceIds: [P(0).id],
    provenance: [cite(0, 'Transporting value over long time scales improves long-horizon credit assignment.', '§3')],
    position: { x: 360, y: 120 },
  }),
  T({
    id: 'g_metric_sr',
    type: 'metric',
    label: 'Deadline-respecting success rate',
    detail: 'Fraction of tasks solved within the deadline.',
    sourceIds: [],
    provenance: [derive('Standard success rate, conditioned on finishing before the deadline.')],
    position: { x: 720, y: -40 },
  }),
  T({
    id: 'g_assume_latency',
    type: 'assumption',
    label: 'Tool latency is observable to the agent',
    detail: 'Assumes the scaffold can expose per-call latency in the observation stream.',
    sourceIds: [],
    provenance: [note('Holds for our harness; may not hold for hosted tool APIs.')],
    position: { x: 720, y: 160 },
  }),
  T({
    id: 'g_limit_synth',
    type: 'limitation',
    label: 'Synthetic tasks may not transfer to real long-horizon SWE work',
    sourceIds: [],
    provenance: [note('Tasks are harness-generated; no SWE-bench-style repo tasks included.')],
    position: { x: 1080, y: 60 },
  }),
  T({
    id: 'g_contra',
    type: 'contradiction',
    label: 'Latency-only signal vs. explicit timer: which drives behavior?',
    detail: 'P(6) implies implicit temporal signals suffice; our run 002 suggests they do not.',
    sourceIds: [P(6).id],
    provenance: [cite(6, 'Temporal-difference uncertainty acts as an implicit exploration signal.', '§4')],
    position: { x: 1080, y: -120 },
  }),
]

const gedges: GraphEdge[] = [
  { id: 'e1', source: 'g_q_track', target: 'g_claim_success', relation: 'addresses' },
  { id: 'e2', source: 'g_method_timer', target: 'g_q_track', relation: 'addresses' },
  { id: 'e3', source: 'g_method_timer', target: 'g_metric_sr', relation: 'measures' },
  { id: 'e4', source: 'g_method_timer', target: 'g_assume_latency', relation: 'uses' },
  { id: 'e5', source: 'g_contra', target: 'g_method_timer', relation: 'contradicts', weight: 0.6 },
  { id: 'e6', source: 'g_limit_synth', target: 'g_metric_sr', relation: 'contradicts', weight: 0.4 },
  { id: 'e7', source: 'g_claim_success', target: 'g_method_timer', relation: 'motivates' },
  { id: 'e8', source: 'g_long_horizon', target: 'g_claim_success', relation: 'motivates' },
]

// ── runs + lab notebook ─────────────────────────────────────────────────────
const run3Id = 'run_003'
const resTimerOn = 'res_sr_timer_on'
const resTimerOff = 'res_sr_timer_off'

const project: Project = {
  id: 'proj_time_awareness',
  name: 'Time-awareness in LLM agents',
  question:
    'Do LLM agents reason about wall-clock time, tool latency, and deadlines — and does surfacing elapsed time improve budgeted task performance?',
  createdAt: '2026-05-18T10:00:00Z',
  updatedAt: '2026-06-10T12:50:00Z',

  corpus,

  claimGraph: { nodes: gnodes, edges: gedges },

  questions: [
    T({
      id: 'q1',
      label: 'Q1 · Do agents track wall-clock time?',
      detail: 'Without explicit time observations, do agents model elapsed time at all?',
      status: 'in-progress',
      hypothesisIds: ['hyp_timer'],
      provenance: [cite(3, 'No temporal budget is exposed in the standard evaluation loop.', '§2')],
    }),
    T({
      id: 'q2',
      label: 'Q2 · Can they infer elapsed time from tool latency?',
      detail: 'Is implicit latency a usable signal, or is explicit time needed?',
      status: 'open',
      hypothesisIds: ['hyp_latency'],
      provenance: [cite(6, 'TD-uncertainty provides an implicit temporal signal.', '§4')],
    }),
    T({
      id: 'q3',
      label: 'Q3 · Do time-aware prompts improve budgeted performance?',
      status: 'answered',
      hypothesisIds: ['hyp_timer'],
      provenance: [fromResult(resTimerOn, run3Id, 'success_rate 34% → 49% with timer observations')],
    }),
  ],

  campaign: {
    id: 'campaign_time_awareness',
    title: 'Deadline-aware agent research sprint',
    objective:
      'Find a reproducible intervention that improves deadline-respecting task success without merely teaching the agent to rush.',
    evaluator: { metric: 'success_rate', direction: 'maximize', target: 50, unit: '%' },
    budget: { maxAttempts: 8, maxMinutesPerAttempt: 90, compute: '24 GPU-hours' },
    runCommand: 'python experiments/time_awareness.py',
    editablePaths: ['experiments/', 'analysis/', 'configs/'],
    allowedCommands: ['python ', 'pytest ', 'uv run ', 'echo '],
    requiredEvidence: ['3 seeds for promoted results', 'figure linked to script and data', 'reviewer-risk note'],
    stopConditions: ['Target reached and replicated', 'Attempt budget exhausted', 'Compute envelope exhausted'],
    status: 'active',
    championAttemptId: 'attempt_003',
    createdAt: '2026-05-22T09:00:00Z',
    updatedAt: '2026-05-23T13:40:00Z',
  },

  hypotheses: [
    T({
      id: 'hyp_timer',
      questionId: 'q1',
      title: 'Time-to-completion awareness via explicit timer observations',
      claim:
        'Agents given explicit elapsed-time observations after each tool call will respect deadlines better than agents given only natural-language instructions.',
      why:
        'Current agent benchmarks measure success but under-model real wall-clock constraints; deadline-aware planning is a missing capability.',
      noveltyRisk: 3,
      feasibility: 2,
      computeEstimate: '≈18 GPU-hours',
      dataNeeds: '30–50 synthetic deadline tasks, no human annotation for the MVP',
      failureModes: [
        'Hard to separate model time-awareness from scaffold time-awareness',
        'Timer signal may just act as a generic "hurry up" nudge',
      ],
      mvp: '30 tasks · 3 models · 2 scaffolds · timer/no-timer ablation',
      closestRelatedWork: [
        { sourceId: P(0).id, relation: 'closest', note: 'long-time-scale credit assignment, but RL not agents' },
        { sourceId: P(6).id, relation: 'same-motivation', note: 'implicit temporal signal framing' },
      ],
      expectedContribution: 'A deadline-aware tool-use benchmark + evidence that explicit time helps.',
      status: 'selected',
      provenance: [
        cite(0, 'Transporting value over long time scales improves credit assignment.', '§3'),
        note('Most promising of the five — smallest MVP, clearest measurement.'),
      ],
    }),
    T({
      id: 'hyp_latency',
      questionId: 'q2',
      title: 'Latency as an implicit clock',
      claim: 'Agents can infer elapsed time from tool latency without an explicit timer.',
      why: 'If true, no scaffold changes are needed — time-awareness is emergent.',
      noveltyRisk: 4,
      feasibility: 3,
      computeEstimate: '≈12 GPU-hours',
      dataNeeds: 'Same tasks, latency logged but not surfaced',
      failureModes: ['Latency variance may be too noisy to read as a clock'],
      mvp: 'Reuse hyp_timer tasks with latency-only condition',
      closestRelatedWork: [{ sourceId: P(6).id, relation: 'closest' }],
      expectedContribution: 'A negative/positive result on implicit temporal signals.',
      status: 'proposed',
      provenance: [cite(6, 'TD-uncertainty as an implicit signal.', '§4')],
    }),
    T({
      id: 'hyp_tradeoff',
      title: 'Slow-accurate vs. fast-approximate tool choice under deadlines',
      claim: 'Under tight deadlines, time-aware agents shift toward fast-approximate tools.',
      why: 'Tests deadline-sensitive opportunity-cost reasoning, not just speed.',
      noveltyRisk: 3,
      feasibility: 3,
      computeEstimate: '≈20 GPU-hours',
      dataNeeds: 'Tasks with paired slow/fast tools of differing accuracy',
      failureModes: ['Optimal policy may be task-dependent and hard to score'],
      mvp: '20 tasks with paired tools, 2 deadline levels',
      closestRelatedWork: [{ sourceId: P(5).id, relation: 'same-motivation' }],
      expectedContribution: 'Evidence of opportunity-cost reasoning under time pressure.',
      status: 'proposed',
      provenance: [cite(5, 'Spending robot time as a budgeted resource.', '§1')],
    }),
  ],

  experiments: [
    T({
      id: 'exp_timer',
      hypothesisId: 'hyp_timer',
      title: 'E1 · Timer-tool ablation',
      spec:
        'Run 3 models × 2 scaffolds × 50 deadline tasks, with and without a timer observation injected after every tool call. Measure deadline-respecting success rate and deadline-violation rate.',
      variables: [
        { name: 'model', levels: ['Qwen3-8B', 'Llama-3-8B', 'GPT-4o-mini'] },
        { name: 'scaffold', levels: ['ReAct', 'Plan-Execute'] },
        { name: 'timer', levels: ['on', 'off'] },
      ],
      baselines: ['No-timer ReAct', 'No-timer Plan-Execute'],
      ablations: ['Timer after each call', 'Timer only at start', 'Remaining-time-only'],
      metrics: [
        { name: 'success_rate', direction: 'maximize', unit: '%', description: 'solved within deadline' },
        { name: 'deadline_violation_rate', direction: 'minimize', unit: '%' },
        { name: 'tool_selection_efficiency', direction: 'maximize' },
      ],
      dataPlan: '50 synthetic deadline tasks generated by the harness; 3 seeds each.',
      computeEstimate: '≈18 GPU-hours on 1×A100',
      successCriteria: [
        'Timer condition improves success_rate by ≥10pts on ≥2 models',
        'Effect holds across both scaffolds',
      ],
      reviewerRisks: [
        { concern: 'Confounds model vs scaffold time-awareness', severity: 4, mitigation: 'Hold scaffold fixed within each ablation arm' },
        { concern: 'Only synthetic tasks', severity: 3, mitigation: 'Frame as a controlled probe; flag transfer as future work' },
        { concern: 'Few seeds → noisy', severity: 3, mitigation: 'Report 3 seeds + CIs; rerun borderline cells' },
      ],
      status: 'done',
      computeApproved: true,
      provenance: [
        cite(0, 'Long-time-scale value transport.', '§3'),
        note('Approved compute budget on May 22.'),
      ],
    }),
  ],

  attempts: [
    {
      id: 'attempt_001',
      campaignId: 'campaign_time_awareness',
      experimentId: 'exp_timer',
      runId: 'run_001',
      hypothesis: 'A timer observation can be injected without changing the tokenizer.',
      command: 'python experiments/time_awareness.py --timer on --seed 0',
      patchSummary: 'Initial timer prompt template.',
      cost: '16 minutes',
      confidence: 'unreplicated',
      artifactIds: ['a_log1'],
      status: 'failed',
      createdAt: '2026-05-23T10:42:00Z',
      completedAt: '2026-05-23T10:58:00Z',
    },
    {
      id: 'attempt_002',
      campaignId: 'campaign_time_awareness',
      experimentId: 'exp_timer',
      runId: 'run_002',
      parentAttemptId: 'attempt_001',
      hypothesis: 'Explicit per-call timer observations outperform implicit latency alone.',
      command: 'python experiments/time_awareness.py --timer on --tasks 20',
      patchSummary: 'Added timer tokens and per-call timer observations.',
      metric: { name: 'success_rate', value: 34, unit: '%' },
      cost: '50 minutes',
      confidence: 'provisional',
      artifactIds: ['a_log2'],
      status: 'rejected',
      createdAt: '2026-05-23T11:05:00Z',
      completedAt: '2026-05-23T11:55:00Z',
    },
    {
      id: 'attempt_003',
      campaignId: 'campaign_time_awareness',
      experimentId: 'exp_timer',
      runId: run3Id,
      parentAttemptId: 'attempt_002',
      hypothesis: 'Per-call timer observations improve success across models and scaffolds.',
      command: 'python experiments/time_awareness.py --matrix full --seeds 3',
      patchSummary: 'Expanded the timer ablation to the full matrix and three seeds.',
      metric: { name: 'success_rate', value: 49, unit: '%' },
      cost: '90 minutes · 1×A100',
      confidence: 'replicated',
      artifactIds: ['fig_main', 'a_log3'],
      status: 'accepted',
      createdAt: '2026-05-23T12:10:00Z',
      completedAt: '2026-05-23T13:40:00Z',
    },
  ],

  runs: [
    {
      id: 'run_001',
      experimentId: 'exp_timer',
      label: 'Run 001 · baseline',
      status: 'failed',
      startedAt: '2026-05-23T10:42:00Z',
      endedAt: '2026-05-23T10:58:00Z',
      seed: 0,
      notebook: [
        { id: 'n1', at: '2026-05-23T10:42:00Z', level: 'action', text: 'Tried Qwen3-8B with timer prompts.' },
        { id: 'n2', at: '2026-05-23T10:47:00Z', level: 'error', text: 'Failed: tokenizer mismatch on the timer template tokens.' },
      ],
      artifacts: [{ id: 'a_log1', type: 'log', name: 'run_001.log', createdAt: '2026-05-23T10:58:00Z' }],
      summary: 'Environment setup failed (tokenizer).',
    },
    {
      id: 'run_002',
      experimentId: 'exp_timer',
      label: 'Run 002 · fixed harness, partial',
      status: 'partial',
      startedAt: '2026-05-23T11:05:00Z',
      endedAt: '2026-05-23T11:55:00Z',
      seed: 0,
      notebook: [
        { id: 'n3', at: '2026-05-23T11:05:00Z', level: 'fix', text: 'Fixed tokenizer mismatch (added timer tokens to vocab).' },
        { id: 'n4', at: '2026-05-23T11:31:00Z', level: 'observation', text: 'Ran 20 tasks. Success rate low (34%). Hypothesis: tool latency not visible enough.' },
        { id: 'n5', at: '2026-05-23T11:50:00Z', level: 'action', text: 'Added explicit timer observation after each tool call.' },
      ],
      artifacts: [{ id: 'a_log2', type: 'log', name: 'run_002.log', createdAt: '2026-05-23T11:55:00Z' }],
      summary: 'Partial results; identified that implicit latency was insufficient.',
    },
    {
      id: run3Id,
      experimentId: 'exp_timer',
      label: 'Run 003 · final results with ablation',
      status: 'done',
      startedAt: '2026-05-23T12:10:00Z',
      endedAt: '2026-05-23T13:40:00Z',
      seed: 0,
      env: { gpu: '1×A100', framework: 'vllm 0.6.3' },
      notebook: [
        { id: 'n6', at: '2026-05-23T12:10:00Z', level: 'action', text: 'Reran with per-call timer observation across 3 models × 2 scaffolds.' },
        { id: 'n7', at: '2026-05-23T12:50:00Z', level: 'result', text: 'Improvement from 34% → 49% with explicit timer (Qwen3-8B, ReAct).', artifactId: 'fig_main' },
        { id: 'n8', at: '2026-05-23T13:20:00Z', level: 'observation', text: 'Effect smaller on GPT-4o-mini (already time-aware?). Worth a seed rerun.' },
        { id: 'n9', at: '2026-05-23T13:40:00Z', level: 'result', text: 'Deadline-violation rate dropped 41% → 23% with timer.' },
      ],
      artifacts: [
        { id: 'fig_main', type: 'figure', name: 'success_by_timer.svg', createdAt: '2026-05-23T12:50:00Z', producedBy: { scriptPath: 'analysis/plot_main.py', dataPath: 'runs/003/results.csv' } },
        { id: 'a_log3', type: 'log', name: 'run_003.log', createdAt: '2026-05-23T13:40:00Z' },
      ],
      summary: 'Explicit per-call timer improves success and reduces deadline violations; effect strongest on smaller models.',
    },
  ],

  results: [
    T({
      id: resTimerOff,
      runId: run3Id,
      metric: 'success_rate',
      value: 34,
      unit: '%',
      conditions: { model: 'Qwen3-8B', scaffold: 'ReAct', timer: 'off' },
      seeds: 3,
      signal: 'real',
      ci: [30, 38],
      provenance: [fromResult(resTimerOff, run3Id, 'baseline, timer off')],
    }),
    T({
      id: resTimerOn,
      runId: run3Id,
      metric: 'success_rate',
      value: 49,
      unit: '%',
      conditions: { model: 'Qwen3-8B', scaffold: 'ReAct', timer: 'on' },
      seeds: 3,
      signal: 'real',
      ci: [45, 53],
      provenance: [fromResult(resTimerOn, run3Id, 'timer on')],
    }),
    T({
      id: 'res_violation',
      runId: run3Id,
      metric: 'deadline_violation_rate',
      value: 23,
      unit: '%',
      conditions: { model: 'Qwen3-8B', timer: 'on' },
      seeds: 3,
      signal: 'real',
      provenance: [fromResult('res_violation', run3Id, 'down from 41%')],
    }),
    T({
      id: 'res_gpt',
      runId: run3Id,
      metric: 'success_rate',
      value: 6,
      unit: 'pts',
      conditions: { model: 'GPT-4o-mini', timer: 'delta' },
      seeds: 1,
      signal: 'likely-noise',
      provenance: [note('Only 1 seed; effect within noise. Rerun before claiming.')],
    }),
  ],

  figures: [
    T({
      id: 'fig_main',
      title: 'Success rate by timer condition',
      artifactId: 'fig_main',
      caption: 'Deadline-respecting success rate with vs. without per-call timer observations.',
      provenance: [fromResult(resTimerOn, run3Id, '34% → 49%')],
    }),
  ],

  manuscript: {
    id: 'ms_1',
    title: 'Do LLM Agents Understand Time? A Benchmark for Deadline-Aware Tool Use',
    updatedAt: '2026-06-10T12:40:00Z',
    sections: [
      section('sec_abstract', 'abstract', 'Abstract',
        'We study whether LLM agents reason about wall-clock time under deadlines. We introduce a deadline-aware tool-use benchmark and show that surfacing elapsed time after each tool call raises deadline-respecting success rate from 34% to 49% on a small open model.',
        [
          claim('c_ab1', 'surfacing elapsed time after each tool call raises deadline-respecting success rate from 34% to 49%', [fromResult(resTimerOn, run3Id, '34% → 49%')]),
        ]),
      section('sec_intro', 'introduction', '1 · Introduction',
        'Agent benchmarks largely measure task success while under-modeling wall-clock constraints. We ask whether agents track elapsed time at all, and whether making time explicit helps.',
        [
          claim('c_in1', 'Agent benchmarks largely measure task success while under-modeling wall-clock constraints', [cite(3, 'Evaluation focuses on final outcome quality.', '§2')]),
          claim('c_in2', 'Time-awareness is critical for agentic intelligence', []), // intentionally unsupported → editor flags it
        ]),
      section('sec_related', 'related-work', '2 · Related Work',
        'Long-horizon credit assignment transports value across time. Implicit temporal signals such as TD-uncertainty have been proposed as exploration drivers.',
        [
          claim('c_rw1', 'Long-horizon credit assignment transports value across time', [cite(0, 'Transporting value over long time scales.', '§3')]),
          claim('c_rw2', 'Implicit temporal signals such as TD-uncertainty drive exploration', [cite(6, 'TD-uncertainty as an implicit signal.', '§4')]),
        ]),
      section('sec_results', 'results', '4 · Results',
        'Explicit per-call timer observations improved success rate by 15 points and reduced deadline violations from 41% to 23%. The effect was strongest on smaller models.',
        [
          claim('c_re1', 'Explicit per-call timer observations improved success rate by 15 points', [fromResult(resTimerOn, run3Id, '34% → 49%')]),
          claim('c_re2', 'reduced deadline violations from 41% to 23%', [fromResult('res_violation', run3Id, '41% → 23%')]),
          claim('c_re3', 'The effect was strongest on smaller models', [note('GPT-4o-mini delta only 6pts, 1 seed — weak support')]),
        ]),
      section('sec_limits', 'limitations', '6 · Limitations',
        'Experiments use synthetic tasks, so results may not transfer to real long-horizon software-engineering environments. Several cells use only one seed.',
        [
          claim('c_li1', 'Experiments use synthetic tasks, so results may not transfer to real long-horizon SWE environments', [note('Tasks are harness-generated; no SWE-bench-style repo tasks.')]),
        ]),
    ],
  },

  reviews: [
    {
      id: 'rev_1',
      persona: 'reviewer-1',
      score: 5,
      recommendation: 'borderline',
      summary: 'Interesting probe, but novelty is incremental and evaluation is thin.',
      createdAt: '2026-06-09T18:00:00Z',
      comments: [
        { id: 'rc1', kind: 'weakness', text: 'Novelty is weak — timer prompts are a small delta over existing scaffolds.', targetId: 'hyp_timer', evidence: [cite(0, 'Prior work already studies long-time-scale value.', '§3')], severity: 4 },
        { id: 'rc2', kind: 'weakness', text: 'Baselines insufficient — only ReAct and Plan-Execute.', targetId: 'exp_timer', evidence: [], severity: 3 },
        { id: 'rc3', kind: 'strength', text: 'The deadline-violation metric is well-motivated.', targetId: 'g_metric_sr', evidence: [] },
      ],
    },
    {
      id: 'rev_2',
      persona: 'reviewer-2',
      score: 6,
      recommendation: 'weak-accept',
      summary: 'Clear question and a clean ablation, but the single-seed cells worry me.',
      createdAt: '2026-06-09T18:00:00Z',
      comments: [
        { id: 'rc4', kind: 'weakness', text: 'Some results use a single seed; the GPT-4o-mini delta may be noise.', targetId: 'res_gpt', evidence: [{ id: pid(), kind: 'result', resultId: 'res_gpt', runId: run3Id, summary: '1 seed, within noise' }], severity: 3 },
        { id: 'rc5', kind: 'question', text: 'Is the effect from time-awareness or just a generic urgency nudge?', targetId: 'hyp_timer', evidence: [] },
      ],
    },
    {
      id: 'rev_ac',
      persona: 'area-chair',
      score: 6,
      recommendation: 'borderline',
      summary: 'Promising but under-evaluated. Would be stronger with a real-task transfer experiment.',
      createdAt: '2026-06-09T20:00:00Z',
      comments: [
        { id: 'rc6', kind: 'weakness', text: 'Synthetic-only evaluation limits the claim. Add a SWE-bench-style transfer probe.', targetId: 'g_limit_synth', evidence: [], severity: 3 },
      ],
    },
  ],

  proposals: [
    {
      id: 'prop_claim',
      agentId: 'writing',
      stage: 'manuscript',
      title: 'Narrow the headline claim',
      summary: 'The current claim overgeneralizes beyond what runs 003–005 show.',
      status: 'pending',
      createdAt: '2026-06-10T12:30:00Z',
      evidence: [fromResult(resTimerOn, run3Id, '34% → 49%, one model family')],
      risks: ['Reviewer 1 already flagged overclaiming on novelty'],
      changes: [
        {
          id: 'ch1',
          kind: 'update',
          entityType: 'inline-claim',
          label: 'Change main claim',
          before: 'Agents cannot reason about time.',
          after:
            'Current agents show unreliable deadline-sensitive behavior unless elapsed time is explicitly surfaced.',
          reason:
            'The first claim is too broad. Runs 003–005 show improvement only with explicit timer observations, on smaller models.',
        },
      ],
    },
    {
      id: 'prop_limit',
      agentId: 'analysis',
      stage: 'manuscript',
      title: 'Add a transfer limitation',
      summary: 'Make the synthetic-task limitation explicit, as the area chair requested.',
      status: 'pending',
      createdAt: '2026-06-10T12:34:00Z',
      evidence: [note('Benchmark tasks are harness-generated; no SWE-bench-style repository tasks were included.')],
      changes: [
        {
          id: 'ch2',
          kind: 'create',
          entityType: 'inline-claim',
          label: 'Add limitation',
          after:
            'Experiments use synthetic tasks, so the results may not transfer to real long-horizon software-engineering environments.',
          reason: 'Benchmark tasks were generated by our harness; no SWE-bench-style repo tasks were included.',
        },
      ],
    },
    {
      id: 'prop_cite',
      agentId: 'citation',
      stage: 'manuscript',
      title: 'Remove an unsupported citation',
      summary: 'A citation does not actually support the sentence it is attached to.',
      status: 'pending',
      createdAt: '2026-06-10T12:36:00Z',
      evidence: [note('Cited work studies token budgets, not wall-clock deadlines.')],
      risks: ['arXiv now bans submissions with unchecked/unsupported references'],
      changes: [
        {
          id: 'ch3',
          kind: 'delete',
          entityType: 'inline-claim',
          label: 'Remove citation',
          before: 'Smith et al. 2024 — cited for the deadline claim in §1',
          reason: 'It studies token budgets, not wall-clock deadlines. Does not support the sentence.',
        },
      ],
    },
    {
      id: 'prop_rerun',
      agentId: 'execution',
      stage: 'runs',
      title: 'Rerun GPT-4o-mini cell with 3 seeds',
      summary: 'The 6-point delta is within noise at 1 seed; rerun before claiming it.',
      status: 'pending',
      createdAt: '2026-06-10T12:38:00Z',
      evidence: [note('res_gpt: 1 seed, signal=likely-noise')],
      changes: [
        {
          id: 'ch4',
          kind: 'create',
          entityType: 'run',
          label: 'Queue Run 004',
          after: 'Run 004 · GPT-4o-mini, timer on/off, 3 seeds (≈4 GPU-hours)',
          reason: 'Establish whether the small-model advantage is real or an artifact of model choice.',
        },
      ],
    },
  ],

  activity: [
    { id: 'act1', agentId: 'analysis', state: 'proposed', text: 'Flagged res_gpt as likely noise (1 seed).', at: '2026-06-10T12:32:00Z', proposalId: 'prop_rerun' },
    { id: 'act2', agentId: 'writing', state: 'proposed', text: 'Proposed narrowing the headline claim.', at: '2026-06-10T12:30:00Z', proposalId: 'prop_claim' },
    { id: 'act3', agentId: 'citation', state: 'proposed', text: 'Found 1 citation that does not support its sentence.', at: '2026-06-10T12:36:00Z', proposalId: 'prop_cite' },
    { id: 'act4', agentId: 'reviewer', state: 'done', text: 'Generated 3 simulated reviews (mean score 5.7).', at: '2026-06-09T20:00:00Z' },
    { id: 'act5', agentId: 'execution', state: 'done', text: 'Run 003 complete — 34% → 49% with timer.', at: '2026-05-23T13:40:00Z' },
  ],
}

// ── small constructors (kept after `project` so helpers can hoist) ──────────
function claim(id: string, text: string, provenance: ProvenanceLink[]) {
  return { id, text, provenance, trust: computeTrust(provenance) }
}
function section(
  id: string,
  kind: import('../domain/types').SectionKind,
  heading: string,
  body: string,
  claims: ReturnType<typeof claim>[],
) {
  const s = { id, kind, heading, body, claims, figureIds: kind === 'results' ? ['fig_main'] : [], trust: 'medium' as const }
  return { ...s, trust: sectionTrust(s) }
}

export const seedProject: Project = project
