import { useEffect, useRef, useState } from 'react'
import { Terminal as XTerm, type IMarker, type ITheme } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { SearchAddon } from '@xterm/addon-search'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { WebglAddon } from '@xterm/addon-webgl'
import { bridge, isDesktop, type TermSnapshot } from '../lib/bridge'
import { useKaisola, terminalOwnerMap, POP_TERMINAL_ID, type TermBackground, type TerminalContinuationStatus } from '../store/store'
import { clockTime } from '../lib/format'
import { touchMountedTerminal } from '../lib/terminalResidency'
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
  // minimalist default: the cursor is the same ink as the text; a custom
  // color (Settings → Terminal) overrides it in xtermTheme below
  cursor: '#d6dae2',
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
  cursor: '#21242b',
  cursorAccent: '#e9ebef',
  selectionBackground: 'rgba(94,112,48,0.18)',
  // TUIs use ANSI black as a panel/composer BACKGROUND. On a light surface it
  // must invert to paper; xterm's contrast floor remaps black foreground text.
  black: '#eef0f4',
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
const FIND_DECORATIONS = {
  matchBackground: '#d8a44a55',
  activeMatchBackground: '#95a45688',
  matchOverviewRuler: '#d8a44a',
  activeMatchColorOverviewRuler: '#95a456',
}
// The xterm surface is ALWAYS opaque (allowTransparency stays off): a transparent
// WebGL surface forces an extra GPU compose every frame the terminal paints — the
// app's dominant cost while an agent streams. Glass BAKES the old translucent look
// (45% --term-bg over the opaque --bg-1 card) into a solid color, so it's visually
// identical to the old transparent surface but never re-composited; eco stays flat
// --term-bg. The termBackground setting (ink / slate / paper) picks the tone;
// 'paper' is light regardless of app theme and swaps to the light text palette.
// Keep these in sync with tokens.css [data-termbg] if --term-bg / --bg-1 change.
const TERM_SURFACE: Record<TermBackground, { glass: { dark: string; light: string }; eco: { dark: string; light: string } }> = {
  ink: {
    glass: { dark: '#0d0f13', light: '#ffffff' },
    eco: { dark: '#0b0d11', light: '#ffffff' },
  },
  slate: {
    glass: { dark: '#1c2027', light: '#ffffff' },
    eco: { dark: '#191d24', light: '#ffffff' },
  },
  paper: {
    glass: { dark: '#ffffff', light: '#ffffff' },
    eco: { dark: '#ffffff', light: '#ffffff' },
  },
}
const xtermTheme = (theme: 'dark' | 'light', eco: boolean, cursorColor = 'auto', termBg: TermBackground = 'ink') => {
  // paper is a light surface even in the dark app — text must flip with it
  const lightSurface = theme === 'light' || termBg === 'paper'
  const base = lightSurface ? LIGHT_THEME : DARK_THEME
  const t = cursorColor === 'auto' ? base : { ...base, cursor: cursorColor }
  const surface = TERM_SURFACE[termBg] ?? TERM_SURFACE.paper
  return { ...t, background: (eco ? surface.eco : surface.glass)[theme] }
}

/** xterm may reflow its buffer when its palette, font, or fitted geometry
 * changes. Preserve the user's distance from the live prompt through both the
 * synchronous update and the next paint instead of snapping to row zero. */
const preserveTerminalViewport = (term: XTerm, mutate: () => void) => {
  const fromBottom = Math.max(0, term.buffer.active.baseY - term.buffer.active.viewportY)
  const restore = () => {
    try {
      if (fromBottom <= 1) term.scrollToBottom()
      else term.scrollToLine(Math.max(0, term.buffer.active.baseY - fromBottom))
    } catch { /* renderer mid-rebuild */ }
  }
  mutate()
  restore()
  requestAnimationFrame(restore)
}

/** Output kept for a HIDDEN terminal until its card is shown again. Sized to
 * comfortably refill the 5000-line scrollback (~100 chars/line) — a bigger
 * buffer only makes re-showing the card parse megabytes it will immediately
 * scroll away, which is what made tab switches stutter. */
const HIDDEN_BUF_CAP = 512_000
/** Minimize/hide can be a momentary Mission Control transition. Wait briefly
 * before paying the teardown/replay cost; a genuinely hidden window then owns
 * zero xterm canvases, glyph atlases, listeners, or renderer scrollback. */
const WINDOW_HIBERNATE_GRACE_MS = 1200

