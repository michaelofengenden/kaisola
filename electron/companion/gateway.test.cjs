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
const { AcpSessionService } = require('../ipc/acpSessionService.cjs')

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'snapshot-board.json'), 'utf8')).body.projection

function setup({
  queueBytes,
  terminalObserver,
  terminalControlAdapter,
  acpSessionService,
  attentionService,
  ledgerAdapter,
  deviceCapabilities = ['observe'],
  enabledCapabilities = ['observe'],
  transportHintProvider,
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
    terminalControlAdapter,
    acpSessionService,
    attentionService,
    ledgerAdapter,
    enabledCapabilities,
    transportHintProvider,
    logger,
    now: () => now,
  })
  const transport = new LoopbackCompanionTransport({ ...(queueBytes ? { maxQueueBytes: queueBytes } : {}) })
  const session = gateway.attach(transport, { deviceId: 'device-michael-iphone', capabilities: deviceCapabilities })
  const hello = ({
    lastAck,
    capabilities = ['observe'],
    deviceId = 'device-michael-iphone',
    connectionId = `connection-${lastAck ?? 'new'}`,
  } = {}) => ({
    v: 1,
    kind: 'hello',
    desktopId: 'desktop-michael-mac',
    deviceId,
    connectionId,
    epoch: 'desktop-epoch-7',
    seq: 0,
    id: `hello-${deviceId}-${lastAck ?? 'new'}`,
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
  deviceId = 'device-michael-iphone',
}) {
  return {
    v: 1,
    kind: 'command',
    desktopId: 'desktop-michael-mac',
    deviceId,
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

test('desktop hello securely refreshes the current LAN and Tailscale routes', async () => {
  const transportHint = {
    service: '_kaisola._tcp', protocol: 'tcp', host: '192.168.1.23', tailscaleHost: '100.90.1.14', port: 49321,
  }
  const { hello, publish, transport } = setup({ transportHintProvider: () => transportHint })
  publish()
  await transport.sendFromDevice(hello())
  const desktopHello = transport.receiveForDevice().find((frame) => frame.kind === 'hello')
  assert.deepEqual(desktopHello.body.transportHint, transportHint)
})

test('reconnect from an acknowledged cursor receives only the ordered live suffix', async () => {
  const first = setup()
  first.publish()
  await first.transport.sendFromDevice(first.hello())
  first.transport.receiveForDevice()
  first.gateway.acpSessionEvent({
    type: 'agent.turn.delta',
    projectId: 'project-kaisola',
    targetId: 'session-codex',
    turnId: 'turn-reconnect',
    delta: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'resume me' } },
  })
  first.session.close('device_reconnect')

  const reconnectTransport = new LoopbackCompanionTransport()
  const reconnect = first.gateway.attach(reconnectTransport, { deviceId: 'device-michael-iphone', capabilities: ['observe'] })
  await reconnectTransport.sendFromDevice(first.hello({ lastAck: 1 }))
  const frames = reconnectTransport.receiveForDevice()
  assert.deepEqual(frames.map(({ kind }) => kind), ['hello', 'event'])
  assert.equal(frames[1].body.type, 'agent.turn.delta')
  assert.equal(frames[1].body.delta.content.text, 'resume me')
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

test('secret-shaped ACP deltas are rejected from both live and replay delivery', async () => {
  const { desktopState, gateway, hello, publish, session, transport } = setup()
  publish()
  await transport.sendFromDevice(hello())
  transport.receiveForDevice()
  const before = desktopState.stats().eventLog.currentSeq
  const base = {
    type: 'agent.turn.delta',
    projectId: 'project-kaisola',
    targetId: 'session-codex',
    turnId: 'turn-secret',
  }
  const rejected = [
    {
      ...base,
      delta: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'hidden', environment: { API_TOKEN: 'live-secret' } } },
    },
    {
      ...base,
      delta: {
        sessionUpdate: 'tool_call',
        toolCallId: 'tool-secret',
        title: 'Edit secret',
        content: [{ type: 'diff', path: '/Users/michael/.env', oldText: 'old-token', newText: 'new-token' }],
      },
    },
    {
      ...base,
      delta: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'safe', unknownNested: 'secret' } },
    },
    {
      ...base,
      delta: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'x'.repeat(16 * 1024 + 1) } },
    },
  ]
  for (const event of rejected) assert.equal(gateway.acpSessionEvent(event), null)
  await Promise.resolve()
  assert.equal(desktopState.stats().eventLog.currentSeq, before)
  assert.deepEqual(transport.receiveForDevice(), [])

  session.close('secret-replay-check')
  const replayTransport = new LoopbackCompanionTransport()
  gateway.attach(replayTransport, { deviceId: 'device-michael-iphone', capabilities: ['observe'] })
  await replayTransport.sendFromDevice(hello({ lastAck: before, connectionId: 'connection-secret-replay' }))
  const replayFrames = replayTransport.receiveForDevice()
  assert.deepEqual(replayFrames.map(({ kind }) => kind), ['hello'])
  assert.equal(JSON.stringify(replayFrames).includes('live-secret'), false)
  assert.equal(JSON.stringify(replayFrames).includes('/Users/michael'), false)
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

  // Durable brokers from an older app build are observed by bounded polling;
  // each changed snapshot replaces the mobile emulator state without asking
  // the broker to restart or transfer PTY ownership.
  observerArgs.onEvent({
    channel: 'terminal:observer-snapshot',
    payload: {
      id: 'terminal-codex',
      streamEpoch: 'stream-gateway',
      output: 'replaced\n',
      startOffset: 0,
      endOffset: 9,
      truncated: false,
      exited: false,
    },
  })
  await Promise.resolve()
  frames = transport.receiveForDevice()
  const replacement = frames.find((frame) => frame.body.type === 'terminal.snapshot')
  assert.equal(replacement.body.output, 'replaced\n')
  assert.equal(replacement.body.endOffset, 9)

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

