// A minimal Agent Client Protocol (ACP) client — the same protocol Zed uses to
// talk to external agents. We are the CLIENT; the agent is a subprocess we spawn
// (e.g. Gemini CLI, the Claude Code ACP adapter, or any ACP agent). Transport is
// line-delimited JSON-RPC 2.0 over the agent's stdin/stdout.
//
// Flow: initialize → session/new → session/prompt, while the agent streams
// session/update notifications and may call back for permissions / file reads.
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const { StringDecoder } = require('node:string_decoder')
const { agentEnv } = require('./shellEnv.cjs')

const PROTOCOL_VERSION = 1
const MAX_JSON_LINE_BYTES = 16 * 1024 * 1024
const MAX_TEXT_FILE_BYTES = 8 * 1024 * 1024
// Default/maximum retained bytes for an agent-owned terminal. Same value as
// MAX_TEXT_FILE_BYTES today, but a separate constant: the file-read cap and
// the terminal-output cap are independent knobs (and the broker snapshot
// envelope in brokerWire.cjs is sized against this one).
const MAX_TERMINAL_OUTPUT_BYTES = 8 * 1024 * 1024
const REQUEST_TIMEOUT_MS = 120_000
const MAX_TERMINAL_ENV_VARS = 256
const MAX_TERMINAL_ENV_VALUE_BYTES = 1024 * 1024

/** ACP models terminal env as [{name,value}], while older adapters sometimes
 * sent an object. Normalize both into the object node-pty expects, with bounded
 * portable names and values; invalid schema items are skipped as ACP directs. */
const terminalEnvObject = (input) => {
  const rows = Array.isArray(input)
    ? input.map((item) => [item?.name, item?.value])
    : input && typeof input === 'object' ? Object.entries(input) : []
  const env = Object.create(null)
  for (const [rawName, rawValue] of rows.slice(0, MAX_TERMINAL_ENV_VARS)) {
    if (typeof rawName !== 'string' || typeof rawValue !== 'string') continue
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(rawName)) continue
    if (Buffer.byteLength(rawValue, 'utf8') > MAX_TERMINAL_ENV_VALUE_BYTES) continue
    env[rawName] = rawValue
  }
  return env
}

const terminalOutputLimit = (input) => {
  if (input == null) return MAX_TERMINAL_OUTPUT_BYTES
  const n = Number(input)
  if (!Number.isFinite(n)) return MAX_TERMINAL_OUTPUT_BYTES
  return Math.max(0, Math.min(Math.floor(n), MAX_TERMINAL_OUTPUT_BYTES))
}

const isInside = (root, candidate) => {
  const relative = path.relative(root, candidate)
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))
}

class AcpConnection {
  constructor(config, hooks = {}) {
    this.config = config // { command, args, env, cwd, mcpServers, sessionMeta }
    this.hooks = hooks // { onUpdate, onNotice, onPermission }
    this.mcpServers = Array.isArray(config.mcpServers) ? config.mcpServers : null
    this.proc = null
    this.buffer = ''
    this.decoder = new StringDecoder('utf8')
    this.nextId = 1
    this.pending = new Map() // id → {resolve, reject}
    this.sessionId = null
    this.cwd = config.cwd || process.env.HOME
    this.alive = false
    // session controls the agent declares (drives the composer dropdowns)
    this.modes = null // { currentModeId, availableModes: [{id,name,description}] }  (set_mode)
    this.models = null // { currentModelId, availableModels: [{modelId,name,description}] }  (set_model)
    this.configOptions = [] // [{id,name,category,type,currentValue,options:[{value,name,description}]}]  (set_config_option)
    this.authMethods = [] // [{id,name,description}] from initialize — drives the login buttons
    this.supportsPromptQueue = false // set from initialize — enables mid-turn steering
    this.canResumeSession = false
    this.canCloseSession = false
    // Terminal broker ownership is window-scoped, but one window can host many
    // mutually untrusted Mesh adapters. Keep a second, per-connection boundary
    // so one provider cannot guess another provider's acp-term-N identifier and
    // read, kill, wait on, or release its terminal.
    this.ownedTerminalIds = new Set()
  }

