'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const { AttentionService, createAttentionActorCapability } = require('./ipc/attentionService.cjs')
const { CompanionDesktopState } = require('./companion/desktopState.cjs')
const { CompanionGateway } = require('./companion/gateway.cjs')
const { LoopbackCompanionTransport } = require('./companion/loopbackTransport.cjs')
const { CompanionProjectionStore } = require('./companion/projectionStore.cjs')
const { CompanionStateHub } = require('./companion/stateHub.cjs')

function serviceHarness(options = {}) {
  let now = 1_784_250_000_000
  const storage = options.storage ?? new Map()
  const service = new AttentionService({
    get: (key) => storage.get(key) ?? null,
    set: (key, value) => storage.set(key, value),
    now: () => now,
    ...(options.bounds || {}),
  })
  return { service, storage, setNow: (value) => { now = value }, tick: (ms = 1) => { now += ms; return now } }
}

function completion(projectId, sessionId, turnId, ok = true) {
  return {
    type: 'agent.turn.completed',
    projectId,
    targetId: `codex::${sessionId}`,
    attentionSessionId: sessionId,
    turnId,
    agent: 'Codex',
    ok,
  }
}

function actor(projectId, id = 'device-phone') {
  return createAttentionActorCapability({ id, surface: 'companion', projectId, capabilities: ['observe'] })
}

function projection({ needsYou = true } = {}) {
  return {
    projectionKind: 'kaisola.companion.projection',
    revision: 1,
    generatedAt: 1_784_250_000_000,
    freshness: 'live',
    projects: [
      { id: 'project-a', name: 'A', connection: 'live', lastContactAt: 1_784_250_000_000 },
      { id: 'project-b', name: 'B', connection: 'live', lastContactAt: 1_784_250_000_000 },
    ],
    sessions: [
      { id: 'session-a', projectId: 'project-a', kind: 'agent', title: 'Codex A', status: needsYou ? 'waiting' : 'done', needsYou, unread: needsYou, updatedAt: 1_784_250_000_010 },
      { id: 'session-b', projectId: 'project-b', kind: 'terminal', title: 'Terminal B', status: 'running', needsYou: false, unread: false, updatedAt: 1_784_250_000_020 },
    ],
    attention: [
      { id: 'attention-task-review-1', projectId: 'project-a', kind: 'review', title: 'Review result', createdAt: 1_784_250_000_030, severity: 'info' },
    ],
    permissions: [
      { permId: 'perm-1', projectId: 'project-a', sessionId: 'session-a', agent: 'Codex', title: 'Write file?', requestedAt: 1_784_250_000_040, options: [], diffs: [] },
    ],
  }
}

test('focused visible sessions settle as seen while background project completions raise durable attention', () => {
  const { service, tick } = serviceHarness()
  const events = []
  service.subscribe((event) => events.push(event))
  service.updateSurface({
    windowId: 'saved-primary',
    focused: true,
    projectId: 'project-a',
    visibleSessionIds: ['session-a'],
    projects: [{ projectId: 'project-a', alias: '/repo/a' }, { projectId: 'project-b', alias: '/repo/b' }],
  })

  const visible = service.handleAcpEvent(completion('project-a', 'session-a', 'turn-a'))
  assert.equal(visible.observed, true)
  assert.equal(visible.active, false)
  tick()
  const background = service.handleAcpEvent(completion('project-b', 'session-b', 'turn-b'))
  assert.equal(background.active, true)
  assert.deepEqual(service.activeEvents().map(({ projectId }) => projectId), ['project-b'])
  assert.deepEqual(events.map(({ type, projectId }) => ({ type, projectId })), [
    { type: 'attention.raised', projectId: 'project-b' },
  ])

  const board = service.boardState()
  assert.equal(board.sessions.find((session) => session.id === 'session-a').status, 'done')
  assert.equal(board.sessions.find((session) => session.id === 'session-b').needsYou, true)
})