test('one terminal observer fans each byte range once only to subscribed companion sessions', async () => {
  let observerArgs
  let observerCalls = 0
  let upstreamUnsubscribed = 0
  const terminalObserver = async (args) => {
    observerCalls++
    observerArgs = args
    return {
      ok: true,
      mode: 'snapshot',
      snapshot: {
        streamEpoch: 'stream-shared',
        output: 'ready\n',
        startOffset: 0,
        endOffset: 6,
        truncated: false,
        exited: false,
      },
      unsubscribe: async () => { upstreamUnsubscribed++; return { ok: true } },
    }
  }
  const first = setup({ terminalObserver })
  first.publish()
  await first.transport.sendFromDevice(first.hello())
  first.transport.receiveForDevice()

  const secondTransport = new LoopbackCompanionTransport()
  const second = first.gateway.attach(secondTransport, { deviceId: 'device-second-phone', capabilities: ['observe'] })
  await secondTransport.sendFromDevice(first.hello({ deviceId: 'device-second-phone', connectionId: 'connection-second' }))
  secondTransport.receiveForDevice()
  const thirdTransport = new LoopbackCompanionTransport()
  first.gateway.attach(thirdTransport, { deviceId: 'device-no-stream', capabilities: ['observe'] })
  await thirdTransport.sendFromDevice(first.hello({ deviceId: 'device-no-stream', connectionId: 'connection-third' }))
  thirdTransport.receiveForDevice()

  await first.transport.sendFromDevice(command({
    type: 'stream.subscribe',
    commandId: 'shared-subscribe-first',
    capability: 'observe',
    payload: { streamEpoch: 'stream-shared', afterOffset: 6 },
  }))
  await Promise.resolve()
  const firstSubscribeFrames = first.transport.receiveForDevice()
  assert.equal(firstSubscribeFrames.filter((frame) => frame.body.type === 'terminal.snapshot').length, 1)
  secondTransport.receiveForDevice()
  thirdTransport.receiveForDevice()

  await secondTransport.sendFromDevice(command({
    type: 'stream.subscribe',
    commandId: 'shared-subscribe-second',
    capability: 'observe',
    payload: { streamEpoch: 'stream-shared', afterOffset: 6 },
    deviceId: 'device-second-phone',
    connectionId: 'connection-second',
  }))
  await Promise.resolve()
  assert.equal(observerCalls, 1)
  assert.equal(first.transport.receiveForDevice().filter((frame) => frame.body.type === 'terminal.snapshot').length, 0)
  assert.equal(secondTransport.receiveForDevice().filter((frame) => frame.body.type === 'terminal.snapshot').length, 1)
  assert.deepEqual(thirdTransport.receiveForDevice(), [])
  assert.equal(first.session.stats().terminalSubscriptions, 1)
  assert.equal(second.stats().terminalSubscriptions, 1)

  const beforeOutput = first.desktopState.stats().eventLog.currentSeq
  observerArgs.onEvent({
    channel: 'terminal:observer-output',
    payload: { id: 'terminal-codex', streamEpoch: 'stream-shared', startOffset: 6, endOffset: 10, data: 'live' },
  })
  await Promise.resolve()
  await Promise.resolve()
  const firstOutput = first.transport.receiveForDevice().filter((frame) => frame.body.type === 'terminal.output')
  const secondOutput = secondTransport.receiveForDevice().filter((frame) => frame.body.type === 'terminal.output')
  assert.equal(firstOutput.length, 1)
  assert.equal(secondOutput.length, 1)
  assert.equal(firstOutput[0].body.data, 'live')
  assert.equal(firstOutput[0].seq, secondOutput[0].seq)
  assert.equal(first.desktopState.stats().eventLog.currentSeq, beforeOutput + 1)
  assert.deepEqual(thirdTransport.receiveForDevice(), [])

  observerArgs.onEvent({
    channel: 'terminal:observer-output',
    payload: { id: 'terminal-codex', streamEpoch: 'stream-shared', startOffset: 6, endOffset: 10, data: 'live' },
  })
  await Promise.resolve()
  assert.equal(first.desktopState.stats().eventLog.currentSeq, beforeOutput + 1)
  assert.deepEqual(first.transport.receiveForDevice(), [])
  assert.deepEqual(secondTransport.receiveForDevice(), [])

  first.session.close('shared-first-close')
  second.close('shared-second-close')
  await first.gateway.settle()
  assert.equal(upstreamUnsubscribed, 1)
})

