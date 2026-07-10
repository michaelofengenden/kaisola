import { useKaisola, type ThemeMode, type CustomAgent, type SessionTemplate } from '../store/store'
import { bridge, isDesktop } from './bridge'
import type { AutonomyLevel } from '../domain/types'

/**
 * Zed-style user config: two plain JSON files in userData — settings.json
 * (overrides applied at launch and on every save) and keymap.json
 * ([{bindings}] — chord → action id, null disables). The GUI Settings stays;
 * the files are the automatable power-user surface, and they always win at
 * load time. Comments (`//`) and trailing commas are tolerated.
 */

export const SETTINGS_TEMPLATE = `// Kaisola settings — applied on launch and whenever you save this file.
// Every key is optional; delete a line to fall back to the in-app setting.
{
  // "theme": "system",                      // "system" | "light" | "dark"
  // "termFontFamily": "JetBrains Mono",
  // "termFontSize": 13,
  // "termFontWeight": 500,                  // 400 | 500 | 700
  // "termCursorColor": "auto",              // "auto" (match text) | "#rrggbb"
  // "perfMode": "eco",                      // "glass" (native) | "eco" (opaque, lowest memory)
  // "wordDiffs": true,                      // word-level highlights in research diffs
  // "showCosts": true,                      // $-cost chips on Claude session cards
  // "inbox": true,                          // cross-project needs-you inbox in the tab strip
  // "draftRestore": true,                   // retype saved CLI drafts after restart
  // "wallpaperTint": true,                  // wallpaper-sampled chrome tinting
  // "autonomy": "propose",                  // observe | propose | execute | sprint
  // "enabledAgents": ["claude-code", "codex", "opencode"],
  // "customAgents": [{ "id": "custom-my", "name": "My agent", "kind": "terminal", "command": "my-cli", "args": [] }],
  // "sensitiveGlobs": ["**/.env*", "**/*.pem"],
  // "sessionTemplates": [{ "id": "tpl-paper", "name": "Paper", "kind": "terminal", "command": "claude", "cwd": "~/papers/x" }]
}
`

export const KEYMAP_TEMPLATE = `// Kaisola keymap — chord → action (null disables a default chord).
// Chords: cmd- ctrl- alt- shift- + a key, e.g. "cmd-shift-t".
// Actions: dock.toggle canvas.toggle layout.toggle settings.open window.new
//   omni.toggle session.next session.prev session.reopen session.1 … session.9
//   terminal.new git.panel browser.new latex.toggle rail.toggle
// (⌘K / ⌘P for the palettes are fixed.)
[
  { "bindings": {
    // "cmd-shift-t": "session.reopen",
    // "cmd-l": null
  } }
]
`

/**
 * Tolerant JSON: strips // comments and trailing commas OUTSIDE strings
 * (Zed's JSONC habit). A character walk, not regexes — a glob like
 * "**\/x,}" or a command containing :// must come through untouched.
 */
export function parseLoose(text: string): unknown {
  let out = ''
  let inStr = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (inStr) {
      out += c
      if (c === '\\') { out += text[i + 1] ?? ''; i++ }
      else if (c === '"') inStr = false
      continue
    }
    if (c === '"') { inStr = true; out += c; continue }
    if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i++
      out += '\n'
      continue
    }
    if (c === '/' && text[i + 1] === '*') {
      i += 2
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++
      i += 1 // land on the '/' of '*/'; the loop's i++ steps past it
      out += ' '
      continue
    }
    if (c === ',') {
      // trailing comma: only whitespace/comments between here and }/]
      let j = i + 1
      while (j < text.length) {
        if (/\s/.test(text[j])) { j++; continue }
        if (text[j] === '/' && text[j + 1] === '/') { while (j < text.length && text[j] !== '\n') j++; continue }
        if (text[j] === '/' && text[j + 1] === '*') { j += 2; while (j < text.length && !(text[j] === '*' && text[j + 1] === '/')) j++; j += 2; continue }
        break
      }
      if (text[j] === '}' || text[j] === ']') continue // drop the comma
    }
    out += c
  }
  // an all-comments (or empty) file legitimately resolves to nothing — don't let
  // JSON.parse('') throw a false "syntax error" at a user who commented it all out
  return out.trim() ? JSON.parse(out) : {}
}

