// The Kaisola MCP server — one protocol surface, with a separate capability
// for every project. Agents coordinate without inheriting whichever project is
// visible in a window at request time.
// From the Traycer deep-dive architecture: instead of a proprietary
// agent-to-agent bus, the IDE exposes its state over MCP and hands the SAME
// server to every agent — the Claude terminal gets it via `--mcp-config`,
// ACP agents (Codex, Gemini, OpenCode…) get it in `session/new` mcpServers.
//
// Transport: Streamable HTTP (spec 2025-06-18), plain-JSON responses, bound to
// 127.0.0.1 on an ephemeral port. Hardened: per-project bearer capabilities +
// a Host allowlist (DNS-rebinding guard). Hand-rolled on node:http — the request/
// response subset we need (initialize / tools/list / tools/call / ping) is
// small and dependency-free.
//
// Read tools reach the renderer's PERSISTED store (throttled ~800ms behind
// live state — fine for research reads). Write tools touch ONLY the agent-task
// ledger (coordination), never project state: research mutations stay behind
// the human proposal gate.
const http = require('node:http')
const crypto = require('node:crypto')
const path = require('node:path')
const fs = require('node:fs')
const { app, BrowserWindow } = require('electron')
const { dbGet } = require('./dbHandler.cjs')
const ledger = require('./ledgerHandler.cjs')
const catalog = require('./mcpCatalog.cjs')

const MAX_CAPABILITIES = 128
const capabilities = new Map() // bearer token -> immutable project context
const capabilityTokens = new Map() // project/workspace key -> bearer token
const claudeConfigs = new Map() // project/workspace key -> { context, token, file }
const pendingProposalAcks = new Map() // proposal id -> exact renderer receipts

const cleanProjectId = (value) => {
  const text = typeof value === 'string' ? value.trim() : ''
  return text && text.length <= 240 && !/[\0-\x1f\x7f]/.test(text) ? text : null
}
const cleanWorkspace = (value) => {
  const text = typeof value === 'string' ? value.trim() : ''
  return text && text.length <= 4096 && path.isAbsolute(text) ? path.resolve(text) : null
}
const validStoreKey = (value) => typeof value === 'string' && /^kaisola-store(?:-w[1-9][0-9]{0,5})?$/.test(value)

function storeKeyForSender(sender) {
  try {
    const win = sender && BrowserWindow.fromWebContents(sender)
    const slot = win?.__kaisolaSlot
    return slot && /^[1-9][0-9]{0,5}$/.test(String(slot)) ? `kaisola-store-w${slot}` : 'kaisola-store'
  } catch {
    return 'kaisola-store'
  }
}

function storeKeyForWindow(win) {
  const slot = win?.__kaisolaSlot
  return slot && /^[1-9][0-9]{0,5}$/.test(String(slot)) ? `kaisola-store-w${slot}` : 'kaisola-store'
}

function normalizeContext(input = {}) {
  const projectId = cleanProjectId(input.projectId)
  const workspace = cleanWorkspace(input.workspace)
  if (!projectId || !workspace) return null
  return Object.freeze({
    projectId,
    workspace,
    storeKey: validStoreKey(input.storeKey) ? input.storeKey : storeKeyForSender(input.sender),
    webContentsId: Number.isSafeInteger(input.sender?.id) && input.sender.id > 0 ? input.sender.id : null,
  })
}

const capabilityKey = (context) => `${context.projectId}\0${context.workspace}`

function revokeCapability(bearer) {
  const context = capabilities.get(bearer)
  if (!context) return
  const key = capabilityKey(context)
  capabilities.delete(bearer)
  if (capabilityTokens.get(key) === bearer) capabilityTokens.delete(key)
  const config = claudeConfigs.get(key)
  if (config?.token === bearer) {
    claudeConfigs.delete(key)
    try { fs.unlinkSync(config.file) } catch { /* absent */ }
  }
}

