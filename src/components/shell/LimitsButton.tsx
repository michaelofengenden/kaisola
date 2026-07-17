import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { bridge, isDesktop, type ClaudeTokenSums, type ClaudeUsage, type CodexUsage, type OpenCodeUsage } from '../../lib/bridge'
import { useClickAway } from '../../lib/useClickAway'
import { shellConfigDir, useKaisola } from '../../store/store'
import { Icon } from '../Icon'

/** Top-bar usage gauge. Codex uses app-server; Claude uses the official Agent
 * SDK's structured `/usage` control, with a best-effort status-line fallback.
 * OpenCode and transcript tokens remain clearly secondary local diagnostics. */

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
        <div style={{ width: '100%', height: '100%', borderRadius: 'var(--r-full)', background: tone, transform: `scaleX(${pct / 100})`, transformOrigin: 'left', transition: 'transform 180ms ease-out' }} />
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

const EXTRA_AMOUNT_FORMATTERS = new Map<string, Intl.NumberFormat>()

const extraAmount = (value: number | undefined, currency?: string): string => {
  if (value == null) return '—'
  try {
    const key = currency || 'decimal'
    let formatter = EXTRA_AMOUNT_FORMATTERS.get(key)
    if (!formatter) {
      formatter = new Intl.NumberFormat(undefined, {
        style: currency ? 'currency' : 'decimal',
        currency: currency || undefined,
        maximumFractionDigits: 2,
      })
      EXTRA_AMOUNT_FORMATTERS.set(key, formatter)
    }
    return formatter.format(value)
  } catch {
    return `${value.toFixed(2)}${currency ? ` ${currency}` : ''}`
  }
}

interface ClaudeRow { id: string; label: string; email?: string; usage?: ClaudeUsage }
interface CodexRow { id: string; label: string; codexHome?: string; usage?: CodexUsage }
const AGENT_USAGE_KEY = 'kaisola:agent-usage-warning:v1'

