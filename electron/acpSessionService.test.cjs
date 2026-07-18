'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  AcpSessionService,
  createAcpActorCapability,
  PERMISSION_COMPLETENESS,
} = require('./ipc/acpSessionService.cjs')

const PROJECT = 'project-alpha'
const TARGET = `codex::thread-1@@${PROJECT}`
const SESSION = 'session-alpha'

function desktop(projectId = PROJECT, ownerId = '41') {
  return createAcpActorCapability({
    id: `desktop-${ownerId}`,
    surface: 'desktop',
    projectId,
    ownerId,
    capabilities: ['observe', 'agent-control'],
  })
}

function companion(projectId = PROJECT, id = 'phone-1', capabilities = ['observe', 'agent-control']) {
  return createAcpActorCapability({ id, surface: 'companion', projectId, capabilities })
}

function makeEntry(overrides = {}) {
  const sender = overrides.sender ?? { id: 41, isDestroyed: () => false }
  return {
    sender,
    meta: { key: TARGET, presetId: 'codex', scope: PROJECT, name: 'Codex', sessionId: SESSION },
    controls: { modes: null, configOptions: [] },
    availableCommands: [],
    current: { actorId: null, turnId: null },
    inFlightTurns: 0,
    cancelRequested: false,
    conn: {
      alive: true,
      supportsPromptQueue: true,
      cancel() {},
      dispose() {},
      async setMode() {},
      async prompt() { return { stopReason: 'end_turn' } },
    },
    ...overrides,
  }
}

function harness({ entry = makeEntry(), permissionTimeoutMs = 5_000, hasDesktop = true, idFactory } = {}) {
  const connections = new Map([[`41|${TARGET}`, entry]])
  const pendingPermissions = new Map()
  const desktopEvents = []
  const service = new AcpSessionService({
    connections,
    pendingPermissions,
    permissionTimeoutMs,
    cancelGraceMs: 1_000,
    steerFlushMs: 20,
    hasDesktopSubscriber: () => hasDesktop,
    onDesktopEvent: (_entry, event) => desktopEvents.push(event),
    ...(idFactory ? { idFactory } : {}),
  })
  return { service, entry, connections, pendingPermissions, desktopEvents }
}