  getControls() {
    return { modes: this.modes, models: this.models, configOptions: this.configOptions }
  }

  start() {
    const { command, args = [], env } = this.config
    // Use the login-shell PATH so binaries (gemini/codex/npx) resolve even when
    // Kaisola was launched as a GUI app with a stripped PATH.
    const childEnv = agentEnv(env)
    // Claude Code's ACP adapter refuses to launch if it sees a parent Claude Code
    // session; strip the marker so it always starts cleanly.
    delete childEnv.CLAUDECODE
    delete childEnv.CLAUDE_CODE_ENTRYPOINT
    this.proc = spawn(command, args, {
      cwd: this.cwd,
      env: childEnv,
      stdio: ['pipe', 'pipe', 'pipe'],
      // One owned process group lets Kaisola reap the adapter AND any model CLI
      // it spawned. Killing only an npx wrapper is what left PPID-1 trees.
      detached: process.platform !== 'win32',
    })
    this.alive = true
    this.hooks.onSpawn?.({ pid: this.proc.pid, pgid: this.proc.pid, command, args })
    this.proc.stdout.on('data', (d) => this._onData(d))
    this.proc.stderr.on('data', (d) => this.hooks.onNotice?.({ kind: 'stderr', text: d.toString() }))
    this.proc.on('exit', (code) => {
      this.alive = false
      this.hooks.onProcessExit?.({ pid: this.proc && this.proc.pid, code })
      for (const { reject, timer } of this.pending.values()) {
        if (timer) clearTimeout(timer)
        reject(new Error(`agent exited (${code})`))
      }
      this.pending.clear()
      this.hooks.onNotice?.({ kind: 'exit', code })
    })
    this.proc.on('error', (err) => {
      this.alive = false
      for (const { reject, timer } of this.pending.values()) {
        if (timer) clearTimeout(timer)
        reject(err)
      }
      this.pending.clear()
      this.hooks.onNotice?.({ kind: 'error', text: err.message })
    })
  }

