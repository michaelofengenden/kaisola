import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { bridge, isDesktop, type ClaudeTokenSums, type ClaudeUsage, type CodexUsage } from '../../lib/bridge'
import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'

/** Top-bar usage gauge. Codex exposes real rolling-window percentages through
 * its app-server. Claude's supported local surface only exposes transcript
 * token activity, so that section is deliberately labelled rather than
 * presenting an invented subscription percentage. */

const fmt = (n: number): string =>
  n >= 1e9 ? `${(n / 1e9).toFixed(1)}B`
    : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M`
      : n >= 1e3 ? `${(n / 1e3).toFixed(0)}k`
        : String(n)

const relativeTime = (at?: number): string => {
  if (!at) return 'never'
  const mins = Math.max(0, Math.round((Date.now() - at) / 60_000))
  if (mins < 1) return 'just now'
  if (mins < 60) return `${mins}m ago`
  const hours = Math.round(mins / 60)
  return hours < 48 ? `${hours}h ago` : `${Math.round(hours / 24)}d ago`
}

const resetIn = (epochSec?: number): string => {
  if (!epochSec) return ''
  const totalMins = Math.max(0, Math.round((epochSec * 1000 - Date.now()) / 60_000))
  if (totalMins <= 0) return 'resets soon'
  if (totalMins >= 48 * 60) return `resets in ${Math.round(totalMins / 1440)}d`
  const h = Math.floor(totalMins / 60)
  const m = totalMins % 60
  return h > 0 ? `resets in ${h}h ${m}m` : `resets in ${m}m`
}

function WindowBar({ label, usedPercent, resetsAt, color = 'var(--accent)' }: {
  label: string
  usedPercent?: number
  resetsAt?: number
  color?: string
}) {
  const pct = Math.max(0, Math.min(100, usedPercent ?? 0))
  const tone = pct >= 90 ? 'var(--danger)' : pct >= 70 ? 'var(--warn)' : color
  const reset = resetIn(resetsAt)
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12 }}>
        <span>{label}</span>
        <span className="faint">
          {usedPercent != null ? `${Math.round(pct)}% used${reset ? ` · ${reset}` : ''}` : 'Not reported'}
        </span>
      </div>
      <div style={{ height: 5, borderRadius: 'var(--r-full)', background: 'var(--bg-inset)', overflow: 'hidden' }}>
        <div style={{ width: `${pct}%`, height: '100%', borderRadius: 'var(--r-full)', background: tone, transition: 'width 180ms ease-out' }} />
      </div>
    </div>
  )
}

const activityTokens = (s?: ClaudeTokenSums): number => s ? s.input + s.output + s.cacheWrite : 0

function ClaudeActivity({ label, sums }: { label: string; sums?: ClaudeTokenSums }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12 }}>
      <span>{label}</span>
      <span className="faint" title={sums ? `${fmt(sums.cacheRead)} cache-read tokens (shown separately because they do not reveal a plan percentage)` : undefined}>
        {sums ? `${fmt(activityTokens(sums))} tokens · ${fmt(sums.cacheRead)} cached` : '—'}
      </span>
    </div>
  )
}

interface ClaudeRow { id: string; label: string; email?: string; usage?: ClaudeUsage }

export function LimitsButton() {
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState<{ right: number; top: number }>({ right: 12, top: 44 })
  const [codexLoading, setCodexLoading] = useState(false)
  const [claudeLoading, setClaudeLoading] = useState(false)
  const [codex, setCodex] = useState<CodexUsage | null>(null)
  const [claude, setClaude] = useState<ClaudeRow[]>([])
  const [updatedAt, setUpdatedAt] = useState(0)
  const btnRef = useRef<HTMLButtonElement | null>(null)
  const seqRef = useRef(0)
  const initialLoadRef = useRef(false)

  const load = useCallback(async () => {
    if (!bridge.usage) return
    const seq = ++seqRef.current
    const accounts = useKaisola.getState().claudeAccounts
    const accountRows = [
      { id: '__default__', label: 'Default', configDir: undefined as string | undefined, email: undefined as string | undefined },
      ...accounts.map((a) => ({ id: a.id, label: a.label, configDir: a.configDir, email: a.email })),
    ]

    // Keep the last good values visible during refresh, but immediately reflect
    // added/removed account rows.
    setClaude((previous) => accountRows.map((row) => ({
      id: row.id,
      label: row.label,
      email: row.email ?? previous.find((p) => p.id === row.id)?.email,
      usage: previous.find((p) => p.id === row.id)?.usage,
    })))
    setCodexLoading(true)
    setClaudeLoading(true)

    // Do not put these in one Promise.all: a missing Codex executable used to
    // hold the already-finished Claude result hostage for the full timeout.
    const codexTask = bridge.usage.codex()
      .catch((err) => ({ ok: false, message: String((err as Error)?.message || err || 'Unavailable') } as CodexUsage))
      .then((result) => { if (seq === seqRef.current) setCodex(result) })
      .finally(() => { if (seq === seqRef.current) setCodexLoading(false) })

    const claudeTask = (async () => {
      const infoTask = bridge.claude.accountInfo?.().catch(() => undefined) ?? Promise.resolve(undefined)
      const usages = await Promise.all(accountRows.map((row) => bridge.usage!.claude(row.configDir).catch((err) => ({ ok: false, message: String((err as Error)?.message || err) } as ClaudeUsage))))
      const defaultInfo = await infoTask
      if (seq !== seqRef.current) return
      setClaude(accountRows.map((row, i) => ({
        id: row.id,
        label: row.label,
        email: i === 0 ? defaultInfo?.email : row.email,
        usage: usages[i],
      })))
    })().finally(() => { if (seq === seqRef.current) setClaudeLoading(false) })

    await Promise.allSettled([codexTask, claudeTask])
    if (seq === seqRef.current) setUpdatedAt(Date.now())
  }, [])

  const toggle = () => {
    if (!open) {
      const r = btnRef.current?.getBoundingClientRect()
      if (r) setPos({ right: Math.max(8, window.innerWidth - r.right), top: r.bottom + 6 })
      void load()
    }
    setOpen(!open)
  }

  // Prime the gauge once after startup; opening the panel always refreshes.
  useEffect(() => {
    if (bridge.smoke) return
    if (initialLoadRef.current) return
    initialLoadRef.current = true
    void load()
  }, [load])

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open])

  if (!isDesktop || !bridge.usage) return null
  const peak = codex?.ok ? Math.max(codex.primary?.usedPercent ?? 0, codex.secondary?.usedPercent ?? 0) : null
  const indicator = codexLoading && !codex
    ? 'var(--text-3)'
    : peak == null ? 'var(--text-3)' : peak >= 90 ? 'var(--danger)' : peak >= 70 ? 'var(--warn)' : 'var(--success)'

  return (
    <>
      <button
        ref={btnRef}
        className="btn-icon"
        data-active={open}
        onClick={toggle}
        title={codex?.ok ? `Usage — Codex ${Math.round(codex.primary?.usedPercent ?? 0)}% current, ${Math.round(codex.secondary?.usedPercent ?? 0)}% weekly` : 'Usage — Claude & Codex'}
        aria-label="Open Claude and Codex usage"
        style={{ position: 'relative' }}
      >
        <Icon name="Gauge" size={15} />
        <span aria-hidden style={{ position: 'absolute', width: 6, height: 3, borderRadius: 3, right: 5, top: 5, background: indicator }} />
      </button>
      {open && createPortal(
        <div className="tree-menu-overlay" onMouseDown={() => setOpen(false)}>
          <div
            className="limits-panel"
            style={{
              position: 'fixed', right: pos.right, top: pos.top, width: 350, maxHeight: 'min(620px, calc(100vh - 70px))', overflowY: 'auto', zIndex: 'var(--z-menu, 900)' as never,
              background: 'var(--bg-3)', border: '1px solid var(--border)', borderRadius: 'var(--r-3, 10px)',
              boxShadow: 'var(--shadow-3, 0 12px 40px rgba(0,0,0,.4))', padding: '12px 14px',
              display: 'flex', flexDirection: 'column', gap: 13, fontSize: 'var(--fs-12)',
            }}
            onMouseDown={(e) => e.stopPropagation()}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
              <Icon name="Gauge" size={14} />
              <span style={{ fontWeight: 600 }}>Usage</span>
              <span className="faint">Updated {relativeTime(updatedAt)}</span>
              <span className="grow" />
              <button className="btn-icon btn-sm" onClick={() => void load()} title="Refresh usage" disabled={codexLoading || claudeLoading}>
                <Icon name="RefreshCw" size={12} />
              </button>
            </div>

            <section style={{ display: 'flex', flexDirection: 'column', gap: 9 }} aria-label="Codex usage">
              <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                <span style={{ fontWeight: 600 }}>Codex</span>
                <span className="faint truncate">{codex?.ok ? [codex.email, codex.plan].filter(Boolean).join(' · ') : ''}</span>
              </div>
              {codex?.ok ? (
                <>
                  <WindowBar label="Current session" usedPercent={codex.primary?.usedPercent} resetsAt={codex.primary?.resetsAt} color="var(--success)" />
                  <WindowBar label="Weekly" usedPercent={codex.secondary?.usedPercent} resetsAt={codex.secondary?.resetsAt} color="var(--accent)" />
                </>
              ) : (
                <span className="faint">{codexLoading ? 'Reading Codex limits…' : codex?.message ?? 'Not available'}</span>
              )}
            </section>

            <div style={{ height: 1, background: 'var(--border)' }} />

            <section style={{ display: 'flex', flexDirection: 'column', gap: 9 }} aria-label="Claude local activity">
              <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                <span style={{ fontWeight: 600 }}>Claude</span>
                <span className="faint">local activity</span>
              </div>
              {claude.length === 0 && <span className="faint">{claudeLoading ? 'Reading Claude transcripts…' : 'No accounts'}</span>}
              {claude.map((row) => {
                const usage = row.usage
                return (
                  <div key={row.id} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                    <div style={{ display: 'flex', alignItems: 'baseline', gap: 7, minWidth: 0 }}>
                      <span style={{ fontWeight: 500, whiteSpace: 'nowrap' }}>{row.label}</span>
                      <span className="faint truncate" title={row.email}>{row.email}</span>
                      <span className="grow" />
                      {usage?.lastActivity ? <span className="faint" style={{ whiteSpace: 'nowrap' }}>{relativeTime(usage.lastActivity)}</span> : null}
                    </div>
                    {usage?.ok && usage.exists ? (
                      <>
                        <ClaudeActivity label="Last 5 hours" sums={usage.fiveHour} />
                        <ClaudeActivity label="Last 7 days" sums={usage.week} />
                        {usage.partial && <span className="faint" style={{ fontSize: 'var(--fs-10, 10px)' }}>Recent {usage.scannedFiles ?? ''} transcript files shown; older activity was capped.</span>}
                      </>
                    ) : (
                      <span className="faint">{claudeLoading && !usage ? 'Reading…' : usage?.message ?? 'No local activity found'}</span>
                    )}
                  </div>
                )
              })}
              <span className="faint" style={{ fontSize: 'var(--fs-10, 10px)', lineHeight: 1.4 }}>
                Anthropic does not expose an exact subscription meter to desktop clients. These are local transcript tokens, not plan percentages; use <code>/usage</code> in Claude for the official view.
              </span>
            </section>
          </div>
        </div>,
        document.body,
      )}
    </>
  )
}
