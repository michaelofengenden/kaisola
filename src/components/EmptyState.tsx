import type { ReactNode } from 'react'
import { Icon } from './Icon'

/** A calm, centered empty state. Used wherever a stage has nothing yet. */
export function EmptyState({
  icon,
  title,
  hint,
  children,
}: {
  icon: string
  title: string
  hint?: string
  children?: ReactNode
}) {
  return (
    <div className="emptystate">
      <Icon name={icon} size={22} strokeWidth={1.5} />
      <div className="emptystate-title">{title}</div>
      {hint && <div className="emptystate-hint">{hint}</div>}
      {children}
    </div>
  )
}
