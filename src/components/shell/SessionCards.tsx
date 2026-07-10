import { Suspense, lazy, useRef, useState, type CSSProperties, type DragEvent, type ReactNode } from 'react'
import { useShallow } from 'zustand/react/shallow'
import { useKaisola, type TerminalMeta } from '../../store/store'
import { sessionHue, terminalAgentKey } from '../../lib/sessionHue'
import { useAgentRegistry } from '../../lib/registry'
import { urlHost, terminalLabel, threadLabel } from '@/lib/sessionLabel'
import { CostChip } from './CostChip'
import { Terminal, everMountedTerminals, hiddenTerminalResidentCap } from '../Terminal'
import { Assistant } from '../Assistant'
import { BrowserCard } from './BrowserCard'
import { LedgerCard } from './LedgerCard'
import { SessionTabs } from './SessionTabs'
import { Icon } from '../Icon'

// Git diff rendering pulls in CodeMirror. Keep it out of the initial shell
// bundle; Files and Commit share the same lazy editor chunk on first use.
const GitPanel = lazy(() => import('./GitPanel').then((module) => ({ default: module.GitPanel })))

/**
 * While ANY shell drag runs (card heads, column grips, the canvas edge),
 * iframes/webviews must stop eating pointer events — a PDF or browser card
 * under the cursor otherwise freezes the drag mid-flight.
 */
export const shellDrag = {
  start: () => document.body.setAttribute('data-shell-drag', '1'),
  end: () => document.body.removeAttribute('data-shell-drag'),
}

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
  const removeDockView = useKaisola((s) => s.removeDockView)
  const placeDockView = useKaisola((s) => s.placeDockView)
  const popOutTerminal = useKaisola((s) => s.popOutTerminal)
  const termRemounts = useKaisola((s) => s.termRemounts)
  const dockColWeights = useKaisola((s) => s.dockColWeights)
  const setDockColWeights = useKaisola((s) => s.setDockColWeights)
  // Keep only a tiny most-recently-used set of hidden xterms warm. Older ones
  // unmount, persist their viewport/scrollback to disk, and leave the pty alive.
  const warmTerminalIds = new Set([...everMountedTerminals].slice(-hiddenTerminalResidentCap()))
  // (Record identity is stable across background feed patches → shallow bails.)
  const ghostTerms = useKaisola(
    useShallow((s) => Object.values(s.projectSlices).flatMap((sl) => sl.terminals.filter((t) => warmTerminalIds.has(t.id)))),
  )
  const ghostAgentTerms = useKaisola(
    useShallow((s) => Object.values(s.projectSlices).flatMap((sl) => sl.agentTerminals.filter((t) => warmTerminalIds.has(t.terminalId)))),
  )
  const { all: agents } = useAgentRegistry()
  const dragRef = useRef<string | null>(null)
  const gridRef = useRef<HTMLDivElement>(null)
  const [drop, setDrop] = useState<{ id: string; edge: Edge } | null>(null)

  if (!open) return null

  // column widths: stored fr weights when they match the current column count,
  // equal shares otherwise (adding/removing a card resets to equal)
  const weights =
    dockColWeights && dockColWeights.length === grid.length ? dockColWeights : grid.map(() => 1)

  // drag the divider between column i and i+1 — pure weight transfer, so the
  // other columns keep their size
  const startColResize = (e: React.MouseEvent, i: number) => {
    e.preventDefault()
    const el = gridRef.current
    if (!el) return
    shellDrag.start()
    const total = weights.reduce((a, b) => a + b, 0)
    const pxPerWeight = el.getBoundingClientRect().width / total
    const startX = e.clientX
    const left0 = weights[i]
    const right0 = weights[i + 1]
    const onMove = (ev: MouseEvent) => {
      const d = (ev.clientX - startX) / pxPerWeight
      const next = [...weights]
      const shift = Math.max(-(left0 - 0.2), Math.min(right0 - 0.2, d))
      next[i] = left0 + shift
      next[i + 1] = right0 - shift
      setDockColWeights(next)
    }
    const onUp = () => {
      shellDrag.end()
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
    }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
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
  const rows = grid.reduce((m, col) => lcm(m, col.length), 1)
  const pos = new Map<string, { col: number; row: number; span: number }>()
  grid.forEach((col, ci) =>
    col.forEach((id, ri) => {
      const span = rows / col.length
      pos.set(id, { col: ci + 1, row: ri * span + 1, span })
    }),
  )

  interface CardIdentity {
    hue: string
    sub?: { repo?: string; branch?: string; path?: string } | null
    running?: boolean
    failed?: boolean
    /** Terminals can move to their own window (the pty stream follows). */
    poppable?: boolean
    /** Dev-server ports seen in the output — chips that open a browser card. */
    ports?: number[]
  }

  const card = (id: string, icon: string, label: string, body: ReactNode, idn?: CardIdentity) => {
    const p = pos.get(id)
    return (
      <div
        key={id}
        className="session-card"
        data-show={!!p}
        data-drop={drop?.id === id && dragRef.current && dragRef.current !== id ? drop.edge : undefined}
        style={{
          ...(p ? { gridColumn: p.col, gridRow: `${p.row} / span ${p.span}` } : {}),
          ...(idn ? ({ '--sid': idn.hue } as CSSProperties) : {}),
        }}
        onDragOver={(e) => {
          if (!dragRef.current || dragRef.current === id) return
          e.preventDefault()
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
        {p && (
          <div
            className="pane-head"
            draggable
            onDragStart={() => { dragRef.current = id; shellDrag.start() }}
            onDragEnd={() => { dragRef.current = null; setDrop(null); shellDrag.end() }}
            title="Drag onto another card's edge to place it there"
          >
            <Icon name={icon} size={12} className="pane-head-icon" />
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
            <CostChip termId={id} />
            {idn?.ports?.map((port) => (
              <button
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
                className="pane-head-close pane-head-pop"
                onClick={() => popOutTerminal(id, label, idn.hue)}
                title="Open in its own window"
              >
                <Icon name="PictureInPicture2" size={11} />
              </button>
            )}
            <button className="pane-head-close" onClick={() => removeDockView(id)} title="Close this card">
              <Icon name="X" size={11} />
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
      <SessionTabs />
      <div
        ref={gridRef}
        className="session-grid"
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
          onMouseDown={(e) => startColResize(e, i)}
          onDoubleClick={() => setDockColWeights(null)}
          title="Drag to resize · double-click to reset"
        />
      ))}
      {threads.map((t, i) => {
        const label = threadLabel(t, agents, threads, i)
        return card(t.id, 'Sparkles', label, pos.has(t.id) ? <Assistant threadId={t.id} /> : null, {
          hue: sessionHue({ agentKey: t.agentKey }),
          running: t.busy,
        })
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
              running: agentKey ? !!meta?.agentBusy : !!meta?.running,
              failed: !(agentKey ? meta?.agentBusy : meta?.running) && (meta?.lastExit ?? 0) > 0,
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
              poppable: true,
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