function applySettings(raw: unknown) {
  if (!raw || typeof raw !== 'object') return
  const cfg = raw as Record<string, unknown>
  const s = useKaisola.getState()
  if (cfg.theme === 'light' || cfg.theme === 'dark' || cfg.theme === 'system') s.setThemeMode(cfg.theme as ThemeMode)
  if (typeof cfg.termFontFamily === 'string') s.setTermFontFamily(cfg.termFontFamily)
  if (typeof cfg.termFontSize === 'number') s.setTermFontSize(cfg.termFontSize)
  if (typeof cfg.termFontWeight === 'number') s.setTermFontWeight(cfg.termFontWeight)
  if (typeof cfg.termCursorColor === 'string') s.setTermCursorColor(cfg.termCursorColor)
  if (cfg.perfMode === 'glass' || cfg.perfMode === 'eco') s.setPerfMode(cfg.perfMode)
  if (typeof cfg.wordDiffs === 'boolean') s.setWordDiffs(cfg.wordDiffs)
  if (typeof cfg.showCosts === 'boolean') s.setShowCosts(cfg.showCosts)
  if (typeof cfg.inbox === 'boolean') s.setInbox(cfg.inbox)
  if (typeof cfg.draftRestore === 'boolean') s.setDraftRestore(cfg.draftRestore)
  if (typeof cfg.wallpaperTint === 'boolean') s.setWallpaperTint(cfg.wallpaperTint)
  if (typeof cfg.autonomy === 'string' && ['observe', 'propose', 'execute', 'sprint'].includes(cfg.autonomy)) {
    s.setAutonomy(cfg.autonomy as AutonomyLevel)
  }
  if (Array.isArray(cfg.enabledAgents) && cfg.enabledAgents.every((x) => typeof x === 'string')) {
    useKaisola.setState({ enabledAgents: cfg.enabledAgents as string[] })
  }
  if (Array.isArray(cfg.customAgents)) {
    // a custom id that shadows a BUILT-IN preset would hijack its connects
    // and its singleton terminal — refuse those ids
    const BUILTIN_IDS = new Set(['claude-code', 'codex', 'opencode', 'gemini', 'qwen', 'kimi', 'amp', 'aider', 'goose', 'crush', 'mock'])
    for (const a of cfg.customAgents as CustomAgent[]) {
      if (a && typeof a.id === 'string' && typeof a.name === 'string' && typeof a.command === 'string' && !BUILTIN_IDS.has(a.id)) {
        s.addCustomAgent({ id: a.id, name: a.name, kind: a.kind === 'acp' ? 'acp' : 'terminal', command: a.command, args: Array.isArray(a.args) ? a.args : [] })
      }
    }
  }
  if (Array.isArray(cfg.sensitiveGlobs) && cfg.sensitiveGlobs.every((x) => typeof x === 'string')) {
    s.setSensitiveGlobs(cfg.sensitiveGlobs as string[])
  }
  if (Array.isArray(cfg.sessionTemplates)) {
    const existing = useKaisola.getState().sessionTemplates.filter((t) => !String(t.id).startsWith('cfg-'))
    const fromFile = (cfg.sessionTemplates as SessionTemplate[])
      .filter((t) => t && typeof t.name === 'string')
      .map((t, i) => ({ ...t, id: `cfg-${t.id ?? i}` }))
    useKaisola.setState({ sessionTemplates: [...existing, ...fromFile] })
  }
}

// the keymap's public contract — chords may bind to these action ids (or null
// to disable a default). Mirrors KEY_ACTIONS in App.tsx + session.1..9.
const KEYMAP_ACTIONS = new Set([
  'dock.toggle', 'canvas.toggle', 'layout.toggle', 'settings.open', 'window.new',
  'omni.toggle', 'session.next', 'session.prev', 'session.reopen',
  'terminal.new', 'git.panel', 'browser.new', 'latex.toggle', 'rail.toggle',
  ...Array.from({ length: 9 }, (_, i) => `session.${i + 1}`),
])
// the palettes own these — a rebind here would DOUBLE-FIRE against their own
// fixed listener, so they're reserved
const RESERVED_CHORDS = new Set(['cmd-k', 'ctrl-k', 'cmd-p', 'ctrl-p', 'cmd-shift-p', 'ctrl-shift-p'])

