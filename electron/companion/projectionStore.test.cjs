'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { CompanionProjectionStore, projectionStoreKey } = require('./projectionStore.cjs')

const golden = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'snapshot-board.json'), 'utf8')).body.projection

function memoryStorage() {
  const records = new Map()
  return {
    records,
    get: (key) => records.get(key) ?? null,
    set: (key, value) => records.set(key, value),
    del: (key) => records.delete(key),
    keys: () => [...records.keys()],
  }
}

test('publishes a validated live projection under an isolated window key', () => {
  const storage = memoryStorage()
  const store = new CompanionProjectionStore({ epoch: 'desktop-epoch-current', ...storage, now: () => 500 })
  const result = store.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: golden })
  assert.equal(result.ok, true)
  assert.equal(result.projection.generatedAt, 500)
  assert.equal(result.projection.freshness, 'live')
  assert.equal(storage.records.has(projectionStoreKey('saved-primary')), true)
  assert.equal(store.load('saved-primary').projection.board.columns[1].title, 'Needs You')
})

test('persisted projections are stale until republished in the current desktop epoch', () => {
  const storage = memoryStorage()
  const prior = new CompanionProjectionStore({ epoch: 'desktop-epoch-old', ...storage, now: () => 100 })
  prior.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: golden })

  const current = new CompanionProjectionStore({ epoch: 'desktop-epoch-new', ...storage, now: () => 200 })
  assert.equal(current.load('saved-primary').projection.freshness, 'stale')
  current.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: { ...golden, revision: golden.revision + 1 } })
  assert.equal(current.load('saved-primary').projection.freshness, 'live')
})

test('publisher generations fence a retiring renderer during a window swap', () => {
  const storage = memoryStorage()
  const store = new CompanionProjectionStore({ epoch: 'desktop-epoch-current', ...storage, now: () => 500 })
  store.publish({ windowId: 'saved-primary', publisherGeneration: 4, projection: golden })
  store.publish({ windowId: 'saved-primary', publisherGeneration: 5, projection: { ...golden, revision: 1 } })
  const stale = store.publish({ windowId: 'saved-primary', publisherGeneration: 4, projection: { ...golden, revision: 99 } })
  assert.deepEqual(stale, { ok: false, stale: true, reason: 'stale_publisher', revision: 1 })
  assert.equal(store.load('saved-primary').publisherGeneration, 5)
})

test('a closed or reloading renderer becomes stale without fencing its replacement', () => {
  const storage = memoryStorage()
  const store = new CompanionProjectionStore({ epoch: 'desktop-epoch-current', ...storage, now: () => 500 })
  store.publish({ windowId: 'saved-primary', publisherGeneration: 4, projection: golden })
  assert.equal(store.markStale('saved-primary', 3), false)
  assert.equal(store.markStale('saved-primary', 4), true)
  assert.equal(store.load('saved-primary').projection.freshness, 'stale')
  store.publish({ windowId: 'saved-primary', publisherGeneration: 5, projection: { ...golden, revision: 1 } })
  assert.equal(store.load('saved-primary').projection.freshness, 'live')
  assert.equal(store.markStale('saved-primary', 4), false)
})

test('same-publisher revisions are monotonic and duplicate pagehide flushes are idempotent', () => {
  const storage = memoryStorage()
  const store = new CompanionProjectionStore({ epoch: 'desktop-epoch-current', ...storage, now: () => 500 })
  store.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: golden })
  assert.deepEqual(
    store.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: golden }),
    { ok: true, duplicate: true, stale: false, revision: golden.revision },
  )
  const stale = store.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: { ...golden, revision: 1 } })
  assert.equal(stale.stale, true)
  assert.equal(store.load('saved-primary').projection.revision, golden.revision)
})

test('multi-window records remain isolated and malformed records fail closed', () => {
  const storage = memoryStorage()
  const store = new CompanionProjectionStore({ epoch: 'desktop-epoch-current', ...storage, now: () => 500 })
  store.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: golden })
  store.publish({ windowId: 'saved-window-2', publisherGeneration: 2, projection: { ...golden, revision: 20 } })
  storage.records.set(projectionStoreKey('saved-corrupt'), '{')
  assert.deepEqual(store.list().map(({ windowId }) => windowId), ['saved-primary', 'saved-window-2'])
  assert.equal(store.load('saved-corrupt'), null)
  store.delete('saved-window-2')
  assert.equal(store.load('saved-window-2'), null)
  assert.equal(store.load('saved-primary').projection.revision, golden.revision)
})

test('raw renderer stores and forbidden keys never reach persistence', () => {
  const storage = memoryStorage()
  const store = new CompanionProjectionStore({ epoch: 'desktop-epoch-current', ...storage, now: () => 500 })
  assert.throws(
    () => store.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: { projectTabs: [], workspacePath: '/secret' } }),
    /normalized companion projection/,
  )
  assert.equal(storage.records.size, 0)
})
