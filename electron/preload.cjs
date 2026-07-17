// Kaisola preload — the ONLY surface the renderer can use to reach privileged
// capabilities. contextIsolation is on, so the renderer sees exactly this object
// as `window.kaisola` and nothing else from Node/Electron.
const { contextBridge, ipcRenderer, webUtils } = require('electron')

let seq = 0
// Response-only capability context echoed from main. The sanitized display
// payload itself remains main-authoritative; this cache never invents scope or
// revision from renderer state.
const acpPermissionContexts = new Map()

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
    status: (clientKeys, scope) => ipcRenderer.invoke('acp:status', { clientKeys, scope }),
    connect: (config) => ipcRenderer.invoke('acp:connect', config),
    disconnect: (agentKey) => ipcRenderer.invoke('acp:disconnect', { agentKey }),
    cancel: (agentKey) => ipcRenderer.invoke('acp:cancel', { agentKey }),
    closeSession: (agentKey) => ipcRenderer.invoke('acp:close-session', { agentKey }),
    lease: (agentKey, leaseId, active, idleMs) => ipcRenderer.invoke('acp:lease', { agentKey, leaseId, active, idleMs }),
    diagnostics: () => ipcRenderer.invoke('acp:diagnostics'),
    // live autonomy dial → every connection this window owns (see acpHandler)
    setAutonomy: (autonomy) => ipcRenderer.invoke('acp:set-autonomy', { autonomy }),
    setMode: (agentKey, modeId) => ipcRenderer.invoke('acp:setMode', { agentKey, modeId }),
    setModel: (agentKey, modelId) => ipcRenderer.invoke('acp:setModel', { agentKey, modelId }),
    setConfigOption: (agentKey, configId, value) => ipcRenderer.invoke('acp:setConfigOption', { agentKey, configId, value }),
    authenticate: (agentKey, methodId) => ipcRenderer.invoke('acp:authenticate', { agentKey, methodId }),
    /** Send a prompt to agentKey; onUpdate(update) streams session/update payloads. */
    prompt: (agentKey, text, onUpdate, images, _scope, options) => {
      const reqId = `p${++seq}`
      const chan = `acp:update:${reqId}`
      let done = false
      let settled = false
      let resultReady = false
      let result
      let resolvePrompt
      let rejectPrompt
      let safety = null
      const cleanup = () => {
        ipcRenderer.removeListener(chan, listener)
        if (safety) clearTimeout(safety)
      }
      const settle = () => {
        if (settled || !resultReady || (result?.ok && !done)) return
        settled = true
        cleanup()
        resolvePrompt(result)
      }
      const listener = (_e, update) => {
        if (update && update.__done) {
          // IPC invoke completion and streamed events use different channels;
          // Chromium does not guarantee their relative delivery. Resolve only
          // after this boundary so the renderer can synchronously flush every
          // final token into the durable terminal receipt.
          done = true
          settle()
          return
        }
        onUpdate(update)
      }
      ipcRenderer.on(chan, listener)
      const prompt = new Promise((resolve, reject) => { resolvePrompt = resolve; rejectPrompt = reject })
      ipcRenderer.invoke('acp:prompt', { agentKey, reqId, text, images, readOnly: options?.readOnly === true }).then((value) => {
        result = value
        resultReady = true
        settle()
        if (!settled && value?.ok) {
          // Compatibility for a third-party/main-process implementation that
          // omits __done. The normal path settles immediately on the boundary.
          safety = setTimeout(() => {
            if (settled) return
            settled = true
            cleanup()
            resolvePrompt(result)
          }, 3000)
        }
      }, (error) => {
        if (settled) return
        settled = true
        cleanup()
        rejectPrompt(error)
      })
      return prompt
    },
    /** Mid-turn steer: inject a follow-up into the ALREADY-RUNNING turn. No new
     * channel — its output rides the active prompt()'s stream. Rejects (ok:false,
     * unsupported/noTurn) when the agent can't queue or nothing is running. */
    steer: (agentKey, text, images) => ipcRenderer.invoke('acp:steer', { agentKey, text, images }),
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
    onCommands: (cb) => {
      const listener = (_e, info) => cb(info)
      ipcRenderer.on('acp:commands', listener)
      return () => ipcRenderer.removeListener('acp:commands', listener)
    },
    /** Fires when an agent opens a terminal to run a command (show it live). */
    onTerminal: (cb) => {
      const listener = (_e, info) => cb(info)
      ipcRenderer.on('acp:terminal', listener)
      return () => ipcRenderer.removeListener('acp:terminal', listener)
    },
    /** An agent is blocked on a permission — render the inline card. */
    onPermission: (cb) => {
      const listener = (_e, req) => {
        if (req && typeof req.permId === 'string' && typeof req.projectId === 'string' && typeof req.targetId === 'string' && Number.isSafeInteger(req.revision)) {
          acpPermissionContexts.set(req.permId, {
            projectId: req.projectId,
            targetId: req.targetId,
            expectedRevision: req.revision,
          })
        }
        cb(req)
      }
      ipcRenderer.on('acp:permission', listener)
      return () => ipcRenderer.removeListener('acp:permission', listener)
    },
    /** Main auto-resolved a pending permission (timeout / connection death) — drop the card. */
    onPermissionResolved: (cb) => {
      const listener = (_e, { permId }) => {
        acpPermissionContexts.delete(permId)
        cb(permId)
      }
      ipcRenderer.on('acp:permission-resolved', listener)
      return () => ipcRenderer.removeListener('acp:permission-resolved', listener)
    },
    respondPermission: (permId, answer) =>
      ipcRenderer.invoke('acp:permission:respond', { permId, ...acpPermissionContexts.get(permId), ...answer }),
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
    setSettingsFlags: (flags, configDir, cwd) => ipcRenderer.invoke('claude:settings-flags', { flags, configDir, cwd }),
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
    codex: (codexHome, force = false) => ipcRenderer.invoke('usage:codex', { codexHome, force }),
    opencode: (force = false) => ipcRenderer.invoke('usage:opencode', { force }),
    claude: (configDir, force = false, exactOnly = false) => ipcRenderer.invoke('usage:claude', { configDir, force, exactOnly }),
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
    info: (context) => ipcRenderer.invoke('mcp:info', context),
    // an agent used a HUMAN-GATED write tool — the payload becomes a pending
    // Proposal in the renderer's review gate
    onProposal: (cb) => {
      const listener = (_e, ev) => {
        let accepted = false
        try { accepted = cb(ev) === true } catch { /* reject at the mutation boundary */ }
        ipcRenderer.send('mcp:proposal-ack', { proposalId: ev?.proposalId, accepted })
      }
      ipcRenderer.on('mcp:proposal', listener)
      return () => ipcRenderer.removeListener('mcp:proposal', listener)
    },
    // ── external MCP servers (project .mcp.json + the user catalog) ──
    servers: (workspace) => ipcRenderer.invoke('mcp:servers', { workspace }),
    serverSet: (args) => ipcRenderer.invoke('mcp:server-set', args),
    serverProbe: (args) => ipcRenderer.invoke('mcp:server-probe', args),
    userConfig: () => ipcRenderer.invoke('mcp:user-config'),
    discover: () => ipcRenderer.invoke('mcp:discover'),
    importDiscovered: () => ipcRenderer.invoke('mcp:import-discovered'),
    serverAdd: (name, config, extensionId) => ipcRenderer.invoke('mcp:server-add', { name, config, extensionId }),
    serverRemove: (name, extensionId) => ipcRenderer.invoke('mcp:server-remove', { name, extensionId }),
    // kaisola://mcp/install deeplinks: the trust modal renders these; main
    // queues links that arrive before the renderer announces readiness
    onInstallRequest: (cb) => {
      const listener = (_e, req) => cb(req)
      ipcRenderer.on('mcp:install-request', listener)
      ipcRenderer.send('mcp:install-ready')
      return () => ipcRenderer.removeListener('mcp:install-request', listener)
    },
    onServersChanged: (cb) => {
      const listener = () => cb()
      ipcRenderer.on('mcp:servers-changed', listener)
      return () => ipcRenderer.removeListener('mcp:servers-changed', listener)
    },
  },
  // Declarative editor extensions. Main is authoritative for installed/dev
  // records; the renderer keeps only a fast cache of the same safe metadata.
  extensions: {
    state: () => ipcRenderer.invoke('extensions:state'),
    set: (id, record) => ipcRenderer.invoke('extensions:set', { id, record }),
    inspectDev: (sourcePath) => ipcRenderer.invoke('extensions:dev-inspect', { sourcePath }),
    registerDev: (sourcePath) => ipcRenderer.invoke('extensions:dev-register', { sourcePath }),
    removeDev: (id) => ipcRenderer.invoke('extensions:dev-remove', { id }),
    onChanged: (cb) => {
      const listener = (_event, payload) => cb(payload)
      ipcRenderer.on('extensions:changed', listener)
      return () => ipcRenderer.removeListener('extensions:changed', listener)
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
    commitPath: (cwd, file, message) => ipcRenderer.invoke('git:commitPath', { cwd, file, message }),
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
    create: (id, cwd, cols, rows, projectId) => ipcRenderer.invoke('terminal:create', { id, cwd, cols, rows, projectId }),
    write: (id, data, projectId) => ipcRenderer.invoke('terminal:write', { id, data, projectId }),
    agentTurn: (id, busy, projectId) => ipcRenderer.send('terminal:agent-turn', { id, busy, projectId }),
    resize: (id, cols, rows, projectId) => ipcRenderer.invoke('terminal:resize', { id, cols, rows, projectId }),
    snapshot: (id, projectId) => ipcRenderer.invoke('terminal:snapshot', { id, projectId }),
    attach: (id, projectId) => ipcRenderer.invoke('terminal:attach', { id, projectId }),
    detachRenderer: (id, viewState, projectId) => ipcRenderer.invoke('terminal:detachRenderer', { id, viewState, projectId }),
    diagnostics: (projectId) => ipcRenderer.invoke('terminal:diagnostics', { projectId }),
    codexSession: (id, cwd, projectId) => ipcRenderer.invoke('terminal:codexSession', { id, cwd, projectId }),
    signal: (id, signal, projectId) => ipcRenderer.invoke('terminal:signal', { id, signal, projectId }),
    kill: (id, projectId) => ipcRenderer.invoke('terminal:kill', { id, projectId }),
    scheduleRelease: (id, projectId, delayMs) => ipcRenderer.invoke('terminal:schedule-release', { id, projectId, delayMs }),
    cancelRelease: (id, projectId) => ipcRenderer.invoke('terminal:cancel-release', { id, projectId }),
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
    onAgentActivity: (cb) => {
      const listener = (_e, activity) => cb(activity)
      ipcRenderer.on('terminal:agent-activity', listener)
      return () => ipcRenderer.removeListener('terminal:agent-activity', listener)
    },
  },
  assistantArchive: {
    append: (scope, batchId, turns) => ipcRenderer.invoke('assistant-archive:append', { scope, batchId, turns }),
    info: (scope) => ipcRenderer.invoke('assistant-archive:info', { scope }),
    page: (scope, before, limit) => ipcRenderer.invoke('assistant-archive:page', { scope, before, limit }),
    clear: (scope) => ipcRenderer.invoke('assistant-archive:clear', { scope }),
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
  appAuth: {
    status: () => ipcRenderer.invoke('app-auth:status'),
    signInGoogle: () => ipcRenderer.invoke('app-auth:google-start'),
    cancelGoogle: () => ipcRenderer.invoke('app-auth:google-cancel'),
    signOut: () => ipcRenderer.invoke('app-auth:sign-out'),
    onChanged: (cb) => {
      const listener = (_e, status) => cb(status)
      ipcRenderer.on('app-auth:changed', listener)
      return () => ipcRenderer.removeListener('app-auth:changed', listener)
    },
  },

  fs: {
    list: (dir) => ipcRenderer.invoke('fs:list', { dir }),
    search: (root, query) => ipcRenderer.invoke('fs:search', { root, query }),
    index: (root) => ipcRenderer.invoke('fs:index', { root }),
    read: (path) => ipcRenderer.invoke('fs:read', { path }),
    readImage: (path) => ipcRenderer.invoke('fs:readImage', { path }),
    write: (path, content) => ipcRenderer.invoke('fs:write', { path, content }),
    create: (path, dir) => ipcRenderer.invoke('fs:create', { path, dir }),
    importAsset: (source, targetDir, name) => ipcRenderer.invoke('fs:importAsset', { source, targetDir, name }),
    importAssetData: (data, targetDir, name) => ipcRenderer.invoke('fs:importAssetData', { data, targetDir, name }),
    resolvePath: (input, cwd) => ipcRenderer.invoke('fs:resolvePath', { input, cwd }),
    rename: (from, to) => ipcRenderer.invoke('fs:rename', { from, to }),
    trash: (path) => ipcRenderer.invoke('fs:trash', { path }),
    reveal: (path) => ipcRenderer.invoke('fs:reveal', { path }),
    copyPreview: (path) => ipcRenderer.invoke('fs:copyPreview', { path }),
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
    verify: (req) => ipcRenderer.invoke('worktree:verify', req),
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

  browser: {
    releaseGuest: (guestId) => ipcRenderer.invoke('browser:release-guest', { guestId }),
  },
  openExternal: (url) => ipcRenderer.invoke('kaisola:openExternal', url),
  pickFolder: () => ipcRenderer.invoke('kaisola:pickFolder'),
  pickFiles: () => ipcRenderer.invoke('kaisola:pickFiles'),
  // Liquid Glass preference (macOS 26+; applies on next launch)
  glass: (patch) => ipcRenderer.invoke('shell:glass', patch),
  // perf-mode window plumbing: persist next-launch solidity, read the mismatch
  windowMode: (patch) => ipcRenderer.invoke('shell:window-mode', patch),
  relaunch: () => ipcRenderer.invoke('shell:relaunch'),
  // live↔solid swaps only the renderer window; PTYs/agent turns remain in main
  reapplyWindow: () => ipcRenderer.invoke('shell:reapply-window'),
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
    listSaved: () => ipcRenderer.invoke('window:list-saved'),
    reopenSaved: (id) => ipcRenderer.invoke('window:reopen-saved', { id }),
    deleteSaved: (id) => ipcRenderer.invoke('window:delete-saved', { id }),
    onSavedChanged: (cb) => {
      const listener = () => cb()
      ipcRenderer.on('window:saved-changed', listener)
      return () => ipcRenderer.removeListener('window:saved-changed', listener)
    },
    onPrepareDelete: (cb) => {
      const listener = async (_event, request = {}) => {
        let result
        try { result = await cb(request) } catch (error) { result = { ok: false, message: String(error?.message || error) } }
        ipcRenderer.send('window:prepare-delete-ack', { transactionId: request.transactionId, ...result })
      }
      ipcRenderer.on('window:prepare-delete', listener)
      ipcRenderer.send('window:delete-ready')
      return () => ipcRenderer.removeListener('window:prepare-delete', listener)
    },
    pop: (termId, title, hue, projectId) => ipcRenderer.invoke('window:pop', { termId, title, hue, projectId }),
    popped: () => ipcRenderer.invoke('window:popped'),
    ackPopClosed: (termId, projectId, revision) => ipcRenderer.invoke('window:pop-closed-ack', { termId, projectId, revision }),
    onPopClosed: (cb) => {
      const listener = (_e, info) => cb(info)
      ipcRenderer.on('pop:closed', listener)
      return () => ipcRenderer.removeListener('pop:closed', listener)
    },
    mirrorTerminalState: (state) => ipcRenderer.send('window:terminal-state', state),
    onTerminalState: (cb) => {
      const listener = (_e, state) => cb(state)
      ipcRenderer.on('terminal:state-mirror', listener)
      return () => ipcRenderer.removeListener('terminal:state-mirror', listener)
    },
    // Chrome-style window transfer: main may reuse a window under the cursor
    // or create a hidden tear-off; explicit ready/adopted handshakes prevent
    // listener races and keep the source authoritative until receipt.
    detachProject: (payload) => ipcRenderer.invoke('window:detach-project', payload),
    onAdoptProject: (cb) => {
      const listener = (_e, payload) => cb(payload)
      ipcRenderer.on('tab:adopt', listener)
      return () => ipcRenderer.removeListener('tab:adopt', listener)
    },
    adoptionReady: () => ipcRenderer.send('window:adopt-ready'),
    adoptionComplete: (transferId, ok) => ipcRenderer.send('window:adopt-complete', { transferId, ok }),
    finishTransfer: (transferId) => ipcRenderer.invoke('window:finish-transfer', { transferId }),
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
  // App-wide attention: main aggregates every renderer into the macOS dock
  // badge and owns native notifications so they work while Chromium is hidden.
  attention: {
    setCount: (count) => ipcRenderer.send('attention:count', count),
    notify: (payload) => ipcRenderer.send('attention:notify', payload),
    onOpen: (cb) => {
      const listener = (_e, payload) => cb(payload)
      ipcRenderer.on('attention:open', listener)
      return () => ipcRenderer.removeListener('attention:open', listener)
    },
  },
  // Renderer → main carries only the normalized, allowlisted companion view.
  // The pagehide path is synchronous so the last meaningful revision reaches
  // main before Chromium tears down this window.
  companion: {
    publishProjection: (projection, sync = false) => {
      if (sync) return ipcRenderer.sendSync('companion:publish-projection', projection)?.ok === true
      ipcRenderer.send('companion:publish-projection', projection)
      return true
    },
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
