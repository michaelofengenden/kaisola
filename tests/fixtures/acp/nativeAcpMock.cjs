#!/usr/bin/env node
'use strict'

const readline = require('node:readline')

const PROTOCOL_VERSION = 1
const MOCK_TERMINAL_ENABLED = process.env.KAISOLA_MOCK_TERMINAL === '1'
const AUTH_METHODS = [
  {
    id: 'mock-terminal-auth',
    name: 'Mock terminal authentication',
    description: 'Deterministic authentication for the native ACP fixture.',
  },
]
const AVAILABLE_MODELS = [
  { modelId: 'mock-model-pro', name: 'Mock Model Pro', description: 'Deterministic full-capability model.' },
  { modelId: 'mock-model-fast', name: 'Mock Model Fast', description: 'Deterministic low-latency model.' },
]
const AVAILABLE_MODES = [
  { id: 'default', name: 'Default', description: 'Use the deterministic happy path.' },
  { id: 'read-only', name: 'Read Only', description: 'Reject mock mutations.' },
]
const AVAILABLE_COMMANDS = [
  {
    name: 'mock-help',
    description: 'Show the deterministic mock command.',
    input: { hint: 'optional text' },
  },
]
const TOOL_CALL_LOCATIONS = [
  { path: 'fixture/notes.txt' },
]
const TOOL_CALL_CONTENT = [
  {
    type: 'diff',
    path: 'fixture/notes.txt',
    oldText: 'alpha\nbeta\n',
    newText: 'alpha\nBETA\ngamma\n',
  },
  {
    type: 'content',
    content: { type: 'text', text: 'wrote fixture/notes.txt' },
  },
]
const PERMISSION_OPTIONS = [
  { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
  { optionId: 'reject-once', name: 'Reject once', kind: 'reject_once' },
]

let nextSessionNumber = 1
let nextAgentRequestId = 1000
let nextTurnNumber = 1
let shuttingDown = false

const sessions = new Map()
const activeTurns = new Map()
const pendingClientCallbacks = new Map()

function writeFrame(frame) {
  if (shuttingDown || !process.stdout.writable) return
  process.stdout.write(`${JSON.stringify(frame)}\n`)
}

function respond(id, result) {
  if (id == null) return
  writeFrame({ jsonrpc: '2.0', id, result })
}

function respondError(id, code, message) {
  if (id == null) return
  writeFrame({ jsonrpc: '2.0', id, error: { code, message } })
}

function notify(method, params) {
  writeFrame({ jsonrpc: '2.0', method, params })
}

function sessionUpdate(turn, update) {
  if (turn.cancelled || turn.settled || shuttingDown) return false
  notify('session/update', { sessionId: turn.sessionId, update })
  return true
}

function configOptions(session) {
  return [
    {
      id: 'mode',
      name: 'Approval preset',
      description: 'Deterministic mock approval behavior.',
      category: 'mode',
      type: 'select',
      currentValue: session.modeId,
      options: AVAILABLE_MODES.map((mode) => ({
        value: mode.id,
        name: mode.name,
        description: mode.description,
      })),
    },
    {
      id: 'reasoning_effort',
      name: 'Reasoning effort',
      description: 'How much deterministic thought text to produce.',
      category: 'thought_level',
      type: 'select',
      currentValue: session.reasoningEffort,
      options: [
        { value: 'low', name: 'Low' },
        { value: 'high', name: 'High' },
      ],
    },
  ]
}

function sessionResult(session) {
  return {
    sessionId: session.sessionId,
    modes: {
      currentModeId: session.modeId,
      availableModes: AVAILABLE_MODES,
    },
    models: {
      currentModelId: session.modelId,
      availableModels: AVAILABLE_MODELS,
    },
    configOptions: configOptions(session),
  }
}

function createSession(sessionId = `native-mock-session-${nextSessionNumber++}`) {
  const session = {
    sessionId,
    modelId: AVAILABLE_MODELS[0].modelId,
    modeId: AVAILABLE_MODES[0].id,
    reasoningEffort: 'high',
  }
  sessions.set(sessionId, session)
  return session
}

function addTurn(turn) {
  let turns = activeTurns.get(turn.sessionId)
  if (!turns) {
    turns = new Set()
    activeTurns.set(turn.sessionId, turns)
  }
  turns.add(turn)
}

function removeTurn(turn) {
  const turns = activeTurns.get(turn.sessionId)
  if (!turns) return
  turns.delete(turn)
  if (turns.size === 0) activeTurns.delete(turn.sessionId)
}

function pause(turn, milliseconds) {
  if (turn.cancelled || turn.settled || shuttingDown) return Promise.resolve(false)
  return new Promise((resolve) => {
    let done = false
    const finish = (active) => {
      if (done) return
      done = true
      clearTimeout(timer)
      turn.cancelWaiters.delete(cancel)
      resolve(active && !turn.cancelled && !turn.settled && !shuttingDown)
    }
    const cancel = () => finish(false)
    const timer = setTimeout(() => finish(true), milliseconds)
    turn.cancelWaiters.add(cancel)
  })
}

function requestClient(turn, method, params) {
  if (turn.cancelled || turn.settled || shuttingDown) {
    return Promise.resolve({ outcome: { outcome: 'cancelled' } })
  }
  const id = nextAgentRequestId++
  return new Promise((resolve, reject) => {
    pendingClientCallbacks.set(id, { resolve, reject, turn })
    turn.callbackIds.add(id)
    writeFrame({ jsonrpc: '2.0', id, method, params })
  })
}

function turnIsActive(turn) {
  return !turn.cancelled && !turn.settled && !shuttingDown
}

function errorText(error) {
  if (error && typeof error.message === 'string' && error.message) return error.message
  return String(error || 'unknown error')
}

async function requestTerminalClient(turn, method, params) {
  let response
  try {
    response = await requestClient(turn, method, params)
  } catch (error) {
    throw new Error(`${method} failed: ${errorText(error)}`)
  }
  if (response && response.error) {
    throw new Error(`${method} failed: ${errorText(response.error)}`)
  }
  return response
}

async function runTerminalRoundTrip(turn) {
  const toolCallId = 'term-tool-1'
  if (!sessionUpdate(turn, {
    sessionUpdate: 'tool_call',
    toolCallId,
    title: 'Run fixture command',
    kind: 'execute',
    status: 'in_progress',
  })) return false

  try {
    const createResp = await requestTerminalClient(turn, 'terminal/create', {
      sessionId: turn.sessionId,
      command: '/bin/echo',
      args: ['acp-terminal-roundtrip'],
      cwd: null,
      outputByteLimit: 65536,
    })
    if (!turnIsActive(turn)) return false
    const terminalId = createResp && createResp.terminalId
    if (typeof terminalId !== 'string' || !terminalId) {
      throw new Error('terminal/create failed: missing terminalId')
    }

    if (!sessionUpdate(turn, {
      sessionUpdate: 'tool_call_update',
      toolCallId,
      content: [{ type: 'terminal', terminalId }],
    })) return false
    if (!turnIsActive(turn)) return false

    const waitResp = await requestTerminalClient(turn, 'terminal/wait_for_exit', {
      sessionId: turn.sessionId,
      terminalId,
    })
    if (!turnIsActive(turn)) return false

    const outputResp = await requestTerminalClient(turn, 'terminal/output', {
      sessionId: turn.sessionId,
      terminalId,
    })
    if (!turnIsActive(turn)) return false
    void outputResp

    if (!sessionUpdate(turn, {
      sessionUpdate: 'tool_call_update',
      toolCallId,
      status: 'completed',
      content: [
        { type: 'terminal', terminalId },
        {
          type: 'content',
          content: {
            type: 'text',
            text: `terminal-exit:${JSON.stringify((waitResp && waitResp.exitStatus) || null)}`,
          },
        },
      ],
    })) return false
    if (!turnIsActive(turn)) return false

    await requestTerminalClient(turn, 'terminal/release', {
      sessionId: turn.sessionId,
      terminalId,
    })
    return turnIsActive(turn)
  } catch (error) {
    if (!turnIsActive(turn)) return false
    sessionUpdate(turn, {
      sessionUpdate: 'tool_call_update',
      toolCallId,
      status: 'failed',
      content: [{
        type: 'content',
        content: { type: 'text', text: `terminal-error:${errorText(error)}` },
      }],
    })
    return turnIsActive(turn)
  }
}

function finishTurn(turn, stopReason, { writeResponse = true } = {}) {
  if (turn.settled) return
  turn.settled = true
  for (const cancel of [...turn.cancelWaiters]) cancel()
  for (const callbackId of turn.callbackIds) {
    const pending = pendingClientCallbacks.get(callbackId)
    if (!pending) continue
    pendingClientCallbacks.delete(callbackId)
    pending.resolve({ outcome: { outcome: 'cancelled' } })
  }
  turn.callbackIds.clear()
  removeTurn(turn)
  if (writeResponse) respond(turn.requestId, { stopReason })
}

function cancelTurn(turn, { writeResponse = true } = {}) {
  if (turn.cancelled || turn.settled) return
  turn.cancelled = true
  finishTurn(turn, 'cancelled', { writeResponse })
}

function cancelSession(sessionId, options) {
  const turns = activeTurns.get(sessionId)
  if (!turns) return
  for (const turn of [...turns]) cancelTurn(turn, options)
}

function promptText(blocks) {
  return Array.isArray(blocks)
    ? blocks
        .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
        .map((block) => block.text)
        .join(' ')
    : ''
}

async function handlePrompt(requestId, params) {
  const sessionId = params && params.sessionId
  const session = sessions.get(sessionId)
  if (!session) {
    respondError(requestId, -32000, 'Unknown session')
    return
  }

  const text = promptText(params.prompt)
  const turnNumber = nextTurnNumber++
  const turn = {
    requestId,
    sessionId,
    turnNumber,
    cancelled: false,
    settled: false,
    cancelWaiters: new Set(),
    callbackIds: new Set(),
    stepDelayMs: /\bcancel\b/i.test(text) ? 200 : 0,
  }
  addTurn(turn)

  const toolCallId = `native-mock-tool-${turnNumber}`
  const permissionToolCall = {
    toolCallId: `native-mock-permission-${turnNumber}`,
    title: 'Apply deterministic mock change',
    kind: 'edit',
    status: 'pending',
  }

  sessionUpdate(turn, {
    sessionUpdate: 'agent_thought_chunk',
    content: { type: 'text', text: 'Preparing the deterministic ACP response.' },
  })
  if (!await pause(turn, turn.stepDelayMs)) return

  sessionUpdate(turn, {
    sessionUpdate: 'plan',
    entries: [
      { content: 'Inspect the request', priority: 'high', status: 'completed' },
      { content: 'Return the scripted ACP stream', priority: 'medium', status: 'in_progress' },
    ],
  })
  if (!await pause(turn, turn.stepDelayMs)) return

  sessionUpdate(turn, {
    sessionUpdate: 'agent_message_chunk',
    content: { type: 'text', text: 'The native ACP mock is online. ' },
  })
  if (!await pause(turn, turn.stepDelayMs)) return

  sessionUpdate(turn, {
    sessionUpdate: 'agent_message_chunk',
    content: { type: 'text', text: 'The scripted happy path is running.' },
  })
  if (!await pause(turn, turn.stepDelayMs)) return

  sessionUpdate(turn, {
    sessionUpdate: 'tool_call',
    toolCallId,
    title: 'Inspect deterministic fixture',
    kind: 'read',
    status: 'pending',
    locations: TOOL_CALL_LOCATIONS,
  })
  if (!await pause(turn, turn.stepDelayMs)) return

  sessionUpdate(turn, {
    sessionUpdate: 'tool_call_update',
    toolCallId,
    status: 'completed',
    content: TOOL_CALL_CONTENT,
  })
  if (!await pause(turn, turn.stepDelayMs)) return

  if (MOCK_TERMINAL_ENABLED && !await runTerminalRoundTrip(turn)) return

  let permission
  try {
    permission = await requestClient(turn, 'session/request_permission', {
      sessionId,
      toolCall: permissionToolCall,
      options: PERMISSION_OPTIONS,
    })
  } catch {
    permission = { outcome: { outcome: 'cancelled' } }
  }
  if (turn.cancelled || turn.settled) return

  const outcome = permission && permission.outcome
  const selectedOption = outcome && outcome.outcome === 'selected'
    ? PERMISSION_OPTIONS.find((option) => option.optionId === outcome.optionId)
    : null
  if (outcome && outcome.outcome === 'selected' && !selectedOption) {
    finishTurn(turn, 'cancelled')
    return
  }

  sessionUpdate(turn, {
    sessionUpdate: 'current_model_update',
    currentModelId: session.modelId,
  })
  if (!await pause(turn, turn.stepDelayMs)) return

  sessionUpdate(turn, {
    sessionUpdate: 'available_commands_update',
    availableCommands: AVAILABLE_COMMANDS,
  })
  if (!await pause(turn, turn.stepDelayMs)) return

  sessionUpdate(turn, {
    sessionUpdate: 'usage_update',
    usedTokens: 128,
    maxTokens: 4096,
  })

  const rejected = !selectedOption || selectedOption.kind.startsWith('reject_')
  finishTurn(turn, rejected ? 'cancelled' : 'end_turn')
}

function handleClientResponse(message) {
  const pending = pendingClientCallbacks.get(message.id)
  if (!pending) return
  pendingClientCallbacks.delete(message.id)
  pending.turn.callbackIds.delete(message.id)
  if (message.error) {
    pending.reject(new Error(message.error.message || 'Client request failed'))
  } else {
    pending.resolve(message.result)
  }
}

function handleInitialize(id) {
  respond(id, {
    protocolVersion: PROTOCOL_VERSION,
    authMethods: AUTH_METHODS,
    agentCapabilities: {
      loadSession: true,
      sessionCapabilities: { resume: true, close: true },
      promptCapabilities: { image: false },
      mcpCapabilities: { http: true },
      _meta: { claudeCode: { promptQueueing: true } },
    },
  })
}

function handleSessionControl(id, method, params) {
  const session = sessions.get(params && params.sessionId)
  if (!session) {
    respondError(id, -32000, 'Unknown session')
    return
  }

  if (method === 'session/set_model') {
    if (!AVAILABLE_MODELS.some((model) => model.modelId === params.modelId)) {
      respondError(id, -32602, 'Unknown model')
      return
    }
    session.modelId = params.modelId
    respond(id, {})
    notify('session/update', {
      sessionId: session.sessionId,
      update: { sessionUpdate: 'current_model_update', currentModelId: session.modelId },
    })
    return
  }

  if (method === 'session/set_mode') {
    if (!AVAILABLE_MODES.some((mode) => mode.id === params.modeId)) {
      respondError(id, -32602, 'Unknown mode')
      return
    }
    session.modeId = params.modeId
    respond(id, {})
    return
  }

  const option = configOptions(session).find((candidate) => candidate.id === params.configId)
  if (!option || !option.options.some((candidate) => candidate.value === params.value)) {
    respondError(id, -32602, 'Unknown config option value')
    return
  }
  if (params.configId === 'mode') session.modeId = params.value
  if (params.configId === 'reasoning_effort') session.reasoningEffort = params.value
  respond(id, { configOptions: configOptions(session) })
}

function dispatch(message) {
  if (!message || message.jsonrpc !== '2.0') {
    respondError(message && message.id, -32600, 'Invalid Request')
    return
  }
  if (message.id != null && message.method == null) {
    handleClientResponse(message)
    return
  }

  const { id, method, params = {} } = message
  if (method === 'initialize') {
    handleInitialize(id)
  } else if (method === 'authenticate') {
    if (!AUTH_METHODS.some((auth) => auth.id === params.methodId)) respondError(id, -32602, 'Unknown auth method')
    else respond(id, {})
  } else if (method === 'session/new') {
    respond(id, sessionResult(createSession()))
  } else if (method === 'session/load' || method === 'session/resume') {
    const session = sessions.get(params.sessionId) || createSession(params.sessionId)
    respond(id, sessionResult(session))
  } else if (method === 'session/close') {
    cancelSession(params.sessionId)
    sessions.delete(params.sessionId)
    respond(id, {})
  } else if (method === 'session/prompt') {
    if (id == null) return
    void handlePrompt(id, params).catch((error) => respondError(id, -32000, error.message))
  } else if (method === 'session/cancel') {
    cancelSession(params.sessionId)
    respond(id, {})
  } else if (method === 'session/set_model' || method === 'session/set_mode' || method === 'session/set_config_option') {
    handleSessionControl(id, method, params)
  } else {
    respondError(id, -32601, `Method not found: ${String(method)}`)
  }
}

function handleLine(line) {
  if (!line.trim()) return
  try {
    dispatch(JSON.parse(line))
  } catch {
    writeFrame({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } })
  }
}

function shutdown() {
  if (shuttingDown) return
  for (const turns of activeTurns.values()) {
    for (const turn of [...turns]) cancelTurn(turn, { writeResponse: false })
  }
  shuttingDown = true
  process.stdout.end()
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity })
input.on('line', handleLine)
input.on('close', shutdown)