function issueCapability(input) {
  const context = normalizeContext(input)
  if (!context) return null
  const key = capabilityKey(context)
  const existing = capabilityTokens.get(key)
  if (existing && capabilities.has(existing)) {
    // A project can move between windows. Keep its bearer stable while updating
    // which persisted window store should be checked first.
    capabilities.set(existing, context)
    capabilityTokens.delete(key)
    capabilityTokens.set(key, existing)
    return { token: existing, context }
  }
  const bearer = crypto.randomBytes(32).toString('hex')
  capabilities.set(bearer, context)
  capabilityTokens.set(key, bearer)
  while (capabilities.size > MAX_CAPABILITIES) revokeCapability(capabilities.keys().next().value)
  return { token: bearer, context }
}

/** Hand a write request to the renderer as a PENDING proposal — the human
 * approves it in the owning project's review gate before it touches state. */
function handleProposalAck(senderId, reply = {}) {
  const pending = typeof reply.proposalId === 'string' ? pendingProposalAcks.get(reply.proposalId) : null
  if (!pending || !pending.expected.has(senderId)) return false
  pending.finish(reply.accepted === true ? 'accepted' : 'rejected')
  return true
}

async function proposeToRenderer(target, payload, options) {
  const proposalId = crypto.randomUUID()
  return new Promise((resolve) => {
    const expected = new Set([target.webContents.id])
    const finish = (value) => {
      const pending = pendingProposalAcks.get(proposalId)
      if (!pending) return
      clearTimeout(pending.timer)
      pendingProposalAcks.delete(proposalId)
      resolve(value)
    }
    const timer = setTimeout(() => finish('timeout'), options.timeoutMs ?? 3_000)
    if (options.unrefTimer !== false) timer.unref?.()
    pendingProposalAcks.set(proposalId, { expected, finish, timer })
    try {
      target.webContents.send('mcp:proposal', { proposalId, ...payload })
    } catch {
      finish('send_failed')
    }
  })
}

async function broadcastProposal(kind, args, context, options = {}) {
  if (!context) return { ok: false, message: 'Project capability is missing.' }
  const windows = options.browserWindow ?? BrowserWindow
  const preferred = []
  const candidates = []
  for (const win of windows.getAllWindows()) {
    if (win.__kaisolaPop || win.webContents.isDestroyed() || win.webContents.isLoadingMainFrame?.()) continue
    // Capabilities can outlive the window which minted them. Route sensitive
    // proposal contents only to a live full window whose exact persisted
    // project/workspace still owns them. The minting window gets priority only
    // while it remains an owner; projects can move between OS windows.
    let selected = null
    try {
      selected = options.ownsProject
        ? options.ownsProject(win, context)
        : selectProjectState(parseStoredState(dbGet(storeKeyForWindow(win))), context)
    } catch { /* stale window/store */ }
    if (!selected) continue
    if (context.webContentsId && win.webContents.id === context.webContentsId) preferred.push(win)
    else candidates.push(win)
  }
  const unique = [...new Map([...preferred, ...candidates].map((win) => [win.webContents.id, win])).values()]
  if (!unique.length) {
    return {
      ok: false,
      status: 'project_not_open',
      message: 'The owning project is not open in a live Kaisola window. Reopen it before proposing a change.',
    }
  }
  // Try exact owners one at a time. A synchronous negative ACK proves that
  // renderer did not mutate state, so the next persisted owner is safe. A
  // timeout is intentionally terminal: a blocked renderer might later process
  // the payload, and falling through could create a duplicate proposal.
  let accepted = false
  for (const target of unique) {
    const result = await proposeToRenderer(target, {
        kind,
        args,
        projectId: context.projectId,
        workspace: context.workspace,
        at: Date.now(),
    }, options)
    if (result === 'accepted') { accepted = true; break }
    if (result === 'timeout') break
  }
  if (!accepted) {
    return {
      ok: false,
      status: 'project_not_open',
      message: 'No owning Kaisola project accepted the proposal. Reopen the project and retry.',
    }
  }
  return {
    ok: true,
    status: 'pending_human_review',
    note: 'A proposal was created in Kaisola’s review gate. It becomes project state only if the human approves it — do not assume it applied.',
  }
}

