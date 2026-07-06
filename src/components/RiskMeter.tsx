import type { RiskScore } from '../domain/types'

interface Props {
  value: RiskScore
  label?: string
  /** 'risk' colors high values red; 'good' (e.g. feasibility) stays neutral. */
  tone?: 'risk' | 'neutral'
}

/** Five-pip meter for novelty risk / feasibility / reviewer severity. */
export function RiskMeter({ value, label, tone = 'neutral' }: Props) {
  const cls = tone === 'risk' ? (value >= 4 ? 'danger' : value >= 3 ? 'warn' : '') : ''
  return (
    <span className="riskmeter-wrap row gap-3" title={label ? `${label}: ${value}/5` : `${value}/5`}>
      {label && <span className="faint" style={{ fontSize: 'var(--fs-11)' }}>{label}</span>}
      <span className={`riskmeter ${cls}`}>
        {[1, 2, 3, 4, 5].map((i) => (
          <span key={i} className={`pip ${i <= value ? 'on' : ''}`} />
        ))}
      </span>
    </span>
  )
}
