import type { AgentId, Project, Proposal, ProvenanceLink, TrajectoryStage } from '../domain/types'

/**
 * The agent layer. Every agent reads the project and emits Proposals — never
 * mutates state directly. The human approves a Proposal (a research diff) before
 * anything changes.
 *
 * Each agent has two paths:
 *  - `prompt(ctx)` → the model path. Builds a system/user prompt; the runner
 *    forces an `emit_proposal` tool-call and deserializes it into Proposals.
 *  - `run(ctx)` → the deterministic path. Hand-authored output that works with
 *    no key/network, and the fallback when the model path is unavailable.
 */
export interface AgentContext {
  project: Project
  /** Free-text steering from the human, e.g. "make it smaller, open models only". */
  instruction?: string
  /** Relevance-ranked, budget-fit project context (see lib/relevance). */
  contextText?: string
}

export interface AgentMeta {
  id: AgentId
  name: string
  role: string
  stage: TrajectoryStage
  /** lucide-react icon name. */
  icon: string
}

export interface Agent {
  meta: AgentMeta
  /** Deterministic generator — the offline default and the model-path fallback. */
  run(ctx: AgentContext): Promise<Proposal[]>
  /** Optional: build the model prompt for the structured-output path. */
  prompt?(ctx: AgentContext): { system: string; user: string }
  /** Optional: provenance to attach to model-emitted proposals. */
  evidence?(ctx: AgentContext): ProvenanceLink[]
}

export const AGENT_META: Record<AgentId, AgentMeta> = {
  literature: { id: 'literature', name: 'Literature', role: 'Extracts claims, methods & limitations from the corpus', stage: 'claims', icon: 'Library' },
  novelty: { id: 'novelty', name: 'Novelty', role: 'Checks whether an idea has been done', stage: 'ideas', icon: 'Sparkles' },
  hypothesis: { id: 'hypothesis', name: 'Hypothesis', role: 'Proposes evidence-grounded research directions', stage: 'ideas', icon: 'Lightbulb' },
  planning: { id: 'planning', name: 'Planning', role: 'Turns an idea into an executable experiment plan', stage: 'experiments', icon: 'ListChecks' },
  coding: { id: 'coding', name: 'Coding', role: 'Scaffolds the repo and writes experiment code', stage: 'runs', icon: 'Code2' },
  execution: { id: 'execution', name: 'Execution', role: 'Runs experiments, debugs, keeps the lab notebook', stage: 'runs', icon: 'Play' },
  analysis: { id: 'analysis', name: 'Analysis', role: 'Interprets results — real or noise?', stage: 'analysis', icon: 'BarChart3' },
  writing: { id: 'writing', name: 'Writing', role: 'Drafts artifact-grounded prose', stage: 'manuscript', icon: 'PenLine' },
  reviewer: { id: 'reviewer', name: 'Reviewer', role: 'Simulates peer review tied to evidence', stage: 'review', icon: 'Gavel' },
  citation: { id: 'citation', name: 'Citation', role: 'Verifies every reference actually supports its sentence', stage: 'manuscript', icon: 'BadgeCheck' },
  human: { id: 'human', name: 'You', role: 'Reviews and steers every transition', stage: 'corpus', icon: 'User' },
}