const PROTOCOL = '2025-06-18'
let server = null
let port = 0
let readyPromise = null

function parseStoredState(raw) {
  try {
    if (!raw) return null
    const parsed = JSON.parse(raw)
    return parsed && parsed.state ? parsed.state : parsed
  } catch {
    return null
  }
}

/** Select one exact project from a persisted multi-project Zustand snapshot. */
function selectProjectState(state, context) {
  if (!state || !context) return null
  const tab = Array.isArray(state.projectTabs)
    ? state.projectTabs.find((candidate) => candidate?.id === context.projectId)
    : null
  if (!tab) return null
  // Current persistSnapshot normalizes every project, including the active
  // one, into projectSlices. Older snapshots kept the active project's fields
  // flat at the store root, so retain that shape only as a compatibility
  // fallback. Prefer the normalized slice when both exist: it is the durable
  // source of truth and prevents stale flat fields selecting another project.
  const slice = state.projectSlices?.[context.projectId]
    ?? (state.activeProjectId === context.projectId ? state : null)
  if (!slice) return null
  const workspace = cleanWorkspace(slice.workspacePath)
  const tabWorkspace = cleanWorkspace(tab.workspacePath)
  if (!workspace || workspace !== context.workspace || tabWorkspace !== context.workspace) return null
  return slice
}

function candidateStoreKeys(context) {
  const keys = new Set([context.storeKey])
  try {
    for (const win of BrowserWindow.getAllWindows()) {
      keys.add(storeKeyForWindow(win))
    }
  } catch { /* tests and shutdown can have no BrowserWindow implementation */ }
  return [...keys]
}

/** Read only the project named by the bearer capability. Never fall back to
 * the active project, even when a project moved to another OS window. */
function storeState(context) {
  for (const key of candidateStoreKeys(context)) {
    try {
      const selected = selectProjectState(parseStoredState(dbGet(key)), context)
      if (selected) return selected
    } catch { /* try another live window store */ }
  }
  return null
}

const snip = (s, n) => (typeof s === 'string' && s.length > n ? `${s.slice(0, n)}…` : s)