function permissionInput(overrides = {}) {
  return {
    key: TARGET,
    agent: 'Codex',
    sensitive: true,
    toolCall: {
      title: 'Edit a protected file',
      kind: 'edit',
      content: [{ type: 'diff', path: '/repo/.env.local', oldText: 'old', newText: 'new' }],
    },
    options: [
      { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
      { optionId: 'reject', name: 'Reject', kind: 'reject_once' },
    ],
    ...overrides,
  }
}

test('desktop and companion subscribers receive the same ordered turn stream', async () => {
  const h = harness()
  const phoneEvents = []
  const secondPhoneEvents = []
  h.service.subscribe(companion(), { targetId: SESSION, onEvent: (event) => phoneEvents.push(event) })
  h.service.subscribe(companion(PROJECT, 'phone-2', ['observe']), { targetId: TARGET, onEvent: (event) => secondPhoneEvents.push(event) })
  h.entry.conn.prompt = async (text) => {
    assert.equal(text, 'Ship the service')
    h.service.publishUpdate(h.entry, { sessionUpdate: 'agent_message_chunk', content: { text: 'one' } })
    h.service.publishUpdate(h.entry, { sessionUpdate: 'agent_message_chunk', content: { text: 'two' } })
    return { stopReason: 'end_turn' }
  }

  const result = await h.service.prompt(desktop(), {
    projectId: PROJECT,
    targetId: TARGET,
    turnId: 'turn-1',
    attentionSessionId: 'thread-visible-1',
    text: 'Ship the service',
  })

  assert.deepEqual(result, { ok: true, stopReason: 'end_turn' })
  assert.deepEqual(h.desktopEvents, phoneEvents)
  assert.deepEqual(phoneEvents, secondPhoneEvents)
  assert.deepEqual(phoneEvents.map((event) => event.type), [
    'agent.turn.delta',
    'agent.turn.delta',
    'agent.turn.completed',
  ])
  assert.equal(h.desktopEvents[0], phoneEvents[0])
  assert.deepEqual(phoneEvents.map((event) => event.turnId), ['turn-1', 'turn-1', 'turn-1'])
  assert.equal(phoneEvents[2].attentionSessionId, 'thread-visible-1')
  assert.deepEqual(h.entry.current, { actorId: null, turnId: null })
  assert.equal('sender' in h.entry.current, false)
  assert.deepEqual(h.service.sessionSummaries(companion(PROJECT, 'observer', ['observe']))[0], {
    projectId: PROJECT,
    targetId: TARGET,
    sessionId: SESSION,
    provider: 'codex',
    name: 'Codex',
    connected: true,
    busy: false,
    controls: h.entry.controls,
    availableCommands: [],
    canLoadSession: false,
    canResumeSession: false,
    promptImages: false,
    promptQueue: true,
  })
  assert.equal(h.service.connections, undefined)
  assert.equal(h.service.pendingPermissions, undefined)
})

test('steer shares the active renderer-neutral turn and preserves provider queue behavior', async () => {
  const h = harness()
  const events = []
  h.service.subscribe(companion(), { targetId: SESSION, onEvent: (event) => events.push(event) })
  let finishTurn
  let calls = 0
  h.entry.conn.prompt = (text) => {
    calls++
    if (calls === 1) return new Promise((resolve) => { finishTurn = resolve })
    assert.equal(text, 'Also add receipts')
    return Promise.resolve({ stopReason: 'queued' })
  }

  const prompt = h.service.prompt(desktop(), {
    projectId: PROJECT,
    targetId: TARGET,
    turnId: 'turn-steer',
    text: 'Start',
  })
  await Promise.resolve()
  h.service.publishUpdate(h.entry, { sessionUpdate: 'agent_message_chunk', content: { text: 'working' } })
  const steered = await h.service.steer(companion(), {
    projectId: PROJECT,
    targetId: SESSION,
    text: 'Also add receipts',
  })
  assert.deepEqual(steered, { ok: true, stopReason: 'queued' })
  finishTurn({ stopReason: 'end_turn' })
  assert.equal((await prompt).ok, true)
  assert.equal(calls, 2)
  assert.deepEqual(events.map((event) => event.type), ['agent.turn.delta', 'agent.turn.completed'])
  assert.ok(events.every((event) => event.turnId === 'turn-steer'))
})

test('permission payload, resolution, and replay receipt are shared and exactly once', async () => {
  const h = harness({ idFactory: () => 'permission-once' })
  const phoneEvents = []
  const phone = companion()
  let reentrantReplay
  h.service.subscribe(phone, {
    targetId: SESSION,
    onEvent: (event) => {
      phoneEvents.push(event)
      if (event.type === 'agent.permission.resolved') {
        reentrantReplay = h.service.respondPermission(phone, {
          projectId: PROJECT,
          targetId: SESSION,
          permId: event.permId,
          expectedRevision: event.revision,
          optionId: 'allow-once',
        })
      }
    },
  })
  const providerResult = h.service.requestPermission(h.entry, permissionInput())
  const requested = phoneEvents[0]

  assert.equal(requested.type, 'agent.permission.requested')
  assert.equal(requested.completeness, 'complete')
  assert.equal(requested.revision, 1)
  assert.equal(requested.projectId, PROJECT)
  assert.equal(requested.targetId, TARGET)
  assert.equal(requested.sessionId, SESSION)
  assert.equal(requested.diffs[0].path, '/repo/.env.local')
  assert.equal(requested.diffs[0].newText, 'new')
  assert.equal(requested.sensitive, true)
  assert.equal(Object.isFrozen(requested), true)
  assert.equal(Object.isFrozen(requested.diffs), true)
  assert.equal(h.pendingPermissions.get(requested.permId).displayPayload, requested)
  assert.equal(h.service.pendingPermissionEvents(companion(), { targetId: SESSION })[0], requested)
  assert.equal(Object.hasOwn(h.service.pendingPermissionEvents(companion())[0], 'resolve'), false)
  assert.equal(h.desktopEvents[0], requested)

  const invalid = h.service.respondPermission(companion(), {
    projectId: PROJECT,
    targetId: SESSION,
    permId: requested.permId,
    expectedRevision: requested.revision,
    optionId: 'not-advertised',
  })
  assert.equal(invalid.status, 'rejected')
  assert.equal(h.pendingPermissions.has(requested.permId), true)

  const wrongProject = h.service.respondPermission(companion('project-beta'), {
    projectId: 'project-beta',
    targetId: SESSION,
    permId: requested.permId,
    expectedRevision: requested.revision,
    optionId: 'allow-once',
  })
  assert.equal(wrongProject.status, 'rejected')
  assert.equal(h.pendingPermissions.has(requested.permId), true)

  const applied = h.service.respondPermission(companion(), {
    projectId: PROJECT,
    targetId: SESSION,
    permId: requested.permId,
    expectedRevision: requested.revision,
    optionId: 'allow-once',
  })
  assert.equal(applied.status, 'applied')
  assert.deepEqual(await providerResult, { optionId: 'allow-once' })
  assert.equal(h.pendingPermissions.has(requested.permId), false)
  assert.deepEqual(h.desktopEvents, phoneEvents)
  assert.equal(h.desktopEvents[1], phoneEvents[1])
  assert.deepEqual(phoneEvents[1], {
    type: 'agent.permission.resolved',
    projectId: PROJECT,
    targetId: TARGET,
    sessionId: SESSION,
    permId: requested.permId,
    revision: requested.revision,
    resolution: 'responded',
    actorId: 'phone-1',
  })

  const replayCommand = {
    projectId: PROJECT,
    targetId: SESSION,
    permId: requested.permId,
    expectedRevision: requested.revision,
    optionId: 'allow-once',
  }
  const replayOne = h.service.respondPermission(companion(), replayCommand)
  const replayTwo = h.service.respondPermission(companion(), replayCommand)
  assert.deepEqual(reentrantReplay, replayOne)
  assert.deepEqual(replayOne, replayTwo)
  assert.equal(replayOne.status, 'stale')
  assert.equal(replayOne.resolved, true)
  assert.equal(phoneEvents.length, 2)

  const staleRevision = h.service.respondPermission(companion(), { ...replayCommand, expectedRevision: requested.revision + 1 })
  assert.equal(staleRevision.status, 'stale')
  assert.equal(staleRevision.currentRevision, requested.revision)
})

test('every stored permission revision has an explicit immutable completeness state', async () => {
  const h = harness({ hasDesktop: false })
  const events = []
  h.service.subscribe(companion(PROJECT, 'phone-completeness'), { onEvent: (event) => events.push(event) })
  const inputs = [
    permissionInput(),
    permissionInput({ toolCall: { title: 'x'.repeat(700), kind: 'edit', content: [] } }),
    permissionInput({ toolCall: { title: 'Run command', kind: 'execute', content: [{ type: 'text', text: 'not displayable' }] } }),
    permissionInput({ toolCall: null }),
  ]
  const expected = ['complete', 'truncated', 'redacted', 'unavailable']

  for (let index = 0; index < inputs.length; index++) {
    const result = h.service.requestPermission(h.entry, inputs[index])
    const requested = events.at(-1)
    assert.equal(requested.completeness, expected[index])
    assert.ok(PERMISSION_COMPLETENESS.includes(requested.completeness))
    assert.equal(requested.revision, index + 1)
    assert.throws(() => { requested.completeness = 'complete' }, TypeError)
    const receipt = h.service.respondPermission(companion(PROJECT, 'phone-completeness'), {
      projectId: PROJECT,
      targetId: TARGET,
      permId: requested.permId,
      expectedRevision: requested.revision,
      decision: 'reject',
    })
    assert.equal(receipt.status, 'applied')
    assert.equal(await result, 'reject')
  }
})

test('agent death, timeout, and cancel fail closed and clear every surface', async () => {
  const h = harness({ permissionTimeoutMs: 15 })
  const phoneEvents = []
  h.service.subscribe(companion(), { targetId: TARGET, onEvent: (event) => phoneEvents.push(event) })

  const death = h.service.requestPermission(h.entry, permissionInput())
  const deathId = phoneEvents.at(-1).permId
  assert.equal(h.service.cancelPendingFor(h.entry, 'agent_exit'), 1)
  assert.equal(await death, 'cancel')
  assert.equal(phoneEvents.find((event) => event.permId === deathId && event.type === 'agent.permission.resolved').resolution, 'agent_exit')

  const timeout = h.service.requestPermission(h.entry, permissionInput())
  const timeoutId = phoneEvents.at(-1).permId
  assert.equal(await timeout, 'cancel')
  assert.equal(phoneEvents.find((event) => event.permId === timeoutId && event.type === 'agent.permission.resolved').resolution, 'timed_out')

  let cancelCalls = 0
  h.entry.conn.cancel = () => { cancelCalls++ }
  h.entry.current = { actorId: 'desktop-41', turnId: 'turn-cancel' }
  h.entry.inFlightTurns = 1
  const cancelled = h.service.requestPermission(h.entry, permissionInput())
  const cancelId = phoneEvents.at(-1).permId
  assert.deepEqual(h.service.cancel(desktop(), { projectId: PROJECT, targetId: TARGET }), { ok: true })
  assert.equal(await cancelled, 'cancel')
  assert.equal(cancelCalls, 1)
  assert.deepEqual(h.entry.current, { actorId: null, turnId: null })
  assert.equal(phoneEvents.find((event) => event.permId === cancelId && event.type === 'agent.permission.resolved').resolution, 'cancelled')
  h.entry.inFlightTurns = 0
  h.service.clearCancelWatchdog(h.entry)

  assert.deepEqual(h.desktopEvents, phoneEvents)
})

test('project capability mismatch fails before provider prompt, mode, or subscription', async () => {
  const h = harness()
  let prompts = 0
  let modes = 0
  h.entry.conn.prompt = async () => { prompts++; return {} }
  h.entry.conn.setMode = async () => { modes++ }
  const wrongProjectActor = companion('project-beta')

  const prompt = await h.service.prompt(wrongProjectActor, {
    projectId: 'project-beta',
    targetId: TARGET,
    turnId: 'turn-wrong-project',
    text: 'must not run',
  })
  const mode = await h.service.setMode(wrongProjectActor, {
    projectId: 'project-beta',
    targetId: TARGET,
    modeId: 'acceptEdits',
  })
  assert.equal(prompt.status, 'rejected')
  assert.equal(mode.status, 'rejected')
  assert.equal(prompts, 0)
  assert.equal(modes, 0)
  assert.throws(
    () => h.service.subscribe(wrongProjectActor, { targetId: TARGET, onEvent() {} }),
    /another project/,
  )
  assert.equal(Object.hasOwn(wrongProjectActor, 'ownerId'), false)
})
