/**
 * Claim/citation linter — surfaces evidence problems on any Provenanced item as
 * inline issues (the "red-squiggle an unsupported sentence" UX). Pure and
 * deterministic: it reads the already-computed `trust` and the citations'
 * `verified` flags — NO model calls, zero API cost. The 'unverified-citation'
 * issue is fixable in place by the existing Verify-citations action.
 */
import type { Provenanced } from '../domain/types'

export type LintKind = 'unsupported' | 'unverified-citation'

export interface LintIssue {
  kind: LintKind
  message: string
}

/** Lint a claim / graph node / hypothesis. Speculative claims are exempt from 'unsupported'. */
export function lintProvenanced(item: Provenanced & { speculative?: boolean }): LintIssue[] {
  const issues: LintIssue[] = []
  if (item.trust === 'unsupported' && !item.speculative) {
    issues.push({ kind: 'unsupported', message: 'Unsupported — add a citation, result, or mark speculative.' })
  }
  const unverified = item.provenance.filter((p) => p.kind === 'citation' && p.verified === false).length
  if (unverified > 0) {
    issues.push({
      kind: 'unverified-citation',
      message: `Cited but unverified${unverified > 1 ? ` (${unverified})` : ''} — run Verify citations to check the quote supports the claim.`,
    })
  }
  return issues
}

/** The worst lint kind on an item, for the squiggle color (unsupported beats unverified). */
export function lintSeverity(issues: LintIssue[]): LintKind | null {
  if (issues.some((i) => i.kind === 'unsupported')) return 'unsupported'
  if (issues.some((i) => i.kind === 'unverified-citation')) return 'unverified-citation'
  return null
}