// ── tools ───────────────────────────────────────────────────────────────────
const TOOLS = [
  {
    name: 'project_overview',
    description: 'This agent session’s exact Kaisola project: name, research question, workspace path, campaign, and counts of corpus sources, hypotheses, claims, experiments and runs. Call this first to orient.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    run: (_args, context) => {
      const s = storeState(context)
      if (!s) return { error: 'No project state available yet.' }
      const p = s.project || {}
      return {
        name: p.name || null,
        question: p.question || null,
        workspacePath: s.workspacePath || null,
        stage: s.stage || null,
        campaign: p.campaign ? { title: p.campaign.title, status: p.campaign.status } : null,
        counts: {
          corpus: (p.corpus || []).length,
          hypotheses: (p.hypotheses || []).length,
          claims: ((p.claimGraph || {}).nodes || []).length,
          experiments: (p.experiments || []).length,
          runs: (p.runs || []).length,
          proposals: (p.proposals || []).length,
        },
      }
    },
  },
  {
    name: 'corpus_search',
    description: 'Search the project corpus (papers, repos, datasets, notes) by title/abstract substring. Empty query lists the most recent items.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Case-insensitive substring; empty = list all' },
        limit: { type: 'number', description: 'Max items (default 10)' },
      },
      additionalProperties: false,
    },
    run: ({ query, limit } = {}, context) => {
      const s = storeState(context)
      if (!s) return { error: 'Project state is unavailable.' }
      const corpus = ((s && s.project) || {}).corpus || []
      const q = String(query || '').toLowerCase()
      const hits = corpus
        .filter((c) => !q || `${c.title || ''} ${c.abstract || ''} ${c.summary || ''}`.toLowerCase().includes(q))
        .slice(0, Math.min(Number(limit) || 10, 50))
        .map((c) => ({ id: c.id, kind: c.kind, title: c.title, year: c.year, abstract: snip(c.abstract, 500) }))
      return { total: corpus.length, matched: hits.length, items: hits }
    },
  },
  {
    name: 'hypotheses_list',
    description: 'List the project hypotheses (id, title, claim, status).',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    run: (_args, context) => {
      const s = storeState(context)
      if (!s) return { error: 'Project state is unavailable.' }
      const hyps = ((s && s.project) || {}).hypotheses || []
      return { items: hyps.slice(0, 50).map((h) => ({ id: h.id, title: h.title, claim: snip(h.claim, 400), status: h.status })) }
    },
  },
  {
    name: 'runs_list',
    description: 'List experiment runs (id, label, status, summary) — the lab-notebook trail.',
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'number', description: 'Max items (default 15)' } },
      additionalProperties: false,
    },
    run: ({ limit } = {}, context) => {
      const s = storeState(context)
      if (!s) return { error: 'Project state is unavailable.' }
      const runs = ((s && s.project) || {}).runs || []
      return { items: runs.slice(-Math.min(Number(limit) || 15, 50)).map((r) => ({ id: r.id, label: r.label, status: r.status, summary: snip(r.summary, 400) })) }
    },
  },
  {
    name: 'agent_tasks_list',
    description: 'The shared agent-task ledger — how agents coordinate in Kaisola. Lists tasks other agents (or the human) posted: check for open work addressed to you, or read results teammates posted.',
    inputSchema: {
      type: 'object',
      properties: { status: { type: 'string', description: 'Filter: open | claimed | in_progress | blocked | review | done | rejected' } },
      additionalProperties: false,
    },
    run: ({ status } = {}, context) => {
      const s = storeState(context)
      if (!s?.workspacePath) return { error: 'Project state is unavailable.' }
      return { tasks: ledger.listTasks({ project: (s && s.workspacePath) || undefined, status }) }
    },
  },
  {
    name: 'agent_task_post',
    description: 'Post a task or a result to the shared agent ledger — the sanctioned way to hand work to another agent or leave a finding for the team. Writes ONLY coordination state (never project files or research state) and is visible to the human in the activity feed. Set `owner` to address a specific agent (e.g. "codex", "claude").',
    inputSchema: {
      type: 'object',
      properties: {
        title: { type: 'string', description: 'Short imperative title' },
        detail: { type: 'string', description: 'What needs doing / what was found, with references' },
        owner: { type: 'string', description: 'Agent this is addressed to (optional)' },
        from: { type: 'string', description: 'Your agent name' },
      },
      required: ['title'],
      additionalProperties: false,
    },
    run: ({ title, detail, owner, from } = {}, context) => {
      const s = storeState(context)
      if (!s?.workspacePath) return { ok: false, message: 'Project state is unavailable.' }
      return ledger.postTask({ project: (s && s.workspacePath) || undefined, title, detail, owner, createdBy: from })
    },
  },
  {
    name: 'hypothesis_propose',
    description: 'Propose a research hypothesis to the project. HUMAN-GATED: this creates a pending proposal in Kaisola’s review gate — it becomes project state only if the human approves. Give a falsifiable claim and why it matters.',
    _meta: { 'anthropic/requiresUserInteraction': true },
    inputSchema: {
      type: 'object',
      properties: {
        title: { type: 'string', description: 'Short hypothesis title' },
        claim: { type: 'string', description: 'The falsifiable statement' },
        why: { type: 'string', description: 'Why it matters / expected contribution' },
        mvp: { type: 'string', description: 'The minimum experiment that would test it' },
        from: { type: 'string', description: 'Your agent name' },
      },
      required: ['title', 'claim'],
      additionalProperties: false,
    },
    run: (args = {}, context) => {
      if (!String(args.title || '').trim() || !String(args.claim || '').trim()) {
        return { ok: false, message: 'title and claim are required' }
      }
      return broadcastProposal('hypothesis', args, context)
    },
  },
  {
    name: 'claim_assert',
    description: 'Assert a claim (or method/result/limitation…) into the project’s claim graph. HUMAN-GATED: creates a pending proposal in the review gate — applied only if the human approves.',
    _meta: { 'anthropic/requiresUserInteraction': true },
    inputSchema: {
      type: 'object',
      properties: {
        label: { type: 'string', description: 'The claim, stated compactly' },
        detail: { type: 'string', description: 'Supporting detail / evidence pointers' },
        type: { type: 'string', description: 'Node type: claim | method | dataset | metric | result | limitation | assumption | question | contradiction (default claim)' },
        from: { type: 'string', description: 'Your agent name' },
      },
      required: ['label'],
      additionalProperties: false,
    },
    run: (args = {}, context) => {
      if (!String(args.label || '').trim()) return { ok: false, message: 'label is required' }
      return broadcastProposal('claim', args, context)
    },
  },
  {
    name: 'agent_task_update',
    description: 'Update a ledger task: claim it (status=claimed, owner=you), report progress (in_progress/blocked), or finish it (done + result). Ledger-only — never mutates project state.',
    inputSchema: {
      type: 'object',
      properties: {
        id: { type: 'string' },
        status: { type: 'string', description: 'open | claimed | in_progress | blocked | review | done | rejected' },
        owner: { type: 'string', description: 'Your agent name when claiming' },
        result: { type: 'string', description: 'Outcome summary when finishing' },
      },
      required: ['id'],
      additionalProperties: false,
    },
    run: (args = {}, context) => {
      const s = storeState(context)
      if (!s?.workspacePath) return { ok: false, message: 'Project state is unavailable.' }
      return ledger.updateTask({ ...args, project: s.workspacePath })
    },
  },
]