test('two windows acknowledge only the exact visible project and survive a renderer swap', () => {
  const { service, tick } = serviceHarness()
  service.updateSurface({ windowId: 'saved-a', focused: true, projectId: 'project-a', visibleSessionIds: [] })
  service.updateSurface({ windowId: 'saved-b', focused: false, projectId: 'project-b', visibleSessionIds: ['session-b'] })
  const b = service.handleAcpEvent(completion('project-b', 'session-b', 'turn-b'))
  tick()
  const a = service.handleAcpEvent(completion('project-a', 'session-a', 'turn-a'))
  assert.equal(service.stats().active, 2)

  service.removeSurface('saved-b')
  assert.equal(service.stats().active, 2, 'destroying a renderer does not acknowledge its events')
  const rendererProjection = projection({ needsYou: false })
  service.synchronizeProjections([{ windowId: 'saved-b', projection: {
    ...rendererProjection,
    projects: rendererProjection.projects.filter((project) => project.id === 'project-b'),
    sessions: rendererProjection.sessions
      .filter((session) => session.projectId === 'project-b')
      .map((session) => ({ ...session, status: 'waiting', needsYou: true, unread: true })),
    attention: [],
    permissions: [],
  } }])
  service.synchronizeProjections([])
  assert.equal(service.activeEvents('project-b').length, 1, 'removing the renderer projection does not acknowledge attention')
  service.updateSurface({ windowId: 'saved-b', focused: true, projectId: 'project-b', visibleSessionIds: ['session-b'] })
  assert.equal(service.activeEvents('project-b').length, 0)
  assert.deepEqual(service.activeEvents().map(({ id }) => id), [a.event.id])
  assert.notEqual(a.event.id, b.event.id)
})

test('duplicate terminal completion and renderer notice share one event id and one raised event', () => {
  const { service } = serviceHarness()
  const emitted = []
  service.subscribe((event) => emitted.push(event))
  const terminal = {
    projectId: 'project-a',
    sessionId: 'terminal-a',
    completedAt: 1_784_250_000_100,
    streamEpoch: 'stream-a',
    offset: 42,
    title: 'Codex terminal',
  }
  const first = service.handleTerminalEvent(terminal)
  const duplicate = service.handleTerminalEvent(terminal)
  const renderer = service.raise({
    projectId: 'project-a',
    sessionId: 'terminal-a',
    source: 'renderer-notice',
    sourceId: 'terminal:terminal-a:1784250000100',
    kind: 'completed',
    title: 'Codex finished',
    coalesceTarget: true,
  })
  assert.equal(duplicate.duplicate, true)
  assert.equal(renderer.duplicate, true)
  assert.equal(first.event.id, duplicate.event.id)
  assert.equal(first.event.id, renderer.event.id)
  assert.equal(service.stats().active, 1)
  assert.equal(emitted.filter((event) => event.type === 'attention.raised' && event.updated !== true).length, 1)
})

test('renderer completion arriving before the main source still coalesces to one event', () => {
  const { service } = serviceHarness()
  const emitted = []
  service.subscribe((event) => emitted.push(event))
  const renderer = service.raise({
    projectId: 'project-a',
    sessionId: 'terminal-a',
    source: 'renderer-notice',
    sourceId: 'terminal:terminal-a:1784250000100',
    kind: 'completed',
    title: 'Codex finished',
    coalesceTarget: true,
  })
  const main = service.handleTerminalEvent({
    projectId: 'project-a',
    sessionId: 'terminal-a',
    completedAt: 1_784_250_000_100,
    streamEpoch: 'stream-a',
    offset: 42,
    title: 'Codex terminal',
  })
  assert.equal(main.duplicate, true)
  assert.equal(main.event.id, renderer.event.id)
  assert.equal(service.stats().active, 1)
  assert.equal(emitted.filter((event) => event.type === 'attention.raised' && event.updated !== true).length, 1)
})

