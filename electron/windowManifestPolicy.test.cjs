const test = require('node:test')
const assert = require('node:assert/strict')
const {
  OPEN_AT_QUIT,
  PARKED,
  idForSlot,
  mostRecentParked,
  occupiedSlots,
  parseManifest,
  removeEntry,
  restoreCandidates,
  serializeManifest,
  slotFromStoreKey,
  storeKeysForSlot,
  upsertEntry,
} = require('./ipc/windowManifestPolicy.cjs')

test('manifest accepts only primary/numbered saved windows and two durable states', () => {
  const rows = parseManifest({
    version: 1,
    entries: [
      { id: 'forged', slot: null, state: OPEN_AT_QUIT, title: ' Primary ', updatedAt: 10 },
      { slot: 2, state: PARKED, title: ' Slot   two ', updatedAt: 20 },
      { slot: 1, state: PARKED, updatedAt: 30 },
      { slot: 3, state: 'deleted', updatedAt: 40 },
      { slot: 4, state: OPEN_AT_QUIT, bounds: { x: 2, y: 3, width: 1200, height: 800 }, maximized: true, updatedAt: 50 },
    ],
  })
  assert.deepEqual(rows, [
    { id: 'primary', slot: null, state: OPEN_AT_QUIT, updatedAt: 10, title: 'Primary' },
    { id: 'slot-2', slot: 2, state: PARKED, updatedAt: 20, title: 'Slot two' },
    { id: 'slot-4', slot: 4, state: OPEN_AT_QUIT, updatedAt: 50, bounds: { x: 2, y: 3, width: 1200, height: 800 }, maximized: true },
  ])
})

test('startup restoration is ordered and exactly once per saved id', () => {
  const manifest = parseManifest(JSON.stringify({
    version: 1,
    entries: [
      { slot: 3, state: OPEN_AT_QUIT, updatedAt: 3 },
      { slot: null, state: OPEN_AT_QUIT, updatedAt: 1 },
      { slot: 2, state: OPEN_AT_QUIT, updatedAt: 2 },
      { slot: 2, state: OPEN_AT_QUIT, updatedAt: 4 },
      { slot: 4, state: PARKED, updatedAt: 5 },
    ],
  }))
  assert.deepEqual(restoreCandidates(manifest, new Set(['slot-3'])).map((entry) => entry.id), ['primary', 'slot-2'])
  assert.deepEqual(restoreCandidates(manifest, new Set(['primary', 'slot-2', 'slot-3'])), [])
})

test('close parks, reopen marks open, and explicit deletion removes the entry', () => {
  let manifest = []
  manifest = upsertEntry(manifest, { slot: 2, state: OPEN_AT_QUIT, title: 'Research', updatedAt: 1 })
  manifest = upsertEntry(manifest, { slot: 2, state: PARKED, title: 'Research', updatedAt: 2 })
  assert.equal(mostRecentParked(manifest).id, 'slot-2')
  manifest = upsertEntry(manifest, { ...manifest[0], state: OPEN_AT_QUIT, updatedAt: 3 })
  assert.equal(manifest[0].state, OPEN_AT_QUIT)
  manifest = removeEntry(manifest, 'slot-2')
  assert.deepEqual(manifest, [])
  assert.equal(serializeManifest(manifest), '{"version":1,"entries":[]}')
})

test('manifest slots and every saved DB spelling remain occupied', () => {
  const manifest = [
    { id: idForSlot(2), slot: 2, state: PARKED, updatedAt: 1 },
    { id: idForSlot(5), slot: 5, state: OPEN_AT_QUIT, updatedAt: 2 },
  ]
  assert.deepEqual([...occupiedSlots(manifest)], [2, 5])
  assert.deepEqual(storeKeysForSlot(null), ['kaisola-store', 'kiasola-store', 'pasola-store'])
  assert.deepEqual(storeKeysForSlot(7), ['kaisola-store-w7', 'kiasola-store-w7', 'pasola-store-w7'])
  assert.equal(slotFromStoreKey('kaisola-store'), null)
  assert.equal(slotFromStoreKey('kiasola-store-w7'), 7)
  assert.equal(slotFromStoreKey('pasola-store-w9'), 9)
  assert.equal(slotFromStoreKey('kaisola-window-manifest-v1'), undefined)
})