// MCP is more than tool calls. Expose the same project context as native,
// read-only resources and reusable prompts so clients that support those
// protocol surfaces can integrate without inventing tool-call boilerplate.
const RESOURCES = [
  { uri: 'kaisola://project/overview', name: 'project-overview', title: 'Project overview', description: 'Active project, stage, workspace and research-object counts.' },
  { uri: 'kaisola://project/corpus', name: 'project-corpus', title: 'Research corpus', description: 'Bounded list of papers, repositories, datasets and notes.' },
  { uri: 'kaisola://project/hypotheses', name: 'project-hypotheses', title: 'Hypotheses', description: 'Current hypotheses and their research status.' },
  { uri: 'kaisola://project/runs', name: 'project-runs', title: 'Experiment runs', description: 'Recent experiment and evaluation runs.' },
  { uri: 'kaisola://agents/tasks', name: 'agent-tasks', title: 'Shared agent tasks', description: 'Open coordination work and findings shared across agents.' },
].map((resource) => ({ ...resource, mimeType: 'application/json' }))

const PROMPTS = [
  {
    name: 'orient_to_project',
    title: 'Orient to this project',
    description: 'Read the project and return a concise operational orientation before acting.',
    arguments: [{ name: 'focus', description: 'Optional area or question to prioritize', required: false }],
    text: ({ focus } = {}) => `Read kaisola://project/overview, kaisola://project/corpus, and kaisola://agents/tasks. Give a concise orientation: current stage, active research question, relevant sources, open work, and the safest next action.${focus ? ` Prioritize: ${String(focus).slice(0, 500)}.` : ''}`,
  },
  {
    name: 'review_research_state',
    title: 'Review research state',
    description: 'Review hypotheses and experiment runs for gaps, contradictions and next tests.',
    arguments: [],
    text: () => 'Read kaisola://project/hypotheses and kaisola://project/runs. Identify unsupported hypotheses, contradictory evidence, missing controls, and the smallest useful next experiment. Post coordination work through the agent-task ledger; do not mutate project state directly.',
  },
  {
    name: 'coordinate_agents',
    title: 'Coordinate with other agents',
    description: 'Check the shared ledger, claim relevant work, and leave a bounded handoff.',
    arguments: [{ name: 'agent', description: 'Your agent name', required: false }],
    text: ({ agent } = {}) => `Read kaisola://agents/tasks. Claim only work that fits your current session, report progress through agent_task_update, and leave precise results or blockers for the next agent.${agent ? ` Identify yourself as ${String(agent).slice(0, 120)}.` : ''}`,
  },
]

