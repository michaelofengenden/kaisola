import type { TrustLevel } from '../domain/types'
import { TRUST_LABEL } from '../domain/trust'

interface Props {
  trust: TrustLevel
  /** Show the word, or just the dot. */
  compact?: boolean
  title?: string
}

/**
 * The trust badge. Provenance is first-class, so trust gets its own color
 * language everywhere it appears (sections, claims, hypotheses, graph nodes).
 */
export function TrustBadge({ trust, compact, title }: Props) {
  return (
    <span
      className={`trust trust-${trust}`}
      title={title ?? `Trust: ${TRUST_LABEL[trust]}`}
      aria-label={`Trust ${TRUST_LABEL[trust]}`}
    >
      {!compact && TRUST_LABEL[trust]}
    </span>
  )
}
