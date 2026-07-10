#!/usr/bin/env node
// A tiny ACP *agent* for testing Kaisola end-to-end: declares session controls
// (modes + configOptions, like codex), handles set_mode / set_config_option,
// streams a thought chunk + a tool call, runs a real command via the client's
// terminal host, then returns. Mirrors the real codex-acp shapes.
let buf = ''
let nextId = 1000
const pending = new Map()

const modes = {
  currentModeId: 'auto',
  availableModes: [
    { id: 'read-only', name: 'Read Only', description: 'Read files; approval required to edit.' },
    { id: 'auto', name: 'Default', description: 'Read/edit and run commands; approval for the rest.' },
    { id: 'full-access', name: 'Full Access', description: 'No approval prompts. Use with caution.' },
  ],
}
// Standard ACP models field (like Gemini) — set via session/set_model.
const models = {
  currentModelId: 'mock-pro',
  availableModels: [
    { modelId: 'mock-pro', name: 'Mock Pro', description: 'Frontier mock' },
    { modelId: 'mock-mini', name: 'Mock Mini', description: 'Fast mock' },
  ],
}
// configOptions (like codex) — set via session/set_config_option.
const configOptions = [
  { id: 'mode', name: 'Approval Preset', description: 'Approval & sandboxing preset', category: 'mode', type: 'select', currentValue: 'auto',
    options: modes.availableModes.map((m) => ({ value: m.id, name: m.name, description: m.description })) },
  { id: 'reasoning_effort', name: 'Reasoning Effort', description: 'How much the model thinks', category: 'thought_level', type: 'select', currentValue: 'high',
    options: [{ value: 'low', name: 'Low' }, { value: 'medium', name: 'Medium' }, { value: 'high', name: 'High' }, { value: 'max', name: 'Max' }] },
]
const authMethods = [{ id: 'oauth-mock', name: 'Log in with Mock', description: 'Authorize the mock agent (would open a browser)' }]

function send(obj) { process.stdout.write(JSON.stringify(obj) + '\n') }
function request(method, params) {
  const id = nextId++
  return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); send({ jsonrpc: '2.0', id, method, params }) })
}
function update(sessionId, u) { send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: u } }) }
function text(sessionId, t) { update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: t } }) }
function thought(sessionId, t) { update(sessionId, { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: t } }) }
function emitConfig(sessionId) { update(sessionId, { sessionUpdate: 'config_option_update', configOptions }) }

process.stdin.on('data', (chunk) => {
  buf += chunk.toString('utf8')
  let nl
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1)
    if (!line) continue
    let msg; try { msg = JSON.parse(line) } catch { continue }
    dispatch(msg)
  }
})

function dispatch(msg) {
  if (msg.id != null && msg.method == null) {
    const p = pending.get(msg.id)
    if (p) { pending.delete(msg.id); msg.error ? p.reject(new Error(msg.error.message || 'error')) : p.resolve(msg.result) }
    return
  }
  const { id, method, params } = msg
  if (method === 'initialize') {
    // _meta.claudeCode.promptQueueing → the renderer offers mid-turn STEER for
    // this agent (a follow-up sent while busy injects concurrently, exercised by
    // the STEER smoke section). handlePrompt runs each prompt independently, so a
    // second session/prompt during a held first turn streams its own frames.
    send({ jsonrpc: '2.0', id, result: { protocolVersion: 1, agentCapabilities: { promptCapabilities: {}, _meta: { claudeCode: { promptQueueing: true } } }, authMethods } })
  } else if (method === 'authenticate') {
    // emulate an agent that prints its OAuth URL (so the client can surface/open it)
    process.stderr.write(`Please visit https://example.com/auth/mock-${(params && params.methodId) || 'x'} to authorize\n`)
    send({ jsonrpc: '2.0', id, result: {} })
  } else if (method === 'session/new') {
    send({ jsonrpc: '2.0', id, result: { sessionId: 'mock-session-1', modes, models, configOptions } })
  } else if (method === 'session/set_mode') {
    modes.currentModeId = params.modeId
    const mo = configOptions.find((o) => o.id === 'mode'); if (mo) mo.currentValue = params.modeId
    send({ jsonrpc: '2.0', id, result: {} })
    emitConfig(params.sessionId)
  } else if (method === 'session/set_model') {
    models.currentModelId = params.modelId
    send({ jsonrpc: '2.0', id, result: {} })
    update(params.sessionId, { sessionUpdate: 'current_model_update', currentModelId: params.modelId })
  } else if (method === 'session/set_config_option') {
    const o = configOptions.find((x) => x.id === params.configId); if (o) o.currentValue = params.value
    send({ jsonrpc: '2.0', id, result: {} })
    emitConfig(params.sessionId)
  } else if (method === 'session/prompt') {
    handlePrompt(id, params)
  } else if (id != null) {
    send({ jsonrpc: '2.0', id, result: {} })
  }
}