function resourceData(uri, context) {
  const s = storeState(context)
  const p = (s && s.project) || {}
  if (!s) return { error: 'Project state is unavailable.' }
  if (uri === 'kaisola://project/overview') return TOOLS.find((tool) => tool.name === 'project_overview').run({}, context)
  if (uri === 'kaisola://project/corpus') {
    return { items: (p.corpus || []).slice(0, 200).map((item) => ({ id: item.id, kind: item.kind, title: item.title, year: item.year, abstract: snip(item.abstract || item.summary, 1000) })) }
  }
  if (uri === 'kaisola://project/hypotheses') {
    return { items: (p.hypotheses || []).slice(0, 200).map((item) => ({ id: item.id, title: item.title, claim: snip(item.claim, 1000), status: item.status })) }
  }
  if (uri === 'kaisola://project/runs') {
    return { items: (p.runs || []).slice(-200).map((item) => ({ id: item.id, label: item.label, status: item.status, summary: snip(item.summary, 1000) })) }
  }
  if (uri === 'kaisola://agents/tasks') return { tasks: ledger.listTasks({ project: (s && s.workspacePath) || undefined }).slice(0, 200) }
  return null
}

// ── JSON-RPC over Streamable HTTP ───────────────────────────────────────────
function rpcResult(id, result) {
  return { jsonrpc: '2.0', id, result }
}
function rpcError(id, code, message) {
  return { jsonrpc: '2.0', id, error: { code, message } }
}

async function handleRpc(msg, context) {
  if (!msg || typeof msg !== 'object' || Array.isArray(msg)) {
    return rpcError(null, -32600, 'Invalid JSON-RPC request')
  }
  const { id, method, params } = msg
  if (method === 'initialize') {
    return rpcResult(id, {
      protocolVersion: PROTOCOL,
      capabilities: {
        tools: { listChanged: false },
        resources: { subscribe: false, listChanged: false },
        prompts: { listChanged: false },
      },
      serverInfo: { name: 'kaisola', title: 'Kaisola Research IDE', version: app.getVersion() },
      instructions: 'Kaisola project state (read) + the shared agent-task ledger (coordinate with other agents). Research state is human-gated: post findings as ledger tasks, never assume writes.',
    })
  }
  if (method === 'ping') return rpcResult(id, {})
  if (method === 'tools/list') {
    // _meta carries anthropic/requiresUserInteraction on the write tools — the
    // client must prompt the human on EVERY call, even under auto-accept modes
    return rpcResult(id, {
      tools: TOOLS.map(({ name, description, inputSchema, _meta }) =>
        _meta ? { name, description, inputSchema, _meta } : { name, description, inputSchema }),
    })
  }
  if (method === 'tools/call') {
    const tool = TOOLS.find((t) => t.name === (params && params.name))
    if (!tool) return rpcError(id, -32602, `Unknown tool: ${params && params.name}`)
    try {
      const out = await tool.run((params && params.arguments) || {}, context)
      return rpcResult(id, {
        content: [{ type: 'text', text: JSON.stringify(out, null, 1).slice(0, 100_000) }],
        structuredContent: out,
        isError: !!(out && (out.ok === false || typeof out.error === 'string')),
      })
    } catch (err) {
      return rpcResult(id, { content: [{ type: 'text', text: `Tool failed: ${String((err && err.message) || err)}` }], isError: true })
    }
  }
  if (method === 'resources/list') return rpcResult(id, { resources: RESOURCES })
  if (method === 'resources/templates/list') return rpcResult(id, { resourceTemplates: [] })
  if (method === 'resources/read') {
    const uri = String(params?.uri || '')
    const data = resourceData(uri, context)
    if (!data) return rpcError(id, -32602, `Unknown resource: ${uri}`)
    return rpcResult(id, { contents: [{ uri, mimeType: 'application/json', text: JSON.stringify(data, null, 2).slice(0, 250_000) }] })
  }
  if (method === 'prompts/list') {
    return rpcResult(id, { prompts: PROMPTS.map(({ text: _text, ...prompt }) => prompt) })
  }
  if (method === 'prompts/get') {
    const prompt = PROMPTS.find((candidate) => candidate.name === params?.name)
    if (!prompt) return rpcError(id, -32602, `Unknown prompt: ${params?.name}`)
    return rpcResult(id, {
      description: prompt.description,
      messages: [{ role: 'user', content: { type: 'text', text: prompt.text(params?.arguments || {}) } }],
    })
  }
  if (typeof method === 'string' && method.startsWith('notifications/')) return null // 202, no body
  return rpcError(id, -32601, `Method not implemented: ${method}`)
}

