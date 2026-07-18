'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const { CompanionDesktopState } = require('./desktopState.cjs')
const { CompanionGateway } = require('./gateway.cjs')
const { LoopbackCompanionTransport } = require('./loopbackTransport.cjs')
const { CompanionProjectionStore } = require('./projectionStore.cjs')
const { CompanionStateHub } = require('./stateHub.cjs')

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'snapshot-board.json'), 'utf8')).body.projection

function setup({
  queueBytes,
  terminalObserver,
  acpSessionService,
  attentionService,
  ledgerAdapter,
  deviceCapabilities = ['observe'],
  enabledCapabilities = ['observe'],
  logger,
} = {}) {
  let now = 1_784_250_001_200
  const records = new Map()
  const projectionStore = new CompanionProjectionStore({
    epoch: 'desktop-epoch-7',
    get: (key) => records.get(key) ?? null,
    set: (key, value) => records.set(key, value),
    del: (key) => records.delete(key),
    keys: () => [...records.keys()],
    now: () => now,
  })
  const desktopState = new CompanionDesktopState({ epoch: 'desktop-epoch-7', projectionStore, attentionService, now: () => now })
  const stateHub = new CompanionStateHub({ desktopState })
  const gateway = new CompanionGateway({
    desktopId: 'desktop-michael-mac',
    epoch: 'desktop-epoch-7',
    stateHub,
    terminalObserver,
    acpSessionService,
    attentionService,
    ledgerAdapter,
    enabledCapabilities,
    logger,
    now: () => now,
  })
  const transport = new LoopbackCompanionTransport({ ...(queueBytes ? { maxQueueBytes: queueBytes } : {}) })
  const session = gateway.attach(transport, { deviceId: 'device-michael-iphone', capabilities: deviceCapabilities })
  const hello = ({ lastAck, capabilities = ['observe'] } = {}) => ({
    v: 1,
    kind: 'hello',
    desktopId: 'desktop-michael-mac',
    deviceId: 'device-michael-iphone',
    connectionId: `connection-${lastAck ?? 'new'}`,
    epoch: 'desktop-epoch-7',
    seq: 0,
    id: `hello-${lastAck ?? 'new'}`,
    sentAt: now,
    body: { type: 'hello', role: 'device', protocolMinor: 0, capabilities, ...(lastAck == null ? {} : { lastAck }) },
  })
  const publish = (projection = fixture) => {
    const result = projectionStore.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection })
    desktopState.projectionPublished('saved-primary', result)
    return result
  }
  return { desktopState, gateway, hello, publish, session, stateHub, transport, setNow: (value) => { now = value } }
}

function command({
  type,
  commandId,
  capability,
  projectId = 'project-kaisola',
  targetId = 'terminal-codex',
  payload = {},
  connectionId = 'connection-new',
}) {
  return {
    v: 1,
    kind: 'command',
    desktopId: 'desktop-michael-mac',
    deviceId: 'device-michael-iphone',
    connectionId,
    epoch: 'desktop-epoch-7',
    seq: 1,
    id: commandId,
    sentAt: 1_784_250_001_300,
    body: { type, commandId, projectId, targetId, capability, payload },
  }
}

test('first loopback connection receives desktop hello and a coherent board snapshot', async () => {
  const { hello, publish, session, transport } = setup()
  publish()
  await transport.sendFromDevice(hello())
  const frames = transport.receiveForDevice()
  assert.deepEqual(frames.map(({ kind }) => kind), ['hello', 'snapshot'])
  assert.equal(frames[0].body.role, 'desktop')
  assert.deepEqual(frames[1].body.projection.board.columns.map(({ id, count }) => ({ id, count })), [
    { id: 'running', count: 1 },
    { id: 'waiting', count: 1 },
    { id: 'done', count: 1 },
  ])
  assert.equal(session.stats().lastSentSeq, 1)
})

