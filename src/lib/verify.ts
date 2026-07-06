/**
 * Citation verification — turning `CitationProvenance.verified` from a flag a
 * human flips into something computed.
 *
 * Pipeline (the AutoAIS / NLI shape, scoped to what's verifiable offline):
 *   1. quote-match — does the cited quote actually appear in the source text?
 *   2. entailment — does that quote support the claim?
 *   verified ⟺ the quote is found AND it entails the claim above a threshold.
 *
 * The entailment judge is pluggable: offline it's a lexical-recall proxy
 * (deterministic, verified); with a key it can be swapped for NLI-style model
 * entailment. 2025 work stresses correctness ≠ faithfulness, so a found-but-
 * unsupportive quote is reported, not rubber-stamped.
 */
import { tokenize } from './relevance'
import type { CitationStance } from '../domain/types'

export interface VerificationResult {
  verified: boolean
  /** 0..1 overall confidence. */
  confidence: number
  /** Whether the quote was located in the source text. */
  quoteFound: boolean
  /** 0..1 entailment proxy (does the quote support the claim?). */
  supportScore: number
  /** How the source stands toward the claim (scite.ai-style). */
  stance: CitationStance
  reason: string
}

/** Word-boundary cues that a quote pushes AGAINST a claim (deterministic proxy). */
const CONTRAST_RE =
  /\b(?:however|but|fails?|failed|does not|doesn'?t|did not|no evidence|contrary|contradicts?|unlike|cannot|can'?t|never|refut\w*|disagree\w*|unable|not supported|no significant|in contrast|whereas)\b/i

/**
 * Deterministic offline stance proxy: supporting (quote entails the claim),
 * contrasting (topically related but carries a negation/contrast cue), or
 * mentioning (referenced without clearly backing the claim). Pluggable for a
 * model NLI judge later — same shape, zero API cost offline.
 *
 * A quote that STRONGLY entails the claim is supporting — we never demote it to
 * contrasting on an incidental cue word (so "no significant overhead, supporting
 * feasibility" is not misread as a contradiction). Word-boundary cues also keep
 * "failure modes"/"gracefully" from tripping the 'fail' cue. Contrast only wins
 * for weakly-entailing quotes.
 */
export function classifyStance(quote: string, claim: string, quoteFound: boolean): CitationStance {
  if (!quote || !quoteFound) return 'mentioning'
  const support = offlineEntailment(quote, claim)
  if (support >= 0.5) return 'supporting'
  if (CONTRAST_RE.test(quote) && support >= 0.25) return 'contrasting'
  return 'mentioning'
}

export type EntailmentJudge = (quote: string, claim: string) => number | Promise<number>

function norm(s: string): string {
  return s.toLowerCase().replace(/\s+/g, ' ').trim()
}

/** Fuzzy containment: exact substring, else ≥80% of the needle's tokens present. */
export function fuzzyContains(haystack: string, needle: string): boolean {
  const h = norm(haystack)
  const n = norm(needle)
  if (!n) return false
  if (h.includes(n)) return true
  const nTokens = tokenize(n)
  if (nTokens.length === 0) return false
  const hTokens = new Set(tokenize(h))
  const hit = nTokens.filter((t) => hTokens.has(t)).length
  return hit / nTokens.length >= 0.8
}

/** Offline entailment proxy: fraction of the claim's content words the quote covers. */
export function offlineEntailment(quote: string, claim: string): number {
  const claimTokens = tokenize(claim)
  if (claimTokens.length === 0) return 0
  const quoteTokens = new Set(tokenize(quote))
  const covered = claimTokens.filter((t) => quoteTokens.has(t)).length
  return covered / claimTokens.length
}

export interface VerifyArgs {
  quote?: string
  /** The claim the citation is meant to support. */
  claim: string
  /** Source text to search the quote in (title + abstract + summary). */
  sourceText?: string
}

/**
 * Verify a single citation. Always resolves with a result — a missing quote or
 * source is reported as unverified, never thrown.
 */
export async function verifyCitation(
  args: VerifyArgs,
  judge: EntailmentJudge = offlineEntailment,
): Promise<VerificationResult> {
  const quote = args.quote?.trim() ?? ''
  if (!quote) {
    return { verified: false, confidence: 0, quoteFound: false, supportScore: 0, stance: 'mentioning', reason: 'No quote attached to verify.' }
  }
  const quoteFound = args.sourceText ? fuzzyContains(args.sourceText, quote) : false
  const supportRaw = await judge(quote, args.claim)
  const supportScore = Math.max(0, Math.min(1, typeof supportRaw === 'number' ? supportRaw : 0))
  const verified = quoteFound && supportScore >= 0.5
  const stance = classifyStance(quote, args.claim, quoteFound)
  const confidence = quoteFound ? 0.5 + 0.5 * supportScore : 0.2 * supportScore
  const reason = !quoteFound
    ? args.sourceText
      ? 'Quote not located in the source — cannot verify.'
      : 'Source text unavailable — cannot verify.'
    : verified
      ? `Quote found and supports the claim (${Math.round(supportScore * 100)}% coverage).`
      : `Quote found but weakly supports the claim (${Math.round(supportScore * 100)}% coverage).`
  return { verified, confidence, quoteFound, supportScore, stance, reason }
}
