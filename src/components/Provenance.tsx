import { useEffect, useRef } from 'react'
import type { ProvenanceLink } from '../domain/types'
import { useKaisola } from '../store/store'
import { resolveProvenance } from '../lib/provenance'
import { Icon } from './Icon'

/**
 * An inline "evidence" chip. Click it to open the provenance popover explaining
 * exactly what supports the thing it is attached to. This is the interaction
 * that makes provenance feel first-class: every claim is one click from its
 * source.
 */
export function ProvenanceChip({
  links,
  title,
  label,
}: {
  links: ProvenanceLink[]
  title: string
  label?: string
}) {
  const show = useKaisola((s) => s.showProvenance)
  if (links.length === 0) {
    return (
      <button className="prov-chip prov-chip-empty" title="No evidence attached" disabled>
        <Icon name="Unlink" size={11} />
        unsupported
      </button>
    )
  }
  return (
    <button
      className="prov-chip"
      onClick={(e) => {
        const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
        show({ title, links, anchor: { x: r.left, y: r.bottom + 6 } })
      }}
      title="Show evidence"
    >
      <Icon name="Link2" size={11} />
      {label ?? `${links.length} source${links.length > 1 ? 's' : ''}`}
    </button>
  )
}

/** Global provenance popover. Mount once near the app root. */
export function ProvenancePopover() {
  const target = useKaisola((s) => s.provenance)
  const project = useKaisola((s) => s.project)
  const hide = useKaisola((s) => s.hideProvenance)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!target) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && hide()
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) hide()
    }
    document.addEventListener('keydown', onKey)
    // defer so the opening click doesn't immediately close it
    const t = setTimeout(() => document.addEventListener('mousedown', onClick), 0)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('mousedown', onClick)
      clearTimeout(t)
    }
  }, [target, hide])

  if (!target) return null
  const x = target.anchor?.x ?? 120
  const y = target.anchor?.y ?? 120
  const left = Math.min(x, window.innerWidth - 380)

  return (
    <div
      ref={ref}
      className="prov-pop"
      style={{ left, top: y }}
      role="dialog"
      aria-label="Evidence"
    >
      <header className="prov-pop-head">
        <Icon name="ShieldCheck" size={13} />
        <span className="grow truncate">{target.title}</span>
        <button className="btn-icon btn-sm" onClick={hide} aria-label="Close">
          <Icon name="X" size={13} />
        </button>
      </header>
      <div className="prov-pop-body">
        {target.links.map((link) => {
          const r = resolveProvenance(link, project)
          return (
            <div key={link.id} className={`prov-row prov-${r.kind}`}>
              <Icon name={r.icon} size={14} className="prov-row-icon" />
              <div className="grow" style={{ minWidth: 0 }}>
                <div className="row gap-3">
                  <span className="prov-kind">{r.kind}</span>
                  {r.verified != null &&
                    (r.verified ? (
                      <span className="prov-verified">
                        <Icon name="BadgeCheck" size={11} /> verified
                      </span>
                    ) : (
                      <span className="prov-unverified">
                        <Icon name="AlertTriangle" size={11} /> unverified
                      </span>
                    ))}
                  {link.kind === 'citation' && link.stance && (
                    <span className={`prov-stance stance-${link.stance}`} title={`This source ${link.stance === 'mentioning' ? 'mentions' : link.stance === 'supporting' ? 'supports' : 'contrasts with'} the claim`}>
                      <Icon name={link.stance === 'supporting' ? 'ThumbsUp' : link.stance === 'contrasting' ? 'ThumbsDown' : 'Minus'} size={11} /> {link.stance}
                    </span>
                  )}
                </div>
                <div className="prov-label">{r.label}</div>
                {r.detail && <div className="prov-detail serif">{r.detail}</div>}
                {link.kind === 'citation' && (link.bbox || link.locator) && (
                  <div className="prov-locator faint">
                    <Icon name="MapPin" size={10} />
                    {link.bbox ? `PDF p.${link.bbox.page} · pinned rectangle` : link.locator}
                  </div>
                )}
              </div>
            </div>
          )
        })}
      </div>
      <footer className="prov-pop-foot faint">
        Every claim must link to a citation, result, derivation, dataset, or note.
      </footer>
    </div>
  )
}
