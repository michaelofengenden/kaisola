'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  JOURNAL_KEY,
  abortProjectTransfer,
  finishProjectTransfer,
  markProjectTransferCommitted,
  parseJournal,
  prepareProjectTransfer,
  recoverProjectTransfers,
  removeProjectFromStoreRaw,
} = require('./ipc/projectTransferJournal.cjs')
const { MANIFEST_KEY, OPEN_AT_QUIT, serializeManifest } = require('./ipc/windowManifestPolicy.cjs')
const { projectionStoreKey } = require('./companion/projectionStore.cjs')

const envelope = (active, ids) => JSON.stringify({
  state: {
    projectTabs: ids.map((id) => ({ id, workspacePath: `/${id}`, createdAt: 1 })),
    activeProjectId: active,
    projectSlices: Object.fromEntries(ids.map((id) => [id, { workspacePath: `/${id}` }])),
  },
  version: 13,
})

const memoryDb = (seed = {}) => {
  const values = new Map(Object.entries(seed))
  return {
    get: (key) => values.get(key) ?? null,
    mutate: ({ set = {}, delete: deleted = [] }) => {
      for (const [key, value] of Object.entries(set)) values.set(key, value)
      for (const key of deleted) values.delete(key)
    },
    values,
  }
}

test('recovery removal preserves neighboring projects and elects the right neighbor', () => {
  const result = JSON.parse(removeProjectFromStoreRaw(envelope('b', ['a', 'b', 'c']), 'b', 'transfer-1'))
  assert.deepEqual(result.state.projectTabs.map((tab) => tab.id), ['a', 'c'])
  assert.equal(result.state.activeProjectId, 'c')
  assert.deepEqual(Object.keys(result.state.projectSlices).sort(), ['a', 'c'])
})

test('prepared transfer recovery restores the destination preimage', () => {
  const source = envelope('move', ['stay', 'move'])
  const target = envelope('target', ['target'])
  const db = memoryDb({
    'kaisola-store': source,
    'kaisola-store-w2': target,
    [MANIFEST_KEY]: serializeManifest([
      { slot: null, state: OPEN_AT_QUIT, updatedAt: 1 },
      { slot: 2, state: OPEN_AT_QUIT, updatedAt: 2 },
    ]),
  })
  prepareProjectTransfer({
    ...db,
    transferId: 'transfer-2',
    projectId: 'move',
    sourceSlot: null,
    targetSlot: 2,
    targetKind: 'existing',
    closeSource: false,
  })
  db.values.set('kaisola-store-w2', envelope('move', ['target', 'move']))
  const recovered = recoverProjectTransfers({ ...db, manifestKey: MANIFEST_KEY, projectionKey: projectionStoreKey })
  assert.equal(recovered.recovered, 1)
  assert.equal(db.values.get('kaisola-store-w2'), target)
  assert.equal(db.values.get('kaisola-store'), source)
  assert.equal(db.values.has(JOURNAL_KEY), false)
})

test('aborting a prepared transfer restores the destination immediately', () => {
  const target = envelope('target', ['target'])
  const db = memoryDb({
    'kaisola-store': envelope('move', ['move']),
    'kaisola-store-w2': target,
  })
  prepareProjectTransfer({
    ...db,
    transferId: 'transfer-abort',
    projectId: 'move',
    sourceSlot: null,
    targetSlot: 2,
    targetKind: 'existing',
    closeSource: false,
  })
  db.values.set('kaisola-store-w2', envelope('move', ['target', 'move']))
  const result = abortProjectTransfer({ ...db, transferId: 'transfer-abort', manifestKey: MANIFEST_KEY, projectionKey: projectionStoreKey })
  assert.equal(result.ok, true)
  assert.equal(db.values.get('kaisola-store-w2'), target)
  assert.equal(db.values.has(JOURNAL_KEY), false)
})

test('committed transfer recovery removes only the source project', () => {
  const db = memoryDb({
    'kaisola-store': envelope('move', ['stay', 'move']),
    'kaisola-store-w2': envelope('target', ['target']),
  })
  prepareProjectTransfer({
    ...db,
    transferId: 'transfer-3',
    projectId: 'move',
    sourceSlot: null,
    targetSlot: 2,
    targetKind: 'existing',
    closeSource: false,
  })
  markProjectTransferCommitted({ ...db, transferId: 'transfer-3' })
  db.values.set('kaisola-store-w2', envelope('move', ['target', 'move']))
  recoverProjectTransfers({ ...db, manifestKey: MANIFEST_KEY, projectionKey: projectionStoreKey })
  const source = JSON.parse(db.values.get('kaisola-store'))
  assert.deepEqual(source.state.projectTabs.map((tab) => tab.id), ['stay'])
  assert.equal(source.state.activeProjectId, 'stay')
  assert.deepEqual(JSON.parse(db.values.get('kaisola-store-w2')).state.projectTabs.map((tab) => tab.id), ['target', 'move'])
})

test('finishing a recombination deletes the throwaway source slot and manifest entry', () => {
  const db = memoryDb({
    'kaisola-store': envelope('target', ['target']),
    'kaisola-store-w2': envelope('move', ['move']),
    [MANIFEST_KEY]: serializeManifest([
      { slot: null, state: OPEN_AT_QUIT, updatedAt: 1 },
      { slot: 2, state: OPEN_AT_QUIT, updatedAt: 2 },
    ]),
  })
  prepareProjectTransfer({
    ...db,
    transferId: 'transfer-4',
    projectId: 'move',
    sourceSlot: 2,
    targetSlot: null,
    targetKind: 'existing',
    closeSource: true,
  })
  markProjectTransferCommitted({ ...db, transferId: 'transfer-4' })
  const result = finishProjectTransfer({ ...db, transferId: 'transfer-4', manifestKey: MANIFEST_KEY, projectionKey: projectionStoreKey })
  assert.equal(result.ok, true)
  assert.equal(db.values.has('kaisola-store-w2'), false)
  assert.deepEqual(result.manifest.map((entry) => entry.id), ['primary'])
  assert.equal(parseJournal(db.values.get(JOURNAL_KEY)).length, 0)
})
