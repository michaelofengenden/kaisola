/**
 * Idea tournament — pairwise Elo over hypotheses (the co-scientist pattern),
 * instead of a single flat novelty/feasibility number.
 *
 * The comparator is pluggable. Offline (the default, deterministic, verified) a
 * pair is scored by a logistic of the difference in a composite quality score.
 * With a key, a model `judge(a, b)` can return P(a beats b) from a simulated
 * debate — the Elo machinery is identical, only the comparator changes.
 */
import type { Hypothesis } from '../domain/types'
import { trustRank, linkTrust } from '../domain/trust'

export interface RankedHypothesis {
  hyp: Hypothesis
  /** Final Elo rating. */
  elo: number
  /** 1-based rank (1 = best). */
  rank: number
}

/** Probability a pairwise judge returns; offline derived from compositeScore. */
export type Judge = (a: Hypothesis, b: Hypothesis) => number | Promise<number>

/**
 * A deterministic composite quality score in [0, 1].
 *  - novelty peaks at "defensibly novel" (~3.5/5), penalising both trivial (1)
 *    and reckless (5) ideas;
 *  - feasibility rewards lower risk (more feasible);
 *  - evidence rewards more + higher-trust provenance;
 *  - a small bonus for a stated expected contribution and an MVP.
 */
export function compositeScore(h: Hypothesis): number {
  const novelty = 1 - Math.abs(h.noveltyRisk - 3.5) / 3.5 // peak at 3.5
  const feasibility = (6 - h.feasibility) / 5 // 1 (most feasible) → 1.0
  const provCount = Math.min(1, h.provenance.length / 3)
  const trust = h.provenance.length
    ? Math.max(...h.provenance.map((p) => trustRank(linkTrust(p)))) / 3
    : 0
  const evidence = 0.5 * provCount + 0.5 * trust
  const bonus = (h.expectedContribution ? 0.5 : 0) + (h.mvp ? 0.5 : 0)
  return 0.35 * novelty + 0.3 * feasibility + 0.25 * evidence + 0.1 * bonus
}

function logistic(x: number): number {
  return 1 / (1 + Math.exp(-x))
}

/** The default offline judge: P(a beats b) from the composite-score gap. */
export function offlineJudge(a: Hypothesis, b: Hypothesis): number {
  return logistic(6 * (compositeScore(a) - compositeScore(b)))
}

/**
 * Run a round-robin Elo tournament. `judge(a,b)` returns P(a beats b); the
 * "actual" Elo result for the pair IS that probability (no RNG → deterministic).
 * Two passes over all unordered pairs stabilise the ratings.
 */
export async function tournament(
  hypotheses: Hypothesis[],
  judge: Judge = offlineJudge,
  opts?: { k?: number; passes?: number },
): Promise<RankedHypothesis[]> {
  const K = opts?.k ?? 24
  const passes = opts?.passes ?? 2
  const n = hypotheses.length
  if (n === 0) return []
  const elo = new Array(n).fill(1000)
  for (let pass = 0; pass < passes; pass++) {
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        const p = await judge(hypotheses[i], hypotheses[j])
        const sa = Math.max(0, Math.min(1, typeof p === 'number' ? p : 0.5))
        const ea = 1 / (1 + 10 ** ((elo[j] - elo[i]) / 400))
        elo[i] += K * (sa - ea)
        elo[j] += K * (1 - sa - (1 - ea))
      }
    }
  }
  return hypotheses
    .map((hyp, i) => ({ hyp, elo: Math.round(elo[i]) }))
    .sort((a, b) => b.elo - a.elo)
    .map((r, idx) => ({ ...r, rank: idx + 1 }))
}