  _onData(chunk) {
    this.buffer += this.decoder.write(chunk)
    let nl
    while ((nl = this.buffer.indexOf('\n')) >= 0) {
      const raw = this.buffer.slice(0, nl)
      this.buffer = this.buffer.slice(nl + 1)
      if (Buffer.byteLength(raw, 'utf8') > MAX_JSON_LINE_BYTES) {
        this._fatalProtocol(`ACP frame exceeded ${MAX_JSON_LINE_BYTES} bytes`)
        return
      }
      const line = raw.trim()
      if (!line) continue
      let msg
      try {
        msg = JSON.parse(line)
      } catch {
        // non-JSON stdout — some agents print the OAuth URL on a plain line here
        if (/https?:\/\//.test(line)) this.hooks.onNotice?.({ kind: 'stdout', text: line })
        continue
      }
      this._dispatch(msg)
    }
    if (Buffer.byteLength(this.buffer, 'utf8') > MAX_JSON_LINE_BYTES) {
      this._fatalProtocol(`ACP frame exceeded ${MAX_JSON_LINE_BYTES} bytes`)
    }
  }

  _fatalProtocol(message) {
    this.hooks.onNotice?.({ kind: 'error', text: message })
    for (const { reject, timer } of this.pending.values()) {
      if (timer) clearTimeout(timer)
      reject(new Error(message))
    }
    this.pending.clear()
    this.dispose()
  }

  _dispatch(msg) {
    // response to one of our requests
    if (msg.id != null && (msg.result !== undefined || msg.error !== undefined)) {
      const p = this.pending.get(msg.id)
      if (!p) return
      this.pending.delete(msg.id)
      if (p.timer) clearTimeout(p.timer)
      if (msg.error) p.reject(new Error(msg.error.message || 'agent error'))
      else p.resolve(msg.result)
      return
    }
    // request FROM the agent (needs a response)
    if (msg.method && msg.id != null) {
      this._handleRequest(msg)
      return
    }
    // notification (e.g. session/update)
    if (msg.method) {
      if (msg.method === 'session/update') {
        const u = msg.params && msg.params.update
        // keep declared controls fresh as the agent confirms changes
        if (u && u.sessionUpdate === 'config_option_update' && u.configOptions) {
          this.configOptions = u.configOptions
          this.hooks.onControls?.(this.getControls())
        } else if (u && u.sessionUpdate === 'current_mode_update') {
          if (this.modes) this.modes.currentModeId = u.currentModeId ?? u.modeId
          this.hooks.onControls?.(this.getControls())
        } else if (u && u.sessionUpdate === 'current_model_update') {
          if (this.models) this.models.currentModelId = u.currentModelId ?? u.modelId
          this.hooks.onControls?.(this.getControls())
        }
        this.hooks.onUpdate?.(msg.params)
      } else {
        this.hooks.onNotice?.({ kind: 'notify', method: msg.method, params: msg.params })
      }
    }
  }

  _write(obj) {
    if (!this.proc || !this.proc.stdin.writable) return false
    try {
      this.proc.stdin.write(JSON.stringify(obj) + '\n')
      return true
    } catch (err) {
      this.hooks.onNotice?.({ kind: 'error', text: err.message })
      return false
    }
  }

  request(method, params, timeoutMs = (method === 'session/prompt' || method === 'authenticate') ? 0 : REQUEST_TIMEOUT_MS) {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      const timer = timeoutMs > 0 ? setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method} timed out after ${timeoutMs}ms`))
      }, timeoutMs) : null
      timer?.unref?.()
      this.pending.set(id, { resolve, reject, timer, prompt: method === 'session/prompt' })
      if (!this._write({ jsonrpc: '2.0', id, method, params })) {
        if (timer) clearTimeout(timer)
        this.pending.delete(id)
        reject(new Error(`cannot send ${method}: agent is not connected`))
      }
    })
  }

  notify(method, params) {
    this._write({ jsonrpc: '2.0', method, params })
  }

  respond(id, result) {
    this._write({ jsonrpc: '2.0', id, result })
  }

  respondError(id, code, message) {
    this._write({ jsonrpc: '2.0', id, error: { code, message } })
  }

  /** Resolve a provider-supplied path inside the selected workspace. Both the
   * lexical path and its nearest existing real parent are checked so `..` and
   * symlink hops cannot escape the project before Kaisola's sensitive-file
   * guard gets a chance to run. */
  _workspacePath(input, { mustExist = false, directory = false } = {}) {
    if (typeof input !== 'string' || !input.trim()) throw new Error('A workspace-relative path is required')
    const root = path.resolve(this.cwd)
    const candidate = path.resolve(root, input)
    if (!isInside(root, candidate)) throw new Error('Blocked: path is outside the active workspace')
    const realRoot = fs.realpathSync.native(root)
    let probe = candidate
    while (!fs.existsSync(probe)) {
      const parent = path.dirname(probe)
      if (parent === probe) break
      probe = parent
    }
    const realProbe = fs.realpathSync.native(probe)
    if (!isInside(realRoot, realProbe)) throw new Error('Blocked: path resolves outside the active workspace')
    if (mustExist && !fs.existsSync(candidate)) throw new Error('Path does not exist')
    if (fs.existsSync(candidate)) {
      const realCandidate = fs.realpathSync.native(candidate)
      if (!isInside(realRoot, realCandidate)) throw new Error('Blocked: path resolves outside the active workspace')
      if (directory && !fs.statSync(realCandidate).isDirectory()) throw new Error('Terminal cwd must be a directory')
      return realCandidate
    }
    if (directory) throw new Error('Terminal cwd does not exist')
    return candidate
  }

  _ownedTerminalId(input) {
    const terminalId = typeof input === 'string' ? input : ''
    if (!terminalId || !this.ownedTerminalIds.has(terminalId)) {
      throw new Error('Blocked: terminal is not owned by this agent connection')
    }
    return terminalId
  }

  // ── agent → client requests ──
  async _handleRequest(msg) {
    const { id, method, params } = msg
    try {
      if (method === 'session/request_permission') {
        const outcome = await this._decidePermission(params)
        this.respond(id, outcome)
      } else if (method === 'fs/read_text_file') {
        const p = this._workspacePath(params.path, { mustExist: true })
        if (this.hooks.fsGuard && !this.hooks.fsGuard(p)) {
          return this.respondError(id, -32000, 'Blocked: sensitive file (Kaisola guardrails — Settings → Agents)')
        }
        const stat = await fs.promises.stat(p)
        if (!stat.isFile()) return this.respondError(id, -32000, 'Only regular text files can be read')
        if (stat.size > MAX_TEXT_FILE_BYTES) return this.respondError(id, -32000, `Text file exceeds the ${MAX_TEXT_FILE_BYTES}-byte ACP limit`)
        const content = await fs.promises.readFile(p, 'utf8')
        this.respond(id, { content })
      } else if (method === 'fs/write_text_file') {
        const content = typeof params.content === 'string' ? params.content : ''
        if (Buffer.byteLength(content, 'utf8') > MAX_TEXT_FILE_BYTES) {
          return this.respondError(id, -32000, `Text file exceeds the ${MAX_TEXT_FILE_BYTES}-byte ACP limit`)
        }
        const p = this._workspacePath(params.path)
        if (this.hooks.fsGuard && !this.hooks.fsGuard(p)) {
          return this.respondError(id, -32000, 'Blocked: sensitive file (Kaisola guardrails — Settings → Agents)')
        }
        await fs.promises.mkdir(path.dirname(p), { recursive: true })
        // Re-check after mkdir so a concurrently replaced parent symlink cannot
        // turn the write into an escape between validation and creation.
        const checked = this._workspacePath(p)
        await fs.promises.writeFile(checked, content, 'utf8')
        this.respond(id, {})
      } else if (method === 'terminal/create') {
        // run the agent's command in a real, visible pty
        const host = this.hooks.terminalHost
        if (!host) return this.respondError(id, -32601, 'terminal not supported')
        const { terminalId } = await host.create({
          command: params.command,
          args: params.args,
          env: terminalEnvObject(params.env),
          cwd: this._workspacePath(params.cwd || this.cwd, { mustExist: true, directory: true }),
          outputByteLimit: terminalOutputLimit(params.outputByteLimit),
        })
        if (typeof terminalId !== 'string' || !terminalId) throw new Error('Terminal host returned an invalid terminal id')
        this.ownedTerminalIds.add(terminalId)
        this.respond(id, { terminalId })
      } else if (method === 'terminal/output') {
        const o = await this.hooks.terminalHost.output(this._ownedTerminalId(params.terminalId))
        this.respond(id, o)
      } else if (method === 'terminal/wait_for_exit') {
        const r = await this.hooks.terminalHost.waitForExit(this._ownedTerminalId(params.terminalId))
        this.respond(id, { exitStatus: r })
      } else if (method === 'terminal/kill') {
        await this.hooks.terminalHost.kill(this._ownedTerminalId(params.terminalId))
        this.respond(id, {})
      } else if (method === 'terminal/release') {
        const terminalId = this._ownedTerminalId(params.terminalId)
        await this.hooks.terminalHost.release(terminalId)
        this.ownedTerminalIds.delete(terminalId)
        this.respond(id, {})
      } else {
        this.respondError(id, -32601, `Method not handled: ${method}`)
      }
    } catch (err) {
      this.respondError(id, -32000, err.message)
    }
  }

  // Permission policy is driven by the autonomy ladder + the human.
  async _decidePermission(params) {
    const options = params.options || []
    // reject must fail closed: never fall through to options[0] (the ALLOW option)
    const pick = (kinds, fallbackToFirst = true) => {
      for (const k of kinds) {
        const o = options.find((opt) => opt.kind === k)
        if (o) return { outcome: { outcome: 'selected', optionId: o.optionId } }
      }
      return fallbackToFirst && options[0] ? { outcome: { outcome: 'selected', optionId: options[0].optionId } } : { outcome: { outcome: 'cancelled' } }
    }
    if (this.hooks.onPermission) {
      // 'allow' | 'reject' | { optionId } — the object form is the human picking
      // a specific option from the inline permission card
      const decision = await this.hooks.onPermission(params)
      if (decision && typeof decision === 'object' && decision.optionId) {
        const o = options.find((opt) => opt.optionId === decision.optionId)
        if (o) return { outcome: { outcome: 'selected', optionId: o.optionId } }
      }
      if (decision === 'cancel') return { outcome: { outcome: 'cancelled' } }
      if (decision === 'reject') return pick(['reject_once', 'reject_always'], false)
      return pick(['allow_once', 'allow_always'])
    }
    return pick(['allow_once'])
  }

  // ── lifecycle ──
  async initialize() {
    const res = await this.request('initialize', {
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: true },
        terminal: true, // we can run the agent's commands in a real, visible pty
        // Terminal-based sign-in. claude-code-acp only advertises its real auth
        // methods (`claude auth login --claudeai`, `--console`) when the client
        // declares one of these; without them it emits an unusable localhost
        // browser-redirect URL its OWN source calls broken over ACP (dist/
        // acp-agent.js: supportsTerminalAuth / supportsMetaTerminalAuth). We CAN
        // run its login in a real pty, so we advertise both spellings.
        auth: { terminal: true },
        _meta: { 'terminal-auth': true },
      },
    })
    this.authMethods = (res && res.authMethods) || []
    // agents advertising loadSession can resume a prior session after an app
    // restart (session/load) instead of starting blank
    this.canLoadSession = !!(res && res.agentCapabilities && res.agentCapabilities.loadSession)
    // Native prompt queueing: a session/prompt sent while a turn is running is
    // pushed onto the agent's streaming input and injected at the next tool
    // boundary (claude-code-acp: agentCapabilities._meta.claudeCode.
    // promptQueueing). This is what powers mid-turn STEERING — a follow-up that
    // reaches the agent between tool calls instead of waiting out the turn.
    const caps = (res && res.agentCapabilities) || {}
    const sessionCaps = caps.sessionCapabilities || {}
    this.canResumeSession = !!sessionCaps.resume
    this.canCloseSession = !!sessionCaps.close
    this.supportsPromptQueue = !!(caps._meta && caps._meta.claudeCode && caps._meta.claudeCode.promptQueueing)
    // agents that accept HTTP/SSE MCP servers get remote entries at session/new
    this.mcpHttpOk = !!(res && res.agentCapabilities && res.agentCapabilities.mcpCapabilities && res.agentCapabilities.mcpCapabilities.http)
    this.mcpSseOk = !!(res && res.agentCapabilities && res.agentCapabilities.mcpCapabilities && res.agentCapabilities.mcpCapabilities.sse)
    // agents that accept image content blocks in session/prompt (claude does;
    // an image dropped on the chat rides as real pixels, not just a path)
    this.promptImageOk = !!(res && res.agentCapabilities && res.agentCapabilities.promptCapabilities && res.agentCapabilities.promptCapabilities.image)
    return res
  }

  /** The mcpServers param for session/new|load, filtered PER ENTRY by the
   * agent's declared mcp capabilities: stdio servers are baseline ACP (every
   * agent spawns them itself), remote http/sse entries only ride when the
   * agent said it can dial them. The old all-or-nothing http gate silently
   * dropped stdio servers from agents without http support. */
  sessionMcpServers() {
    const list = Array.isArray(this.mcpServers) ? this.mcpServers : []
    return list.filter((s) => s && (s.type === 'http' ? this.mcpHttpOk : s.type === 'sse' ? this.mcpSseOk : true))
  }

  /** Trigger an auth method (the agent runs its own OAuth / opens a browser). */
  async authenticate(methodId) {
    return this.request('authenticate', { methodId })
  }

  /** session/new|load with the mcpServers param — and a bare retry when the
   * agent advertises http MCP but zod-rejects our entry (-32602): a broken
   * tool hookup must degrade to a working, tool-less chat, never a dead thread. */
  async _session(method, params) {
    const servers = this.sessionMcpServers()
    const withClientMeta = (mcpServers) => ({
      ...params,
      mcpServers,
      ...(this.config.sessionMeta ? { _meta: this.config.sessionMeta } : {}),
    })
    try {
      return await this.request(method, withClientMeta(servers))
    } catch (err) {
      if (!servers.length || !/invalid params/i.test(String(err && err.message))) throw err
      return await this.request(method, withClientMeta([]))
    }
  }

  async newSession() {
    const res = await this._session('session/new', { cwd: this.cwd })
    this.sessionId = res.sessionId
    this.modes = res.modes || null
    this.models = res.models || null
    this.configOptions = res.configOptions || []
    this.hooks.onControls?.(this.getControls())
    return res
  }

  /** Resume a prior session by id (agents advertising loadSession). The agent
   * replays its history as session/update notifications — with no turn in
   * flight those route nowhere, which is right: the renderer already shows the
   * persisted transcript; what we want back is the AGENT's internal state. */
  async loadSession(sessionId) {
    const res = await this._session('session/load', { sessionId, cwd: this.cwd })
    this.sessionId = sessionId
    this.modes = (res && res.modes) || this.modes || null
    this.models = (res && res.models) || this.models || null
    this.configOptions = (res && res.configOptions) || this.configOptions || []
    this.hooks.onControls?.(this.getControls())
    return res
  }

  /** Stable ACP lifecycle: resume without replaying history. Prefer this over
   * legacy session/load when advertised; the renderer already owns its durable
   * transcript and needs only the provider's internal conversation state. */
  async resumeSession(sessionId) {
    const res = await this._session('session/resume', { sessionId, cwd: this.cwd })
    this.sessionId = sessionId
    this.modes = (res && res.modes) || this.modes || null
    this.models = (res && res.models) || this.models || null
    this.configOptions = (res && res.configOptions) || this.configOptions || []
    this.hooks.onControls?.(this.getControls())
    return res
  }

  async closeSession() {
    if (!this.sessionId || !this.canCloseSession) return { closed: false }
    const res = await this.request('session/close', { sessionId: this.sessionId })
    this.sessionId = null
    return { ...res, closed: true }
  }

  // ── session controls (the composer dropdowns) ──
  async setMode(modeId) {
    const r = await this.request('session/set_mode', { sessionId: this.sessionId, modeId })
    if (this.modes) this.modes.currentModeId = modeId
    this.hooks.onControls?.(this.getControls())
    return r
  }

  async setConfigOption(configId, value) {
    const r = await this.request('session/set_config_option', { sessionId: this.sessionId, configId, value })
    if (Array.isArray(r?.configOptions)) this.configOptions = r.configOptions
    else {
      const opt = this.configOptions.find((o) => o.id === configId)
      if (opt) opt.currentValue = value
    }
    this.hooks.onControls?.(this.getControls())
    return r
  }

  async setModel(modelId) {
    const r = await this.request('session/set_model', { sessionId: this.sessionId, modelId })
    if (this.models) this.models.currentModelId = modelId
    this.hooks.onControls?.(this.getControls())
    return r
  }

  async prompt(text, images) {
    // attached images become ACP image content blocks — only for agents that
    // advertised promptCapabilities.image. Every attachment is ALSO listed by
    // path in the text, so a text-only agent still gets something it can read.
    const blocks = this.promptImageOk && Array.isArray(images)
      ? images
          .filter((i) => i && typeof i.data === 'string' && typeof i.mimeType === 'string')
          .map((i) => ({ type: 'image', mimeType: i.mimeType, data: i.data }))
      : []
    return this.request('session/prompt', {
      sessionId: this.sessionId,
      prompt: [{ type: 'text', text }, ...blocks],
    })
  }

  cancel() {
    if (this.sessionId) this.notify('session/cancel', { sessionId: this.sessionId })
  }

  /** Reject any session/prompt requests still pending after their turn fully
   * settled. promptQueueing adapters absorb injected (steer) prompts into the
   * running turn and may never answer their JSON-RPC ids; without this sweep
   * each absorbed steer would leave a pending record and an un-settleable
   * promise behind for the connection's lifetime. Callers already ignore
   * these promises, and a late adapter response for a swept id is dropped
   * harmlessly by _dispatch. */
  abandonSettledTurnPrompts() {
    for (const [id, entry] of [...this.pending]) {
      if (!entry.prompt) continue
      this.pending.delete(id)
      if (entry.timer) clearTimeout(entry.timer)
      entry.reject(new Error('session/prompt was absorbed by a completed turn'))
    }
  }

  async releaseOwnedTerminals() {
    const terminalIds = [...this.ownedTerminalIds]
    const host = this.hooks.terminalHost
    const results = await Promise.allSettled(terminalIds.map(async (terminalId) => {
      if (!host?.release) throw new Error('terminal release hook unavailable')
      try {
        await host.release(terminalId)
      } catch (releaseError) {
        // A running process can race an adapter shutdown. Stop it, then retry
        // the authoritative release so the broker record cannot remain dead
        // but undiscoverable forever.
        try { await host.kill?.(terminalId) } catch { /* retry release below */ }
        try { await host.release(terminalId) } catch { throw releaseError }
      }
      this.ownedTerminalIds.delete(terminalId)
    }))
    return {
      ok: results.every((result) => result.status === 'fulfilled'),
      released: results.filter((result) => result.status === 'fulfilled').length,
      failed: results.filter((result) => result.status === 'rejected').length,
    }
  }

  async disposeAndWait() {
    const terminals = await this.releaseOwnedTerminals()
    this.dispose({ releaseTerminals: false })
    return terminals
  }

  dispose({ releaseTerminals = true } = {}) {
    for (const { reject, timer } of this.pending.values()) {
      if (timer) clearTimeout(timer)
      reject(new Error('agent connection disposed'))
    }
    this.pending.clear()
    // Adapter parking/reconnect must not strand broker PTYs that the new ACP
    // connection cannot own. terminal/release is the protocol cleanup point;
    // the host implementation also kills a still-running command.
    if (releaseTerminals) void this.releaseOwnedTerminals().catch(() => {})
    try {
      if (this.proc && this.proc.pid && process.platform !== 'win32') {
        const pgid = this.proc.pid
        try { process.kill(-pgid, 'SIGTERM') } catch { this.proc.kill() }
        // A wedged grandchild must not survive as a PPID-1 orphan. The exact
        // group was created above by this connection, never discovered by name.
        const hard = setTimeout(() => {
          try { process.kill(-pgid, 'SIGKILL') } catch { /* already gone */ }
        }, 1500)
        hard.unref?.()
      } else {
        this.proc?.kill()
      }
    } catch {
      /* noop */
    }
    this.alive = false
    this.ownedTerminalIds.clear()
  }
}

module.exports = { AcpConnection, PROTOCOL_VERSION, terminalEnvObject, terminalOutputLimit }
