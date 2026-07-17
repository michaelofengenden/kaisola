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

function setup({ queueBytes } = {}) {
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
  const desktopState = new CompanionDesktopState({ epoch: 'desktop-epoch-7', projectionStore, now: () => now })
  const stateHub = new CompanionStateHub({ desktopState })
  const gateway = new CompanionGateway({
    desktopId: 'desktop-michael-mac',
    epoch: 'desktop-epoch-7',
    stateHub,
    now: () => now,
  })
  const transport = new LoopbackCompanionTransport({ ...(queueBytes ? { maxQueueBytes: queueBytes } : {}) })
  const session = gateway.attach(transport, { deviceId: 'device-michael-iphone', capabilities: ['observe'] })
  const hello = ({ lastAck } = {}) => ({
    v: 1,
    kind: 'hello',
    desktopId: 'desktop-michael-mac',
    deviceId: 'device-michael-iphone',
    connectionId: `connection-${lastAck ?? 'new'}`,
    epoch: 'desktop-epoch-7',
    seq: 0,
    id: `hello-${lastAck ?? 'new'}`,
    sentAt: now,
    body: { type: 'hello', role: 'device', protocolMinor: 0, capabilities: ['observe'], ...(lastAck == null ? {} : { lastAck }) },
  })
  const publish = (projection = fixture) => {
    const result = projectionStore.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection })
    desktopState.projectionPublished('saved-primary', result)
    return result
  }
  return { desktopState, gateway, hello, publish, session, stateHub, transport, setNow: (value) => { now = value } }
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