function startMcpServer() {
  if (server) return readyPromise
  readyPromise = new Promise((resolve) => {
    let settled = false
    const finish = (ok) => {
      if (settled) return
      settled = true
      resolve(ok)
    }
    server = http.createServer((req, res) => {
      // DNS-rebinding guard: loopback host only, and a minted project bearer.
      const host = String(req.headers.host || '')
      if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) { res.writeHead(403); return res.end() }
      const match = String(req.headers.authorization || '').match(/^Bearer ([0-9a-f]{64})$/i)
      const context = match ? capabilities.get(match[1]) : null
      if (!context) { res.writeHead(401); return res.end() }
      if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end() }
      const chunks = []
      let bytes = 0
      req.on('data', (chunk) => {
        bytes += chunk.length
        if (bytes > 1_000_000) req.destroy()
        else chunks.push(chunk)
      })
      req.on('end', async () => {
        let msg
        try { msg = JSON.parse(Buffer.concat(chunks, bytes).toString('utf8')) } catch { res.writeHead(400); return res.end() }
        // batches are removed in 2025-06-18; handle single messages
        let reply
        try {
          reply = await handleRpc(msg, context)
        } catch {
          reply = rpcError(msg && typeof msg === 'object' && !Array.isArray(msg) ? (msg.id ?? null) : null, -32603, 'Internal error')
        }
        if (!reply) { res.writeHead(202); return res.end() }
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify(reply))
      })
    })
    server.once('error', () => finish(false))
    server.listen(0, '127.0.0.1', () => {
      port = server.address().port
      finish(true)
    })
    server.unref?.()
  })
  // Old/crashed launch files contain dead bearer tokens; remove them before a
  // new caller can accidentally hand one to Claude.
  try {
    for (const name of fs.readdirSync(app.getPath('userData'))) {
      if (name === 'kaisola-mcp.json' || /^kaisola-mcp-[0-9a-f]{24}\.json$/.test(name)) {
        try { fs.unlinkSync(path.join(app.getPath('userData'), name)) } catch { /* absent */ }
      }
    }
  } catch { /* userData may not exist yet */ }
  return readyPromise
}

/** The `claude --mcp-config` file: the kaisola server + the user-scope
 * catalog servers (object-map .mcp.json shape). Project .mcp.json is NOT
 * merged — the claude CLI reads that natively with its own approval prompt.
 * Rewritten whenever the catalog changes so toggles apply to the next launch. */
function configPath(context) {
  const digest = crypto.createHash('sha256').update(capabilityKey(context)).digest('hex').slice(0, 24)
  return path.join(app.getPath('userData'), `kaisola-mcp-${digest}.json`)
}

function writeClaudeConfig(record) {
  if (!port || !record) return false
  try {
    catalog.writePrivateJson(record.file, {
      mcpServers: {
        ...catalog.claudeUserEntries(),
        // last so a user entry can never shadow the built-in server
        kaisola: { type: 'http', url: `http://127.0.0.1:${port}/`, headers: { Authorization: `Bearer ${record.token}` } },
      },
    })
    return true
  } catch {
    return false // claude boots without the built-in tools
  }
}

