import type { TrajectoryStage, AgentId } from '../domain/types'

/**
 * A thin supervisor (the co-scientist pattern, scoped). Instead of firing every
 * agent independently, it sequences the right agents for the stage you're on —
 * e.g. *ideas* runs Hypothesis then Novelty. Each still emits a human-reviewable
 * proposal; the supervisor only decides ordering. Deliberately a plain mapping
 * (no autonomy, no loops) so it stays inspectable and minimal.
 */
export const STAGE_AGENTS: Partial<Record<TrajectoryStage, AgentId[]>> = {
  corpus: ['literature'],
  claims: ['literature'],
  questions: ['literature', 'hypothesis'],
  ideas: ['hypothesis', 'novelty'],
  experiments: ['planning'],
  runs: ['execution'],
  analysis: ['analysis'],
  manuscript: ['writing', 'citation'],
  review: ['reviewer'],
}

export function agentsForStage(stage: TrajectoryStage): AgentId[] {
  return STAGE_AGENTS[stage] ?? []
}
