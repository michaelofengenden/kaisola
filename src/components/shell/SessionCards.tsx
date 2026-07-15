import { Suspense, lazy, useEffect, useRef, useState, type CSSProperties, type DragEvent, type ReactNode } from 'react'
import { useShallow } from 'zustand/react/shallow'
import { useKaisola, type TerminalMeta } from '../../store/store'
import { sessionHue, terminalAgentKey } from '../../lib/sessionHue'
import { everMountedTerminals, hiddenTerminalResidentCap } from '../../lib/terminalResidency'
import { useAgentRegistry } from '../../lib/registry'
import { urlHost, terminalLabel, threadLabel } from '@/lib/sessionLabel'
import { Terminal } from '../Terminal'
import { BrowserCard } from './BrowserCard'
import { LedgerCard } from './LedgerCard'
import { SessionTabs } from './SessionTabs'
import { Icon } from '../Icon'
import { ProviderIcon } from '../ProviderIcon'
import { shellDrag } from './shellDrag'

// Git diff rendering pulls in CodeMirror. Keep it out of the initial shell
// bundle; Files and Commit share the same lazy editor chunk on first use.
const GitPanel = lazy(() => import('./GitPanel').then((module) => ({ default: module.GitPanel })))
// Chat threads carry the react-markdown stack — loaded on the first chat
// card, not at boot (the default shell is a lone agent terminal now).
const Assistant = lazy(() => import('../Assistant').then((module) => ({ default: module.Assistant })))
const GroupAssistant = lazy(() => import('../GroupAssistant').then((module) => ({ default: module.GroupAssistant })))

const homeTilde = (p: string) => p.replace(/^\/Users\/[^/]+/, '~')

/** `repo ⎇ branch · ~/path` — the card's identity line. */
function metaLine(meta?: TerminalMeta): { repo?: string; branch?: string; path?: string } | null {
  if (!meta?.cwd && !meta?.repo) return null
  return {
    repo: meta.repo ?? undefined,
    branch: meta.branch ?? undefined,
    path: meta.cwd ? homeTilde(meta.cwd) : undefined,
  }
}

type Edge = 'left' | 'right' | 'top' | 'bottom'

const gcd = (a: number, b: number): number => (b ? gcd(b, a % b) : a)
const lcm = (a: number, b: number) => (a * b) / gcd(a, b)

/** Which edge of the card the pointer is nearest — that's where a drop lands. */
function edgeAt(e: DragEvent, el: HTMLElement): Edge {
  const r = el.getBoundingClientRect()
  const x = (e.clientX - r.left) / Math.max(1, r.width)
  const y = (e.clientY - r.top) / Math.max(1, r.height)
  const d: { edge: Edge; v: number }[] = [
    { edge: 'left', v: x },
    { edge: 'right', v: 1 - x },
    { edge: 'top', v: y },
    { edge: 'bottom', v: 1 - y },
  ]
  return d.sort((a, b) => a.v - b.v)[0].edge
}

/**
 * The open sessions, each as its OWN floating card laid out on a grid to the
 * left of the files/canvas card. A card's slim head is the handle: drag it
 * onto another card's edge to place it beside, above or below; × closes just
 * that card. Hidden renderers are hibernated after a tiny LRU; ptys and chat
 * state stay live/durable without retaining every xterm/React transcript.
 */
