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
const { agentEnv } = require('./shellEnv.cjs')

const PROTOCOL_VERSION = 1

class AcpConnection {
  constructor(config, hooks = {}) {
    this.config = config // { command, args, env, cwd, mcpServers, sessionMeta }
    this.hooks = hooks // { onUpdate, onNotice, onPermission }
    this.mcpServers = Array.isArray(config.mcpServers) ? config.mcpServers : null
    this.proc = null
    this.buffer = ''
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
    })
    this.alive = true
    this.proc.stdout.on('data', (d) => this._onData(d))
    this.proc.stderr.on('data', (d) => this.hooks.onNotice?.({ kind: 'stderr', text: d.toString() }))
    this.proc.on('exit', (code) => {
      this.alive = false
      for (const { reject } of this.pending.values()) reject(new Error(`agent exited (${code})`))
      this.pending.clear()
      this.hooks.onNotice?.({ kind: 'exit', code })
    })
    this.proc.on('error', (err) => {
      this.alive = false
      this.hooks.onNotice?.({ kind: 'error', text: err.message })
    })
  }

  _onData(chunk) {
    this.buffer += chunk.toString('utf8')
    let nl
    while ((nl = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, nl).trim()
      this.buffer = this.buffer.slice(nl + 1)
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
  }

  _dispatch(msg) {
    // response to one of our requests
    if (msg.id != null && (msg.result !== undefined || msg.error !== undefined)) {
      const p = this.pending.get(msg.id)
      if (!p) return
      this.pending.delete(msg.id)
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
    if (this.proc && this.proc.stdin.writable) this.proc.stdin.write(JSON.stringify(obj) + '\n')
  }

  request(method, params) {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this._write({ jsonrpc: '2.0', id, method, params })
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

  // ── agent → client requests ──
  async _handleRequest(msg) {
    const { id, method, params } = msg
    try {
      if (method === 'session/request_permission') {
        const outcome = await this._decidePermission(params)
        this.respond(id, outcome)
      } else if (method === 'fs/read_text_file') {
        const p = path.resolve(this.cwd, params.path)
        if (this.hooks.fsGuard && !this.hooks.fsGuard(p)) {
          return this.respondError(id, -32000, 'Blocked: sensitive file (Kaisola guardrails — Settings → Agents)')
        }
        const content = fs.readFileSync(p, 'utf8')
        this.respond(id, { content })
      } else if (method === 'fs/write_text_file') {
        const p = path.resolve(this.cwd, params.path)
        if (this.hooks.fsGuard && !this.hooks.fsGuard(p)) {
          return this.respondError(id, -32000, 'Blocked: sensitive file (Kaisola guardrails — Settings → Agents)')
        }
        fs.mkdirSync(path.dirname(p), { recursive: true })
        fs.writeFileSync(p, params.content ?? '', 'utf8')
        this.respond(id, {})
      } else if (method === 'terminal/create') {
        // run the agent's command in a real, visible pty
        const host = this.hooks.terminalHost
        if (!host) return this.respondError(id, -32601, 'terminal not supported')
        const { terminalId } = await host.create({
          command: params.command,
          args: params.args,
          env: params.env,
          cwd: params.cwd || this.cwd,
          outputByteLimit: params.outputByteLimit,
        })
        this.respond(id, { terminalId })
      } else if (method === 'terminal/output') {
        const o = this.hooks.terminalHost.output(params.terminalId)
        this.respond(id, o)
      } else if (method === 'terminal/wait_for_exit') {
        const r = await this.hooks.terminalHost.waitForExit(params.terminalId)
        this.respond(id, { exitStatus: r })
      } else if (method === 'terminal/kill') {
        this.hooks.terminalHost.kill(params.terminalId)
        this.respond(id, {})
      } else if (method === 'terminal/release') {
        this.hooks.terminalHost.release(params.terminalId)
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
      },
    })
    this.authMethods = (res && res.authMethods) || []
    // agents advertising loadSession can resume a prior session after an app
    // restart (session/load) instead of starting blank
    this.canLoadSession = !!(res && res.agentCapabilities && res.agentCapabilities.loadSession)
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

  // ── session controls (the composer dropdowns) ──
  async setMode(modeId) {
    const r = await this.request('session/set_mode', { sessionId: this.sessionId, modeId })
    if (this.modes) this.modes.currentModeId = modeId
    this.hooks.onControls?.(this.getControls())
    return r
  }

  async setConfigOption(configId, value) {
    const r = await this.request('session/set_config_option', { sessionId: this.sessionId, configId, value })
    const opt = this.configOptions.find((o) => o.id === configId)
    if (opt) opt.currentValue = value
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

  dispose() {
    try {
      this.proc?.kill()
    } catch {
      /* noop */
    }
    this.alive = false
  }
}

module.exports = { AcpConnection, PROTOCOL_VERSION }