function UsageSurface({ embedded = false }: { embedded?: boolean }) {
  const [open, setOpen] = useState(embedded)
  const [pos, setPos] = useState<{ left?: number; right?: number; top?: number; bottom?: number }>({ right: 12, top: 44 })
  const [codexLoading, setCodexLoading] = useState(false)
  const [claudeLoading, setClaudeLoading] = useState(false)
  const [openCodeLoading, setOpenCodeLoading] = useState(false)
  const [codex, setCodex] = useState<CodexRow[]>([])
  const [openCode, setOpenCode] = useState<OpenCodeUsage | null>(null)
  const [claude, setClaude] = useState<ClaudeRow[]>([])
  const [updatedAt, setUpdatedAt] = useState(0)
  const btnRef = useRef<HTMLButtonElement | null>(null)
  const panelRef = useRef<HTMLDivElement | null>(null)
  const seqRef = useRef(0)
  const initialLoadRef = useRef(false)
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const close = useCallback(() => setOpen(false), [])

  const load = useCallback(async (force = false, exactOnly = false) => {
    if (!bridge.usage) return
    const seq = ++seqRef.current
    const state = useKaisola.getState()
    const accounts = state.claudeAccounts
    const accountRows = [
      { id: '__default__', label: 'Default', configDir: undefined as string | undefined, email: undefined as string | undefined },
      ...accounts.map((a) => ({ id: a.id, label: a.label, configDir: a.configDir, email: a.email })),
    ]
    const codexRows = [
      { id: '__default__', label: 'Default', codexHome: undefined as string | undefined },
      ...state.codexAccounts.map((account) => ({ id: account.id, label: account.label, codexHome: account.codexHome })),
    ]

    // Keep the last good values visible during refresh, but immediately reflect
    // added/removed account rows.
    setClaude((previous) => accountRows.map((row) => ({
      id: row.id,
      label: row.label,
      email: row.email ?? previous.find((p) => p.id === row.id)?.email,
      usage: previous.find((p) => p.id === row.id)?.usage,
    })))
    setCodex((previous) => codexRows.map((row) => ({ ...row, usage: previous.find((item) => item.id === row.id)?.usage })))
    setCodexLoading(true)
    setClaudeLoading(true)
    setOpenCodeLoading(!exactOnly)

    // Do not put these in one Promise.all: a missing Codex executable used to
    // hold the already-finished Claude result hostage for the full timeout.
    const codexTask = Promise.all(codexRows.map((row) => bridge.usage!.codex(row.codexHome, force)
      .catch((err) => ({ ok: false, message: String((err as Error)?.message || err || 'Unavailable') } as CodexUsage))))
      .then((usages) => {
        if (seq === seqRef.current) setCodex(codexRows.map((row, index) => ({ ...row, usage: usages[index] })))
      })
      .finally(() => { if (seq === seqRef.current) setCodexLoading(false) })

    const openCodeTask = exactOnly
      ? Promise.resolve()
      : bridge.usage.opencode(force)
        .catch((err) => ({ ok: false, message: String((err as Error)?.message || err || 'Unavailable') } as OpenCodeUsage))
        .then((usage) => { if (seq === seqRef.current) setOpenCode(usage) })
        .finally(() => { if (seq === seqRef.current) setOpenCodeLoading(false) })

    const claudeTask = (async () => {
      const infoTask = bridge.claude.accountInfo?.().catch(() => undefined) ?? Promise.resolve(undefined)
      const usages = await Promise.all(accountRows.map((row) => bridge.usage!.claude(row.configDir, force, exactOnly).catch((err) => ({ ok: false, message: String((err as Error)?.message || err) } as ClaudeUsage))))
      const defaultInfo = await infoTask
      if (seq !== seqRef.current) return
      setClaude(accountRows.map((row, i) => ({
        id: row.id,
        label: row.label,
        email: usages[i]?.email ?? (i === 0 ? defaultInfo?.email : row.email),
        usage: usages[i],
      })))
    })().finally(() => { if (seq === seqRef.current) setClaudeLoading(false) })

    await Promise.allSettled([codexTask, openCodeTask, claudeTask])
    if (seq === seqRef.current) setUpdatedAt(Date.now())
  }, [])

  const toggle = () => {
    if (!open) {
      const r = btnRef.current?.getBoundingClientRect()
      if (r) {
        const horizontal = r.left < 360
          ? { left: Math.max(8, r.left) }
          : { right: Math.max(8, window.innerWidth - r.right) }
        setPos(r.bottom > window.innerHeight * 0.62
          ? { ...horizontal, bottom: window.innerHeight - r.top + 6 }
          : { ...horizontal, top: r.bottom + 6 })
      }
      if (!bridge.smoke) void load()
    }
    setOpen(!open)
  }

  // Prime the gauge once after startup; opening the panel always refreshes.
  useEffect(() => {
    if (bridge.smoke) return
    if (initialLoadRef.current) return
    initialLoadRef.current = true
    void load(false, true)
  }, [load])

  useEffect(() => {
    if (bridge.smoke) return
    const refresh = () => { if (document.visibilityState === 'visible') void load(false, true) }
    const timer = window.setInterval(refresh, 5 * 60_000)
    window.addEventListener('focus', refresh)
    return () => { window.clearInterval(timer); window.removeEventListener('focus', refresh) }
  }, [load])

  useEffect(() => {
    if (!updatedAt) return
    const rows: Array<{ label: string; usedPercent: number; resetsAt?: number }> = []
    for (const account of codex) {
      const usage = account.usage
      if (!usage?.ok) continue
      if ((usage.primary?.usedPercent ?? 0) >= 50) rows.push({ label: `Codex ${account.label} current session`, usedPercent: usage.primary!.usedPercent!, resetsAt: usage.primary?.resetsAt })
      if ((usage.secondary?.usedPercent ?? 0) >= 50) rows.push({ label: `Codex ${account.label} weekly`, usedPercent: usage.secondary!.usedPercent!, resetsAt: usage.secondary?.resetsAt })
    }
    for (const account of claude) {
      const limits = account.usage?.limits
      if ((limits?.fiveHour?.usedPercent ?? 0) >= 50) rows.push({ label: `Claude ${account.label} current session`, usedPercent: limits!.fiveHour!.usedPercent!, resetsAt: limits?.fiveHour?.resetsAt })
      if ((limits?.sevenDay?.usedPercent ?? 0) >= 50) rows.push({ label: `Claude ${account.label} weekly`, usedPercent: limits!.sevenDay!.usedPercent!, resetsAt: limits?.sevenDay?.resetsAt })
      for (const model of limits?.modelScoped ?? []) if ((model.usedPercent ?? 0) >= 50) rows.push({ label: `Claude ${account.label} ${model.label}`, usedPercent: model.usedPercent!, resetsAt: model.resetsAt })
    }
    try {
      if (rows.length) localStorage.setItem(AGENT_USAGE_KEY, JSON.stringify({ at: Date.now(), rows }))
      else localStorage.removeItem(AGENT_USAGE_KEY)
    } catch { /* optional agent context cache */ }
  }, [claude, codex, updatedAt])

  useClickAway(open && !embedded, close, btnRef, panelRef)

  if (!isDesktop || !bridge.usage) return null
  const codexPercents = codex.flatMap((row) => [row.usage?.primary?.usedPercent, row.usage?.secondary?.usedPercent].flatMap((value) => value == null ? [] : [value]))
  const codexPeak = codexPercents.length ? Math.max(...codexPercents) : null
  const claudePercents = claude.flatMap((row) => [
    row.usage?.limits?.fiveHour?.usedPercent,
    row.usage?.limits?.sevenDay?.usedPercent,
    ...(row.usage?.limits?.modelScoped?.map((model) => model.usedPercent) ?? []),
  ].flatMap((value) => value == null ? [] : [value]))
  const claudePeak = claudePercents.length ? Math.max(...claudePercents) : null
  const peak = codexPeak == null ? claudePeak : claudePeak == null ? codexPeak : Math.max(codexPeak, claudePeak)
  const indicator = (codexLoading || claudeLoading || openCodeLoading) && peak == null
    ? 'var(--text-3)'
    : peak == null ? 'var(--text-3)' : peak >= 90 ? 'var(--danger)' : peak >= 70 ? 'var(--warn)' : peak >= 50 ? 'var(--accent)' : 'var(--success)'
  const usageTitle = [
    codexPeak == null ? null : `Codex ${Math.round(100 - codexPeak)}% remaining`,
    claudePeak == null ? null : `Claude ${Math.round(100 - claudePeak)}% remaining`,
  ].filter(Boolean).join(' · ')

  const signInCodex = (row: CodexRow) => {
    const prefix = row.codexHome ? `mkdir -p ${shellConfigDir(row.codexHome)} && CODEX_HOME=${shellConfigDir(row.codexHome)} ` : ''
    requestTerminal(`${prefix}codex login`, { name: row.id === '__default__' ? 'Codex Login' : `Codex login · ${row.label}` })
    useKaisola.getState().setSettingsOpen(false)
    setOpen(false)
  }

  const content = (
    <div
      ref={panelRef}
      className={embedded ? 'settings-usage' : 'limits-panel'}
      style={embedded ? {
        width: '100%', display: 'flex', flexDirection: 'column', gap: 16, fontSize: 'var(--fs-12)',
      } : {
        position: 'fixed', ...pos, width: 350, maxHeight: 'min(620px, calc(100vh - 70px))', overflowY: 'auto', zIndex: 'var(--z-menu, 900)' as never,
        background: 'var(--bg-3)', border: '1px solid var(--border)', borderRadius: 'var(--r-3, 10px)',
        boxShadow: 'var(--shadow-3, 0 12px 40px rgba(0,0,0,.4))', padding: '12px 14px',
        display: 'flex', flexDirection: 'column', gap: 13, fontSize: 'var(--fs-12)',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
        <Icon name="Gauge" size={14} />
        <span style={{ fontWeight: 600 }}>Usage</span>
        <span className="faint">Updated {relativeTime(updatedAt)}</span>
        <span className="grow" />
        <button type="button" className="btn-icon btn-sm" onClick={() => void load(true)} title="Refresh usage (bypass cache)" aria-label="Refresh usage" disabled={codexLoading || claudeLoading || openCodeLoading}>
          <Icon name="RefreshCw" size={12} />
        </button>
      </div>

      <section style={{ display: 'flex', flexDirection: 'column', gap: 9 }} aria-label="Codex usage">
        <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
          <span style={{ fontWeight: 600 }}>Codex</span>
          <span className="faint">subscription limits</span>
        </div>
        {codex.map((row) => {
          const usage = row.usage
          return (
            <div key={row.id} style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 7, minWidth: 0 }}>
                <span style={{ fontWeight: 500 }}>{row.label}</span>
                <span className="faint truncate" title={usage?.email}>{usage?.ok ? [usage.email, usage.plan].filter(Boolean).join(' · ') : ''}</span>
              </div>
              {usage?.ok ? (
                <>
                  <WindowBar label="Current session" usedPercent={usage.primary?.usedPercent} resetsAt={usage.primary?.resetsAt} color="var(--success)" />
                  <WindowBar label="Weekly" usedPercent={usage.secondary?.usedPercent} resetsAt={usage.secondary?.resetsAt} color="var(--accent)" />
                </>
              ) : (
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span className="faint grow">{codexLoading && !usage ? 'Reading Codex limits…' : usage?.message ?? 'Not available'}</span>
                  {usage?.authRequired && !codexLoading && <button type="button" className="btn btn-primary btn-sm" onClick={() => signInCodex(row)}>Sign in again</button>}
                </div>
              )}
            </div>
          )
        })}
      </section>

      <div style={{ height: 1, background: 'var(--border)' }} />

      <section style={{ display: 'flex', flexDirection: 'column', gap: 8 }} aria-label="OpenCode and Kimi usage">
        <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
          <span style={{ fontWeight: 600 }}>OpenCode · Kimi</span>
          <span className="faint">last 7 days</span>
        </div>
        {openCode?.ok ? (
          <>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12 }}>
              <span>{openCode.sessions ?? 0} sessions · {openCode.messages ?? 0} messages</span>
              <span className="faint">{openCode.cost ?? '$0.00'}</span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, minWidth: 0 }}>
              <span className="truncate" style={{ minWidth: 0 }} title={openCode.models?.map((model) => model.model).join(', ')}>{openCode.models?.[0]?.model ?? 'All models'}</span>
              <span className="faint" style={{ flexShrink: 0, textAlign: 'right' }}>{openCode.input ?? '—'} in · {openCode.output ?? '—'} out · {openCode.cacheRead ?? '—'} cached</span>
            </div>
            <span className="faint" style={{ fontSize: 'var(--fs-10, 10px)', lineHeight: 1.35 }}>
              Local OpenCode activity, not Kimi membership quota. Kimi exposes the plan percentage in its account console.
            </span>
            <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => void bridge.openExternal('https://www.kimi.com/code')}>
              Open Kimi quota
            </button>
          </>
        ) : <span className="faint">{openCodeLoading ? 'Reading OpenCode stats…' : openCode?.message ?? 'No OpenCode activity available'}</span>}
      </section>

      <div style={{ height: 1, background: 'var(--border)' }} />

      <section style={{ display: 'flex', flexDirection: 'column', gap: 9 }} aria-label="Claude subscription usage">
        <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
          <span style={{ fontWeight: 600 }}>Claude</span>
          <span className="faint">subscription limits</span>
        </div>
        {claude.length === 0 && <span className="faint">{claudeLoading ? 'Reading Claude limits…' : 'No accounts'}</span>}
        {claude.map((row) => {
          const usage = row.usage
          const limits = usage?.limits
          const activity = usage?.activity
          const hasLimits = Boolean(limits?.fiveHour || limits?.sevenDay || limits?.modelScoped?.length)
          const plan = usage?.subscriptionType ? usage.subscriptionType.charAt(0).toUpperCase() + usage.subscriptionType.slice(1) : ''
          return (
            <div key={row.id} style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 7, minWidth: 0 }}>
                <span style={{ fontWeight: 500, whiteSpace: 'nowrap' }}>{row.label}</span>
                {plan && <span className="tag" style={{ textTransform: 'none' }}>{plan}</span>}
                <span className="faint truncate" title={row.email}>{row.email}</span>
              </div>
              {hasLimits ? (
                <>
                  <WindowBar label="Current session" usedPercent={limits?.fiveHour?.usedPercent} resetsAt={limits?.fiveHour?.resetsAt} />
                  <WindowBar label="Weekly" usedPercent={limits?.sevenDay?.usedPercent} resetsAt={limits?.sevenDay?.resetsAt} />
                  {limits?.modelScoped?.map((model) => (
                    <WindowBar key={`${model.label}:${model.resetsAt ?? ''}`} label={model.label} usedPercent={model.usedPercent} resetsAt={model.resetsAt} />
                  ))}
                  {limits?.extraUsage && (
                    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12 }}>
                      <span>Extra usage</span>
                      <span className="faint">
                        {limits.extraUsage.enabled
                          ? `${extraAmount(limits.extraUsage.usedCredits, limits.extraUsage.currency)} / ${extraAmount(limits.extraUsage.monthlyLimit, limits.extraUsage.currency)}${limits.extraUsage.utilization == null ? '' : ` · ${Math.round(limits.extraUsage.utilization)}%`}`
                          : 'Off'}
                      </span>
                    </div>
                  )}
                </>
              ) : (
                <span className="faint">{claudeLoading && !usage ? 'Reading…' : usage?.message ?? 'No subscription limits reported yet'}</span>
              )}
              {usage && (
                <span className="faint" style={{ fontSize: 'var(--fs-10, 10px)', lineHeight: 1.35 }}>
                  {usage.sourceLabel ?? 'Claude'}{usage.experimental ? ' · experimental structured API' : ''}
                  {usage.updatedAt ? ` · ${relativeTime(usage.updatedAt)}` : ''}{usage.stale ? ' · last known good' : ''}
                  {usage.refreshError ? ` · refresh failed: ${usage.refreshError}` : ''}
                </span>
              )}
              {activity && (
                <details style={{ color: 'var(--text-3)', fontSize: 'var(--fs-10, 10px)' }}>
                  <summary style={{ cursor: 'pointer' }}>Local activity diagnostic</summary>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 4, paddingTop: 5 }}>
                    <ClaudeActivity label="Last 5 hours" sums={activity.fiveHour} />
                    <ClaudeActivity label="Last 7 days" sums={activity.week} />
                    {activity.lastActivity ? <span>Last response {relativeTime(activity.lastActivity)}</span> : null}
                    {activity.partial && <span>Recent {activity.scannedFiles ?? ''} files scanned; older activity was capped.</span>}
                    <span>Transcript tokens are local diagnostics, not plan percentages.</span>
                  </div>
                </details>
              )}
            </div>
          )
        })}
      </section>
    </div>
  )

  return (
    <>
      {!embedded && <button type="button"
        ref={btnRef}
        className="btn-icon"
        data-active={open}
        onClick={toggle}
        title={usageTitle ? `Usage — ${usageTitle}` : 'Usage — Codex, Claude, OpenCode & Kimi'}
        aria-label="Open usage"
        style={{ position: 'relative' }}
      >
        <Icon name="Gauge" size={15} />
        <span aria-hidden style={{ position: 'absolute', width: 6, height: 3, borderRadius: 3, right: 5, top: 5, background: indicator }} />
      </button>}
      {embedded ? content : open && createPortal(content, document.body)}
    </>
  )
}

export function LimitsButton() {
  return <UsageSurface />
}

export function UsageSettings() {
  return <UsageSurface embedded />
}