export function SessionCards() {
  const open = useKaisola((s) => s.dockOpen)
  const grid = useKaisola((s) => s.dockGrid)
  const threads = useKaisola((s) => s.assistantThreads)
  const terminals = useKaisola((s) => s.terminals)
  const agentTerminals = useKaisola((s) => s.agentTerminals)
  const panels = useKaisola((s) => s.panels)
  const terminalMeta = useKaisola((s) => s.terminalMeta)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const perfMode = useKaisola((s) => s.perfMode)
  const tabLayout = useKaisola((s) => s.tabLayout)
  const removeDockView = useKaisola((s) => s.removeDockView)
  const placeDockView = useKaisola((s) => s.placeDockView)
  const popOutTerminal = useKaisola((s) => s.popOutTerminal)
  const termRemounts = useKaisola((s) => s.termRemounts)
  const dockColWeights = useKaisola((s) => s.dockColWeights)
  const setDockColWeights = useKaisola((s) => s.setDockColWeights)
  const [, bumpResidencyPreference] = useState(0)
  useEffect(() => {
    const refresh = () => bumpResidencyPreference((value) => value + 1)
    window.addEventListener('kaisola:terminal-residency', refresh)
    return () => window.removeEventListener('kaisola:terminal-residency', refresh)
  }, [])
  // Keep only a tiny most-recently-used set of hidden xterms warm. Older ones
  // unmount, persist their viewport/scrollback to disk, and leave the pty alive.
  const hiddenCap = hiddenTerminalResidentCap(perfMode)
  const warmTerminalIds = new Set(hiddenCap > 0 ? [...everMountedTerminals].slice(-hiddenCap) : [])
  // (Record identity is stable across background feed patches → shallow bails.)
  const ghostTerms = useKaisola(
    useShallow((s) => Object.values(s.projectSlices).flatMap((sl) => sl.terminals.filter((t) => warmTerminalIds.has(t.id)))),
  )
  const ghostAgentTerms = useKaisola(
    useShallow((s) => Object.values(s.projectSlices).flatMap((sl) => sl.agentTerminals.filter((t) => warmTerminalIds.has(t.terminalId)))),
  )
  const { all: agents } = useAgentRegistry()
  const threadById = new Map(threads.map((thread) => [thread.id, thread]))
  const dragRef = useRef<string | null>(null)
  const gridRef = useRef<HTMLDivElement>(null)
  const [drop, setDrop] = useState<{ id: string; edge: Edge } | null>(null)
  const [maximizedId, setMaximizedId] = useState<string | null>(null)
  useEffect(() => {
    if (maximizedId && !grid.some((column) => column.includes(maximizedId))) setMaximizedId(null)
  }, [grid, maximizedId])

  if (!open) return null

  const displayGrid = maximizedId ? [[maximizedId]] : grid

  // column widths: stored fr weights when they match the current column count,
  // equal shares otherwise (adding/removing a card resets to equal)
  const weights = maximizedId
    ? [1]
    : dockColWeights && dockColWeights.length === displayGrid.length ? dockColWeights : displayGrid.map(() => 1)

  // drag the divider between column i and i+1 — pure weight transfer, so the
  // other columns keep their size
  const startColResize = (e: React.PointerEvent<HTMLDivElement>, i: number) => {
    e.preventDefault()
    const el = gridRef.current
    if (!el) return
    const handle = e.currentTarget
    handle.setPointerCapture(e.pointerId)
    shellDrag.start()
    const total = weights.reduce((a, b) => a + b, 0)
    const gridWidth = el.getBoundingClientRect().width
    const pxPerWeight = gridWidth / total
    const pairTotal = weights[i] + weights[i + 1]
    const minWeight = Math.min(pairTotal / 2, Math.max(0.2, 280 / Math.max(1, pxPerWeight)))
    const startX = e.clientX
    const left0 = weights[i]
    const right0 = weights[i + 1]
    const onMove = (ev: PointerEvent) => {
      const d = (ev.clientX - startX) / pxPerWeight
      const next = [...weights]
      const shift = Math.max(-(left0 - minWeight), Math.min(right0 - minWeight, d))
      next[i] = left0 + shift
      next[i + 1] = right0 - shift
      setDockColWeights(next)
    }
    const onUp = () => {
      shellDrag.end()
      handle.removeEventListener('pointermove', onMove)
      handle.removeEventListener('pointerup', onUp)
      handle.removeEventListener('pointercancel', onUp)
    }
    handle.addEventListener('pointermove', onMove)
    handle.addEventListener('pointerup', onUp)
    handle.addEventListener('pointercancel', onUp)
  }

  // identity chrome earns its pixels only under AMBIGUITY: when every session
  // lives in the workspace tree, no repo metadata shows anywhere; the moment
  // sessions span folders, each terminal card grows its identity line
  const rootOf = (id: string, fallback?: string) => {
    const m = terminalMeta[id]
    return m?.root ?? m?.cwd ?? fallback ?? workspacePath ?? undefined
  }
  const allRoots = new Set(
    [
      ...terminals.map((t) => rootOf(t.id, t.cwd)),
      ...agentTerminals.map((t) => rootOf(t.terminalId, t.cwd)),
    ].filter(Boolean) as string[],
  )
  const ambiguous = allRoots.size > 1
  const showMetaFor = (id: string, fallback?: string) =>
    ambiguous || (rootOf(id, fallback) && workspacePath && rootOf(id, fallback) !== workspacePath)

  // uneven stacks share one grid: rows = lcm of the column heights, so a
  // lone card spans what two stacked neighbours split between them
  const rows = displayGrid.reduce((m, col) => lcm(m, col.length), 1)
  const pos = new Map<string, { col: number; row: number; span: number }>()
  displayGrid.forEach((col, ci) =>
    col.forEach((id, ri) => {
      const span = rows / col.length
      pos.set(id, { col: ci + 1, row: ri * span + 1, span })
    }),
  )
  const soloCard = pos.size === 1

  interface CardIdentity {
    hue: string
    sub?: { repo?: string; branch?: string; path?: string } | null
    running?: boolean
    failed?: boolean
    /** Terminals can move to their own window (the pty stream follows). */
    poppable?: boolean
    /** Dev-server ports seen in the output — chips that open a browser card. */
    ports?: number[]
    agentKey?: string
  }

  const card = (id: string, icon: string, label: string, body: ReactNode, idn?: CardIdentity) => {
    const p = pos.get(id)
    // The session tab already carries identity + working/completed state. A
    // second title bar earns its height only when there are multiple movable
    // cards or meaningful cross-workspace metadata.
    const showHead = !!p && (!soloCard || !!idn?.sub || !!maximizedId || grid.flat().length > 1)
    return (
      <div
        key={id}
        className="session-card"
        data-session-id={id}
        data-show={!!p}
        data-headless={!!p && !showHead || undefined}
        data-maximized={maximizedId === id || undefined}
        data-drop={drop?.id === id && dragRef.current && dragRef.current !== id ? drop.edge : undefined}
        style={{
          ...(p ? { gridColumn: p.col, gridRow: `${p.row} / span ${p.span}` } : {}),
          ...(idn ? ({ '--sid': idn.hue } as CSSProperties) : {}),
        }}
        onDragOver={(e) => {
          if (!dragRef.current || dragRef.current === id) return
          e.preventDefault()
          e.dataTransfer.dropEffect = 'move'
          const edge = edgeAt(e, e.currentTarget)
          setDrop((d) => (d?.id === id && d.edge === edge ? d : { id, edge }))
        }}
        onDragLeave={(e) => {
          if (drop?.id === id && !e.currentTarget.contains(e.relatedTarget as Node)) setDrop(null)
        }}
        onDrop={(e) => {
          e.preventDefault()
          if (dragRef.current && dragRef.current !== id) placeDockView(dragRef.current, id, edgeAt(e, e.currentTarget))
          dragRef.current = null
          setDrop(null)
        }}
      >
        {showHead && (
          <div
            className="pane-head"
            draggable={!maximizedId}
            onDragStart={(event) => {
              dragRef.current = id
              event.dataTransfer.effectAllowed = 'move'
              event.dataTransfer.setData('text/plain', id)
              shellDrag.start()
            }}
            onDragEnd={() => { dragRef.current = null; setDrop(null); shellDrag.end() }}
            title="Drag onto another card's edge to place it there"
          >
            {idn?.agentKey
              ? <ProviderIcon provider={idn.agentKey} name={label} size={12} className="pane-head-icon" />
              : <Icon name={icon} size={12} className="pane-head-icon" />}
            <span className="pane-head-title truncate">{label}</span>
            {idn?.running && <span className="session-busy" title="Running" />}
            {!idn?.running && idn?.failed && <span className="pane-fail-dot" title="Last command failed" />}
            {idn?.sub && (
              <span className="pane-head-sub truncate">
                {idn.sub.repo && <span className="pane-sub-repo">{idn.sub.repo}</span>}
                {idn.sub.branch && (
                  <span className="pane-sub-branch">
                    <Icon name="GitBranch" size={9} />
                    {idn.sub.branch}
                  </span>
                )}
                {idn.sub.path && <span className="pane-sub-path">{idn.sub.path}</span>}
              </span>
            )}
            <span className="grow" />
            {idn?.ports?.map((port) => (
              <button
                type="button"
                key={port}
                className="pane-port"
                onClick={() => useKaisola.getState().openBrowserPanel(`http://localhost:${port}`)}
                title={`Open localhost:${port} in a browser card`}
              >
                <Icon name="Globe" size={9} />:{port}
              </button>
            ))}
            {idn?.poppable && (
              <button
                type="button"
                className="pane-head-close pane-head-pop"
                onClick={() => popOutTerminal(id, label, idn.hue)}
                title="Open in its own window"
                aria-label={`Open ${label} in its own window`}
              >
                <Icon name="PictureInPicture2" size={11} />
              </button>
            )}
            <button
              type="button"
              className="pane-head-close"
              draggable={false}
              onClick={() => setMaximizedId(maximizedId === id ? null : id)}
              title={maximizedId === id ? 'Restore card layout' : 'Maximize this card'}
              aria-label={maximizedId === id ? `Restore ${label} card layout` : `Maximize ${label} card`}
            >
              <Icon name={maximizedId === id ? 'Minimize2' : 'Maximize2'} size={11} />
            </button>
            <button type="button" className="pane-head-close" draggable={false} onClick={() => { if (maximizedId === id) setMaximizedId(null); removeDockView(id) }} title="Minimize this card" aria-label={`Minimize ${label} card`}>
              <Icon name="Minus" size={11} />
            </button>
          </div>
        )}
        {body}
      </div>
    )
  }

  // divider positions: cumulative weight fraction per column boundary
  const totalW = weights.reduce((a, b) => a + b, 0)
  const boundaries: number[] = []
  let acc = 0
  for (let i = 0; i < weights.length - 1; i++) {
    acc += weights[i]
    boundaries.push(acc / totalW)
  }

  return (
    <div className="dock-col">
      {tabLayout !== 'compact' && tabLayout !== 'sidebar' && <SessionTabs />}
      <div
        ref={gridRef}
        className="session-grid"
        data-solo={soloCard || undefined}
        style={{
          gridTemplateColumns: weights.map((w) => `minmax(0, ${w}fr)`).join(' ') || 'minmax(0, 1fr)',
          gridTemplateRows: `repeat(${rows}, minmax(0, 1fr))`,
        }}
      >
      {boundaries.map((frac, i) => (
        <div
          key={`colgrip-${i}`}
          className="grid-col-resize"
          style={{ left: `${frac * 100}%` }}
          onPointerDown={(e) => startColResize(e, i)}
          onDoubleClick={() => setDockColWeights(null)}
          onKeyDown={(event) => {
            if (event.key === 'Home') { event.preventDefault(); setDockColWeights(null); return }
            if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
            event.preventDefault()
            const next = [...weights]
            const delta = event.key === 'ArrowLeft' ? -0.1 : 0.1
            const pxPerWeight = (gridRef.current?.getBoundingClientRect().width ?? 1) / Math.max(0.01, next.reduce((sum, value) => sum + value, 0))
            const minWeight = Math.min((next[i] + next[i + 1]) / 2, Math.max(0.2, 280 / Math.max(1, pxPerWeight)))
            const shift = Math.max(-(next[i] - minWeight), Math.min(next[i + 1] - minWeight, delta))
            next[i] += shift
            next[i + 1] -= shift
            setDockColWeights(next)
          }}
          role="separator"
          aria-label={`Resize session columns ${i + 1} and ${i + 2}`}
          aria-orientation="vertical"
          tabIndex={0}
          title="Drag to resize · double-click to reset"
        />
      ))}
      {threads.flatMap((t, i) => {
        if (t.groupParentId) return []
        const label = threadLabel(t, agents, threads, i)
        const body = pos.has(t.id)
          ? <Suspense fallback={<div className="fx-loading aurora"><span className="shimmer-text">Loading chat…</span></div>}>
              {t.group ? <GroupAssistant threadId={t.id} /> : <Assistant threadId={t.id} />}
            </Suspense>
          : null
        return [card(t.id, t.group ? 'Network' : 'Sparkles', label, body, {
          hue: sessionHue({ agentKey: t.group ? 'group' : t.agentKey }),
          agentKey: t.group ? undefined : t.agentKey,
          running: t.group
            ? t.group.members.some((member) => threadById.get(member.threadId)?.busy)
            : t.busy,
        })]
      })}
      {/* live + ghost terminal cards share ONE array expression on purpose:
          React matches keys only within the same child slot, so a terminal
          moving between active and ghost on a project switch keeps its element
          (and its live xterm) instead of remounting */}
      {[
        ...terminals.map((t, i) => {
          const meta = terminalMeta[t.id]
          const agentKey = terminalAgentKey(t.singletonKey)
          const label = terminalLabel(t, { meta, agents, index: i, count: terminals.length })
          const sub = showMetaFor(t.id, t.cwd) ? metaLine(meta) : null
          return card(
            t.id,
            'SquareTerminal',
            label,
            // keyed by the remount seq: a returning pop-out re-attaches the pty
            // stream and replays the snapshot into a fresh xterm
            pos.has(t.id) || warmTerminalIds.has(t.id)
              ? <div className="dock-pane-term"><Terminal key={termRemounts[t.id] ?? 0} id={t.id} boot={t.boot} cwd={t.cwd} /></div>
              : null,
            {
              hue: sessionHue({ agentKey, folder: meta?.root ?? meta?.cwd ?? t.cwd }),
              // when the title already IS the repo, the sub line keeps only branch·path
              sub: sub && sub.repo === label ? { ...sub, repo: undefined } : sub,
              running: agentKey ? !!(meta?.agentBusy ?? meta?.running) : !!meta?.running,
              failed: !(agentKey ? (meta?.agentBusy ?? meta?.running) : meta?.running) && (meta?.lastExit ?? 0) > 0,
              poppable: true,
              ports: meta?.ports,
            },
          )
        }),
        ...agentTerminals.map((t) => {
          const meta = terminalMeta[t.terminalId]
          return card(
            t.terminalId,
            'SquareTerminal',
            t.label || 'agent',
            pos.has(t.terminalId) || warmTerminalIds.has(t.terminalId)
              ? <div className="dock-pane-term"><Terminal key={termRemounts[t.terminalId] ?? 0} id={t.terminalId} attach /></div>
              : null,
            {
              hue: sessionHue({ agentKey: t.agentKey, folder: meta?.root ?? meta?.cwd ?? t.cwd }),
              sub: showMetaFor(t.terminalId, t.cwd) ? metaLine(meta) : null,
              running: !!meta?.running,
            },
          )
        }),
        // ghost cards — never placed (no pos), so they render hidden
        ...ghostTerms.map((t) =>
          card(
            t.id,
            'SquareTerminal',
            t.name ?? 'Terminal',
            <div className="dock-pane-term"><Terminal key={termRemounts[t.id] ?? 0} id={t.id} boot={t.boot} cwd={t.cwd} /></div>,
          ),
        ),
        ...ghostAgentTerms.map((t) =>
          card(
            t.terminalId,
            'SquareTerminal',
            t.label || 'agent',
            <div className="dock-pane-term"><Terminal key={termRemounts[t.terminalId] ?? 0} id={t.terminalId} attach /></div>,
          ),
        ),
      ]}
      {panels.map((p) => {
        // terminals stay mounted while put away (pty parity) — panels don't:
        // a hidden GitPanel would keep running `git status` on every file
        // change, and a hidden webview holds a live page nobody can see
        const placed = pos.has(p.id)
        return p.kind === 'git'
          ? card(p.id, 'GitCommitHorizontal', 'Commit', placed ? <Suspense fallback={<div className="fx-loading aurora"><span className="shimmer-text">Loading diff…</span></div>}><GitPanel /></Suspense> : null, {
              hue: sessionHue({ agentKey: 'git', folder: workspacePath }),
            })
          : p.kind === 'ledger'
            ? card(p.id, 'ListTodo', 'Agent tasks', placed ? <LedgerCard /> : null, {
                hue: sessionHue({ agentKey: 'ledger', folder: workspacePath }),
              })
            : card(p.id, 'Globe', p.title ?? urlHost(p.url) ?? 'Browser', placed ? <BrowserCard id={p.id} /> : null, {
                hue: sessionHue({ agentKey: urlHost(p.url) ?? 'browser' }),
              })
      })}
      </div>
    </div>
  )
}
