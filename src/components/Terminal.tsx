import { useEffect, useRef, useState } from 'react'
import { Terminal as XTerm, type IMarker, type ITheme } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { SearchAddon } from '@xterm/addon-search'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { WebglAddon } from '@xterm/addon-webgl'
import { bridge, isDesktop } from '../lib/bridge'
import { useKaisola, POP_TERMINAL_ID } from '../store/store'
import { clockTime } from '../lib/format'
import { Icon } from './Icon'

// xterm needs concrete hex (no CSS vars). These mirror --term-bg in tokens.css:
// the terminal sits a touch darker than the app surface in BOTH themes.
const DARK_THEME: ITheme = {
  // fully transparent — the pane's CSS provides the glass tint, so the
  // terminal reads as frosted glass over the desktop like the rest of the shell
  background: 'rgba(11, 13, 17, 0)',
  // a step brighter than the UI's --text-1: glyphs on glass lose edge contrast
  // to the blended backdrop, so the terminal needs more ink than DOM text
  foreground: '#d6dae2',
  cursor: '#95a456',
  cursorAccent: '#0b0d11',
  selectionBackground: 'rgba(149,164,86,0.25)',
  black: '#14161c',
  brightBlack: '#5a5f6b',
  red: '#e16a6a',
  green: '#54c08a',
  yellow: '#d8a44a',
  blue: '#5aa9e6',
  magenta: '#a88752',
  cyan: '#5ec5c0',
  white: '#c4c8d2',
  brightWhite: '#f3f4f6',
}
const LIGHT_THEME: ITheme = {
  background: 'rgba(233, 235, 239, 0)',
  foreground: '#21242b',
  cursor: '#5e7030',
  cursorAccent: '#e9ebef',
  selectionBackground: 'rgba(94,112,48,0.18)',
  black: '#2a2d34',
  brightBlack: '#8b909d',
  red: '#cf4f4f',
  green: '#2f9e6b',
  yellow: '#9a6b1f',
  blue: '#2f86c9',
  magenta: '#8a713a',
  cyan: '#1f8f88',
  white: '#3b3f48',
  brightWhite: '#16181d',
}
// energy saver trades the glass look for an opaque backbuffer (transparent
// WebGL surfaces force an extra compose pass per frame) — solid --term-bg hex
const xtermTheme = (theme: 'dark' | 'light', eco: boolean) => {
  const t = theme === 'light' ? LIGHT_THEME : DARK_THEME
  return eco ? { ...t, background: theme === 'light' ? '#e9ebef' : '#0b0d11' } : t
}

/** Output kept for a HIDDEN terminal until its card is shown again. Sized to
 * comfortably refill the 5000-line scrollback (~100 chars/line) — a bigger
 * buffer only makes re-showing the card parse megabytes it will immediately
 * scroll away, which is what made tab switches stutter. */
const HIDDEN_BUF_CAP = 512_000

/** The user's chosen face first, honest fallbacks behind it. 'ui-monospace'
 * is the "SF Mono (system)" choice — the name itself, unquoted. */
const fontStack = (family: string) =>
  family === 'ui-monospace'
    ? 'ui-monospace, Menlo, monospace'
    : `'${family}', ui-monospace, Menlo, monospace`

/** POSIX single-quote escaping, for paths written into the live shell. */
const shellQuote = (s: string) => `'${s.replace(/'/g, "'\\''")}'`

/** Terminal ids that have mounted an xterm in THIS renderer. SessionCards keeps
 * exactly these alive as hidden ghost cards across project switches — a switch
 * back re-shows a live xterm instead of replaying the whole pty snapshot. Never
 * seeds NEW ptys: an id lands here only after its terminal actually mounted. */
export const everMountedTerminals = new Set<string>()

/** Window-level visibility (minimized / fully occluded): while nobody can see
 * the window, every terminal buffers instead of parsing + painting. */
