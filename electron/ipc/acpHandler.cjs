// IPC surface for ACP agents. Supports MULTIPLE simultaneous connections (keyed
// by preset id), each with its own session, declared controls (modes / config
// options that drive the composer dropdowns), and live terminals. Also a
// registry of presets — open-source agents you can add, Zed-style.
const path = require('node:path')
const os = require('node:os')
const { shell } = require('electron')
const { AcpConnection } = require('./acp.cjs')
const { mcpHttpEntry } = require('./mcpServer.cjs')
const mgr = require('./terminalManager.cjs')

const URL_RE = /https?:\/\/[^\s"'<>)]+/

/** Send to a connection's CURRENT renderer, skipping destroyed windows. */
function sendTo(entry, channel, payload) {
  if (entry.sender && !entry.sender.isDestroyed()) entry.sender.send(channel, payload)
}

/** Surface (and, just after a sign-in, auto-open) an OAuth URL the agent printed. */
function surfaceAuthUrl(entry, name, key, url) {
  if (!url || entry.lastAuthUrl === url) return
  entry.lastAuthUrl = url
  sendTo(entry, 'acp:notice', { agent: name, key, kind: 'auth', text: 'Authorize in your browser', url })
  // if a sign-in was just requested, open it for the user (never during smoke tests)
  if (entry.recentAuthAt && Date.now() - entry.recentAuthAt < 180_000 && !(process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE)) {
    shell.openExternal(url).catch(() => {})
  }
}

const MOCK_AGENT = path.join(__dirname, '..', 'acp-mock-agent.cjs')
let acpTermSeq = 0
// autonomy is PER-CONNECTION (entry.autonomy) — this is only the initial default
// a connect uses when the renderer didn't send one.
const DEFAULT_AUTONOMY = 'propose'
// sensitive-file guardrails (Zed's pattern): agents' fs channel refuses these.
// The renderer owns the list (Settings) and pushes updates; defaults mirror it.
let sensitiveGlobs = ['**/.env*', '**/*.pem', '**/*.key', '**/*.cert', '**/*.crt', '**/.dev.vars', '**/secrets.yml']
// MUST mirror src/lib/permissionRules.ts `wildcardMatch` (the canonical spec):
// same flags 'is' (case-insensitive + dotAll) so a newline-containing path the
// renderer flags sensitive is refused here too, not silently allowed.
const globRe = (g) =>
  new RegExp('^' + g.split('*').map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$', 'is')
function isSensitivePath(p) {
  const s = String(p || '')
  return sensitiveGlobs.some(
    (g) => globRe(g).test(s) || (g.startsWith('**/') && (globRe(g.slice(3)).test(s) || globRe('*' + g.slice(2)).test(s))),
  )
}
// inline permission cards: permId → { resolve, timer, entry } for the agent's
// blocked request (entry lets us clean up a dying connection's cards)
let permSeq = 0
const pendingPermissions = new Map()
const PERMISSION_TIMEOUT_MS = 300_000

/** Auto-resolve (as cancel) and clear every inline permission a dying connection
 * left pending, telling its renderer to drop the now-orphaned card + needs-you
 * badge. Idempotent — an already-answered/timed-out permId is simply absent. */
function cancelPendingFor(entry) {
  for (const [permId, p] of pendingPermissions) {
    if (p.entry !== entry) continue
    clearTimeout(p.timer)
    pendingPermissions.delete(permId)
    p.resolve('cancel')
    sendTo(entry, 'acp:permission-resolved', { permId })
  }
}

/**
 * `${webContents.id}|${presetId}` → { conn, meta, sender, controls, current }.
 * Connections are scoped PER WINDOW (multi-window: window 2 connecting codex
 * must never dispose or hijack window 1's live session). The renderer-facing
 * key stays the bare presetId — handlers resolve the internal key from the
 * calling webContents. Orphans (window closed, agent alive) are adopted by
 * the next window that announces itself via acp:status.
 */
const connections = new Map()
const ikey = (sender, presetId) => `${sender.id}|${presetId}`
const entryFor = (sender, presetId) => connections.get(ikey(sender, presetId))

// The built-in agent registry (Zed's agent_servers pattern). Each agent runs
// as the official CLI (installed by the user). Auth is owned by the CLI:
// `login` is run in Kaisola's real terminal so the browser OAuth works;
// `installCmd` installs it; `command/args` connect over ACP using cached
// creds; terminalOnly agents launch their CLI in a real pty instead. The
// renderer decides WHICH of these show in the + menu (Settings → Agents).
function presets() {
  return [
    // Claude speaks ACP (chat threads) since v0.1.20 — the auto-prepared
    // per-project terminal (accounts, hooks tap, --mcp-config, --resume) stays
    // the workspace default until the ACP path reaches feature parity.
    { id: 'claude-code', name: 'Claude',
      command: 'npx', args: ['-y', '@zed-industries/claude-code-acp'],
      login: 'claude /login', installCmd: 'npm i -g @anthropic-ai/claude-code',
      docs: 'https://docs.anthropic.com/en/docs/claude-code/overview', builtin: false },
    { id: 'codex', name: 'Codex', command: 'npx', args: ['-y', '@zed-industries/codex-acp'],
      login: 'codex login', installCmd: 'npm i -g @openai/codex',
      // plain `codex login` — the CLI retired `--device-auth` (codex-cli
      // ≥0.14x rejects it, which surfaced as a bare "invalid params" in the
      // sign-in card). It prints/opens the OAuth URL and exits 0 when the
      // browser flow completes, which is exactly what auth:start streams.
      deviceLogin: { command: 'codex', args: ['login'] },
      docs: 'https://developers.openai.com/codex/cli', builtin: false },
    // OpenCode ships a real ACP server (`opencode acp`) — full chat threads,
    // inline permission cards, the autonomy dial. No wrapper package needed.
    { id: 'opencode', name: 'OpenCode', command: 'opencode', args: ['acp'],
      login: 'opencode auth login', installCmd: 'npm i -g opencode-ai',
      docs: 'https://opencode.ai/docs', builtin: false },
    { id: 'gemini', name: 'Gemini', command: 'gemini', args: ['--experimental-acp'],
      login: 'gemini', installCmd: 'npm i -g @google/gemini-cli',
      docs: 'https://github.com/google-gemini/gemini-cli', builtin: false },
    // Qwen Code is a gemini-cli fork — same ACP flag, Qwen OAuth
    { id: 'qwen', name: 'Qwen Code', command: 'qwen', args: ['--experimental-acp'],
      login: 'qwen', installCmd: 'npm i -g @qwen-code/qwen-code',
      docs: 'https://github.com/QwenLM/qwen-code', builtin: false },
    { id: 'kimi', name: 'Kimi', command: 'kimi', args: ['--acp'],
      login: 'kimi', installCmd: 'uv tool install --python 3.13 kimi-cli',
      docs: 'https://github.com/MoonshotAI/kimi-cli', builtin: false },
    { id: 'amp', name: 'Amp', terminalOnly: true, terminalCommand: 'amp',
      login: 'amp login', installCmd: 'npm i -g @sourcegraph/amp',
      docs: 'https://ampcode.com/manual', builtin: false },
    { id: 'aider', name: 'Aider', terminalOnly: true, terminalCommand: 'aider',
      installCmd: 'uv tool install aider-chat',
      docs: 'https://aider.chat', builtin: false },
    { id: 'goose', name: 'Goose', terminalOnly: true, terminalCommand: 'goose',
      installCmd: 'brew install block-goose-cli',
      docs: 'https://block.github.io/goose', builtin: false },
    { id: 'crush', name: 'Crush', terminalOnly: true, terminalCommand: 'crush',
      installCmd: 'npm i -g @charmland/crush',
      docs: 'https://github.com/charmbracelet/crush', builtin: false },
    // test wiring — reachable programmatically (smoke), never listed in menus
    { id: 'mock', name: 'Mock agent (test wiring)', command: process.execPath, args: [MOCK_AGENT],
      env: { ELECTRON_RUN_AS_NODE: '1' }, builtin: true, hidden: true },
  ]
}

const CONNECT_TIMEOUT_MS = 120_000

function resolveConfig(config) {
  if (config && config.command) return { presetId: config.presetId || config.command, name: config.name || config.command, command: config.command, args: config.args, env: config.env }
  const p = presets().find((x) => x.id === (config && config.presetId)) || presets()[0]
  return { presetId: p.id, name: p.name, command: p.command, args: p.args, env: p.env }
}

function buildTerminalHost(entry, sessionCwd, agentKey, agentName) {
  return {
    async create({ command, args, env, cwd }) {
      const terminalId = `acp-term-${++acpTermSeq}`
      mgr.spawn({ id: terminalId, command, args, env, cwd: cwd || sessionCwd, sender: entry.sender })
      const label = [command, ...(args || [])].join(' ').slice(0, 80)
      sendTo(entry, 'acp:terminal', { terminalId, command, label, cwd: cwd || sessionCwd, agentKey, agentName })
      return { terminalId }
    },
    output(terminalId) {
      const s = mgr.snapshot(terminalId)
      return { output: s.output, truncated: !!s.truncated, exitStatus: s.exitStatus }
    },
    waitForExit(terminalId) { return mgr.waitForExit(terminalId) },
    kill(terminalId) { mgr.kill(terminalId) },
    release(terminalId) { mgr.release(terminalId) },
  }
}

function friendly(resolved, err, stderrTail) {
  const tail = stderrTail && stderrTail.trim() ? ` — ${stderrTail.trim().slice(-240)}` : ''
  if (err.message === 'TIMEOUT') {
    return `Timed out starting ${resolved.name}. First run via npx downloads the binary and can be slow — try again, install it once, or check auth (OPENAI_API_KEY / \`codex login\`).${tail}`
  }
  if (/ENOENT|not found|spawn/i.test(err.message)) {
    return `Could not start "${resolved.command} ${(resolved.args || []).join(' ')}". Is it installed and on your PATH?${tail}`
  }
  return `${err.message}${tail}`
}

/** The calling window's connections. `key` is the scoped wire key (bridge.ts
 * splits it back into bare presetId + project scope for the renderer). */
function agentSummary(sender) {
  return [...connections.values()]
    .filter((e) => e.sender === sender)
    .map((e) => ({
      key: (e.meta && (e.meta.key || e.meta.presetId)), name: e.meta && e.meta.name, presetId: e.meta && e.meta.presetId,
      connected: !!(e.conn && e.conn.alive), controls: e.controls,
      authMethods: (e.conn && e.conn.authMethods) || [],
    }))
}

function registerAcpHandlers(ipcMain) {
  ipcMain.handle('acp:presets', () =>
    presets().map(({ id, name, login, installCmd, deviceLogin, docs, builtin, terminalOnly, terminalCommand, hidden }) =>
      ({ id, name, login, installCmd, deviceLogin, docs, builtin, terminalOnly, terminalCommand, hidden })),
  )

  // status is the renderer announcing itself (Assistant calls it on mount).
  // ONLY orphaned connections (their window's webContents destroyed) are
  // adopted by the caller — so agents survive a window close/reopen on macOS,
  // while a second live window can never hijack the first window's agents.
  ipcMain.handle('acp:status', (event) => {
    for (const [k, entry] of [...connections.entries()]) {
      if (!entry.sender || entry.sender.isDestroyed()) {
        const rendererKey = entry.meta && (entry.meta.key || entry.meta.presetId)
        const nk = ikey(event.sender, rendererKey)
        if (!connections.has(nk)) {
          connections.delete(k)
          entry.sender = event.sender
          connections.set(nk, entry)
        }
      }
    }
    return { ok: true, agents: agentSummary(event.sender) }
  })

  ipcMain.handle('acp:connect', async (event, config = {}) => {
    const resolved = resolveConfig(config)
    // scope = the renderer's project id: the SAME preset in two project tabs is
    // two independent connections/sessions. The composed key is what the
    // renderer echoes back on every later call (bridge.ts scopes/unscopes it).
    const scope = typeof config.scope === 'string' && config.scope ? config.scope : ''
    const key = scope ? `${resolved.presetId}@@${scope}` : resolved.presetId
    const internalKey = ikey(event.sender, key)
    const preset = presets().find((x) => x.id === resolved.presetId)
    if (preset && preset.terminalOnly) {
      return { ok: false, message: `${preset.name} runs as a terminal session. Open it from the + menu or Settings.` }
    }
    // a reconnect replaces THIS window's session only — never another window's
    if (connections.has(internalKey)) {
      connections.get(internalKey).conn.dispose()
      connections.delete(internalKey)
    }
    const sessionCwd = config.cwd || os.homedir()
    let stderrTail = ''
    // entry.sender tracks the CURRENT window (acp:status rebinds it), so these
    // callbacks keep reaching the renderer after a window close/reopen
    const entry = { conn: null, meta: null, sender: event.sender, controls: { modes: null, configOptions: [] }, current: { sender: null, channel: null }, autonomy: config.autonomy || DEFAULT_AUTONOMY }

    // per-connection env on top of the preset's (e.g. CLAUDE_CONFIG_DIR / CODEX_HOME
    // for the project's bound subscription)
    const env = config.env && typeof config.env === 'object'
      ? { ...(resolved.env || {}), ...config.env }
      : resolved.env
    const conn = new AcpConnection(
      // every ACP agent gets the shared Kaisola MCP server (project state +
      // agent-task ledger) when it can dial HTTP — one tool surface, all vendors
      { command: resolved.command, args: resolved.args, env, cwd: sessionCwd, mcpServers: [mcpHttpEntry()].filter(Boolean) },
      {
        onUpdate: (params) => {
          try { const m = JSON.stringify(params).match(URL_RE); if (m) surfaceAuthUrl(entry, resolved.name, key, m[0]) } catch { /* noop */ }
          if (entry.current.channel && entry.current.sender && !entry.current.sender.isDestroyed()) {
            entry.current.sender.send(entry.current.channel, params && params.update ? params.update : params)
          }
        },
        onNotice: (n) => {
          if (n && n.kind === 'stderr' && n.text) stderrTail = (stderrTail + n.text).slice(-600)
          // the agent process died — drop any inline cards it left pending, else
          // their resolvers + needs-you badge leak until the 5-min timeout
          if (n && n.kind === 'exit') cancelPendingFor(entry)
          sendTo(entry, 'acp:notice', { agent: resolved.name, key, ...n })
          const m = n && n.text && n.text.match(URL_RE)
          if (m) surfaceAuthUrl(entry, resolved.name, key, m[0])
        },
        onControls: (controls) => {
          entry.controls = controls
          sendTo(entry, 'acp:controls', { key, controls })
        },
        // The autonomy ladder decides who answers: observe auto-rejects,
        // execute/sprint auto-allow, propose asks the human via an inline
        // card in the thread (Zed-style — non-modal, option-per-button).
        onPermission: async (params) => {
          // per-connection autonomy (NOT a shared global): a window-1 Observe
          // agent stays read-only even after window-2 connects at Sprint, and the
          // live dial (acp:set-autonomy) can lower it mid-turn to stop this agent
          if (entry.autonomy === 'observe') return 'reject'
          if (entry.autonomy === 'execute' || entry.autonomy === 'sprint') return 'allow'
          // no live window to ask → fail CLOSED, never silently allow
          if (!entry.sender || entry.sender.isDestroyed()) return 'cancel'
          const toolCall = (params && params.toolCall) || {}
          const permId = `perm-${++permSeq}`
          // diff-shaped content (OpenCode sends one diff block per file) —
          // the card renders the ACTUAL change, not just a tool name
          const diffs = (Array.isArray(toolCall.content) ? toolCall.content : [])
            .filter((c) => c && c.type === 'diff' && typeof c.path === 'string')
            .slice(0, 8)
            .map((c) => ({
              path: c.path,
              oldText: typeof c.oldText === 'string' ? c.oldText.slice(0, 40_000) : '',
              newText: typeof c.newText === 'string' ? c.newText.slice(0, 40_000) : '',
            }))
          return await new Promise((resolve) => {
            const timer = setTimeout(() => {
              pendingPermissions.delete(permId)
              resolve('cancel') // nobody answered — never silently allow
              // symmetrical to the acp:permission emit below: clear the orphaned
              // inline card + needs-you badge the renderer is still showing
              sendTo(entry, 'acp:permission-resolved', { permId })
            }, PERMISSION_TIMEOUT_MS)
            pendingPermissions.set(permId, { resolve, timer, entry })
            sendTo(entry, 'acp:permission', {
              permId,
              key,
              agent: resolved.name,
              title: toolCall.title || toolCall.kind || 'Agent action',
              kind: toolCall.kind,
              options: (params && params.options) || [],
              diffs,
            })
          })
        },
        terminalHost: buildTerminalHost(entry, sessionCwd, key, resolved.name),
        fsGuard: (p) => !isSensitivePath(p),
      },
    )
    entry.conn = conn

    try {
      conn.start()
      const handshake = (async () => {
        await conn.initialize()
        // restart/relaunch continuity: resume the thread's prior session when
        // the agent supports session/load; a stale/pruned id falls back fresh
        if (config.resumeSessionId && conn.canLoadSession) {
          try {
            await conn.loadSession(String(config.resumeSessionId))
            return { sessionId: String(config.resumeSessionId), resumed: true }
          } catch { /* fall through to session/new */ }
        }
        const session = await conn.newSession()
        return session
      })()
      const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT')), CONNECT_TIMEOUT_MS))
      const session = await Promise.race([handshake, timeout])
      entry.meta = { key, presetId: resolved.presetId, scope, name: resolved.name, sessionId: session.sessionId }
      entry.controls = conn.getControls()
      connections.set(internalKey, entry)
      return { ok: true, key, agent: entry.meta, controls: entry.controls, authMethods: conn.authMethods, resumed: !!session.resumed }
    } catch (err) {
      conn.dispose()
      return { ok: false, message: friendly(resolved, err, stderrTail) }
    }
  })

  ipcMain.handle('acp:prompt', async (event, { agentKey, reqId, text, images } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    if (entry.current.channel) return { ok: false, message: 'Agent is mid-turn — send again when it finishes.' }
    // identity token: acp:cancel may null entry.current to free the composer for a
    // hung agent, so read the __done target from this local turn (not entry.current,
    // which cancel/a newer prompt may have replaced) and clear only if still ours.
    const turn = { sender: event.sender, channel: `acp:update:${reqId}` }
    entry.current = turn
    try {
      const res = await entry.conn.prompt(text, images)
      if (turn.sender && !turn.sender.isDestroyed()) {
        turn.sender.send(turn.channel, { __done: true, stopReason: res && res.stopReason })
      }
      return { ok: true, stopReason: res && res.stopReason }
    } catch (err) {
      if (turn.sender && !turn.sender.isDestroyed()) turn.sender.send(turn.channel, { __done: true })
      return { ok: false, message: err.message }
    } finally {
      if (entry.current === turn) entry.current = { sender: null, channel: null }
    }
  })

  ipcMain.handle('acp:setMode', async (event, { agentKey, modeId } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    try { await entry.conn.setMode(modeId); return { ok: true } } catch (err) { return { ok: false, message: err.message } }
  })

  ipcMain.handle('acp:setConfigOption', async (event, { agentKey, configId, value } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    try { await entry.conn.setConfigOption(configId, value); return { ok: true } } catch (err) { return { ok: false, message: err.message } }
  })

  ipcMain.handle('acp:setModel', async (event, { agentKey, modelId } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    try { await entry.conn.setModel(modelId); return { ok: true } } catch (err) { return { ok: false, message: err.message } }
  })

  // Trigger an agent's auth method. The agent prints/opens its OAuth URL; we
  // auto-open it (surfaceAuthUrl). The `authenticate` call itself can block until
  // the user finishes signing in, so we do NOT await it — we race a short timeout
  // and let the URL surface asynchronously.
  ipcMain.handle('acp:authenticate', async (event, { agentKey, methodId } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry) return { ok: false, message: 'Agent not connected.' }
    // never send a methodId the agent didn't advertise — agents answer an
    // unknown/absent id with a bare JSON-RPC "Invalid params", which is
    // useless to a human. Fall back to the first advertised method.
    const methods = (entry.conn && entry.conn.authMethods) || []
    const mid = methods.some((m) => m && m.id === methodId) ? methodId : methods[0] && methods[0].id
    if (mid == null) return { ok: false, message: 'This agent offers no in-app sign-in — use its CLI login instead.' }
    entry.recentAuthAt = Date.now()
    entry.lastAuthUrl = null
    const call = entry.conn.authenticate(mid).then(() => ({ done: true })).catch((err) => ({ err: err.message }))
    const quick = await Promise.race([call, new Promise((r) => setTimeout(() => r({ pending: true }), 2500))])
    if (quick.err) return { ok: false, message: quick.err }
    if (quick.pending) return { ok: true, pending: true } // browser flow in progress; URL opens via surfaceAuthUrl
    return { ok: true }
  })

  // renderer-owned guardrail globs (Settings → Agents)
  ipcMain.on('acp:guardrails', (_e, globs) => {
    if (Array.isArray(globs)) sensitiveGlobs = globs.filter((g) => typeof g === 'string' && g.trim())
  })

  // live autonomy dial: apply to EVERY connection this window owns (keys start
  // `${sender.id}|`) so lowering to Observe mid-session immediately stops each
  // running agent's next request, without touching another window's agents.
  ipcMain.handle('acp:set-autonomy', (event, { autonomy } = {}) => {
    const prefix = `${event.sender.id}|`
    for (const [k, entry] of connections) {
      if (k.startsWith(prefix)) entry.autonomy = autonomy || DEFAULT_AUTONOMY
    }
    return { ok: true }
  })

  // the inline card's answer — 'allow' | 'reject' | a concrete optionId
  ipcMain.handle('acp:permission:respond', (_e, { permId, optionId, decision } = {}) => {
    const pending = pendingPermissions.get(permId)
    if (!pending) return { ok: false }
    pendingPermissions.delete(permId)
    clearTimeout(pending.timer)
    pending.resolve(optionId ? { optionId } : decision === 'reject' ? 'reject' : 'allow')
    return { ok: true }
  })

  ipcMain.handle('acp:cancel', (event, { agentKey } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    entry?.conn.cancel()
    // a hung agent may ACK session/cancel but neither finish nor exit, so the
    // prompt's promise never settles and its finally never clears the lock —
    // free it here so the composer isn't wedged. The in-flight prompt's finally
    // is identity-guarded (only clears if entry.current is still its own turn),
    // so this can't double-clear or stomp a newer turn.
    if (entry && entry.current.channel) entry.current = { sender: null, channel: null }
    return { ok: true }
  })

  ipcMain.handle('acp:disconnect', (event, { agentKey } = {}) => {
    const internalKey = ikey(event.sender, agentKey)
    const entry = connections.get(internalKey)
    if (entry) {
      cancelPendingFor(entry) // drop any inline cards before the connection goes away
      entry.conn.dispose()
      connections.delete(internalKey)
    }
    return { ok: true }
  })
}

function disposeAcp() {
  for (const e of connections.values()) e.conn.dispose()
  connections.clear()
}

module.exports = { registerAcpHandlers, disposeAcp }