test('completion notices retain the exact projected session title and provider', () => {
  const { service, tick } = serviceHarness()
  const exactProjection = projection({ needsYou: false })
  exactProjection.sessions = [
    { id: 'terminal-codex', projectId: 'project-a', kind: 'terminal', title: 'Kaisola — Codex review', provider: 'Codex', status: 'running', needsYou: false, unread: false, updatedAt: tick() },
    { id: 'agent-claude', projectId: 'project-a', kind: 'agent', title: 'Fix companion reconnect', provider: 'Claude', status: 'running', needsYou: false, unread: false, updatedAt: tick() },
  ]
  exactProjection.attention = []
  exactProjection.permissions = []
  service.synchronizeProjections([{ windowId: 'saved-primary', projection: exactProjection }])

  const terminal = service.handleTerminalEvent({
    projectId: 'project-a',
    sessionId: 'terminal-codex',
    completedAt: tick(),
    streamEpoch: 'stream-title',
    offset: 99,
  })
  const agent = service.handleAcpEvent({
    type: 'agent.turn.completed',
    projectId: 'project-a',
    attentionSessionId: 'agent-claude',
    targetId: 'claude::agent-claude',
    turnId: 'turn-title',
    ok: true,
  })

  assert.equal(terminal.event.title, 'Kaisola — Codex review finished')
  assert.equal(terminal.event.detail, 'Codex terminal')
  assert.equal(agent.event.title, 'Fix companion reconnect finished')
  assert.equal(agent.event.detail, 'Claude')
})

test('permission projection dedupes the main event and resolution clears its canonical session', () => {
  const { service } = serviceHarness()
  const requested = service.handleAcpEvent({
    type: 'agent.permission.requested',
    projectId: 'project-a',
    targetId: 'codex::child-session',
    sessionId: 'provider-session',
    attentionSessionId: 'parent-session',
    permId: 'perm-1',
    agent: 'Codex',
    title: 'Approve write?',
  })
  assert.equal(service.boardState().projects.find((project) => project.projectId === 'project-a').needsYou, 1)
  service.synchronizeProjections([{ windowId: 'saved-primary', projection: projection() }])
  const permissions = service.activeEvents('project-a').filter((event) => event.kind === 'permission')
  assert.equal(permissions.length, 1)
  assert.equal(permissions[0].id, requested.event.id)
  assert.equal(permissions[0].sessionId, 'parent-session')

  service.handleAcpEvent({
    type: 'agent.permission.resolved',
    projectId: 'project-a',
    permId: 'perm-1',
    resolution: 'approved',
  })
  service.synchronizeProjections([{ windowId: 'saved-primary', projection: projection() }])
  assert.equal(service.activeEvents('project-a').some((event) => event.kind === 'permission'), false)
})

test('user cancels stay quiet, real failures raise, and ledger review or blocked occurrences replace and resolve exactly', () => {
  const { service, tick } = serviceHarness()
  // A user-initiated Stop (ok:true + stopReason 'cancelled') is deliberate:
  // the session leaves 'running' but no needs-you attention is raised.
  const cancelled = service.handleAcpEvent({ ...completion('project-a', 'session-a', 'turn-cancelled'), stopReason: 'cancelled' })
  assert.equal(cancelled, null)
  assert.equal(service.boardState().sessions.find((session) => session.id === 'session-a')?.status, 'done')
  const failed = service.handleAcpEvent(completion('project-a', 'session-a', 'turn-failed', false))
  assert.equal(failed.event.kind, 'failed')

  const reviewAt = tick()
  const review = service.handleLedgerEvent({
    task: { id: 'task-1', projectId: 'project-a', status: 'review', title: 'Review result', updatedAt: reviewAt },
  })
  assert.equal(review.event.kind, 'review')
  const blockedAt = tick()
  const blocked = service.handleLedgerEvent({
    task: { id: 'task-1', projectId: 'project-a', status: 'blocked', title: 'Need input', updatedAt: blockedAt },
  })
  assert.equal(blocked.event.kind, 'blocked')
  assert.equal(service.activeEvents('project-a').some((event) => event.id === review.event.id), false)
  const duplicate = service.handleLedgerEvent({
    task: { id: 'task-1', projectId: 'project-a', status: 'blocked', title: 'Need input', updatedAt: blockedAt },
  })
  assert.equal(duplicate.duplicate, true)

  service.handleLedgerEvent({
    task: { id: 'task-1', projectId: 'project-a', status: 'done', title: 'Resolved', updatedAt: tick() },
  })
  assert.equal(service.activeEvents('project-a').some((event) => event.kind === 'review' || event.kind === 'blocked'), false)
  assert.equal(service.activeEvents('project-a').some((event) => event.id === failed.event.id), true)
})