test('reconnect from an acknowledged cursor receives only the ordered live suffix', async () => {
  const first = setup()
  first.publish()
  await first.transport.sendFromDevice(first.hello())
  first.transport.receiveForDevice()
  first.desktopState.terminalObserverEvent('project-kaisola', {
    channel: 'terminal:observer-output',
    payload: { id: 'terminal-codex', streamEpoch: 'terminal-epoch-3', startOffset: 3, endOffset: 7, data: '🙂' },
  })
  first.session.close('device_reconnect')

  const reconnectTransport = new LoopbackCompanionTransport()
  const reconnect = first.gateway.attach(reconnectTransport, { deviceId: 'device-michael-iphone', capabilities: ['observe'] })
  await reconnectTransport.sendFromDevice(first.hello({ lastAck: 1 }))
  const frames = reconnectTransport.receiveForDevice()
  assert.deepEqual(frames.map(({ kind }) => kind), ['hello', 'event'])
  assert.equal(frames[1].body.type, 'terminal.output')
  assert.equal(frames[1].body.data, '🙂')
  assert.equal(reconnect.stats().lastSentSeq, 2)
})

test('a fully caught-up reconnect advances its sent cursor and never replays retained events twice', async () => {
  const first = setup()
  first.publish()
  await first.transport.sendFromDevice(first.hello())
  first.transport.receiveForDevice()
  first.session.close('device_reconnect')

  const reconnectTransport = new LoopbackCompanionTransport()
  const reconnect = first.gateway.attach(reconnectTransport, { deviceId: 'device-michael-iphone', capabilities: ['observe'] })
  await reconnectTransport.sendFromDevice(first.hello({ lastAck: 1 }))
  assert.deepEqual(reconnectTransport.receiveForDevice().map(({ kind }) => kind), ['hello'])
  assert.equal(reconnect.stats().lastSentSeq, 1)

  assert.equal(reconnect.synchronize(), true)
  assert.deepEqual(reconnectTransport.receiveForDevice(), [])
  assert.equal(reconnect.stats().lastSentSeq, 1)
})

test('coherent snapshots merge authoritative ACP sessions, permissions, and ledger review state', async () => {
  const seenActors = []
  const acpSessionService = {
    sessionSummaries(actor) {
      seenActors.push(actor)
      return [{
        projectId: 'project-kaisola',
        targetId: 'codex-authority',
        sessionId: 'session-authority',
        provider: 'codex',
        name: 'Codex authority',
        connected: true,
        busy: true,
      }]
    },
    pendingPermissionEvents() {
      return [{
        type: 'agent.permission.requested',
        permId: 'perm-authority',
        revision: 4,
        completeness: 'complete',
        projectId: 'project-kaisola',
        targetId: 'codex-authority',
        sessionId: 'session-authority',
        agent: 'Codex',
        title: 'Review a safe diff',
        kind: 'edit',
        options: [{ optionId: 'reject', name: 'Reject' }],
        diffs: [{ path: 'src/safe.ts', oldText: 'old', newText: 'new' }],
      }]
    },
  }
  const ledgerAdapter = {
    listTasks: () => [{
      id: 'task-gateway',
      project: 'Kaisola',
      status: 'review',
      title: 'Review gateway wiring',
      updatedAt: 1_784_250_001_150,
    }],
  }
  const { gateway, hello, publish, transport } = setup({ acpSessionService, ledgerAdapter })
  publish()
  await transport.sendFromDevice(hello())
  const snapshot = transport.receiveForDevice().find((frame) => frame.kind === 'snapshot')

  assert.ok(snapshot)
  assert.equal(snapshot.body.projection.sessions.find(({ id }) => id === 'session-authority').status, 'running')
  assert.equal(snapshot.body.projection.permissions[0].permId, 'perm-authority')
  assert.equal(snapshot.body.projection.permissions[0].revision, 4)
  assert.equal(snapshot.body.projection.permissions[0].completeness, 'complete')
  assert.equal(snapshot.body.projection.permissions[0].diffs[0].relativePath, 'src/safe.ts')
  assert.equal(snapshot.body.projection.attention.some(({ id }) => id === 'attention-task-gateway'), true)
  assert.ok(seenActors.every((actor) => actor.projectId === 'project-kaisola' && actor.capabilities.includes('observe')))
  assert.deepEqual(gateway.stats().adapters, {
    projection: true,
    terminal: false,
    acp: true,
    attention: false,
    ledger: true,
  })
})