/** The user's chosen face first, honest fallbacks behind it. 'ui-monospace'
 * is the "SF Mono (system)" choice — the name itself, unquoted. */
const fontStack = (family: string) =>
  family === 'ui-monospace'
    ? 'ui-monospace, Menlo, monospace'
    : `'${family}', ui-monospace, Menlo, monospace`

/** POSIX single-quote escaping, for paths written into the live shell. */
const shellQuote = (s: string) => `'${s.replace(/'/g, "'\\''")}'`

/** Agent boots wipe the screen + scrollback right before the TUI draws: the
 * typed `cd … && claude --resume …` launch line is plumbing, and a
 * (re)started agent should look like the conversation it resumes, not the
 * command that produced it. Plain terminal boots keep their echo. The STORED
 * boot stays clean (tab auto-names and dedupe compare it) — the wipe exists
 * only on the line typed into the pty. */
const bootLine = (boot: string, singletonKey?: string) =>
  singletonKey?.startsWith('agent:') ? `printf '\\033[2J\\033[3J\\033[H'; ${boot}` : boot

/** Window visibility has two phases: stop painting immediately, then fully
 * dispose/detach the renderer after a short grace. The broker PTY is untouched. */
function useDocumentTerminalLifecycle() {
  const initial = !document.hidden
  const [visible, setVisible] = useState(initial)
  const [rendererAwake, setRendererAwake] = useState(initial)
  useEffect(() => {
    let timer: number | null = null
    const on = () => {
      const next = !document.hidden
      setVisible(next)
      if (timer != null) window.clearTimeout(timer)
      timer = null
      if (next) {
        setRendererAwake(true)
        return
      }
      timer = window.setTimeout(() => {
        timer = null
        setRendererAwake(false)
      }, WINDOW_HIBERNATE_GRACE_MS)
    }
    on()
    document.addEventListener('visibilitychange', on)
    return () => {
      if (timer != null) window.clearTimeout(timer)
      document.removeEventListener('visibilitychange', on)
    }
  }, [])
  return { visible, rendererAwake }
}

/** Only an across-app-instance handoff of a still-live PTY earns the receipt.
 * Ordinary card/window remounts deliberately return null. */
function continuedStatus(snapshot: Partial<TermSnapshot>): TerminalContinuationStatus | null {
  const continuity = snapshot.continuation
  if (!continuity?.acrossRestart || continuity.exitedWhileDetached || snapshot.exited) return null
  return {
    sameProcess: true,
    at: Number.isFinite(continuity.reattachedAt) ? continuity.reattachedAt! : Date.now(),
    ...(Number.isFinite(continuity.terminalPid) ? { terminalPid: continuity.terminalPid } : {}),
    ...(Number.isFinite(continuity.outputBytes) ? { outputBytes: continuity.outputBytes } : {}),
  }
}

/**
 * A real terminal (node-pty in the main process; raw byte forwarding here).
 * `attach` binds to an existing agent-owned session without owning its lifecycle.
 * The palette follows the app theme.
 */
