import { useEffect, useMemo, useRef, useState } from 'react'
import { useKaisola, sessionOrderIds } from '../../store/store'
import { bridge } from '../../lib/bridge'
import { fuzzyRank } from '../../lib/fuzzy'
import { useAgentRegistry, agentName } from '../../lib/registry'
import { terminalLabel } from '@/lib/sessionLabel'
import { Icon } from '../Icon'

interface OmniAction {
  id: string
  icon: string
  label: string
  hint?: string
  run: () => void
}

// A bare dotted token is a URL unless its suffix is a code/asset file extension
// — "index.ts" / "notes.md" are filenames, and "Open https://index.ts" would be
// a mislabel. Broad TLD matching (any 2+ letters) stays so real domains keep
// working (bbc.co.uk, example.fr, x.tech); a path or scheme always wins as a URL.
const BARE_FILE = /^[\w-]+(\.[\w-]+)*\.(tsx?|jsx?|mjs|cjs|json|mdx?|py|rb|go|rs|css|s[ac]ss|less|html?|xml|txt|ya?ml|toml|lock|sh|zsh|bash|env|log|c|h|hpp|cpp|cc|java|kt|php|swift|sql|csv|tsv|svg|png|jpe?g|gif|webp|pdf|ipynb)$/i
const URLish = /^(https?:\/\/\S+|localhost(:\d+)?(\/\S*)?|[\w.-]+\.[a-z]{2,}(:\d+)?(\/\S*)?)$/i

/**
 * Write to a terminal's pty, retrying until it exists — a put-away terminal
 * has no pty until its card mounts, so a bare write would silently vanish.
 * Docking mounts it; we poll the write (returns ok=false while the pty is
 * still spawning) for up to ~2s.
 */
async function writeWhenReady(id: string, data: string) {
  useKaisola.getState().setDockView(id)
  for (let i = 0; i < 12; i++) {
    const r = await bridge.terminal.write(id, data)
    if (r.ok) return true
    await new Promise((res) => setTimeout(res, 180))
  }
  useKaisola.getState().pushToast('error', 'Could not reach that terminal — it may not have started yet.')
  return false
}

/**
 * ⌘L — the address bar for agents. One line, EXPLICIT actions (Warp shipped
 * shell-vs-prompt auto-detection and walked it back to "Legacy" — so nothing
 * here guesses): plain text surfaces "jump to session" matches plus explicit
 * "ask" / "run" rows; a `$`/`!` prefix pre-selects run-in-terminal; a URL
 * pre-selects the browser card.
 */