test('phone acknowledgement is exact, project-scoped, and stable when desktop follows', () => {
  const { service, tick } = serviceHarness()
  const a = service.handleAcpEvent(completion('project-a', 'session-a', 'turn-a'))
  tick()
  const b = service.handleAcpEvent(completion('project-b', 'session-b', 'turn-b'))

  const wrongProject = service.acknowledge(actor('project-a'), { projectId: 'project-a', eventId: b.event.id })
  assert.equal(wrongProject.status, 'rejected')
  assert.equal(service.stats().active, 2)

  const phone = service.acknowledge(actor('project-a'), { projectId: 'project-a', eventId: a.event.id })
  assert.equal(phone.status, 'applied')
  const desktop = service.acknowledge(
    createAttentionActorCapability({ id: 'desktop-saved-a', surface: 'desktop', projectId: 'project-a', capabilities: ['observe'] }),
    { projectId: 'project-a', eventId: a.event.id },
  )
  assert.equal(desktop.status, 'stale')
  assert.deepEqual(service.activeEvents().map(({ id }) => id), [b.event.id])
})

test('persisted projection rebuilds attention after restart without resurrecting acknowledged events', async () => {
  const first = serviceHarness()
  const records = [{ windowId: 'saved-primary', projection: { ...projection(), permissions: [] } }]
  first.service.synchronizeProjections(records)
  const initial = first.service.activeEvents()
  assert.equal(initial.length, 2)
  const sessionEvent = initial.find((event) => event.sessionId === 'session-a' && event.kind === 'completed')
  assert.ok(sessionEvent)
  await Promise.resolve()

  const restarted = serviceHarness({ storage: first.storage })
  assert.deepEqual(restarted.service.activeEvents().map(({ id }) => id).sort(), initial.map(({ id }) => id).sort())
  restarted.service.synchronizeProjections(records)
  assert.equal(restarted.service.stats().active, 2)
  assert.equal(restarted.service.acknowledge(actor('project-a'), { projectId: 'project-a', eventId: sessionEvent.id }).status, 'applied')
  await Promise.resolve()

  const afterAckRestart = serviceHarness({ storage: first.storage })
  afterAckRestart.service.synchronizeProjections(records)
  assert.equal(afterAckRestart.service.activeEvents().some(({ id }) => id === sessionEvent.id), false)
  assert.equal(afterAckRestart.service.stats().active, 1)
})

test('attention persistence coalesces synchronous bursts and projection sync returns no discarded board clone', async () => {
  const storage = new Map()
  const writes = []
  let now = 1_784_250_000_000
  const service = new AttentionService({
    get: (key) => storage.get(key) ?? null,
    set: (key, value) => { writes.push({ key, value }); storage.set(key, value) },
    now: () => ++now,
  })
  const syncResult = service.synchronizeProjections([{ windowId: 'saved-primary', projection: projection() }])
  assert.equal(syncResult.ok, true)
  assert.equal(Object.hasOwn(syncResult, 'projects'), false)
  assert.equal(Object.hasOwn(syncResult, 'attention'), false)
  for (let index = 0; index < 20; index++) {
    service.handleTerminalEvent({
      projectId: 'project-a',
      sessionId: `terminal-burst-${index}`,
      completedAt: ++now,
      streamEpoch: `stream-${index}`,
      offset: index,
    })
  }
  assert.equal(writes.length, 0)
  await Promise.resolve()
  assert.equal(writes.length, 1)

  service.handleAcpEvent(completion('project-a', 'session-after-flush', 'turn-after-flush'))
  service.handleAcpEvent(completion('project-a', 'session-after-flush-2', 'turn-after-flush-2'))
  assert.equal(writes.length, 1)
  await Promise.resolve()
  assert.equal(writes.length, 2)
})

