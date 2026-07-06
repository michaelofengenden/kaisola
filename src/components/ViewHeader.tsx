import type { ReactNode } from 'react'
import { Icon } from './Icon'

/** Consistent header for every stage view: title, blurb, and right-aligned actions. */
export function ViewHeader({
  icon,
  title,
  sub,
  children,
}: {
  icon: string
  title: string
  sub?: string
  children?: ReactNode
}) {
  return (
    <header className="view-header">
      <div className="view-header-icon">
        <Icon name={icon} size={18} />
      </div>
      <div className="grow" style={{ minWidth: 0 }}>
        <h1 className="view-title">{title}</h1>
        {sub && <p className="view-sub muted">{sub}</p>}
      </div>
      {children && <div className="view-header-actions row gap-3">{children}</div>}
    </header>
  )
}