test('ACP and ledger merge failures drop only offending entries and keep the connection usable', async () => {
  const large = 'x'.repeat(16 * 1024)
  const permission = (permId) => ({
    type: 'agent.permission.requested',
    permId,
    revision: 1,
    completeness: 'complete',
    projectId: 'project-kaisola',
    targetId: 'codex-space',
    sessionId: 'session-space',
    agent: '   ',
    title: '\t ',
    options: [{ optionId: 'allow', name: '   ' }],
    diffs: Array.from({ length: 8 }, (_, index) => ({
      path: `src/large-${index}.ts`,
      oldText: large,
      newText: large,
    })),
  })
  const acpSessionService = {
    sessionSummaries: () => [{
      projectId: 'project-kaisola',
      targetId: 'codex-space',
      sessionId: 'session-space',
      provider: '   ',
      name: ' \n ',
      busy: false,
    }],
    pendingPermissionEvents: () => [permission('perm-large-1'), permission('perm-large-2')],
  }
  const ledgerAdapter = {
    listTasks: () => [{
      id: 'task-whitespace',
      projectId: 'project-kaisola',
      status: 'review',
      title: '   ',
      updatedAt: 1_784_250_001_150,
    }],
  }
  const diagnostics = []
  const { desktopState, gateway, hello, publish, session, transport } = setup({
    acpSessionService,
    ledgerAdapter,
    logger: { warn: (message) => diagnostics.push(message) },
  })
  publish()

  await transport.sendFromDevice(hello())
  const snapshot = transport.receiveForDevice().find((frame) => frame.kind === 'snapshot')
  assert.ok(snapshot)
  assert.equal(session.stats().closed, false)
  assert.equal(snapshot.body.projection.sessions.find(({ id }) => id === 'session-space').title, 'Agent')
  assert.deepEqual(snapshot.body.projection.permissions.map(({ permId }) => permId), ['perm-large-1'])
  assert.equal(snapshot.body.projection.permissions[0].agent, 'Agent')
  assert.equal(snapshot.body.projection.permissions[0].title, 'Agent action')
  assert.equal(snapshot.body.projection.permissions[0].options[0].label, 'allow')
  assert.equal(snapshot.body.projection.attention.find(({ id }) => id === 'attention-task-whitespace').title, 'Review agent result')
  assert.ok(gateway.stats().adapterErrors >= 1)
  assert.ok(diagnostics.length >= 1)
  assert.ok(diagnostics.every((message) => Buffer.byteLength(message, 'utf8') <= 512))

  desktopState.eventLog.invalidate()
  assert.equal(session.synchronize(), true)
  assert.equal(session.stats().closed, false)
  assert.ok(transport.receiveForDevice().some((frame) => frame.kind === 'snapshot'))
})

test('live permission events use the exact snapshot redaction boundary', async () => {
  const permission = {
    type: 'agent.permission.requested',
    permId: 'perm-redaction',
    revision: 7,
    completeness: 'complete',
    projectId: 'project-kaisola',
    targetId: 'codex-authority',
    sessionId: 'session-authority',
    attentionSessionId: 'session-authority',
    key: 'codex-authority@@project-kaisola',
    agent: 'Codex',
    title: 'Review diff',
    kind: 'edit',
    sensitive: true,
    requestedAt: 1_784_250_001_100,
    options: [{ optionId: 'reject', name: 'Reject' }],
    diffs: [
      { path: 'src/safe.ts', oldText: `old-${'a'.repeat(20 * 1024)}`, newText: `new-${'b'.repeat(20 * 1024)}` },
      { path: '/Users/michael/private.ts', oldText: 'secret old', newText: 'secret new' },
    ],
  }
  const acpSessionService = {
    sessionSummaries: () => [{
      projectId: 'project-kaisola',
      targetId: 'codex-authority',
      sessionId: 'session-authority',
      provider: 'codex',
      name: 'Codex authority',
      busy: false,
    }],
    pendingPermissionEvents: () => [permission],
  }
  const { desktopState, gateway, hello, publish, transport } = setup({ acpSessionService })
  publish()
  await transport.sendFromDevice(hello())
  const snapshotPermission = transport.receiveForDevice()
    .find((frame) => frame.kind === 'snapshot').body.projection.permissions[0]

  gateway.acpSessionEvent(permission)
  await Promise.resolve()
  const live = transport.receiveForDevice().find((frame) => frame.kind === 'event' && frame.body.type === 'agent.permission.requested')
  assert.ok(live)
  assert.deepEqual(live.body, { type: 'agent.permission.requested', ...snapshotPermission })
  assert.equal(live.body.completeness, 'redacted')
  assert.equal(live.body.diffs.length, 1)
  assert.equal(live.body.diffs[0].relativePath, 'src/safe.ts')
  assert.ok(live.body.diffs[0].oldText.length <= 16 * 1024)
  assert.ok(live.body.diffs[0].newText.length <= 16 * 1024)
  assert.equal(JSON.stringify(live.body).includes('/Users/'), false)
  assert.equal(Object.hasOwn(live.body, 'key'), false)
  assert.equal(Object.hasOwn(live.body, 'sensitive'), false)

  const before = desktopState.stats().eventLog.currentSeq
  assert.equal(gateway.acpSessionEvent({ ...permission, permId: 'perm-forbidden', metadata: { token: 'never-mobile' } }), null)
  assert.equal(desktopState.stats().eventLog.currentSeq, before)
})