test('attention records, active events, and future board session state remain bounded', () => {
  const { service, tick } = serviceHarness({ bounds: { maxRecords: 6, maxActive: 3, maxSessions: 4, retentionMs: 60_000 } })
  for (let i = 0; i < 20; i++) {
    service.handleTerminalEvent({ projectId: 'project-a', sessionId: `terminal-${i}`, completedAt: tick(), streamEpoch: `stream-${i}`, offset: i })
  }
  const stats = service.stats()
  assert.ok(stats.records <= 6)
  assert.ok(stats.active <= 3)
  assert.ok(stats.sessions <= 4)
  assert.ok(service.boardState().sessions.length <= 4)
})

test('observe-only gateway delivers raised/cleared events and requires exact project plus event id', async () => {
  let now = 1_784_250_001_000
  const storage = new Map()
  const attentionService = new AttentionService({
    get: (key) => storage.get(key) ?? null,
    set: (key, value) => storage.set(key, value),
    now: () => now,
  })
  const projectionRecords = new Map()
  const projectionStore = new CompanionProjectionStore({
    epoch: 'desktop-epoch-7',
    get: (key) => projectionRecords.get(key) ?? null,
    set: (key, value) => projectionRecords.set(key, value),
    del: (key) => projectionRecords.delete(key),
    keys: () => [...projectionRecords.keys()],
    now: () => now,
  })
  const desktopState = new CompanionDesktopState({ epoch: 'desktop-epoch-7', projectionStore, attentionService, now: () => now })
  const gatewayProjection = { ...projection({ needsYou: false }), attention: [], permissions: [] }
  const published = projectionStore.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: gatewayProjection })
  desktopState.projectionPublished('saved-primary', published)
  const stateHub = new CompanionStateHub({ desktopState })
  const gateway = new CompanionGateway({ desktopId: 'desktop-main', epoch: 'desktop-epoch-7', stateHub, now: () => now })
  const transport = new LoopbackCompanionTransport()
  gateway.attach(transport, { deviceId: 'device-phone', capabilities: ['observe'] })
  const hello = {
    v: 1,
    kind: 'hello',
    desktopId: 'desktop-main',
    deviceId: 'device-phone',
    connectionId: 'connection-phone',
    epoch: 'desktop-epoch-7',
    seq: 0,
    id: 'hello-phone',
    sentAt: now,
    body: { type: 'hello', role: 'device', protocolMinor: 0, capabilities: ['observe'] },
  }
  await transport.sendFromDevice(hello)
  transport.receiveForDevice()

  const raised = attentionService.raise({
    projectId: 'project-a',
    sessionId: 'session-a',
    source: 'agent-turn',
    sourceId: 'codex:turn-live',
    kind: 'completed',
    title: 'Codex finished',
  })
  await Promise.resolve()
  let frames = transport.receiveForDevice()
  assert.deepEqual(frames.map((frame) => frame.body.type), ['attention.raised'])
  assert.equal(frames[0].body.eventId, raised.event.id)

  const command = (commandId, projectId) => ({
    v: 1,
    kind: 'command',
    desktopId: 'desktop-main',
    deviceId: 'device-phone',
    connectionId: 'connection-phone',
    epoch: 'desktop-epoch-7',
    seq: 1,
    id: commandId,
    sentAt: ++now,
    body: {
      type: 'attention.ack',
      commandId,
      projectId,
      targetId: raised.event.id,
      capability: 'observe',
      payload: {},
    },
  })
  const rejected = await transport.sendFromDevice(command('command-wrong-project', 'project-b'))
  assert.equal(rejected.status, 'rejected')
  transport.receiveForDevice()
  assert.equal(attentionService.stats().active, 1)

  const applied = await transport.sendFromDevice(command('command-exact-event', 'project-a'))
  assert.equal(applied.status, 'applied')
  await Promise.resolve()
  frames = transport.receiveForDevice()
  assert.deepEqual(frames.map((frame) => frame.kind).sort(), ['event', 'receipt'])
  const cleared = frames.find((frame) => frame.kind === 'event')
  assert.equal(cleared.body.type, 'attention.cleared')
  assert.equal(cleared.body.eventId, raised.event.id)
  assert.equal(attentionService.stats().active, 0)
})
