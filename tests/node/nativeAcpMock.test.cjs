'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const path = require('node:path')

const MOCK_PATH = path.join(__dirname, '..', 'fixtures', 'acp', 'nativeAcpMock.cjs')
const REQUEST_TIMEOUT_MS = 2_000

class InboxTimeoutError extends Error {}

class MockAcpClient {
  constructor({ mockTerminal = false } = {}) {
    this.nextId = 1
    this.pending = new Map()
    this.inbox = []
    this.waiters = []
    this.agentRequests = []
    this.stdoutBuffer = ''
    this.stderr = ''
    this.protocolError = null
    this.closed = false
    const childEnv = { ...process.env, ELECTRON_RUN_AS_NODE: '1' }
    delete childEnv.KAISOLA_MOCK_TERMINAL
    if (mockTerminal) childEnv.KAISOLA_MOCK_TERMINAL = '1'
    this.child = spawn(process.execPath, [MOCK_PATH], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: childEnv,
    })
    this.exitPromise = new Promise((resolve) => {
      this.child.once('exit', (code, signal) => resolve({ code, signal }))
    })
    this.child.stdout.setEncoding('utf8')
    this.child.stderr.setEncoding('utf8')
    this.child.stdout.on('data', (chunk) => this.onStdout(chunk))
    this.child.stderr.on('data', (chunk) => { this.stderr += chunk })
    this.child.once('error', (error) => this.fail(error))
    this.child.once('exit', (code, signal) => {
      const error = new Error(`mock exited before the client closed it (code=${code}, signal=${signal})`)
      for (const { reject, timer } of this.pending.values()) {
        clearTimeout(timer)
        reject(error)
      }
      this.pending.clear()
      for (const waiter of this.waiters.splice(0)) {
        clearTimeout(waiter.timer)
        waiter.reject(error)
      }
    })
  }

  onStdout(chunk) {
    this.stdoutBuffer += chunk
    let newline
    while ((newline = this.stdoutBuffer.indexOf('\n')) >= 0) {
      const line = this.stdoutBuffer.slice(0, newline)
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1)
      if (!line) continue
      try {
        const message = JSON.parse(line)
        assert.equal(message.jsonrpc, '2.0', `non-JSON-RPC stdout frame: ${line}`)
        this.dispatch(message)
      } catch (error) {
        this.fail(error)
      }
    }
  }

  dispatch(message) {
    if (message.id != null && message.method == null) {
      const pending = this.pending.get(message.id)
      if (!pending) return
      this.pending.delete(message.id)
      clearTimeout(pending.timer)
      if (message.error) pending.reject(new Error(message.error.message || 'JSON-RPC request failed'))
      else pending.resolve(message.result)
      return
    }

    if (message.id != null && typeof message.method === 'string') {
      this.agentRequests.push(message)
    }
    const waiterIndex = this.waiters.findIndex((waiter) => waiter.predicate(message))
    if (waiterIndex >= 0) {
      const [waiter] = this.waiters.splice(waiterIndex, 1)
      clearTimeout(waiter.timer)
      waiter.resolve(message)
    } else {
      this.inbox.push(message)
    }
  }

  fail(error) {
    if (!this.protocolError) this.protocolError = error
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer)
      reject(error)
    }
    this.pending.clear()
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer)
      waiter.reject(error)
    }
  }

  write(frame) {
    assert.equal(this.protocolError, null)
    this.child.stdin.write(`${JSON.stringify(frame)}\n`)
  }

  request(method, params) {
    const id = this.nextId++
    const promise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method} timed out`))
      }, REQUEST_TIMEOUT_MS)
      this.pending.set(id, { resolve, reject, timer })
    })
    this.write({ jsonrpc: '2.0', id, method, params })
    return promise
  }

  notify(method, params) {
    this.write({ jsonrpc: '2.0', method, params })
  }

  respond(id, result) {
    this.write({ jsonrpc: '2.0', id, result })
  }

  take(predicate = () => true, timeoutMs = REQUEST_TIMEOUT_MS) {
    const index = this.inbox.findIndex(predicate)
    if (index >= 0) return Promise.resolve(this.inbox.splice(index, 1)[0])
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, reject, timer: null }
      waiter.timer = setTimeout(() => {
        const position = this.waiters.indexOf(waiter)
        if (position >= 0) this.waiters.splice(position, 1)
        reject(new InboxTimeoutError('timed out waiting for an agent frame'))
      }, timeoutMs)
      this.waiters.push(waiter)
    })
  }

  async expectNo(predicate, timeoutMs) {
    try {
      const message = await this.take(predicate, timeoutMs)
      assert.fail(`unexpected agent frame: ${JSON.stringify(message)}`)
    } catch (error) {
      if (!(error instanceof InboxTimeoutError)) throw error
    }
  }

  async close() {
    if (this.closed) return
    this.closed = true
    if (this.child.exitCode == null && this.child.signalCode == null) this.child.stdin.end()
    let closeTimer
    const outcome = await Promise.race([
      this.exitPromise,
      new Promise((resolve) => { closeTimer = setTimeout(() => resolve(null), REQUEST_TIMEOUT_MS) }),
    ])
    clearTimeout(closeTimer)
    if (!outcome) {
      this.child.kill('SIGTERM')
      await this.exitPromise
      assert.fail('mock did not exit after stdin closed')
    }
    assert.equal(outcome.code, 0)
    assert.equal(outcome.signal, null)
    assert.equal(this.protocolError, null)
    assert.equal(this.stdoutBuffer, '')
    assert.equal(this.stderr, '')
  }
}

async function clientFor(t, options) {
  const client = new MockAcpClient(options)
  t.after(async () => client.close())
  return client
}

async function initializeAndCreateSession(client) {
  const initialize = await client.request('initialize', {
    protocolVersion: 1,
    clientCapabilities: {
      fs: { readTextFile: true, writeTextFile: true },
      terminal: true,
      auth: { terminal: true },
      _meta: { 'terminal-auth': true },
    },
  })
  const created = await client.request('session/new', {
    cwd: '/tmp/native-acp-mock',
    mcpServers: [],
    _meta: { testClient: true },
  })
  return { initialize, created }
}

function assertUpdateFrame(frame, sessionId) {
  assert.equal(frame.method, 'session/update')
  assert.equal(frame.id, undefined)
  assert.equal(frame.params.sessionId, sessionId)
  return frame.params.update
}

async function readThroughPermission(client, sessionId) {
  const updates = []
  for (let index = 0; index < 6; index += 1) {
    updates.push(assertUpdateFrame(await client.take(), sessionId))
  }
  const permission = await client.take()
  assert.equal(permission.method, 'session/request_permission')
  return { updates, permission }
}

test('mock initializes, creates a session, and streams the exact happy path', async (t) => {
  const client = await clientFor(t)
  const { initialize, created } = await initializeAndCreateSession(client)

  assert.deepEqual(initialize, {
    protocolVersion: 1,
    authMethods: [{
      id: 'mock-terminal-auth',
      name: 'Mock terminal authentication',
      description: 'Deterministic authentication for the native ACP fixture.',
    }],
    agentCapabilities: {
      loadSession: true,
      sessionCapabilities: { resume: true, close: true },
      promptCapabilities: { image: false },
      mcpCapabilities: { http: true },
      _meta: { claudeCode: { promptQueueing: true } },
    },
    // Sibling of `agentCapabilities`, matching where the shipping adapters
    // advertise the `_session/steering` extension.
    _meta: { steering: { supported: true } },
  })
  assert.equal(created.sessionId, 'native-mock-session-1')
  assert.equal(created.models.currentModelId, 'mock-model-pro')
  assert.deepEqual(created.models.availableModels.map((model) => model.modelId), [
    'mock-model-pro',
    'mock-model-fast',
  ])
  assert.equal(created.configOptions.length, 2)

  const promptPromise = client.request('session/prompt', {
    sessionId: created.sessionId,
    prompt: [{ type: 'text', text: 'exercise the default happy path' }],
  })
  let promptSettled = false
  void promptPromise.then(() => { promptSettled = true }, () => { promptSettled = true })

  const { updates, permission } = await readThroughPermission(client, created.sessionId)
  assert.deepEqual(updates, [
    {
      sessionUpdate: 'agent_thought_chunk',
      content: { type: 'text', text: 'Preparing the deterministic ACP response.' },
    },
    {
      sessionUpdate: 'plan',
      entries: [
        { content: 'Inspect the request', priority: 'high', status: 'completed' },
        { content: 'Return the scripted ACP stream', priority: 'medium', status: 'in_progress' },
      ],
    },
    {
      sessionUpdate: 'agent_message_chunk',
      content: { type: 'text', text: 'The native ACP mock is online. ' },
    },
    {
      sessionUpdate: 'agent_message_chunk',
      content: { type: 'text', text: 'The scripted happy path is running.' },
    },
    {
      sessionUpdate: 'tool_call',
      toolCallId: 'native-mock-tool-1',
      title: 'Inspect deterministic fixture',
      kind: 'read',
      status: 'pending',
      locations: [{ path: 'fixture/notes.txt' }],
    },
    {
      sessionUpdate: 'tool_call_update',
      toolCallId: 'native-mock-tool-1',
      status: 'completed',
      content: [
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
      ],
    },
  ])
  assert.deepEqual(permission, {
    jsonrpc: '2.0',
    id: 1000,
    method: 'session/request_permission',
    params: {
      sessionId: created.sessionId,
      toolCall: {
        toolCallId: 'native-mock-permission-1',
        title: 'Apply deterministic mock change',
        kind: 'edit',
        status: 'pending',
      },
      options: [
        { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
        { optionId: 'reject-once', name: 'Reject once', kind: 'reject_once' },
      ],
    },
  })
  assert.equal(promptSettled, false, 'the prompt must wait for the permission response')

  client.respond(permission.id, {
    outcome: { outcome: 'selected', optionId: 'allow-once' },
  })

  for (let index = 0; index < 3; index += 1) {
    updates.push(assertUpdateFrame(await client.take(), created.sessionId))
  }
  assert.deepEqual(updates.map((update) => update.sessionUpdate), [
    'agent_thought_chunk',
    'plan',
    'agent_message_chunk',
    'agent_message_chunk',
    'tool_call',
    'tool_call_update',
    'current_model_update',
    'available_commands_update',
    'usage_update',
  ])
  assert.deepEqual(updates.slice(6), [
    { sessionUpdate: 'current_model_update', currentModelId: 'mock-model-pro' },
    {
      sessionUpdate: 'available_commands_update',
      availableCommands: [{
        name: 'mock-help',
        description: 'Show the deterministic mock command.',
        input: { hint: 'optional text' },
      }],
    },
    { sessionUpdate: 'usage_update', usedTokens: 128, maxTokens: 4096 },
  ])
  assert.deepEqual(await promptPromise, { stopReason: 'end_turn' })
})

test('completed tool calls include deterministic diff and text content', async (t) => {
  const client = await clientFor(t)
  const { created } = await initializeAndCreateSession(client)
  const promptPromise = client.request('session/prompt', {
    sessionId: created.sessionId,
    prompt: [{ type: 'text', text: 'exercise rich tool call content' }],
  })

  const { updates, permission } = await readThroughPermission(client, created.sessionId)
  const toolCallUpdate = updates.find((update) => update.sessionUpdate === 'tool_call_update')
  assert.deepEqual(toolCallUpdate.content, [
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
  ])

  client.respond(permission.id, {
    outcome: { outcome: 'selected', optionId: 'allow-once' },
  })
  for (let index = 0; index < 3; index += 1) {
    assertUpdateFrame(await client.take(), created.sessionId)
  }
  assert.deepEqual(await promptPromise, { stopReason: 'end_turn' })
})

test('the optional terminal bridge completes a deterministic client round trip', async (t) => {
  const client = await clientFor(t, { mockTerminal: true })
  const { created } = await initializeAndCreateSession(client)
  const promptPromise = client.request('session/prompt', {
    sessionId: created.sessionId,
    prompt: [{ type: 'text', text: 'exercise the terminal bridge' }],
  })

  for (let index = 0; index < 6; index += 1) {
    assertUpdateFrame(await client.take(), created.sessionId)
  }

  assert.deepEqual(assertUpdateFrame(await client.take(), created.sessionId), {
    sessionUpdate: 'tool_call',
    toolCallId: 'term-tool-1',
    title: 'Run fixture command',
    kind: 'execute',
    status: 'in_progress',
  })

  const create = await client.take()
  assert.equal(create.method, 'terminal/create')
  assert.deepEqual(create.params, {
    sessionId: created.sessionId,
    command: '/bin/echo',
    args: ['acp-terminal-roundtrip'],
    cwd: null,
    outputByteLimit: 65536,
  })
  client.respond(create.id, { terminalId: 'jt-1' })

  assert.deepEqual(assertUpdateFrame(await client.take(), created.sessionId), {
    sessionUpdate: 'tool_call_update',
    toolCallId: 'term-tool-1',
    content: [{ type: 'terminal', terminalId: 'jt-1' }],
  })

  const waitForExit = await client.take()
  assert.equal(waitForExit.method, 'terminal/wait_for_exit')
  assert.deepEqual(waitForExit.params, {
    sessionId: created.sessionId,
    terminalId: 'jt-1',
  })
  client.respond(waitForExit.id, {
    exitStatus: { exitCode: 0, signal: null },
  })

  const output = await client.take()
  assert.equal(output.method, 'terminal/output')
  assert.deepEqual(output.params, {
    sessionId: created.sessionId,
    terminalId: 'jt-1',
  })
  client.respond(output.id, {
    output: 'acp-terminal-roundtrip\n',
    truncated: false,
    exitStatus: { exitCode: 0, signal: null },
  })

  const completed = assertUpdateFrame(await client.take(), created.sessionId)
  assert.deepEqual(completed, {
    sessionUpdate: 'tool_call_update',
    toolCallId: 'term-tool-1',
    status: 'completed',
    content: [
      { type: 'terminal', terminalId: 'jt-1' },
      {
        type: 'content',
        content: {
          type: 'text',
          text: 'terminal-exit:{"exitCode":0,"signal":null}',
        },
      },
    ],
  })

  const release = await client.take()
  assert.equal(release.method, 'terminal/release')
  assert.deepEqual(release.params, {
    sessionId: created.sessionId,
    terminalId: 'jt-1',
  })
  client.respond(release.id, {})

  const permission = await client.take()
  assert.equal(permission.method, 'session/request_permission')
  client.respond(permission.id, {
    outcome: { outcome: 'selected', optionId: 'allow-once' },
  })
  for (let index = 0; index < 3; index += 1) {
    assertUpdateFrame(await client.take(), created.sessionId)
  }

  assert.deepEqual(
    client.agentRequests
      .filter((request) => request.method.startsWith('terminal/'))
      .map((request) => request.method),
    [
      'terminal/create',
      'terminal/wait_for_exit',
      'terminal/output',
      'terminal/release',
    ],
  )
  assert.deepEqual(await promptPromise, { stopReason: 'end_turn' })
})

test('the default mock never issues terminal client requests', async (t) => {
  const client = await clientFor(t)
  const { created } = await initializeAndCreateSession(client)
  const promptPromise = client.request('session/prompt', {
    sessionId: created.sessionId,
    prompt: [{ type: 'text', text: 'keep the terminal bridge disabled' }],
  })

  const { permission } = await readThroughPermission(client, created.sessionId)
  client.respond(permission.id, {
    outcome: { outcome: 'selected', optionId: 'allow-once' },
  })
  for (let index = 0; index < 3; index += 1) {
    assertUpdateFrame(await client.take(), created.sessionId)
  }

  assert.deepEqual(await promptPromise, { stopReason: 'end_turn' })
  assert.deepEqual(
    client.agentRequests.filter((request) => request.method.startsWith('terminal/')),
    [],
  )
})

test('the selected permission option controls the prompt result', async (t) => {
  const client = await clientFor(t)
  const { created } = await initializeAndCreateSession(client)
  const promptPromise = client.request('session/prompt', {
    sessionId: created.sessionId,
    prompt: [{ type: 'text', text: 'exercise permission rejection' }],
  })
  const { permission } = await readThroughPermission(client, created.sessionId)

  client.respond(permission.id, {
    outcome: { outcome: 'selected', optionId: 'reject-once' },
  })
  for (let index = 0; index < 3; index += 1) {
    assertUpdateFrame(await client.take(), created.sessionId)
  }
  assert.deepEqual(await promptPromise, { stopReason: 'cancelled' })
})

test('session/cancel stops a turn and resolves its prompt request', async (t) => {
  const client = await clientFor(t)
  const { created } = await initializeAndCreateSession(client)
  const promptPromise = client.request('session/prompt', {
    sessionId: created.sessionId,
    prompt: [{ type: 'text', text: 'cancel this deliberately slow turn' }],
  })

  const first = assertUpdateFrame(await client.take(), created.sessionId)
  assert.equal(first.sessionUpdate, 'agent_thought_chunk')
  client.notify('session/cancel', { sessionId: created.sessionId })

  assert.deepEqual(await promptPromise, { stopReason: 'cancelled' })
  await client.expectNo(
    (message) => message.method === 'session/update' || message.method === 'session/request_permission',
    250,
  )
})

test('_session/steering injects into a running turn and reports "injected"', async (t) => {
  const client = await clientFor(t)
  const { created } = await initializeAndCreateSession(client)
  const promptPromise = client.request('session/prompt', {
    sessionId: created.sessionId,
    // "cancel" makes the fixture step slowly, so the turn is still running
    // when the steering request lands.
    prompt: [{ type: 'text', text: 'cancel this deliberately slow turn' }],
  })

  const first = assertUpdateFrame(await client.take(), created.sessionId)
  assert.equal(first.sessionUpdate, 'agent_thought_chunk')

  const steered = await client.request('_session/steering', {
    sessionId: created.sessionId,
    prompt: [{ type: 'text', text: 'actually use tabs' }],
    _meta: { steering: { idleBehavior: 'promptRequired' } },
  })
  assert.deepEqual(steered, { outcome: 'injected' })

  // The injected message reaches the RUNNING turn's stream. No
  // `user_message_chunk` is echoed for it — neither shipping adapter does —
  // so the host owns showing what the user said.
  const steerEcho = await client.take(
    (message) => message.method === 'session/update'
      && message.params.update.sessionUpdate === 'agent_message_chunk'
      && String(message.params.update.content.text).includes('Steered'),
  )
  assert.equal(
    assertUpdateFrame(steerEcho, created.sessionId).content.text,
    ' Steered: actually use tabs.',
  )
  await client.expectNo(
    (message) => message.method === 'session/update'
      && message.params.update.sessionUpdate === 'user_message_chunk',
    250,
  )

  client.notify('session/cancel', { sessionId: created.sessionId })
  assert.deepEqual(await promptPromise, { stopReason: 'cancelled' })
})

test('_session/steering on an idle session honors the promptRequired opt-in', async (t) => {
  const client = await clientFor(t)
  const { created } = await initializeAndCreateSession(client)

  assert.deepEqual(
    await client.request('_session/steering', {
      sessionId: created.sessionId,
      prompt: [{ type: 'text', text: 'nothing is running' }],
      _meta: { steering: { idleBehavior: 'promptRequired' } },
    }),
    { outcome: 'promptRequired', reason: 'noRunningTurn' },
  )

  // Without the opt-in the adapter takes ownership and starts its own turn —
  // the behavior the opt-in exists to avoid.
  assert.deepEqual(
    await client.request('_session/steering', {
      sessionId: created.sessionId,
      prompt: [{ type: 'text', text: 'nothing is running' }],
    }),
    { outcome: 'startedNewTurn' },
  )
})

test('session/load replays the thread history, user prompts included', async (t) => {
  const client = await clientFor(t)
  const { created } = await initializeAndCreateSession(client)
  const promptPromise = client.request('session/prompt', {
    sessionId: created.sessionId,
    prompt: [{ type: 'text', text: 'what changed?' }],
  })
  const { permission } = await readThroughPermission(client, created.sessionId)
  client.respond(permission.id, { outcome: { outcome: 'selected', optionId: 'allow-once' } })
  await promptPromise
  // Drain the tail of the completed turn.
  for (let index = 0; index < 3; index += 1) await client.take()

  const loaded = client.request('session/load', {
    sessionId: created.sessionId,
    cwd: '/tmp/native-acp-mock',
    mcpServers: [],
  })
  const replayed = assertUpdateFrame(await client.take(), created.sessionId)
  assert.deepEqual(replayed, {
    sessionUpdate: 'user_message_chunk',
    messageId: 'mock-msg-1',
    content: { type: 'text', text: 'what changed?' },
  })
  const reply = assertUpdateFrame(await client.take(), created.sessionId)
  assert.equal(reply.sessionUpdate, 'agent_message_chunk')
  assert.equal((await loaded).sessionId, created.sessionId)

  // `session/resume` restores without re-streaming, so a host that resumes
  // never sees the replay at all.
  const resumed = await client.request('session/resume', {
    sessionId: created.sessionId,
    cwd: '/tmp/native-acp-mock',
    mcpServers: [],
  })
  assert.equal(resumed.sessionId, created.sessionId)
  await client.expectNo((message) => message.method === 'session/update', 250)
})