export function OmniBar() {
  const open = useKaisola((s) => s.omniOpen)
  const setOpen = useKaisola((s) => s.setOmniOpen)
  const threads = useKaisola((s) => s.assistantThreads)
  const terminals = useKaisola((s) => s.terminals)
  const agentTerminals = useKaisola((s) => s.agentTerminals)
  const panels = useKaisola((s) => s.panels)
  const dockViews = useKaisola((s) => s.dockViews)
  const { all: agents } = useAgentRegistry()
  const [q, setQ] = useState('')
  const [active, setActive] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (open) {
      setQ('')
      setActive(0)
      setTimeout(() => inputRef.current?.focus(), 0)
    }
  }, [open])

  const actions = useMemo<OmniAction[]>(() => {
    if (!open) return []
    const s = useKaisola.getState()
    const close = () => setOpen(false)
    const text = q.trim()
    const bare = text.replace(/^[$!]\s*/, '')

    // session labels in rail order (the same order ⌘1-9 uses)
    const labelOf = (id: string): { label: string; icon: string } | null => {
      const th = threads.find((t) => t.id === id)
      if (th) return { label: th.name ?? th.autoName ?? agentName(agents, th.agentKey) ?? 'Agent', icon: 'Sparkles' }
      const te = terminals.find((t) => t.id === id)
      if (te) return { label: terminalLabel(te, { meta: s.terminalMeta[te.id], agents, index: terminals.indexOf(te), count: terminals.length }), icon: 'SquareTerminal' }
      const at = agentTerminals.find((t) => t.terminalId === id)
      if (at) return { label: at.label || 'agent', icon: 'SquareTerminal' }
      const p = panels.find((x) => x.id === id)
      if (p) return { label: p.kind === 'git' ? 'Commit' : p.title ?? p.url ?? 'Browser', icon: p.kind === 'git' ? 'GitCommitHorizontal' : 'Globe' }
      return null
    }
    const sessions = sessionOrderIds(s)
      .map((id) => ({ id, ...(labelOf(id) ?? { label: '', icon: '' }) }))
      .filter((x) => x.label)
    const jumps: OmniAction[] = (text
      ? fuzzyRank(text, sessions, (x) => x.label).map((r) => r.item)
      : sessions
    )
      .slice(0, 5)
      .map((x) => ({
        id: `jump-${x.id}`,
        icon: x.icon,
        label: x.label,
        hint: 'Jump to session',
        run: () => { s.switchSession(x.id); close() },
      }))

    if (!text) return jumps

    // run in a PLAIN shell — an agent-singleton terminal is a REPL, and shell
    // text typed into claude would become a prompt, not an exec
    const plain = terminals.filter((t) => !t.singletonKey?.startsWith('agent:') && !t.singletonKey?.startsWith('wt:'))
    const termTarget = plain.find((t) => dockViews.includes(t.id)) ?? plain[0]
    const run: OmniAction = {
      id: 'run',
      icon: 'SquareTerminal',
      label: `Run: ${bare}`,
      hint: termTarget ? `in ${termTarget.name ?? termTarget.autoName ?? 'the terminal'}` : 'in a new terminal',
      run: () => {
        if (termTarget) void writeWhenReady(termTarget.id, bare + '\n')
        else s.requestTerminal(bare, { cwd: s.workspacePath ?? undefined })
        close()
      },
    }

    // ask an agent — the first visible thread, else the claude terminal's pty,
    // else a fresh thread on the first ACP agent in the menu
    const threadTarget = threads.find((t) => dockViews.includes(t.id)) ?? threads[0]
    const claudeTerm = terminals.find((t) => t.singletonKey === 'agent:claude-code')
    const ask: OmniAction = {
      id: 'ask',
      icon: 'Sparkles',
      label: `Ask: ${bare}`,
      hint: threadTarget
        ? `→ ${threadTarget.name ?? threadTarget.autoName ?? agentName(agents, threadTarget.agentKey) ?? 'agent'}`
        : claudeTerm ? '→ Claude (terminal)' : '→ new agent thread',
      run: () => {
        if (threadTarget) {
          s.sendOmniPrompt(threadTarget.id, bare)
          s.setDockView(threadTarget.id)
        } else if (claudeTerm) {
          void writeWhenReady(claudeTerm.id, bare + '\n')
        } else {
          const acp = agents.find((a) => a.kind === 'acp')
          if (!acp) { s.pushToast('info', 'Add an agent first (Settings → Agents).'); close(); return }
          s.requestNewThread(acp.id)
          queueMicrotask(() => {
            const now = useKaisola.getState()
            if (now.activeThreadId) now.sendOmniPrompt(now.activeThreadId, bare)
          })
        }
        close()
      },
    }

    const openUrl: OmniAction[] = URLish.test(text) && !BARE_FILE.test(text)
      ? [{
          id: 'url',
          icon: 'Globe',
          label: `Open ${text}`,
          hint: 'browser card',
          run: () => {
            const url = /^https?:\/\//i.test(text) ? text : /^localhost/i.test(text) ? `http://${text}` : `https://${text}`
            s.openBrowserPanel(url)
            close()
          },
        }]
      : []

    // explicit ordering decides the DEFAULT (highlight 0) — never a guess the
    // user can't see: prefix → run; URL → open; else session match, ask, run
    if (/^[$!]/.test(text)) return [run, ask, ...openUrl, ...jumps]
    if (openUrl.length) return [...openUrl, ...jumps, ask, run]
    return [...jumps, ask, run]
  }, [open, q, threads, terminals, agentTerminals, panels, dockViews, agents, setOpen])

  useEffect(() => { setActive(0) }, [q])

  if (!open) return null

  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') { setOpen(false); return }
    if (e.key === 'ArrowDown') { e.preventDefault(); setActive((a) => Math.min(a + 1, actions.length - 1)); return }
    if (e.key === 'ArrowUp') { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); return }
    if (e.key === 'Enter') { e.preventDefault(); actions[active]?.run() }
  }

  return (
    <div className="palette-overlay omni-overlay" onMouseDown={() => setOpen(false)}>
      <div className="omni" onMouseDown={(e) => e.stopPropagation()}>
        <div className="omni-inputrow">
          <Icon name="Command" size={14} className="muted" />
          <input
            ref={inputRef}
            className="omni-input"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={onKey}
            placeholder="Jump to a session · ask an agent · $ run a command · open a URL"
            spellCheck={false}
          />
        </div>
        {actions.length > 0 && (
          <div className="omni-list">
            {actions.map((a, i) => (
              <button
                key={a.id}
                className="palette-item omni-item"
                data-active={i === active}
                onMouseEnter={() => setActive(i)}
                onClick={() => a.run()}
              >
                <Icon name={a.icon} size={14} className="palette-item-icon" />
                <span className="truncate">{a.label}</span>
                {a.hint && <span className="palette-item-hint truncate faint">{a.hint}</span>}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
