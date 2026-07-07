import type { ProvenanceLink, TrustLevel, Provenanced, Section } from './types'

const ORDER: TrustLevel[] = ['unsupported', 'low', 'medium', 'high']

export function trustRank(t: TrustLevel): number {
  return ORDER.indexOf(t)
}

export function minTrust(levels: TrustLevel[]): TrustLevel {
  if (levels.length === 0) return 'unsupported'
  return levels.reduce((a, b) => (trustRank(a) <= trustRank(b) ? a : b))
}

/**
 * Trust of a single provenance link.
 *  - a verified citation, or an experiment result → high
 *  - an unverified citation, a derivation, or a dataset → medium
 *  - a human note → low (agency without external support)
 *
 * A `result` grades `high` outright — a recorded experiment result is a strong
 * source. Per-seed grading isn't done here: the ProvenanceLink carries no seed
 * count (seeds live on ResultRecord, not reachable from the link).
 */
export function linkTrust(link: ProvenanceLink): TrustLevel {
  switch (link.kind) {
    case 'citation':
      return link.verified ? 'high' : 'medium'
    case 'result':
      return 'high'
    case 'derivation':
      return 'medium'
    case 'dataset':
      return 'medium'
    case 'note':
      return 'low'
  }
}

/**
 * The opinionated rule, computed: a claim with no provenance is `unsupported`.
 * Otherwise its trust is the BEST available support (a claim is as strong as
 * its strongest leg).
 */
export function computeTrust(links: ProvenanceLink[]): TrustLevel {
  if (!links || links.length === 0) return 'unsupported'
  return links.map(linkTrust).reduce((a, b) => (trustRank(a) >= trustRank(b) ? a : b))
}

export function recomputeProvenanced<T extends Provenanced>(item: T): T {
  return { ...item, trust: computeTrust(item.provenance) }
}

/** A section's trust is the WEAKEST of its claims — one unsupported claim taints it. */
export function sectionTrust(section: Section): TrustLevel {
  if (section.claims.length === 0) return 'medium'
  return minTrust(section.claims.map((c) => (c.speculative ? 'medium' : c.trust)))
}

export const TRUST_LABEL: Record<TrustLevel, string> = {
  high: 'High',
  medium: 'Medium',
  low: 'Low',
  unsupported: 'Unsupported',
}