export function Terminal({ id, attach = false, boot, cwd, projectId: projectIdOverride }: { id: string; attach?: boolean; boot?: string; cwd?: string; projectId?: string }) {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<XTerm | null>(null)
  const searchRef = useRef<SearchAddon | null>(null)
  const findInputRef = useRef<HTMLInputElement>(null)
  const [findOpen, setFindOpen] = useState(false)
  const [findQuery, setFindQuery] = useState('')
  // an OS file drag hovering this terminal — the drop types its path(s) at the
  // prompt (iTerm-style) instead of opening a file tab
  const [fileDropHover, setFileDropHover] = useState(false)
  // prompt timeline for the Claude session: a marker per hook prompt event
  const promptMarksRef = useRef<{ marker: IMarker; text: string; at: number; src?: 'typed' | 'hook' }[]>([])
  // once a hook-sourced mark arrives, the typed fallback stands down
  const hookMarksLiveRef = useRef(false)
  const [, setPromptTick] = useState(0)
  const [railHover, setRailHover] = useState<{ n: number; y: number } | null>(null)
  const theme = useKaisola((s) => s.theme)
  // Terminal capabilities are scoped to the project that owns this id, not
  // merely whichever tab is active. Hidden warm cards can belong to a parked
  // project slice, and popped/transferred cards keep this same project id.
  const projectId = useKaisola((s) => projectIdOverride ?? terminalOwnerMap(s)[id] ?? s.activeProjectId)
  const ecoMode = useKaisola((s) => s.perfMode === 'eco')
  const termFontSize = useKaisola((s) => s.termFontSize)
  const termFontFamily = useKaisola((s) => s.termFontFamily)
  const termFontWeight = useKaisola((s) => s.termFontWeight)
  const termCursorColor = useKaisola((s) => s.termCursorColor)
  const termBackground = useKaisola((s) => s.termBackground)
  const setTermFontSize = useKaisola((s) => s.setTermFontSize)
  // put-away cards keep their pty but must not keep painting: output buffers
  // here and replays when the card is shown (pop-out windows are always shown).
  // An occluded/minimized WINDOW counts as hidden too — agents streaming into a
  // window nobody can see should cost buffering, not parse + GPU frames.
  const cardShown = useKaisola((s) => !!POP_TERMINAL_ID || (s.dockOpen && s.dockViews.includes(id)))
  const { visible: docVisible, rendererAwake } = useDocumentTerminalLifecycle()
  const visible = cardShown && docVisible
  const visibleRef = useRef(visible)
  const cardShownRef = useRef(cardShown)
  // the WebGL renderer lives only while the card is shown — a hidden card
  // paints nothing, so holding a GPU context (and its glyph atlas) for it is
  // pure drain, and freed contexts keep many-session grids under the GL cap
  const glCtlRef = useRef<{ attach: () => void; drop: () => void } | null>(null)
  const pendingRef = useRef<{ chunks: string[]; bytes: number }>({ chunks: [], bytes: 0 })
  const themeRef = useRef(theme)
  const ecoRef = useRef(ecoMode)
  const fontSizeRef = useRef(termFontSize)
  const fontFamilyRef = useRef(termFontFamily)
  const fontWeightRef = useRef(termFontWeight)
  const cursorColorRef = useRef(termCursorColor)
  const termBgRef = useRef(termBackground)
  // boot delivery: `create` boots only FRESH ptys; a boot adopted while the pty
  // is already live arrives via the record's bootPending flag instead
  const bootPending = useKaisola((s) => s.terminals.find((t) => t.id === id)?.bootPending)
  const foregroundProcess = useKaisola((s) => s.terminalMeta[id]?.fgProcess)
  const persistedContinuation = useKaisola((s) => s.terminals.find((t) => t.id === id)?.continued)
  const setTerminalContinuation = useKaisola((s) => s.setTerminalContinuation)
  // Agent-owned attach-only terminals are not durable TerminalSession rows;
  // they still get the receipt for this mount, while user/CLI terminals persist it.
  const [attachedContinuation, setAttachedContinuation] = useState<TerminalContinuationStatus | null>(null)
  const continuation = persistedContinuation ?? attachedContinuation
  const [ptyReady, setPtyReady] = useState(false)
  const [freshBootRequest, setFreshBootRequest] = useState<{ fallbackBoot?: string; requestedAt: number } | null>(null)
  // A broker-owned pty can outlive the Electron renderer across an update.
  // Pending boots must distinguish that live pty from a newly-created shell.
  const ptyExistedRef = useRef(false)
  const bootSentRef = useRef(false)
  // what the create path actually typed (and when) — the adopted-boot effect
  // dedupes against it so a record update landing inside create's 700ms window
  // can't get the same command typed twice
  const lastBootRef = useRef<{ boot: string; at: number } | null>(null)
  // draft survival: the CLI composer's unsent text, reconstructed from
  // keystrokes (see trackDraft) — replayed into a resumed agent after restart
  const lastOutputAtRef = useRef<number | null>(null)
  if (lastOutputAtRef.current === null) lastOutputAtRef.current = Date.now()
  const agentTurnOpenRef = useRef(false)
  const agentDoneTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const codexProbeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const focusTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const draftRetypeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const codexSessionRef = useRef<string | null>(null)
  // A hibernated xterm remounts around the same live CLI composer. Seed the
  // keystroke tracker from durable state so the next character appends to the
  // existing draft instead of replacing it with only the new suffix.
  const draftBufRef = useRef(useKaisola.getState().termDrafts[id] ?? '')
  const trackDraftRef = useRef<(data: string) => void>(() => {})
  const armDraftRetypeRef = useRef<(bootStr: string) => void>(() => {})

  useEffect(() => {
    visibleRef.current = visible
    cardShownRef.current = cardShown
    themeRef.current = theme
    ecoRef.current = ecoMode
    fontSizeRef.current = termFontSize
    fontFamilyRef.current = termFontFamily
    fontWeightRef.current = termFontWeight
    cursorColorRef.current = termCursorColor
    termBgRef.current = termBackground
  }, [visible, cardShown, theme, ecoMode, termFontSize, termFontFamily, termFontWeight, termCursorColor, termBackground])

  // One-time means one actually visible glance, not “eight seconds elapsed in
  // a minimized window.” If the app exits first, the persisted receipt returns.
  useEffect(() => {
    if (!visible || !continuation) return
    const timer = window.setTimeout(() => {
      if (persistedContinuation) setTerminalContinuation(id, undefined)
      setAttachedContinuation(null)
    }, 8000)
    return () => window.clearTimeout(timer)
  }, [visible, continuation, persistedContinuation, id, setTerminalContinuation])

  // keep the live terminal's palette in sync with the app theme + energy saver
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    try {
      preserveTerminalViewport(term, () => {
        term.options.allowTransparency = false // opaque in both modes — no transparent-WebGL per-frame compose
        term.options.theme = xtermTheme(theme, ecoMode, termCursorColor, termBackground)
      })
    } catch { /* renderer mid-rebuild */ }
  }, [theme, ecoMode, termCursorColor, termBackground])

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
    if (cardShown) {
      touchMountedTerminal(id)
      glCtlRef.current?.attach()
    }
    else glCtlRef.current?.drop()
  }, [cardShown, id])

  // font settings (Settings → Terminal, plus ⌘+/⌘−/⌘0) apply LIVE to every
  // terminal — the renderer rebuilds its glyph atlas and the pty re-fits
  const fitRef = useRef<FitAddon | null>(null)
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    try {
      preserveTerminalViewport(term, () => {
        term.options.fontSize = termFontSize
        term.options.fontFamily = fontStack(termFontFamily)
        term.options.fontWeight = termFontWeight as 400 | 500 | 700
        fitRef.current?.fit()
        void bridge.terminal.resize(id, term.cols, term.rows, projectId).catch(() => {})
      })
    } catch { /* transient */ }
  }, [termFontSize, termFontFamily, termFontWeight, id, projectId])

  useEffect(() => {
    if (!isDesktop || !hostRef.current || !rendererAwake) return
    hostRef.current.replaceChildren()
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
      // ⌥-click jumps the prompt cursor to the clicked spot (iTerm parity) —
      // xterm synthesizes the arrow-key presses; plain click stays selection
      altClickMovesCursor: true,
      allowProposedApi: true,
      // the glass shell shows through the pane tint — unless energy saver
      // trades the see-through backbuffer for a cheaper opaque one
      allowTransparency: false, // opaque in both modes — see TERM_SURFACE (no per-frame WebGL compose)
      scrollback: 5000,
      // lift low-contrast ANSI colors (dim grays on glass) to a readable floor
      minimumContrastRatio: 3,
      theme: xtermTheme(themeRef.current, ecoRef.current, cursorColorRef.current, termBgRef.current),
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
    touchMountedTerminal(id)
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

    const finishAgentTurn = () => {
      if (agentDoneTimerRef.current) clearTimeout(agentDoneTimerRef.current)
      agentDoneTimerRef.current = null
      if (!agentTurnOpenRef.current && !useKaisola.getState().terminalMeta[id]?.agentBusy) return
      agentTurnOpenRef.current = false
      const state = useKaisola.getState()
      state.setTerminalMeta(id, { agentBusy: false })
      bridge.terminal.agentTurn(id, false, projectId)
    }
    const armAgentDone = () => {
      if (!agentTurnOpenRef.current) return
      if (agentDoneTimerRef.current) clearTimeout(agentDoneTimerRef.current)
      agentDoneTimerRef.current = setTimeout(finishAgentTurn, 4500)
    }
    const captureCodexSession = () => {
      const state = useKaisola.getState()
      const record = state.terminals.find((terminal) => terminal.id === id)
      if (!record?.singletonKey?.startsWith('agent:codex')) return
      const liveCwd = state.terminalMeta[id]?.cwd ?? record.cwd ?? cwd
      if (codexProbeTimerRef.current) return
      codexProbeTimerRef.current = setTimeout(() => {
        codexProbeTimerRef.current = null
        void bridge.terminal.codexSession(id, liveCwd, projectId).then((result) => {
          if (disposed || !result.ok || !result.sessionId || codexSessionRef.current === result.sessionId) return
          codexSessionRef.current = result.sessionId
          useKaisola.getState().setTerminalResume(id, `codex resume ${result.sessionId}`)
        }).catch(() => {})
      }, 900)
    }
    const beginAgentTurn = () => {
      agentTurnOpenRef.current = true
      const state = useKaisola.getState()
      state.setTerminalMeta(id, { agentBusy: true, lastExit: null })
      bridge.terminal.agentTurn(id, true, projectId)
      const owner = terminalOwnerMap(state)[id]
      if (owner && owner !== state.activeProjectId) state.setProjectActivity(owner, 'running')
      captureCodexSession()
    }

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
      if (disposed) return
      const rec = useKaisola.getState().terminals.find((t) => t.id === id)
      if (rec?.singletonKey !== 'agent:claude-code') return
      if (ev.event === 'Stop') { finishAgentTurn(); return }
      if (ev.event !== 'UserPromptSubmit') return
      beginAgentTurn()
      const marker = term.registerMarker(0)
      if (!marker) return
      hookMarksLiveRef.current = true
      // a typed fallback mark for this same prompt may have landed moments
      // ago (Enter beat the hook event) — replace it, don't double-tick
      promptMarksRef.current = promptMarksRef.current.filter(
        (p) => !(p.src === 'typed' && Date.now() - p.at < 3000),
      )
      promptMarksRef.current.push({ marker, text: (ev.prompt || 'prompt').slice(0, 200), at: ev.at, src: 'hook' })
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
      // Shift+⏎ inserts a newline instead of submitting — backslash+CR,
      // claude's universal "\ then Enter" line continuation (ESC+CR was
      // swallowed by its TUI); a bare shell prompt shows a continuation
      // line, which is also a newline, not a submit
      if (ev.type === 'keydown' && ev.key === 'Enter' && ev.shiftKey && !ev.metaKey && !ev.ctrlKey && !ev.altKey) {
        void bridge.terminal.write(id, '\\\r', projectId).catch(() => {})
        trackDraftRef.current('\\\r') // direct write bypasses term.onData — feed the draft tracker too
        return false
      }
      if (ev.type !== 'keydown' || !ev.metaKey) return true
      // ⌘F — search the scrollback (Terminal.app parity)
      if (ev.key.toLowerCase() === 'f' && !ev.shiftKey) {
        setFindOpen(true)
        if (focusTimerRef.current) clearTimeout(focusTimerRef.current)
        focusTimerRef.current = setTimeout(() => {
          focusTimerRef.current = null
          findInputRef.current?.focus()
        }, 0)
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

    // DRAFT SURVIVAL (agent terminals): the composer's unsent text lives
    // inside the CLI process, so it's reconstructed here from keystrokes —
    // printable chars append, backspace trims, Enter submits (clears), and
    // claude's backslash+CR line continuation becomes a stored newline.
    // Arrow-key edits degrade fidelity (linear model) — accepted best-effort.
    const isAgentTerm = () => {
      const state = useKaisola.getState()
      return !!state.terminals.find((t) => t.id === id)?.singletonKey?.match(/^(agent|wt):/)
        || /^(claude|codex)\b/.test(state.terminalMeta[id]?.fgProcess ?? '')
    }
    const flushDraft = () => useKaisola.getState().setTermDraft(id, draftBufRef.current)
    const trackDraft = (data: string) => {
      if (!isAgentTerm()) return
      if (data === '\x1b' || data === '\x03' || data === '\x15') {
        // bare Esc / Ctrl-C / Ctrl-U — the composer cleared
        draftBufRef.current = ''
        flushDraft()
        return
      }
      const d = data.replace(/\x1b\[20[01]~/g, '') // keep bracketed-paste payloads
      for (let i = 0; i < d.length; i++) {
        const ch = d[i]
        if (ch === '\x1b') {
          // CSI/SS3 (arrows, home/end…) — skip the sequence, track nothing
          i++
          if (d[i] === '[' || d[i] === 'O') {
            while (i + 1 < d.length && !/[a-zA-Z~]/.test(d[i + 1])) i++
            i++
          }
          continue
        }
        if (ch === '\r' || ch === '\n') {
          if (draftBufRef.current.endsWith('\\')) {
            draftBufRef.current = draftBufRef.current.slice(0, -1) + '\n' // Shift+⏎ continuation
          } else {
            // submitted — ALSO pin a prompt-timeline mark. The tracker knows
            // the moment and the text without needing the hooks tap, so the
            // rail works even when hook events never arrive (unarmed hooks,
            // non-claude agents). Hook marks win when both fire (see flag).
            const submitted = draftBufRef.current.trim()
            if (submitted.length >= 3) {
              pinTypedPromptMark(submitted)
              beginAgentTurn()
            }
            draftBufRef.current = ''
          }
          continue
        }
        if (ch === '\x7f') {
          draftBufRef.current = draftBufRef.current.slice(0, -1)
          continue
        }
        if (ch >= ' ') draftBufRef.current += ch
      }
      flushDraft()
    }
    trackDraftRef.current = trackDraft
    // typed-prompt fallback marks: skipped once hook marks prove live (the
    // hook path has better fidelity — server-confirmed prompts)
    const pinTypedPromptMark = (text: string) => {
      if (hookMarksLiveRef.current || !isAgentTerm()) return
      const term = termRef.current
      const marker = term?.registerMarker(0)
      if (!marker) return
      promptMarksRef.current.push({ marker, text: text.slice(0, 200), at: Date.now(), src: 'typed' })
      if (promptMarksRef.current.length > 40) promptMarksRef.current.shift()
      marker.onDispose(() => {
        promptMarksRef.current = promptMarksRef.current.filter((p) => p.marker !== marker)
      })
      setPromptTick((n) => n + 1)
    }
    // after a --resume/--continue boot, retype the saved draft once the TUI
    // settles (quiet pty ≥2s). Abort if the user starts typing first, and
    // give up after 30s — the draft stays persisted for the next launch.
    armDraftRetypeRef.current = (bootStr: string) => {
      if (!useKaisola.getState().draftRestore) return // Settings → Interface switch
      if (!/--resume|--continue|\bcodex\s+resume\b/.test(bootStr)) return
      const saved = useKaisola.getState().termDrafts[id]
      if (!saved || saved.trim().length < 3 || !isAgentTerm()) return
      const born = Date.now()
      const tryType = () => {
        if (disposed) return
        if (draftBufRef.current) return // the user is already typing — leave them be
        if (Date.now() - born > 30_000) return
        if (Date.now() - born > 3000 && Date.now() - (lastOutputAtRef.current ?? born) > 2000) {
          void bridge.terminal.write(id, saved.replaceAll('\n', '\\\r'), projectId).catch(() => {})
          draftBufRef.current = saved // the composer now holds it — track edits from here
          return
        }
        if (draftRetypeTimerRef.current) clearTimeout(draftRetypeTimerRef.current)
        draftRetypeTimerRef.current = setTimeout(() => {
          draftRetypeTimerRef.current = null
          tryType()
        }, 500)
      }
      if (draftRetypeTimerRef.current) clearTimeout(draftRetypeTimerRef.current)
      draftRetypeTimerRef.current = setTimeout(() => {
        draftRetypeTimerRef.current = null
        tryType()
      }, 3200)
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
        lastOutputAtRef.current = Date.now() // draft retype waits for pty quiescence
        if (agentTurnOpenRef.current) {
          useKaisola.getState().setTerminalMeta(id, { agentBusy: true })
          armAgentDone()
          captureCodexSession()
        }
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
      unsubExit = bridge.terminal.onExit(id, finishAgentTurn)
      term.onData((data) => {
        void bridge.terminal.write(id, data, projectId).catch(() => {})
        if (!attach) trackInput(data)
        trackDraftRef.current(data)
      })
      void bridge.terminal.resize(id, term.cols, term.rows, projectId).catch(() => {})
    }

    const restoreSnapshot = (snap: Partial<TermSnapshot>) => {
      if (typeof snap.agentBusy === 'boolean' || snap.agentCompletedAt != null) {
        useKaisola.getState().setTerminalMeta(id, {
          ...(typeof snap.agentBusy === 'boolean' ? { agentBusy: snap.agentBusy } : {}),
          ...(snap.agentCompletedAt != null ? { agentCompletedAt: snap.agentCompletedAt } : {}),
        })
      }
      const restoreView = () => {
        const fromBottom = Number(snap.viewState?.scrollFromBottom)
        if (Number.isFinite(fromBottom)) {
          try {
            if (fromBottom <= 1) term.scrollToBottom()
            else term.scrollToLine(Math.max(0, term.buffer.active.baseY - fromBottom))
          } catch { /* stale geometry */ }
        }
      }
      if (snap.output) term.write(snap.output, restoreView)
      else restoreView()
    }

    if (attach) {
      void bridge.terminal.attach(id, projectId).then((snap) => {
        if (disposed) return
        const receipt = continuedStatus(snap)
        if (receipt) setAttachedContinuation(receipt)
        restoreSnapshot(snap)
        wire()
      }).catch(() => {
        if (!disposed) term.writeln('\x1b[38;2;225;106;106mSession unavailable in this project.\x1b[0m')
      })
    } else {
      void bridge.terminal.create(id, cwd, term.cols, term.rows, projectId).then((res) => {
        if (disposed) return
        if (!res.ok) {
          term.writeln('\x1b[38;2;225;106;106mTerminal unavailable.\x1b[0m')
          return
        }
        ptyExistedRef.current = !!res.existed
        const receipt = continuedStatus(res)
        const state = useKaisola.getState()
        if (receipt) state.setTerminalContinuation(id, receipt)
        // A brand-new PTY proves any unviewed receipt restored from a crashed
        // app is stale; an ordinary same-instance hibernation (`existed`) must
        // leave a still-pending receipt alone.
        else if (!res.existed) state.setTerminalContinuation(id, undefined)
        restoreSnapshot(res)
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
            setFreshBootRequest({ fallbackBoot: boot, requestedAt: Date.now() })
          }
        }
        setPtyReady(true)
      }).catch(() => {
        if (!disposed) term.writeln('\x1b[38;2;225;106;106mTerminal unavailable in this project.\x1b[0m')
      })
    }

    const doFit = () => {
      try {
        preserveTerminalViewport(term, () => {
          fit.fit()
          void bridge.terminal.resize(id, term.cols, term.rows, projectId).catch(() => {})
        })
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
      // Persist the viewport before xterm releases its scrollback. This only
      // detaches the renderer; a running shell/agent is never killed.
      const viewState = {
        scrollFromBottom: Math.max(0, term.buffer.active.baseY - term.buffer.active.viewportY),
        cols: term.cols,
        rows: term.rows,
      }
      void bridge.terminal.detachRenderer(id, viewState, projectId).catch(() => {})
      if (titleTimer) clearTimeout(titleTimer)
      if (agentDoneTimerRef.current) clearTimeout(agentDoneTimerRef.current)
      if (codexProbeTimerRef.current) clearTimeout(codexProbeTimerRef.current)
      if (focusTimerRef.current) clearTimeout(focusTimerRef.current)
      if (draftRetypeTimerRef.current) clearTimeout(draftRetypeTimerRef.current)
      focusTimerRef.current = null
      draftRetypeTimerRef.current = null
      setFreshBootRequest(null)
      trackDraftRef.current = () => {}
      armDraftRetypeRef.current = () => {}
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
      host.replaceChildren()
      termRef.current = null
      fitRef.current = null
      searchRef.current = null
      bootSentRef.current = false
      setPtyReady(false)
    }
    // cwd is intentionally NOT a dep: it only matters at spawn time, and a
    // record cwd change must never tear down a live session mid-run
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, attach, rendererAwake, projectId])

  // A fresh PTY needs one short shell-startup delay before its boot line is
  // written. Keep that delay in its own lifecycle so an unmount/rebuild always
  // cancels the pending write instead of leaving the mount effect to own an
  // asynchronous timer created from inside the broker response callback.
  useEffect(() => {
    if (!freshBootRequest) return
    const timer = window.setTimeout(() => {
      setFreshBootRequest(null)
      const st = useKaisola.getState()
      st.clearBootPending(id) // an update that landed during the wait is delivered right here
      const rec = st.terminals.find((t) => t.id === id)
      const line = rec?.boot ?? freshBootRequest.fallbackBoot
      if (!line) return
      // dedupe against the CLEAN boot — the typed line may carry the wipe
      lastBootRef.current = { boot: line, at: Date.now() }
      void bridge.terminal.write(id, bootLine(line, rec?.singletonKey) + '\n', projectId).catch(() => {})
      armDraftRetypeRef.current(line)
    }, 700)
    return () => window.clearTimeout(timer)
  }, [freshBootRequest, id, projectId])

  // deliver a boot adopted after the pty went live (see bootPending). The shell
  // was spawned before the terminal had a cwd, so cd to it as a user would.
  // A cwd WITHOUT a boot is the workspace adoption: the default shell just
  // cd's into the freshly opened project folder.
  useEffect(() => {
    if (!ptyReady || !bootPending) return
    const st = useKaisola.getState()
    const t = st.terminals.find((x) => x.id === id)
    const processName = foregroundProcess?.split('/').pop()?.replace(/^-/, '') ?? ''
    const idleShell = /^(zsh|bash|fish|sh)$/.test(processName)
    // On update/restart, the broker can hand the new renderer the SAME live
    // Claude/Codex pty. Metadata arrives just after create(), so wait for it;
    // if an agent (or one of its child tools) still owns the foreground, the
    // pending resume is only persisted launch metadata — never type it into
    // the agent's message composer. A surviving idle shell may safely boot.
    if (ptyExistedRef.current) {
      if (!foregroundProcess) return
      if (!idleShell) {
        if (t?.singletonKey?.match(/^(agent|wt):/)) st.clearBootPending(id)
        return
      }
    }
    st.clearBootPending(id)
    // bootPending is an explicit "write it now" (set only for already-live
    // ptys — new terminals boot via the create path), so a rerun of the SAME
    // command (LaTeX rebuild) must not be swallowed by the sent-once guard
    const line = t?.boot
      ? t.cwd ? `cd ${shellQuote(t.cwd)} && ${bootLine(t.boot, t.singletonKey)}` : bootLine(t.boot, t.singletonKey)
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
    const bootTimer = window.setTimeout(() => {
      void bridge.terminal.write(id, line + '\n', projectId).catch(() => {})
      armDraftRetypeRef.current(line)
    }, 700)
    return () => window.clearTimeout(bootTimer)
  }, [ptyReady, bootPending, id, foregroundProcess, projectId])

  const findNext = (back = false) => {
    if (!findQuery) return
    if (back) searchRef.current?.findPrevious(findQuery, { decorations: FIND_DECORATIONS })
    else searchRef.current?.findNext(findQuery, { decorations: FIND_DECORATIONS })
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
  const livePalette = xtermTheme(theme, ecoMode, termCursorColor, termBackground)
  return (
    <div
      className="term-wrap"
      data-rail={promptMarks.length > 1 || undefined}
      data-file-drop={fileDropHover || undefined}
      data-terminal-theme={theme}
      data-ansi-black={livePalette.black}
      data-terminal-id={id}
      data-renderer-awake={rendererAwake}
      onDragOver={(e) => {
        if (!e.dataTransfer?.types.includes('Files')) return
        e.preventDefault()
        e.stopPropagation()
        if (!fileDropHover) setFileDropHover(true)
      }}
      onDragLeave={(e) => {
        if (fileDropHover && !e.currentTarget.contains(e.relatedTarget as Node)) setFileDropHover(false)
      }}
      onDrop={(e) => {
        setFileDropHover(false)
        const files = Array.from(e.dataTransfer?.files ?? [])
        if (!files.length) return
        e.preventDefault()
        e.stopPropagation() // the window-level handler would open it as a file tab
        const paths = files.flatMap((file) => {
          const path = bridge.pathForFile?.(file)
          return path ? [path] : []
        })
        if (!paths.length) return
        const text = paths.map(shellQuote).join(' ') + ' '
        const term = termRef.current
        term?.focus()
        // xterm.paste emits bracketed paste when the CLI enabled it. Direct IPC
        // writes bypassed that protocol, so Codex/Claude TUIs ignored drops.
        if (term) term.paste(text)
        else void bridge.terminal.write(id, text, projectId).catch(() => {})
      }}
    >
      {/* prompt timeline for the Claude session — a tick per instigated turn */}
      {promptMarks.length > 1 && (
        <div className="turn-rail" onMouseLeave={() => setRailHover(null)}>
          {promptMarks.map((p, n) => (
            <button
              type="button"
              key={`${p.at}:${p.text}`}
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
          <button type="button" onClick={() => findNext(true)} title="Previous  ⇧⏎" aria-label="Previous match"><Icon name="ChevronUp" size={12} /></button>
          <button type="button" onClick={() => findNext(false)} title="Next  ⏎" aria-label="Next match"><Icon name="ChevronDown" size={12} /></button>
          <button type="button" onClick={closeFind} title="Close  esc" aria-label="Close search"><Icon name="X" size={12} /></button>
        </div>
      )}
      {continuation && visible && (
        <button
          type="button"
          className="term-continuity"
          aria-live="polite"
          onClick={() => {
            if (persistedContinuation) setTerminalContinuation(id, undefined)
            setAttachedContinuation(null)
          }}
          title={continuation.terminalPid ? `Terminal process ${continuation.terminalPid} stayed alive across the update` : 'The same terminal process stayed alive across the update'}
        >
          <span className="term-continuity-dot" aria-hidden />
          <span>Continued</span>
          <span className="faint">same process</span>
        </button>
      )}
      <div ref={hostRef} className="term-host" />
    </div>
  )
}