test('unsubscribe supersedes an in-flight terminal subscribe and disposes its late observer', async () => {
  let resolveObserver
  let observerStarted
  const started = new Promise((resolve) => { observerStarted = resolve })
  let unsubscribed = 0
  const terminalObserver = async () => {
    observerStarted()
    return new Promise((resolve) => { resolveObserver = resolve })
  }
  const { gateway, hello, publish, session, transport } = setup({ terminalObserver })
  publish()
  await transport.sendFromDevice(hello())
  transport.receiveForDevice()

  const subscribing = transport.sendFromDevice(command({
    type: 'stream.subscribe',
    commandId: 'racing-subscribe',
    capability: 'observe',
  }))
  await started
  const removed = await transport.sendFromDevice(command({
    type: 'stream.unsubscribe',
    commandId: 'racing-unsubscribe',
    capability: 'observe',
  }))
  assert.equal(removed.status, 'applied')
  assert.equal(session.stats().terminalSubscriptions, 0)

  resolveObserver({
    ok: true,
    mode: 'current',
    cursor: { streamEpoch: 'stream-race', offset: 0 },
    unsubscribe: async () => { unsubscribed++; return { ok: true } },
  })
  const late = await subscribing
  await gateway.settle()
  assert.equal(late.status, 'unavailable')
  assert.match(late.message, /superseded/)
  assert.equal(unsubscribed, 1)
  assert.equal(session.stats().terminalSubscriptions, 0)
  assert.equal(gateway.stats().terminalStreams, 0)
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

test('capability negotiation returns the granted intersection when the phone asks for more', async () => {
  const { hello, publish, transport } = setup({
    deviceCapabilities: ['observe', 'agent-control'],
    enabledCapabilities: ['observe', 'agent-control', 'terminal-control'],
  })
  publish()
  await transport.sendFromDevice(hello({ capabilities: ['observe', 'agent-control', 'terminal-control'] }))
  const desktopHello = transport.receiveForDevice().find((frame) => frame.kind === 'hello')
  assert.deepEqual(desktopHello.body.capabilities, ['observe', 'agent-control'])
})

test('terminal control receipts carry a connection-bound lease and route exact scoped input', async () => {
  const calls = []
  const terminalControlAdapter = {
    async available(target) { calls.push({ operation: 'available', ...target }); return { ok: true } },
    async write(input) { calls.push({ operation: 'write', ...input }); return { ok: true } },
    async resize(input) { calls.push({ operation: 'resize', ...input }); return { ok: true } },
    async interrupt(input) { calls.push({ operation: 'interrupt', ...input }); return { ok: true } },
  }
  const capabilities = ['observe', 'terminal-control']
  const first = setup({ terminalControlAdapter, deviceCapabilities: capabilities, enabledCapabilities: capabilities })
  first.publish()
  await first.transport.sendFromDevice(first.hello({ capabilities }))
  first.transport.receiveForDevice()

  const acquired = await first.transport.sendFromDevice(command({
    type: 'terminal.acquire-control',
    commandId: 'terminal-acquire-gateway',
    capability: 'terminal-control',
  }))
  assert.equal(acquired.status, 'applied')
  assert.match(acquired.payload.leaseId, /^lease-/)
  const acquireFrame = first.transport.receiveForDevice().find((frame) => frame.kind === 'receipt')
  assert.equal(acquireFrame.body.payload.leaseId, acquired.payload.leaseId)

  const written = await first.transport.sendFromDevice(command({
    type: 'terminal.write',
    commandId: 'terminal-write-gateway',
    capability: 'terminal-control',
    payload: { leaseId: acquired.payload.leaseId, data: 'status\r' },
  }))
  assert.equal(written.status, 'applied')
  assert.deepEqual(calls.at(-1), {
    operation: 'write',
    id: 'terminal-codex',
    projectId: 'project-kaisola',
    data: 'status\r',
  })

  const secondTransport = new LoopbackCompanionTransport()
  first.gateway.attach(secondTransport, { deviceId: 'device-second-phone', capabilities })
  await secondTransport.sendFromDevice(first.hello({
    capabilities,
    deviceId: 'device-second-phone',
    connectionId: 'connection-second-phone',
  }))
  secondTransport.receiveForDevice()
  const denied = await secondTransport.sendFromDevice(command({
    type: 'terminal.acquire-control',
    commandId: 'terminal-acquire-second',
    capability: 'terminal-control',
    deviceId: 'device-second-phone',
    connectionId: 'connection-second-phone',
  }))
  assert.equal(denied.status, 'rejected')
  assert.match(denied.message, /another device/)

  first.session.close('lease-holder-disconnected')
  const reacquired = await secondTransport.sendFromDevice(command({
    type: 'terminal.acquire-control',
    commandId: 'terminal-acquire-after-disconnect',
    capability: 'terminal-control',
    deviceId: 'device-second-phone',
    connectionId: 'connection-second-phone',
  }))
  assert.equal(reacquired.status, 'applied')
  assert.notEqual(reacquired.payload.leaseId, acquired.payload.leaseId)
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

test('connected companion project subscription keeps an orphaned ACP permission pending', async () => {
  const targetId = 'codex-orphan@@project-kaisola'
  const entry = {
    sender: { id: 91, isDestroyed: () => true },
    meta: {
      key: targetId,
      presetId: 'codex',
      scope: 'project-kaisola',
      name: 'Codex',
      sessionId: 'session-codex',
    },
    current: { actorId: null, turnId: null },
    inFlightTurns: 0,
    conn: { alive: true },
  }
  const pendingPermissions = new Map()
  const acpSessionService = new AcpSessionService({
    connections: new Map([[`91|${targetId}`, entry]]),
    pendingPermissions,
    permissionTimeoutMs: 5_000,
  })
  const { hello, publish, session, transport } = setup({ acpSessionService })
  publish()
  await transport.sendFromDevice(hello())
  transport.receiveForDevice()
  assert.equal(session.stats().acpSubscriptions, 1)

  const keptAlive = acpSessionService.requestPermission(entry, {
    agent: 'Codex',
    key: targetId,
    toolCall: { title: 'Run tests', kind: 'execute', content: [] },
    options: [
      { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
      { optionId: 'reject', name: 'Reject', kind: 'reject_once' },
    ],
  })
  assert.equal(pendingPermissions.size, 1)

  session.close('companion-disconnected')
  assert.equal(session.stats().acpSubscriptions, 0)
  assert.equal(acpSessionService.cancelPendingFor(entry, 'test_cleanup'), 1)
  assert.equal(await keptAlive, 'cancel')
  assert.equal(await acpSessionService.requestPermission(entry, {
    agent: 'Codex',
    key: targetId,
    toolCall: { title: 'Run tests', kind: 'execute', content: [] },
    options: [{ optionId: 'reject', name: 'Reject', kind: 'reject_once' }],
  }), 'cancel')
  acpSessionService.dispose()
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
