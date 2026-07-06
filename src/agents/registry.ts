import type { Agent, AgentContext } from './types'
import { AGENT_META } from './types'
import type { AgentId, Proposal, ProvenanceLink, Hypothesis } from '../domain/types'
import { uid, nowISO } from '../domain/ids'
import { computeTrust } from '../domain/trust'

/**
 * The agent registry. Every agent shares the model path (a generic prompt that
 * grounds the agent in its role + the relevance-ranked project context, forcing
 * an `emit_proposal` tool-call) and carries an optional deterministic generator
 * for the offline default / fallback. See `run.ts` for how the two compose.
 */

function projectSummaryFallback(ctx: AgentContext): string {
  const p = ctx.project
  const papers = p.corpus.filter((s) => s.kind === 'paper').length
  return [
    `Project: ${p.name || 'Untitled'}`,
    p.question ? `Question: ${p.question}` : '',
    `Corpus: ${papers} papers · ${p.claimGraph.nodes.length} claim-graph nodes · ${p.hypotheses.length} hypotheses`,
  ].filter(Boolean).join('\n')
}

/** Build the model prompt for any agent from its role + the grounded context. */
function genericPrompt(id: AgentId) {
  const meta = AGENT_META[id]
  return (ctx: AgentContext): { system: string; user: string } => ({
    system:
      `You are the ${meta.name} agent inside Kaisola, a research IDE built around a typed research trajectory ` +
      `(corpus → claim graph → questions → hypotheses → experiments → runs → analysis → manuscript → review). ` +
      `Your role: ${meta.role}. You operate at the "${meta.stage}" stage.\n\n` +
      `You NEVER mutate state directly. You emit small, atomic, evidence-grounded proposals (research diffs) via ` +
      `the emit_proposal tool for a human to approve. Be conservative and specific — a reviewer reads every word. ` +
      `Surface the honest risks. Never invent results or citations; if support is missing, say so and propose how to get it.`,
    user:
      `${ctx.contextText ?? projectSummaryFallback(ctx)}\n\n` +
      (ctx.instruction ? `Human steering: ${ctx.instruction}\n\n` : '') +
      `Propose the single most valuable next change for the ${meta.stage} stage. Call emit_proposal with 1–2 tightly-scoped proposals.`,
  })
}

/** Assemble an Agent: shared model path + an optional deterministic generator. */
function defineAgent(
  id: AgentId,
  generator?: (ctx: AgentContext) => Proposal[],
  evidence?: (ctx: AgentContext) => ProvenanceLink[],
): Agent {
  return {
    meta: AGENT_META[id],
    prompt: genericPrompt(id),
    evidence,
    async run(ctx) {
      return generator ? generator(ctx) : []
    },
  }
}

// ── deterministic generators (offline default + fallback) ────────────────────

const noveltyGen = (ctx: AgentContext): Proposal[] => {
  const hyp = ctx.project.hypotheses[0]
  if (!hyp) return []
  return [{
    id: uid('prop'),
    agentId: 'novelty',
    stage: 'ideas',
    title: `Novelty check: ${hyp.title}`,
    summary: 'No exact benchmark found in the corpus or a Semantic Scholar sweep; closest work differs in setting.',
    status: 'pending',
    createdAt: nowISO(),
    evidence: hyp.provenance,
    risks: ['One corpus paper shares the motivation but a different setting'],
    changes: [{
      id: uid('ch'),
      kind: 'update',
      entityType: 'hypothesis',
      label: 'Set novelty risk',
      before: `novelty risk ${hyp.noveltyRisk}/5`,
      after: 'novelty risk 3/5 — defensible, framed as a controlled probe',
      reason: 'No exact prior benchmark; closest related work is RL, not agentic tool use.',
      // structured value applied on approval: patch the target hypothesis
      payload: { id: hyp.id, patch: { noveltyRisk: 3 } },
    }],
  }]
}

const hypothesisGen = (ctx: AgentContext): Proposal[] => {
  const q = ctx.project.questions[0]
  const provenance = q?.provenance ?? []
  const newHyp: Hypothesis = {
    id: uid('hyp'),
    questionId: q?.id,
    title: 'Latency-as-clock ablation',
    claim: 'Agents can infer elapsed time from tool latency without an explicit timer.',
    why: 'Isolates implicit temporal signals cheaply by reusing existing tasks with a latency-only condition.',
    noveltyRisk: 3,
    feasibility: 2,
    computeEstimate: '≈6 GPU-hours',
    dataNeeds: 'Existing harness tasks; a latency-logged-but-hidden condition',
    failureModes: ['Tool latency too noisy to carry a usable temporal signal'],
    mvp: 'One latency-only condition vs. the timer-off baseline, success-rate delta',
    closestRelatedWork: [],
    expectedContribution: 'A clean control isolating implicit temporal signals from explicit timers',
    status: 'proposed',
    provenance,
    trust: computeTrust(provenance),
  }
  return [{
    id: uid('prop'),
    agentId: 'hypothesis',
    stage: 'ideas',
    title: 'Propose: latency-as-clock ablation',
    summary: 'Adds a condition where latency is logged but not surfaced, to isolate implicit temporal signals.',
    status: 'pending',
    createdAt: nowISO(),
    evidence: provenance,
    changes: [{
      id: uid('ch'),
      kind: 'create',
      entityType: 'hypothesis',
      label: 'Add hypothesis',
      after: newHyp.claim,
      reason: 'Cheap to add — reuses existing tasks with a latency-only condition.',
      // structured value applied on approval: the full hypothesis
      payload: newHyp,
    }],
  }]
}

// ── registry ─────────────────────────────────────────────────────────────────

export const noveltyAgent = defineAgent('novelty', noveltyGen, (ctx) => ctx.project.hypotheses[0]?.provenance ?? [])
export const hypothesisAgent = defineAgent('hypothesis', hypothesisGen, (ctx) => ctx.project.questions[0]?.provenance ?? [])

/** Agents invokable from the sidebar / palette. The model path works for all of
 *  them when a key is present; only novelty & hypothesis have offline output. */
const SIDEBAR_AGENT_IDS: AgentId[] = [
  'literature', 'novelty', 'hypothesis', 'planning', 'execution', 'analysis', 'writing', 'reviewer', 'citation',
]

const REGISTRY = new Map<AgentId, Agent>([
  ['novelty', noveltyAgent],
  ['hypothesis', hypothesisAgent],
])

export function agentById(id: string): Agent | undefined {
  if (REGISTRY.has(id as AgentId)) return REGISTRY.get(id as AgentId)
  if ((SIDEBAR_AGENT_IDS as string[]).includes(id)) {
    const a = defineAgent(id as AgentId)
    REGISTRY.set(id as AgentId, a)
    return a
  }
  return undefined
}

export const AGENTS: Agent[] = SIDEBAR_AGENT_IDS.map((id) => agentById(id)!).filter(Boolean)