function useDocVisible() {
  const [v, setV] = useState(!document.hidden)
  useEffect(() => {
    const on = () => setV(!document.hidden)
    document.addEventListener('visibilitychange', on)
    return () => document.removeEventListener('visibilitychange', on)
  }, [])
  return v
}

/**
 * A real terminal (node-pty in the main process; raw byte forwarding here).
 * `attach` binds to an existing agent-owned session without owning its lifecycle.
 * The palette follows the app theme.
 */
export function Terminal({ id, attach = false, boot, cwd }: { id: string; attach?: boolean; boot?: string; cwd?: string }) {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<XTerm | null>(null)
  const searchRef = useRef<SearchAddon | null>(null)
  const findInputRef = useRef<HTMLInputElement>(null)
  const [findOpen, setFindOpen] = useState(false)
  const [findQuery, setFindQuery] = useState('')
  // prompt timeline for the Claude session: a marker per hook prompt event
  const promptMarksRef = useRef<{ marker: IMarker; text: string; at: number }[]>([])
  const [, setPromptTick] = useState(0)
  const [railHover, setRailHover] = useState<{ n: number; y: number } | null>(null)
  const theme = useKaisola((s) => s.theme)
  const ecoMode = useKaisola((s) => s.ecoMode)
  const termFontSize = useKaisola((s) => s.termFontSize)
  const termFontFamily = useKaisola((s) => s.termFontFamily)
  const termFontWeight = useKaisola((s) => s.termFontWeight)
  const setTermFontSize = useKaisola((s) => s.setTermFontSize)
  // put-away cards keep their pty but must not keep painting: output buffers
  // here and replays when the card is shown (pop-out windows are always shown).
  // An occluded/minimized WINDOW counts as hidden too — agents streaming into a
  // window nobody can see should cost buffering, not parse + GPU frames.
  const cardShown = useKaisola((s) => !!POP_TERMINAL_ID || (s.dockOpen && s.dockViews.includes(id)))
  const docVisible = useDocVisible()
  const visible = cardShown && docVisible
  const visibleRef = useRef(visible)
  visibleRef.current = visible
  const cardShownRef = useRef(cardShown)
  cardShownRef.current = cardShown
  // the WebGL renderer lives only while the card is shown — a hidden card
  // paints nothing, so holding a GPU context (and its glyph atlas) for it is
  // pure drain, and freed contexts keep many-session grids under the GL cap
  const glCtlRef = useRef<{ attach: () => void; drop: () => void } | null>(null)
  const pendingRef = useRef<{ chunks: string[]; bytes: number }>({ chunks: [], bytes: 0 })
  const themeRef = useRef(theme)
  themeRef.current = theme
  const ecoRef = useRef(ecoMode)
  ecoRef.current = ecoMode
  const fontSizeRef = useRef(termFontSize)
  fontSizeRef.current = termFontSize
  const fontFamilyRef = useRef(termFontFamily)
  fontFamilyRef.current = termFontFamily
  const fontWeightRef = useRef(termFontWeight)
  fontWeightRef.current = termFontWeight
  // boot delivery: `create` boots only FRESH ptys; a boot adopted while the pty
  // is already live arrives via the record's bootPending flag instead
  const bootPending = useKaisola((s) => s.terminals.find((t) => t.id === id)?.bootPending)
  const [ptyReady, setPtyReady] = useState(false)
  const bootSentRef = useRef(false)
  // what the create path actually typed (and when) — the adopted-boot effect
  // dedupes against it so a record update landing inside create's 700ms window
  // can't get the same command typed twice
  const lastBootRef = useRef<{ boot: string; at: number } | null>(null)

  // keep the live terminal's palette in sync with the app theme + energy saver
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    try {
      term.options.allowTransparency = !ecoMode
      term.options.theme = xtermTheme(theme, ecoMode)
    } catch { /* renderer mid-rebuild */ }
  }, [theme, ecoMode])

  // a card being put away / brought back: replay buffered output, and stop the
  // cursor-blink render loop while nobody can see it
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    try { term.options.cursorBlink = visible && !attach } catch { /* mid-teardown */ }
    if (!visible) return
    const p = pendingRef.current
    if (!p.chunks.length) return
    const chunk = p.chunks.join('')
    p.chunks = []
    p.bytes = 0
    term.write(chunk)
  }, [visible, attach])

  // the GPU renderer follows the CARD, not the window: putting a card away
  // frees its GL context; occlusion alone keeps it (re-showing the window
  // must not pay a per-terminal context rebuild)
  useEffect(() => {
    if (cardShown) glCtlRef.current?.attach()
    else glCtlRef.current?.drop()
  }, [cardShown])

  // font settings (Settings → Terminal, plus ⌘+/⌘−/⌘0) apply LIVE to every
  // terminal — the renderer rebuilds its glyph atlas and the pty re-fits
  const fitRef = useRef<FitAddon | null>(null)
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    term.options.fontSize = termFontSize
    term.options.fontFamily = fontStack(termFontFamily)
    term.options.fontWeight = termFontWeight as 400 | 500 | 700
    try {
      fitRef.current?.fit()
      bridge.terminal.resize(id, term.cols, term.rows)
    } catch { /* transient */ }
  }, [termFontSize, termFontFamily, termFontWeight, id])

  useEffect(() => {
    if (!isDesktop || !hostRef.current) return
    const term = new XTerm({
      fontFamily: fontStack(fontFamilyRef.current),
      fontSize: fontSizeRef.current,
      // default Medium (a real loaded face, not faux-bold): the WebGL renderer
      // only has grayscale AA, and on a transparent background 400-weight
      // glyphs read thin — 500 restores the fullness DOM text gets for free
      fontWeight: fontWeightRef.current as 400 | 500 | 700,
      fontWeightBold: 700,
      // 1.0 = the font's natural cell height, matching Terminal.app/iTerm density
      lineHeight: 1.0,
      cursorBlink: !attach,
      allowProposedApi: true,
      // the glass shell shows through the pane tint — unless energy saver
      // trades the see-through backbuffer for a cheaper opaque one
      allowTransparency: !ecoRef.current,
      scrollback: 5000,
      // lift low-contrast ANSI colors (dim grays on glass) to a readable floor
      minimumContrastRatio: 3,
      theme: xtermTheme(themeRef.current, ecoRef.current),
    })
    termRef.current = term
    const fit = new FitAddon()
    fitRef.current = fit
    term.loadAddon(fit)
    // ⌘F search across scrollback
    const search = new SearchAddon()
    searchRef.current = search
    term.loadAddon(search)
    // URLs are clickable. localhost links (the dev server an agent just
    // started) open as a browser CARD beside this terminal; everything else
    // goes to the user's real browser. Pop-out windows have no card grid and
    // a read-only store — there the external browser is the only real target.
    term.loadAddon(new WebLinksAddon((_e, uri) => {
      try {
        const host = new URL(uri).hostname
        if (!POP_TERMINAL_ID && (host === 'localhost' || host === '127.0.0.1' || host === '0.0.0.0')) {
          // one origin per dev server: 127.0.0.1/0.0.0.0 normalize to localhost
          // so the link and the port chip reuse the SAME browser card
          useKaisola.getState().openBrowserPanel(uri.replace('//0.0.0.0', '//localhost').replace('//127.0.0.1', '//localhost'))
          return
        }
      } catch { /* fall through to the external browser */ }
      void bridge.openExternal(uri)
    }))
    term.open(hostRef.current)
    everMountedTerminals.add(id)
    // GPU renderer when available (the pty stays byte-identical without it).
    // Its dispose() is NOT idempotent and crashes inside term.dispose() (seen
    // under StrictMode's dev double-mount) — so we dispose it ourselves first,
    // exactly once, and never let the addon manager hit a live GL renderer.
    // Attach/drop follows card visibility (glCtlRef): hidden cards hold no
    // GL context, so ghost cards and put-away sessions cost RAM, not GPU.
    let gl: WebglAddon | null = null
    const dropWebgl = () => {
      const g = gl
      gl = null
      if (!g) return
      try {
        g.dispose()
      } catch { /* already torn down */ }
    }
    const attachWebgl = () => {
      if (gl) return
      try {
        gl = new WebglAddon()
        gl.onContextLoss(() => dropWebgl())
        term.loadAddon(gl)
      } catch {
        gl = null // canvas/DOM renderer fallback
      }
    }
    glCtlRef.current = { attach: attachWebgl, drop: dropWebgl }
    if (cardShownRef.current) attachWebgl()
    fit.fit()

    let disposed = false
    let unsubData = () => {}
    let unsubExit = () => {}

    // ── blocks-lite: mark each command so scrollback has structure ──
    // Preferred source: OSC 133 shell-integration marks (A = prompt start,
    // D;<code> = command done) when the user's shell emits them; fallback:
    // the Enter key on a non-empty typed line. ⌘↑/⌘↓ jump between marks;
    // each mark draws a hairline separator (red-tinted when the command failed).
    // programs announce themselves (vim, ssh, claude…) via OSC 0/2 titles —
    // adopt them as the session's live identity instead of guessing. Agent
    // TUIs re-title at spinner rate, so writes trail-throttle to ~3/s.
    let titleTimer: ReturnType<typeof setTimeout> | null = null
    let latestTitle = ''
    term.onTitleChange((title) => {
      latestTitle = title.trim()
      if (titleTimer) return
      titleTimer = setTimeout(() => {
        titleTimer = null
        if (disposed) return
        useKaisola.getState().setTerminalMeta(id, { oscTitle: latestTitle ? latestTitle.slice(0, 60) : null })
      }, 300)
    })

    // the Claude session's prompt TIMELINE: each hook prompt event pins a
    // marker at the current scrollback line — the rail's ticks jump there
    const offPrompts = bridge.claude.onEvent((ev) => {
      if (disposed || ev.event !== 'UserPromptSubmit') return
      const rec = useKaisola.getState().terminals.find((t) => t.id === id)
      if (rec?.singletonKey !== 'agent:claude-code') return
      const marker = term.registerMarker(0)
      if (!marker) return
      promptMarksRef.current.push({ marker, text: (ev.prompt || 'prompt').slice(0, 200), at: ev.at })
      if (promptMarksRef.current.length > 40) promptMarksRef.current.shift()
      marker.onDispose(() => {
        promptMarksRef.current = promptMarksRef.current.filter((p) => p.marker !== marker)
      })
      setPromptTick((n) => n + 1)
    })

    const marks: { marker: IMarker; el?: HTMLElement }[] = []
    let oscMarks = false
    const addMark = () => {
      const marker = term.registerMarker(0)
      if (!marker) return
      const deco = term.registerDecoration({ marker, width: term.cols, layer: 'bottom' })
      deco?.onRender((el) => {
        el.classList.add('term-cmd-mark')
        const mark = marks.find((m) => m.marker === marker)
        if (mark) mark.el = el
      })
      marker.onDispose(() => {
        const i = marks.findIndex((m) => m.marker === marker)
        if (i >= 0) marks.splice(i, 1)
      })
      marks.push({ marker })
    }
    term.parser.registerOscHandler(133, (data) => {
      const [cmd, arg] = data.split(';')
      if (cmd === 'A') {
        oscMarks = true
        addMark()
      } else if (cmd === 'D') {
        const code = Number(arg ?? 0)
        if (code !== 0) marks[marks.length - 1]?.el?.classList.add('term-cmd-mark-failed')
        // surface the exit code — the rail/card dots tint red on failure
        useKaisola.getState().setTerminalMeta(id, { lastExit: Number.isFinite(code) ? code : null })
      }
      return false // never consume — other handlers may care
    })
    term.attachCustomKeyEventHandler((ev) => {
      if (ev.type !== 'keydown' || !ev.metaKey) return true
      // ⌘F — search the scrollback (Terminal.app parity)
      if (ev.key.toLowerCase() === 'f' && !ev.shiftKey) {
        setFindOpen(true)
        setTimeout(() => findInputRef.current?.focus(), 0)
        return false
      }
      // ⌘+ / ⌘− / ⌘0 — font zoom, persisted across every terminal
      if (ev.key === '=' || ev.key === '+') {
        useKaisola.getState().setTermFontSize(fontSizeRef.current + 1)
        return false
      }
      if (ev.key === '-') {
        useKaisola.getState().setTermFontSize(fontSizeRef.current - 1)
        return false
      }
      if (ev.key === '0') {
        useKaisola.getState().setTermFontSize(null)
        return false
      }
      if (ev.key !== 'ArrowUp' && ev.key !== 'ArrowDown') return true
      const live = marks.filter((m) => !m.marker.isDisposed)
      if (!live.length) return true
      const viewTop = term.buffer.active.viewportY
      const prev = [...live].reverse().find((m) => m.marker.line < viewTop)
      const next = live.find((m) => m.marker.line > viewTop)
      const target = ev.key === 'ArrowUp' ? prev ?? live[0] : next
      if (target) term.scrollToLine(target.marker.line)
      else if (ev.key === 'ArrowDown') term.scrollToBottom()
      return false
    })

    // best-effort echo of the line being typed — drives command MARKS only
    // (labels come from stable identity: agent/repo/folder, never keystrokes).
    // Escape sequences (history, arrows) mean we no longer know the line —
    // bail rather than guess wrong.
    let typed = ''
    // marks mean "a shell command ran" — never mark keystrokes typed INTO a
    // running program (claude's composer, vim…), and agent TUIs never mark
    const marksApply = () => {
      const st = useKaisola.getState()
      if (st.terminals.find((t) => t.id === id)?.singletonKey?.startsWith('agent:')) return false
      if (term.buffer.active.type === 'alternate') return false
      return !st.terminalMeta[id]?.running
    }
    const trackInput = (data: string) => {
      for (const ch of data) {
        if (ch === '\r' || ch === '\n') {
          const cmd = typed.trim()
          typed = ''
          if (cmd && marksApply()) {
            useKaisola.getState().setTerminalMeta(id, { lastExit: null }) // new command → clear the failure tint
            if (!oscMarks) addMark() // fallback marks only when the shell has no integration
          }
        } else if (ch === '\x7f') typed = typed.slice(0, -1)
        else if (ch === '\x1b' || ch < ' ') typed = ''
        else typed += ch
      }
    }

    // dev-server detection: a URL/port in the output becomes a chip on the
    // card head that opens (or re-points) a browser card beside this terminal
    const PORT_RE = /(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{2,5})/
    const scanPorts = (data: string) => {
      if (!data.includes(':')) return
      const m = data.match(PORT_RE)
      if (!m) return
      const port = Number(m[1])
      // skip only the OS ephemeral range — macOS assigns CLIENT ports from
      // 49152–65535 (the access-log noise this guards). Dev servers below it
      // (3000/5173/8080, and high-but-fixed ports up to 49151) still get a chip.
      if (!port || port >= 49152) return
      const st = useKaisola.getState()
      const ports = st.terminalMeta[id]?.ports ?? []
      if (ports[0] === port) return
      st.setTerminalMeta(id, { ports: [port, ...ports.filter((p) => p !== port)].slice(0, 2) })
    }

    const wire = () => {
      unsubData = bridge.terminal.onData(id, (data) => {
        // hidden cards don't paint: buffer (capped) and replay on show —
        // parse + GPU render for a card nobody can see is pure battery drain
        if (visibleRef.current) {
          term.write(data)
        } else {
          const p = pendingRef.current
          p.chunks.push(data)
          p.bytes += data.length
          while (p.bytes > HIDDEN_BUF_CAP && p.chunks.length > 1) {
            p.bytes -= p.chunks[0].length
            p.chunks.shift()
          }
        }
        scanPorts(data)
      })
      unsubExit = bridge.terminal.onExit(id, () => {})
      term.onData((data) => {
        bridge.terminal.write(id, data)
        if (!attach) trackInput(data)
      })
      bridge.terminal.resize(id, term.cols, term.rows)
    }

    if (attach) {
      bridge.terminal.attach(id).then((snap) => {
        if (disposed) return
        if (snap.output) term.write(snap.output)
        wire()
      })
    } else {
      bridge.terminal.create(id, cwd, term.cols, term.rows).then((res) => {
        if (disposed) return
        if (!res.ok) {
          term.writeln('\x1b[38;2;225;106;106mTerminal unavailable.\x1b[0m')
          return
        }
        if (res.output) term.write(res.output)
        wire()
        // run a boot command (e.g. `codex login`) once the shell prompt is
        // ready. FRESH pty: this path is the single boot writer — it reads the
        // record at FIRE time (the auto-launch may have swapped in a --resume
        // line since mount) and clears bootPending so the adopted-boot effect
        // can't type the same command twice.
        if (!res.existed) {
          useKaisola.getState().clearBootPending(id)
          if (!bootSentRef.current) {
            bootSentRef.current = true
            setTimeout(() => {
              if (disposed) return
              const st = useKaisola.getState()
              st.clearBootPending(id) // an update that landed during the wait is delivered right here
              const line = st.terminals.find((t) => t.id === id)?.boot ?? boot
              if (!line) return
              lastBootRef.current = { boot: line, at: Date.now() }
              bridge.terminal.write(id, line + '\n')
            }, 700)
          }
        }
        setPtyReady(true)
      })
    }

    const doFit = () => {
      try {
        fit.fit()
        bridge.terminal.resize(id, term.cols, term.rows)
      } catch {
        /* ignore */
      }
    }
    const onWinResize = () => doFit()
    window.addEventListener('resize', onWinResize)
    const ro = new ResizeObserver(() => doFit())
    ro.observe(hostRef.current)
    const host = hostRef.current
    const focus = () => term.focus()
    host.addEventListener('click', focus)

    return () => {
      disposed = true
      if (titleTimer) clearTimeout(titleTimer)
      window.removeEventListener('resize', onWinResize)
      host.removeEventListener('click', focus)
      ro.disconnect()
      unsubData()
      unsubExit()
      offPrompts()
      promptMarksRef.current = []
      pendingRef.current = { chunks: [], bytes: 0 }
      glCtlRef.current = null
      dropWebgl() // must go before term.dispose() — see note above
      try {
        term.dispose()
      } catch { /* an addon threw mid-teardown — the pty is unaffected */ }
      termRef.current = null
      fitRef.current = null
      searchRef.current = null
      bootSentRef.current = false
      setPtyReady(false)
    }
    // cwd is intentionally NOT a dep: it only matters at spawn time, and a
    // record cwd change must never tear down a live session mid-run
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, attach])

  // deliver a boot adopted after the pty went live (see bootPending). The shell
  // was spawned before the terminal had a cwd, so cd to it as a user would.
  // A cwd WITHOUT a boot is the workspace adoption: the default shell just
  // cd's into the freshly opened project folder.
  useEffect(() => {
    if (!ptyReady || !bootPending) return
    const st = useKaisola.getState()
    const t = st.terminals.find((x) => x.id === id)
    st.clearBootPending(id)
    // bootPending is an explicit "write it now" (set only for already-live
    // ptys — new terminals boot via the create path), so a rerun of the SAME
    // command (LaTeX rebuild) must not be swallowed by the sent-once guard
    const line = t?.boot
      ? t.cwd ? `cd ${shellQuote(t.cwd)} && ${t.boot}` : t.boot
      : t?.cwd ? `cd ${shellQuote(t.cwd)}` : null
    if (!line) return
    // never type into a program holding the foreground — a running TUI would
    // swallow the command as chat text; boots land at a shell prompt only
    if (st.terminalMeta[id]?.running) return
    // the create path may have typed this exact boot moments ago (a record
    // update that landed inside its 700ms window) — don't type it twice.
    // Deliberate reruns (LaTeX rebuild) come much later and pass the window.
    if (t?.boot && lastBootRef.current?.boot === t.boot && Date.now() - lastBootRef.current.at < 10_000) return
    bootSentRef.current = true
    setTimeout(() => bridge.terminal.write(id, line + '\n'), 700)
  }, [ptyReady, bootPending, id])

  // find-in-scrollback: amber matches, accent active match (proposed-API decorations)
  const findDecorations = {
    matchBackground: '#d8a44a55',
    activeMatchBackground: '#95a45688',
    matchOverviewRuler: '#d8a44a',
    activeMatchColorOverviewRuler: '#95a456',
  }
  const findNext = (back = false) => {
    if (!findQuery) return
    if (back) searchRef.current?.findPrevious(findQuery, { decorations: findDecorations })
    else searchRef.current?.findNext(findQuery, { decorations: findDecorations })
  }
  const closeFind = () => {
    setFindOpen(false)
    setFindQuery('')
    searchRef.current?.clearDecorations()
    termRef.current?.focus()
  }

  if (!isDesktop) {
    return (
      <div className="term-web-notice">
        <Icon name="SquareTerminal" size={20} />
        <div>Terminals run in the desktop app.</div>
        <div className="faint">npm run electron:dev</div>
      </div>
    )
  }
  const promptMarks = promptMarksRef.current.filter((p) => !p.marker.isDisposed)
  return (
    <div className="term-wrap" data-rail={promptMarks.length > 1 || undefined}>
      {/* prompt timeline for the Claude session — a tick per instigated turn */}
      {promptMarks.length > 1 && (
        <div className="turn-rail" onMouseLeave={() => setRailHover(null)}>
          {promptMarks.map((p, n) => (
            <button
              key={`${p.at}-${n}`}
              className="turn-tick"
              onMouseEnter={(e) => setRailHover({ n, y: (e.currentTarget as HTMLElement).offsetTop })}
              onClick={() => termRef.current?.scrollToLine(p.marker.line)}
              aria-label={p.text.slice(0, 60)}
            />
          ))}
          {railHover && promptMarks[railHover.n] && (
            <div className="turn-pop" style={{ top: Math.max(0, railHover.y - 12) }}>
              <div className="turn-pop-title">{promptMarks[railHover.n].text}</div>
              <div className="turn-pop-meta">
                <span>{clockTime(new Date(promptMarks[railHover.n].at).toISOString())}</span>
              </div>
            </div>
          )}
        </div>
      )}
      {findOpen && (
        <div className="term-find">
          <Icon name="Search" size={12} className="muted" />
          <input
            ref={findInputRef}
            value={findQuery}
            onChange={(e) => setFindQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') findNext(e.shiftKey)
              else if (e.key === 'Escape') closeFind()
            }}
            placeholder="Find in terminal"
            spellCheck={false}
          />
          <button onClick={() => findNext(true)} title="Previous  ⇧⏎"><Icon name="ChevronUp" size={12} /></button>
          <button onClick={() => findNext(false)} title="Next  ⏎"><Icon name="ChevronDown" size={12} /></button>
          <button onClick={closeFind} title="Close  esc"><Icon name="X" size={12} /></button>
        </div>
      )}
      <div ref={hostRef} className="term-host" />
    </div>
  )
}