function applyKeymap(raw: unknown, quiet?: boolean) {
  if (!Array.isArray(raw)) return
  const overrides: Record<string, string | null> = {}
  const bad: string[] = []
  for (const entry of raw) {
    const bindings = (entry as { bindings?: Record<string, unknown> })?.bindings
    if (!bindings || typeof bindings !== 'object') continue
    for (const [rawChord, action] of Object.entries(bindings)) {
      if (typeof rawChord !== 'string') continue
      const chord = rawChord.toLowerCase()
      if (RESERVED_CHORDS.has(chord)) { bad.push(`${rawChord} is reserved for the palette`); continue }
      if (action === null) overrides[chord] = null
      else if (typeof action === 'string' && KEYMAP_ACTIONS.has(action)) overrides[chord] = action
      else if (typeof action === 'string') bad.push(`unknown action "${action}"`)
    }
  }
  useKaisola.getState().setKeymapOverrides(overrides)
  if (bad.length && !quiet) {
    useKaisola.getState().pushToast('warn', `keymap.json: ${bad.slice(0, 3).join('; ')}${bad.length > 3 ? '…' : ''}`)
  }
}

export async function configPaths() {
  return bridge.settings.paths?.() ?? null
}

// remember what we last applied so the poll only re-applies on real changes
let lastSettings = ''
let lastKeymap = ''

/** Read + apply both files. Missing files are fine; broken JSON toasts once. */
export async function loadUserConfig(opts?: { quiet?: boolean }) {
  if (!isDesktop) return
  const paths = await configPaths()
  if (!paths) return
  const [st, km] = await Promise.all([bridge.fs.read(paths.settings), bridge.fs.read(paths.keymap)])
  const settingsText = st.ok && typeof st.content === 'string' ? st.content : ''
  const keymapText = km.ok && typeof km.content === 'string' ? km.content : ''
  lastSettings = settingsText
  lastKeymap = keymapText
  if (settingsText.trim()) {
    try { applySettings(parseLoose(settingsText)) }
    catch { if (!opts?.quiet) useKaisola.getState().pushToast('error', 'settings.json has a syntax error — fix it and save again.') }
  }
  if (keymapText.trim()) {
    try { applyKeymap(parseLoose(keymapText), opts?.quiet) }
    catch { if (!opts?.quiet) useKaisola.getState().pushToast('error', 'keymap.json has a syntax error — fix it and save again.') }
  } else {
    useKaisola.getState().setKeymapOverrides({}) // emptied file → back to defaults
  }
}

/**
 * Re-apply the config files when they change. A light 2.5s content-diff POLL
 * of the two files — NOT an fs.watch on userData (which churns on every
 * pasola.db / checkpoint / claude-events write). Handles in-app AND external
 * edits, and clears cleanly (no StrictMode watcher leak). The poll pauses
 * while the window is hidden (nobody applies settings they can't see) and
 * catches up the moment it's visible again.
 */
export function watchUserConfig(): () => void {
  if (!isDesktop) return () => {}
  let disposed = false
  const tick = async () => {
    if (disposed || document.hidden) return
    const paths = await configPaths()
    if (!paths || disposed) return
    const [st, km] = await Promise.all([bridge.fs.read(paths.settings), bridge.fs.read(paths.keymap)])
    const s = st.ok && typeof st.content === 'string' ? st.content : ''
    const k = km.ok && typeof km.content === 'string' ? km.content : ''
    if (s !== lastSettings || k !== lastKeymap) void loadUserConfig()
  }
  const onVisible = () => { if (!document.hidden) void tick() }
  document.addEventListener('visibilitychange', onVisible)
  const iv = window.setInterval(() => void tick(), 2500)
  return () => {
    disposed = true
    window.clearInterval(iv)
    document.removeEventListener('visibilitychange', onVisible)
  }
}

/** Open one of the config files in the editor, creating it from the template. */
export async function openConfigFile(which: 'settings' | 'keymap') {
  const paths = await configPaths()
  if (!paths) return
  const target = which === 'settings' ? paths.settings : paths.keymap
  const existing = await bridge.fs.read(target)
  if (!existing.ok || !String(existing.content ?? '').trim()) {
    await bridge.fs.write(target, which === 'settings' ? SETTINGS_TEMPLATE : KEYMAP_TEMPLATE)
  }
  useKaisola.getState().requestFile(target, 'edit', { pinned: true })
}