function ensureClaudeConfig(capability) {
  const key = capabilityKey(capability.context)
  let record = claudeConfigs.get(key)
  if (!record || record.token !== capability.token) {
    record = { context: capability.context, token: capability.token, file: configPath(capability.context) }
    claudeConfigs.set(key, record)
  } else {
    record.context = capability.context
  }
  if (!fs.existsSync(record.file)) writeClaudeConfig(record)
  return record
}

catalog.onChange(() => {
  for (const record of claudeConfigs.values()) writeClaudeConfig(record)
})

/** The ACP `session/new` mcpServers entry (agents advertising http support).
 * ACP-wire shape: headers is an ARRAY of {name,value} pairs (the spec's
 * HttpHeader[]) — claude-code-acp zod-rejects an object map and codex-acp
 * serde-rejects it, both as a bare -32602 at session/new (the "Invalid
 * params" Connect bug; proven by electron/acpwireprobe.mjs against both
 * agents). The claude TERMINAL's --mcp-config file above is the opposite:
 * .mcp.json wants an object map. Two consumers, two shapes. */
function mcpHttpEntry(input) {
  if (!port) return null
  const capability = issueCapability(input)
  if (!capability) return null
  return { type: 'http', name: 'kaisola', url: `http://127.0.0.1:${port}/`, headers: [{ name: 'Authorization', value: `Bearer ${capability.token}` }] }
}

function registerMcpHandlers(ipcMain) {
  startMcpServer()
  ipcMain.on('mcp:proposal-ack', (event, reply = {}) => {
    handleProposalAck(event.sender.id, reply)
  })
  // the external-server catalog rides the same registration (main calls once)
  catalog.registerMcpCatalogHandlers(ipcMain)
  ipcMain.handle('mcp:info', async (event, args = {}) => {
    await readyPromise
    const capability = port ? issueCapability({ ...args, sender: event.sender }) : null
    const record = capability ? ensureClaudeConfig(capability) : null
    const configReady = !!record && fs.existsSync(record.file)
    return {
      ok: !!port && !!capability,
      url: port && capability ? `http://127.0.0.1:${port}/` : null,
      protocol: PROTOCOL,
      transport: 'streamable-http',
      toolCount: TOOLS.length,
      resourceCount: RESOURCES.length,
      promptCount: PROMPTS.length,
      humanGatedTools: TOOLS.filter((t) => t._meta && t._meta['anthropic/requiresUserInteraction']).map((t) => t.name),
      // only offer a project-specific config once it is on disk — a boot line
      // pointing at a missing file would make claude error at launch
      configPath: configReady ? record.file : null,
      configReady,
      auth: port && capability ? 'bearer' : null,
      host: port ? '127.0.0.1' : null,
      projectId: capability?.context.projectId ?? null,
      message: capability ? undefined : 'An open project folder is required for the built-in MCP server.',
    }
  })
}

function disposeMcp() {
  try { server?.close() } catch { /* going down anyway */ }
  server = null
  port = 0
  readyPromise = null
  for (const pending of pendingProposalAcks.values()) pending.finish(false)
  pendingProposalAcks.clear()
  for (const record of claudeConfigs.values()) {
    try { fs.unlinkSync(record.file) } catch { /* missing / already removed */ }
  }
  claudeConfigs.clear()
  capabilityTokens.clear()
  capabilities.clear()
}

module.exports = {
  registerMcpHandlers,
  disposeMcp,
  mcpHttpEntry,
  _mcpTest: {
    handleRpc,
    issueCapability,
    normalizeContext,
    selectProjectState,
    broadcastProposal,
    handleProposalAck,
    resetCapabilities: () => {
      capabilities.clear()
      capabilityTokens.clear()
      claudeConfigs.clear()
    },
  },
}