test('observe stream commands deliver bounded snapshots and live output, then unsubscribe exactly', async () => {
  let observerArgs
  let unsubscribed = 0
  const terminalObserver = async (args) => {
    observerArgs = args
    return {
      ok: true,
      mode: 'snapshot',
      snapshot: {
        streamEpoch: 'stream-gateway',
        output: 'ready\n',
        startOffset: 0,
        endOffset: 6,
        truncated: false,
        exited: false,
      },
      unsubscribe: async () => { unsubscribed++; return { ok: true } },
    }
  }
  const { hello, publish, session, transport } = setup({ terminalObserver })
  publish()
  await transport.sendFromDevice(hello())
  transport.receiveForDevice()

  const subscribed = await transport.sendFromDevice(command({
    type: 'stream.subscribe',
    commandId: 'stream-subscribe-1',
    capability: 'observe',
  }))
  assert.equal(subscribed.status, 'applied')
  await Promise.resolve()
  let frames = transport.receiveForDevice()
  const terminalSnapshot = frames.find((frame) => frame.kind === 'event' && frame.body.type === 'terminal.snapshot')
  assert.equal(terminalSnapshot.body.output, 'ready\n')
  assert.equal(session.stats().terminalSubscriptions, 1)
  assert.equal(observerArgs.projectId, 'project-kaisola')
  assert.equal(observerArgs.id, 'terminal-codex')

  observerArgs.onEvent({
    channel: 'terminal:observer-output',
    payload: { id: 'terminal-codex', streamEpoch: 'stream-gateway', startOffset: 6, endOffset: 10, data: 'live' },
  })
  await Promise.resolve()
  frames = transport.receiveForDevice()
  assert.equal(frames.find((frame) => frame.body.type === 'terminal.output').body.data, 'live')

  const removed = await transport.sendFromDevice(command({
    type: 'stream.unsubscribe',
    commandId: 'stream-unsubscribe-1',
    capability: 'observe',
  }))
  assert.equal(removed.status, 'applied')
  assert.equal(unsubscribed, 1)
  assert.equal(session.stats().terminalSubscriptions, 0)

  await transport.sendFromDevice(command({
    type: 'stream.subscribe',
    commandId: 'stream-subscribe-before-close',
    capability: 'observe',
  }))
  transport.receiveForDevice()
  session.close('test_disconnect')
  await session.gateway.settle()
  assert.equal(unsubscribed, 2)
  assert.equal(session.stats().terminalSubscriptions, 0)
})

test('ACP and ledger adapters share the live ordered gateway replay', async () => {
  const { gateway, hello, publish, transport } = setup()
  publish()
  await transport.sendFromDevice(hello())
  transport.receiveForDevice()

  gateway.acpSessionEvent({
    type: 'agent.turn.delta',
    projectId: 'project-kaisola',
    targetId: 'session-codex',
    turnId: 'turn-live',
    delta: { text: 'live agent output' },
  })
  gateway.ledgerEvent({
    type: 'updated',
    task: {
      id: 'task-live',
      projectId: 'project-kaisola',
      status: 'review',
      title: 'Review live task',
      updatedAt: 1_784_250_001_220,
    },
  })
  await Promise.resolve()
  const events = transport.receiveForDevice().filter((frame) => frame.kind === 'event')
  assert.deepEqual(events.map((frame) => frame.body.type), ['agent.turn.delta', 'ledger.task.updated'])
})

