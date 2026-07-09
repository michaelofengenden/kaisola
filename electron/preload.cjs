// Kaisola preload — the ONLY surface the renderer can use to reach privileged
// capabilities. contextIsolation is on, so the renderer sees exactly this object
// as `window.kaisola` and nothing else from Node/Electron.
const { contextBridge, ipcRenderer, webUtils } = require('electron')

let seq = 0

const bridge = {
  env: 'electron',
  smoke: !!(process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE),

  // ── live model (direct API; used for lightweight calls) ──
  model: {
    call: (req) => ipcRenderer.invoke('model:call', req),
    stream: (req, onChunk) => {
      const id = `s${++seq}`
      const chan = `model:chunk:${id}`
      // Tear down on the same-channel `done` sentinel — NOT on the invoke reply,
      // which can arrive before trailing chunks (different channel, no ordering).
      const listener = (_e, payload) => {
        if (!payload) return
        if (payload.done) {
          ipcRenderer.removeListener(chan, listener)
          return
        }
        if (payload.text) onChunk(payload.text)
      }
      ipcRenderer.on(chan, listener)
      const p = ipcRenderer.invoke('model:stream', { id, ...req })
      p.finally(() => setTimeout(() => ipcRenderer.removeListener(chan, listener), 3000)) // safety net
      return p
    },
  },

  // ── ACP agents (the Zed way: spawn an agent subprocess, speak the protocol) ──
  // Multiple agents can be connected at once; methods target one by agentKey.
  acp: {
    presets: () => ipcRenderer.invoke('acp:presets'),
    status: () => ipcRenderer.invoke('acp:status'),
    connect: (config) => ipcRenderer.invoke('acp:connect', config),
    disconnect: (agentKey) => ipcRenderer.invoke('acp:disconnect', { agentKey }),
    cancel: (agentKey) => ipcRenderer.invoke('acp:cancel', { agentKey }),
    // live autonomy dial → every connection this window owns (see acpHandler)
    setAutonomy: (autonomy) => ipcRenderer.invoke('acp:set-autonomy', { autonomy }),
    setMode: (agentKey, modeId) => ipcRenderer.invoke('acp:setMode', { agentKey, modeId }),
    setModel: (agentKey, modelId) => ipcRenderer.invoke('acp:setModel', { agentKey, modelId }),
    setConfigOption: (agentKey, configId, value) => ipcRenderer.invoke('acp:setConfigOption', { agentKey, configId, value }),
    authenticate: (agentKey, methodId) => ipcRenderer.invoke('acp:authenticate', { agentKey, methodId }),
    /** Send a prompt to agentKey; onUpdate(update) streams session/update payloads. */
    prompt: (agentKey, text, onUpdate) => {
      const reqId = `p${++seq}`
      const chan = `acp:update:${reqId}`
      const listener = (_e, update) => {
        if (update && update.__done) {
          ipcRenderer.removeListener(chan, listener)
          return
        }
        onUpdate(update)
      }
      ipcRenderer.on(chan, listener)
      const p = ipcRenderer.invoke('acp:prompt', { agentKey, reqId, text })
      p.finally(() => setTimeout(() => ipcRenderer.removeListener(chan, listener), 3000)) // safety net
      return p
    },
    onNotice: (cb) => {
      const listener = (_e, n) => cb(n)
      ipcRenderer.on('acp:notice', listener)
      return () => ipcRenderer.removeListener('acp:notice', listener)
    },
    /** Fires when an agent declares/changes its session controls (modes/configOptions). */
    onControls: (cb) => {
      const listener = (_e, info) => cb(info)
      ipcRenderer.on('acp:controls', listener)
      return () => ipcRenderer.removeListener('acp:controls', listener)
    },
    /** Fires when an agent opens a terminal to run a command (show it live). */
    onTerminal: (cb) => {
      const listener = (_e, info) => cb(info)
      ipcRenderer.on('acp:terminal', listener)
      return () => ipcRenderer.removeListener('acp:terminal', listener)
    },
    /** An agent is blocked on a permission — render the inline card. */
    onPermission: (cb) => {
      const listener = (_e, req) => cb(req)
      ipcRenderer.on('acp:permission', listener)
      return () => ipcRenderer.removeListener('acp:permission', listener)
    },
    /** Main auto-resolved a pending permission (timeout / connection death) — drop the card. */
    onPermissionResolved: (cb) => {
      const listener = (_e, { permId }) => cb(permId)
      ipcRenderer.on('acp:permission-resolved', listener)
      return () => ipcRenderer.removeListener('acp:permission-resolved', listener)
    },
    respondPermission: (permId, answer) =>
      ipcRenderer.invoke('acp:permission:respond', { permId, ...answer }),
    setGuardrails: (globs) => ipcRenderer.send('acp:guardrails', globs),
  },

  // ── Claude Code hook tap (activity feed / follow mode / auto-checkpoints) ──
  claude: {
    // armed at app startup in main; the path is a constant, so the boot line
    // (`claude --settings <path>`) can be built synchronously — no race.
    // try/catch: a missing handler must never kill the whole preload.
    settingsPath: (() => {
      try {
        return ipcRenderer.sendSync('claude:settings-path-sync') || undefined
      } catch {
        return undefined
      }
    })(),
    armHooks: () => ipcRenderer.invoke('claude:arm'),
    rebind: () => ipcRenderer.invoke('claude:rebind'),
    sessionExists: (cwd, sessionId, configDir) => ipcRenderer.invoke('claude:session-exists', { cwd, sessionId, configDir }),
    accountInfo: (configDir) => ipcRenderer.invoke('claude:account-info', { configDir }),
    onEvent: (cb) => {
      const listener = (_e, ev) => cb(ev)
      ipcRenderer.on('claude:event', listener)
      return () => ipcRenderer.removeListener('claude:event', listener)
    },
  },

  // ── subscription limits (the top-bar gauge) ──
  usage: {
    codex: (codexHome) => ipcRenderer.invoke('usage:codex', { codexHome }),
    claude: (configDir) => ipcRenderer.invoke('usage:claude', { configDir }),
    claudeSession: (configDir, sessionId) => ipcRenderer.invoke('usage:claudeSession', { configDir, sessionId }),
  },

  // ── shared agent-task ledger (agent↔agent coordination, human-visible) ──
  ledger: {
    list: (args) => ipcRenderer.invoke('ledger:list', args),
    post: (args) => ipcRenderer.invoke('ledger:post', args),
    update: (args) => ipcRenderer.invoke('ledger:update', args),
    onEvent: (cb) => {
      const listener = (_e, ev) => cb(ev)
      ipcRenderer.on('ledger:event', listener)
      return () => ipcRenderer.removeListener('ledger:event', listener)
    },
  },

  // ── the Kaisola MCP server (one tool surface for every connected agent) ──
  // async on purpose: a sendSync here would FREEZE the renderer forever if the
  // handler isn't registered (sendSync never returns without a listener)
  mcp: {
    info: () => ipcRenderer.invoke('mcp:info'),
    // an agent used a HUMAN-GATED write tool — the payload becomes a pending
    // Proposal in the renderer's review gate
    onProposal: (cb) => {
      const listener = (_e, ev) => cb(ev)
      ipcRenderer.on('mcp:proposal', listener)
      return () => ipcRenderer.removeListener('mcp:proposal', listener)
    },
  },

  // ── git checkpoints + status (tree tinting, diff review) + commit panel ──
  git: {
    status: (cwd) => ipcRenderer.invoke('git:status', { cwd }),
    snapshot: (cwd, label) => ipcRenderer.invoke('git:snapshot', { cwd, label }),
    changes: (cwd, sha) => ipcRenderer.invoke('git:changes', { cwd, sha }),
    show: (cwd, sha, file) => ipcRenderer.invoke('git:show', { cwd, sha, file }),
    restore: (cwd, sha) => ipcRenderer.invoke('git:restore', { cwd, sha }),
    stageStatus: (cwd) => ipcRenderer.invoke('git:stageStatus', { cwd }),
    stage: (cwd, paths) => ipcRenderer.invoke('git:stage', { cwd, paths }),
    unstage: (cwd, paths) => ipcRenderer.invoke('git:unstage', { cwd, paths }),
    commit: (cwd, message) => ipcRenderer.invoke('git:commit', { cwd, message }),
    log: (cwd, n) => ipcRenderer.invoke('git:log', { cwd, n }),
  },

  // ── LaTeX mode: headless builds (parsed errors, no terminal spew) ──
  latex: {
    build: (texPath) => ipcRenderer.invoke('latex:build', { texPath }),
    syncFromPdf: (req) => ipcRenderer.invoke('latex:syncFromPdf', req),
  },

  // ── settings / secrets ──
  settings: {
    setApiKey: (key) => ipcRenderer.invoke('settings:setApiKey', key),
    hasApiKey: () => ipcRenderer.invoke('settings:hasApiKey'),
    clearApiKey: () => ipcRenderer.invoke('settings:clearApiKey'),
    setOpenaiKey: (key) => ipcRenderer.invoke('settings:setOpenaiKey', key),
    hasOpenaiKey: () => ipcRenderer.invoke('settings:hasOpenaiKey'),
    clearOpenaiKey: () => ipcRenderer.invoke('settings:clearOpenaiKey'),
    paths: () => ipcRenderer.invoke('settings:paths'),
  },

  // ── terminal sessions (node-pty) ──
  terminal: {
    create: (id, cwd, cols, rows) => ipcRenderer.invoke('terminal:create', { id, cwd, cols, rows }),
    write: (id, data) => ipcRenderer.invoke('terminal:write', { id, data }),
    resize: (id, cols, rows) => ipcRenderer.invoke('terminal:resize', { id, cols, rows }),
    snapshot: (id) => ipcRenderer.invoke('terminal:snapshot', { id }),
    attach: (id) => ipcRenderer.invoke('terminal:attach', { id }),
    signal: (id, signal) => ipcRenderer.invoke('terminal:signal', { id, signal }),
    kill: (id) => ipcRenderer.invoke('terminal:kill', { id }),
    run: (command, cwd) => ipcRenderer.invoke('terminal:run', { command, cwd }),
    onData: (id, cb) => {
      const chan = `terminal:data:${id}`
      const listener = (_e, data) => cb(data)
      ipcRenderer.on(chan, listener)
      return () => ipcRenderer.removeListener(chan, listener)
    },
    onExit: (id, cb) => {
      const chan = `terminal:exit:${id}`
      const listener = (_e, code) => cb(code)
      ipcRenderer.on(chan, listener)
      return () => ipcRenderer.removeListener(chan, listener)
    },
    /** Live identity for ANY session (fg process, cwd, repo, branch) — diffs only. */
    onMeta: (cb) => {
      const listener = (_e, meta) => cb(meta)
      ipcRenderer.on('terminal:meta', listener)
      return () => ipcRenderer.removeListener('terminal:meta', listener)
    },
  },

  // headless device-code login (e.g. `codex login --device-auth`) → in-app card
  auth: {
    start: (command, args, onEvent) => {
      const id = `auth${++seq}`
      const chan = `auth:event:${id}`
      const listener = (_e, ev) => {
        onEvent(ev)
        if (ev.phase === 'done' || ev.phase === 'failed') ipcRenderer.removeListener(chan, listener)
      }
      ipcRenderer.on(chan, listener)
      ipcRenderer.invoke('auth:start', { id, command, args })
      return id
    },
    cancel: (id) => ipcRenderer.invoke('auth:cancel', { id }),
  },

  fs: {
    list: (dir) => ipcRenderer.invoke('fs:list', { dir }),
    search: (root, query) => ipcRenderer.invoke('fs:search', { root, query }),
    index: (root) => ipcRenderer.invoke('fs:index', { root }),
    read: (path) => ipcRenderer.invoke('fs:read', { path }),
    write: (path, content) => ipcRenderer.invoke('fs:write', { path, content }),
    create: (path, dir) => ipcRenderer.invoke('fs:create', { path, dir }),
    rename: (from, to) => ipcRenderer.invoke('fs:rename', { from, to }),
    trash: (path) => ipcRenderer.invoke('fs:trash', { path }),
    reveal: (path) => ipcRenderer.invoke('fs:reveal', { path }),
    pdfInfo: (path) => ipcRenderer.invoke('fs:pdfInfo', { path }),
    pdfPage: (path, page, scale) => ipcRenderer.invoke('fs:pdfPage', { path, page, scale }),
    watch: (root, cb) => {
      const id = `fs${++seq}`
      const chan = `fs:event:${id}`
      const listener = (_e, ev) => cb(ev)
      ipcRenderer.on(chan, listener)
      ipcRenderer.invoke('fs:watch', { id, root }).then((r) => {
        if (!r || !r.ok) cb({ root, seq: 0, events: [], error: (r && r.message) || 'watch failed' })
      })
      return () => {
        ipcRenderer.removeListener(chan, listener)
        ipcRenderer.invoke('fs:unwatch', { id })
      }
    },
  },
  grobid: {
    process: (req) => ipcRenderer.invoke('grobid:process', req),
  },
  worktree: {
    create: (req) => ipcRenderer.invoke('worktree:create', req),
    finalize: (req) => ipcRenderer.invoke('worktree:finalize', req),
    diff: (req) => ipcRenderer.invoke('worktree:diff', req),
    merge: (req) => ipcRenderer.invoke('worktree:merge', req),
    remove: (req) => ipcRenderer.invoke('worktree:remove', req),
    list: (req) => ipcRenderer.invoke('worktree:list', req),
  },
  codex: {
    exec: (req) => ipcRenderer.invoke('codex:exec', req),
  },
  db: {
    // sync read so the store can rehydrate without an async flash (like localStorage)
    getSync: (key) => ipcRenderer.sendSync('db:get-sync', key),
    setSync: (key, value) => ipcRenderer.sendSync('db:set-sync', { key, value }),
    set: (key, value) => ipcRenderer.invoke('db:set', { key, value }),
    del: (key) => ipcRenderer.invoke('db:del', { key }),
    kind: () => ipcRenderer.invoke('db:kind'),
  },
  sandbox: {
    available: () => ipcRenderer.invoke('sandbox:available'),
    run: (req, onEvent) => {
      const id = req.id || `sbx_${Math.random().toString(36).slice(2)}`
      const chan = `sandbox:event:${id}`
      let done = false
      const cleanup = () => { if (!done) { done = true; ipcRenderer.removeListener(chan, listener) } }
      // tear down on the 'exit' sentinel (not the invoke reply — cross-channel
      // ordering isn't guaranteed), plus a long safety net.
      const listener = (_e, payload) => { onEvent(payload); if (payload && payload.type === 'exit') setTimeout(cleanup, 50) }
      ipcRenderer.on(chan, listener)
      const safety = setTimeout(cleanup, 20 * 60 * 1000)
      return ipcRenderer.invoke('sandbox:run', { ...req, id }).finally(() => clearTimeout(safety))
    },
  },

  openExternal: (url) => ipcRenderer.invoke('kaisola:openExternal', url),
  pickFolder: () => ipcRenderer.invoke('kaisola:pickFolder'),
  pickFiles: () => ipcRenderer.invoke('kaisola:pickFiles'),
  // Liquid Glass preference (macOS 26+; applies on next launch)
  glass: (patch) => ipcRenderer.invoke('shell:glass', patch),
  // perf-mode window plumbing: persist next-launch solidity, read the mismatch
  windowMode: (patch) => ipcRenderer.invoke('shell:window-mode', patch),
  relaunch: () => ipcRenderer.invoke('shell:relaunch'),
  // wallpaper-sampled glass wash (macOS; failures degrade to theme tint)
  glassWash: {
    sample: () => ipcRenderer.invoke('glass:sample'),
    onRefresh: (cb) => {
      const listener = () => cb()
      ipcRenderer.on('glass:refresh', listener)
      return () => ipcRenderer.removeListener('glass:refresh', listener)
    },
  },
  // ── multi-window: full slots (own persisted state) + terminal pop-outs ──
  windows: {
    newWindow: () => ipcRenderer.invoke('window:new'),
    pop: (termId, title, hue) => ipcRenderer.invoke('window:pop', { termId, title, hue }),
    onPopClosed: (cb) => {
      const listener = (_e, info) => cb(info)
      ipcRenderer.on('pop:closed', listener)
      return () => ipcRenderer.removeListener('pop:closed', listener)
    },
    // Chrome-style tear-off: ship a project to a new window / receive one
    detachProject: (payload) => ipcRenderer.invoke('window:detach-project', payload),
    onAdoptProject: (cb) => {
      const listener = (_e, payload) => cb(payload)
      ipcRenderer.on('tab:adopt', listener)
      return () => ipcRenderer.removeListener('tab:adopt', listener)
    },
    // ── project tabs: native File/Window menu ⇄ the renderer's tab strip ──
    // Listeners mirror the onPopClosed pattern; each returns an unsubscribe.
    onNewTab: (cb) => {
      const listener = () => cb()
      ipcRenderer.on('tab:new', listener)
      return () => ipcRenderer.removeListener('tab:new', listener)
    },
    onCloseTab: (cb) => {
      const listener = () => cb()
      ipcRenderer.on('tab:close-active', listener)
      return () => ipcRenderer.removeListener('tab:close-active', listener)
    },
    onReopenTab: (cb) => {
      const listener = () => cb()
      ipcRenderer.on('tab:reopen', listener)
      return () => ipcRenderer.removeListener('tab:reopen', listener)
    },
    onActivateTab: (cb) => {
      const listener = (_e, id) => cb(id)
      ipcRenderer.on('tab:activate', listener)
      return () => ipcRenderer.removeListener('tab:activate', listener)
    },
    // renderer → main: push the current tab list (drives the Window menu) and
    // sync the native window title to the active project.
    tabsChanged: (list) => ipcRenderer.send('tabs:changed', list),
    setTitle: (title) => ipcRenderer.send('win:set-title', title),
  },
  // in-app software updates (electron-updater ↔ the GitHub releases feed)
  update: {
    state: () => ipcRenderer.invoke('update:state'),
    check: () => ipcRenderer.invoke('update:check'),
    install: () => ipcRenderer.invoke('update:install'),
    onEvent: (cb) => {
      const listener = (_e, payload) => cb(payload)
      ipcRenderer.on('update:event', listener)
      return () => ipcRenderer.removeListener('update:event', listener)
    },
  },
  // keep the native under-window material in the app's theme, not the system's
  setAppTheme: (theme) => ipcRenderer.send('shell:app-theme', theme),
  onThemeChanged: (cb) => {
    const listener = (_e, theme) => cb(theme)
    ipcRenderer.on('shell:theme-changed', listener)
    return () => ipcRenderer.removeListener('shell:theme-changed', listener)
  },
  // the renderer-drawn traffic lights drive the real window
  winCtl: (action) => ipcRenderer.send('win:ctl', action),
  onFileTextZoomGesture: (cb) => {
    const listener = (_e, payload) => cb(payload)
    ipcRenderer.on('files:text-zoom-gesture', listener)
    return () => ipcRenderer.removeListener('files:text-zoom-gesture', listener)
  },
  // files the OS hands to the app (Finder double-click / "Open With" / dock
  // drop) — main queues them until the renderer is listening
  onOpenExternalFile: (cb) => {
    const listener = (_e, payload) => cb(payload)
    ipcRenderer.on('files:open-external', listener)
    return () => ipcRenderer.removeListener('files:open-external', listener)
  },
  // absolute path of a File dragged into the window (File.path is gone in
  // Electron ≥32; webUtils is the sanctioned replacement)
  pathForFile: (file) => {
    try {
      return webUtils.getPathForFile(file)
    } catch {
      return ''
    }
  },
}

contextBridge.exposeInMainWorld('kaisola', bridge)

// ── window chrome ────────────────────────────────────────────────────────────
// The desktop window is transparent and the renderer paints its own rounded
// corners; mark the document so the CSS knows, and square off in full-screen.
const setDocAttr = (k, v) => {
  const run = () => { document.documentElement.dataset[k] = v }
  if (document.readyState === 'loading') window.addEventListener('DOMContentLoaded', run, { once: true })
  else run()
}
setDocAttr('shell', 'desktop')
ipcRenderer.on('win:state', (_e, s) => {
  setDocAttr('fullscreen', s && s.fullscreen ? 'true' : 'false')
  if (s && 'focused' in s) setDocAttr('winfocus', s.focused ? 'true' : 'false')
})