async function handlePrompt(reqId, params) {
  const sid = params.sessionId
  const prompt = (params.prompt || []).map((b) => b.text || '').join(' ')
  // Gives the renderer smoke test a deterministic busy window in which to
  // enqueue multiple follow-ups. Production agents naturally have this gap.
  if (prompt.includes('[queue-smoke-hold]')) await new Promise((resolve) => setTimeout(resolve, 350))
  // "plan" anywhere in the prompt → exercise the plan + diff-artifact frames
  // (the renderer's PlanStrip and tool-call disclosures; smoke drives this)
  if (/\bplan\b/i.test(prompt)) {
    update(sid, { sessionUpdate: 'plan', entries: [
      { content: 'Inspect the failing module', priority: 'high', status: 'completed' },
      { content: 'Patch the null guard', priority: 'high', status: 'in_progress' },
      { content: 'Re-run the suite', priority: 'medium', status: 'pending' },
    ] })
    update(sid, { sessionUpdate: 'tool_call', toolCallId: 't-diff', title: 'Edit guard.ts', kind: 'edit', status: 'in_progress',
      content: [{ type: 'diff', path: '/tmp/guard.ts', oldText: 'if (x) {\n  run(x)\n}\n', newText: 'if (x != null) {\n  run(x)\n}\n' }] })
    update(sid, { sessionUpdate: 'tool_call_update', toolCallId: 't-diff', status: 'completed' })
    update(sid, { sessionUpdate: 'plan', entries: [
      { content: 'Inspect the failing module', priority: 'high', status: 'completed' },
      { content: 'Patch the null guard', priority: 'high', status: 'completed' },
      { content: 'Re-run the suite', priority: 'medium', status: 'in_progress' },
    ] })
    update(sid, { sessionUpdate: 'usage_update', usedTokens: 68000, maxTokens: 200000 })
    text(sid, 'plan exercised.')
    send({ jsonrpc: '2.0', id: reqId, result: { stopReason: 'end_turn' } })
    return
  }
  thought(sid, `Reading the request and the project context, then I will run a quick command. (model=${models.currentModelId}, effort=${configOptions.find((o) => o.id === 'reasoning_effort').currentValue})`)
  text(sid, 'mock-agent online. ')
  update(sid, { sessionUpdate: 'tool_call', toolCallId: 't1', title: 'echo agent-ran-this', kind: 'execute', status: 'pending' })
  try {
    const { terminalId } = await request('terminal/create', { sessionId: sid, command: 'echo', args: ['agent-ran-this'] })
    await request('terminal/wait_for_exit', { sessionId: sid, terminalId })
    const out = await request('terminal/output', { sessionId: sid, terminalId })
    update(sid, { sessionUpdate: 'tool_call_update', toolCallId: 't1', status: 'completed' })
    text(sid, `ran a command → ${String(out.output || '').trim()}. `)
    await request('terminal/release', { sessionId: sid, terminalId })
  } catch (e) {
    update(sid, { sessionUpdate: 'tool_call_update', toolCallId: 't1', status: 'failed' })
    text(sid, `(terminal error: ${e.message}) `)
  }
  text(sid, `you said: ${prompt}`)
  send({ jsonrpc: '2.0', id: reqId, result: { stopReason: 'end_turn' } })
}
