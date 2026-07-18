const test = require('node:test')
const assert = require('node:assert/strict')
const { AttentionService, STORE_KEY } = require('./ipc/attentionService.cjs')
const { boundedCount, exactId, safeNotice, registerAttentionHandlers } = require('./ipc/attentionHandler.cjs')

function handlerHarness() {
  const listeners = new Map()
  const handles = new Map()
  const destroyed = []
  const sent = []
  const badges = []
  const storage = new Map()
  let senderDestroyed = false
  const sender = {
    id: 7_001,
    isDestroyed: () => senderDestroyed,
    once: (name, callback) => { if (name === 'destroyed') destroyed.push(callback) },
    send: (channel, payload) => sent.push({ channel, payload }),
  }
  const owner = {
    __kaisolaSavedId: 'saved-primary',
    __kaisolaPop: false,
    webContents: sender,
    isDestroyed: () => false,
    isFocused: () => false,
    isMinimized: () => false,
    show: () => {},
    focus: () => {},
    restore: () => {},
  }
  const BrowserWindow = {
    fromWebContents: (value) => value === sender ? owner : null,
    getAllWindows: () => [owner],
    getFocusedWindow: () => null,
  }
  const service = new AttentionService({
    get: (key) => storage.get(key) ?? null,
    set: (key, value) => storage.set(key, value),
    now: () => 1_784_250_000_000,
  })
  const dispose = registerAttentionHandlers({
    on: (channel, callback) => listeners.set(channel, callback),
    handle: (channel, callback) => handles.set(channel, callback),
  }, {
    app: { dock: { setBadge: (value) => badges.push(value), bounce: () => {} } },
    BrowserWindow,
    Notification: { isSupported: () => false },
    service,
    platform: 'darwin',
  })
  const event = { sender }
  return {
    badges,
    destroy: () => { senderDestroyed = true; for (const callback of destroyed) callback() },
    dispose,
    invoke: (channel, payload) => listeners.get(channel)?.(event, payload),
    sent,
    service,
    storage,
  }
}

test('native attention counts are finite non-negative dock badge values', () => {
  assert.equal(boundedCount(-2), 0)
  assert.equal(boundedCount(4.9), 4)
  assert.equal(boundedCount('12'), 12)
  assert.equal(boundedCount(Infinity), 0)
  assert.equal(boundedCount(5_000), 999)
})

test('native notification payloads are bounded and carry safe navigation ids', () => {
  assert.equal(safeNotice(null), null)
  assert.equal(safeNotice({ title: '   ' }), null)
  assert.deepEqual(safeNotice({
    title: ' Codex finished ',
    body: 'Ready to review',
    projectId: 'project-1',
    sessionId: 'thread-1',
  }), {
    title: 'Codex finished',
    body: 'Ready to review',
    projectId: 'project-1',
    sessionId: 'thread-1',
  })
  assert.equal(exactId('project-exact', 160), 'project-exact')
  assert.equal(exactId(`p${'x'.repeat(160)}`, 160), undefined)
  assert.equal(exactId('project/rewritten', 160), undefined)
  assert.equal(safeNotice({ title: 'Done', projectId: `p${'x'.repeat(160)}` }).projectId, undefined)
})

test('dock badge counts only projects attached to live windows without clearing durable records', async () => {
  const h = handlerHarness()
  h.invoke('attention:surface', {
    projectId: 'project-live',
    projects: [{ projectId: 'project-live', alias: '/repo/live' }],
    visibleSessionIds: [],
    documentVisible: true,
    documentFocused: false,
  })
  h.service.raise({
    projectId: 'project-live',
    source: 'ledger',
    sourceId: 'live-review',
    kind: 'review',
    title: 'Review live project',
  })
  h.service.raise({
    projectId: 'project-closed',
    source: 'ledger',
    sourceId: 'closed-review',
    kind: 'review',
    title: 'Review closed project',
  })
  assert.equal(h.badges.at(-1), '1')
  assert.equal(h.service.activeEvents().length, 2)

  h.destroy()
  assert.equal(h.badges.at(-1), '')
  assert.equal(h.service.activeEvents().length, 2)
  await Promise.resolve()
  const persisted = JSON.parse(h.storage.get(STORE_KEY))
  assert.equal(persisted.records.filter((record) => record.status === 'active').length, 2)
  h.dispose()
})

test('renderer permission echoes never duplicate the authoritative record and resolution clears it everywhere', async () => {
  const h = handlerHarness()
  h.invoke('attention:surface', {
    projectId: 'project-a',
    projects: [{ projectId: 'project-a' }],
    visibleSessionIds: [],
    documentVisible: true,
    documentFocused: false,
  })
  const rendererNotice = {
    title: 'Codex needs you',
    body: 'Approve write?',
    projectId: 'project-a',
    sourceId: 'perm-only',
    kind: 'permission',
  }
  h.invoke('attention:notify', rendererNotice)
  assert.equal(h.service.stats().active, 0)

  h.service.handleAcpEvent({
    type: 'agent.permission.requested',
    projectId: 'project-a',
    targetId: 'codex@@project-a',
    attentionSessionId: 'session-a',
    permId: 'perm-only',
    agent: 'Codex',
    title: 'Approve write?',
  })
  h.invoke('attention:notify', rendererNotice)
  assert.equal(h.service.activeEvents().filter((event) => event.kind === 'permission').length, 1)

  h.service.handleAcpEvent({
    type: 'agent.permission.resolved',
    projectId: 'project-a',
    permId: 'perm-only',
    resolution: 'approved',
  })
  assert.equal(h.service.stats().active, 0)
  assert.equal(h.badges.at(-1), '')
  await Promise.resolve()
  const persisted = JSON.parse(h.storage.get(STORE_KEY))
  assert.equal(persisted.records.filter((record) => record.status === 'active').length, 0)
  h.dispose()
})