test('command routing uses negotiated session capabilities, not wider device grants', async () => {
  const { hello, publish, transport } = setup({ deviceCapabilities: ['observe', 'agent-control'] })
  publish()
  await transport.sendFromDevice(hello({ capabilities: ['observe'] }))
  transport.receiveForDevice()
  const result = await transport.sendFromDevice(command({
    type: 'agent.cancel',
    commandId: 'agent-cancel-negotiated',
    capability: 'agent-control',
    targetId: 'session-codex',
  }))
  assert.equal(result.status, 'rejected')
  assert.match(result.message, /not granted/)
})

test('agent commands filter terminal-control from ACP actors and return normal receipts', async () => {
  const actors = []
  const acpSessionService = {
    sessionSummaries: () => [],
    pendingPermissionEvents: () => [],
    cancel(actor) {
      actors.push(actor)
      return { ok: true, status: 'applied', message: 'Agent cancelled.' }
    },
  }
  const capabilities = ['observe', 'agent-control', 'terminal-control']
  const { hello, publish, session, transport } = setup({
    acpSessionService,
    deviceCapabilities: capabilities,
    enabledCapabilities: capabilities,
  })
  publish()
  await transport.sendFromDevice(hello({ capabilities }))
  transport.receiveForDevice()

  const result = await transport.sendFromDevice(command({
    type: 'agent.cancel',
    commandId: 'agent-cancel-all-capabilities',
    capability: 'agent-control',
    targetId: 'session-codex',
  }))
  assert.equal(result.status, 'applied')
  assert.equal(session.stats().closed, false)
  assert.deepEqual(actors[0].capabilities, ['observe', 'agent-control'])
  const receipt = transport.receiveForDevice().find((frame) => frame.kind === 'receipt')
  assert.equal(receipt.body.status, 'applied')
  assert.equal(receipt.body.message, 'Agent cancelled.')
})

test('observe-only device cannot use a well-formed agent or terminal command', async () => {
  const { hello, publish, transport } = setup()
  publish()
  await transport.sendFromDevice(hello())
  transport.receiveForDevice()
  const command = {
    v: 1,
    kind: 'command',
    desktopId: 'desktop-michael-mac',
    deviceId: 'device-michael-iphone',
    connectionId: 'connection-new',
    epoch: 'desktop-epoch-7',
    seq: 1,
    id: 'command-1',
    sentAt: 1_784_250_001_300,
    body: {
      type: 'agent.cancel',
      commandId: 'command-1',
      projectId: 'project-kaisola',
      targetId: 'session-codex',
      capability: 'agent-control',
      payload: {},
    },
  }
  const result = await transport.sendFromDevice(command)
  assert.equal(result.status, 'rejected')
  assert.match(result.message, /not granted/)
  const frames = transport.receiveForDevice()
  assert.equal(frames[0].kind, 'receipt')
  assert.equal(frames[0].body.status, 'rejected')
})

test('bounded loopback queue closes a slow consumer without retaining state', async () => {
  const { hello, session, transport } = setup({ queueBytes: 256 })
  await transport.sendFromDevice(hello())
  assert.equal(session.stats().closed, true)
  assert.equal(transport.stats().closeReason, 'slow_consumer')
  assert.equal(transport.stats().queuedBytes, 0)
})

test('stale reconnect cursors fall back to a fresh snapshot', async () => {
  const { gateway, hello, publish } = setup()
  publish()
  const transport = new LoopbackCompanionTransport()
  gateway.attach(transport, { deviceId: 'device-michael-iphone', capabilities: ['observe'] })
  const frame = hello({ lastAck: 99 })
  frame.connectionId = 'connection-stale'
  frame.id = 'hello-stale'
  await transport.sendFromDevice(frame)
  const frames = transport.receiveForDevice()
  assert.deepEqual(frames.map(({ kind }) => kind), ['hello', 'snapshot'])
  assert.equal(frames[1].body.reason, 'cursor_ahead')
})
