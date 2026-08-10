'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { collectBrokerInventorySnapshot } = require('../../runtime/node-broker/ipc/brokerInventorySnapshot.cjs')

test('one stable activity epoch returns status diagnostics and live rows together', () => {
  const calls = []
  const snapshot = collectBrokerInventorySnapshot({
    activityEpoch: () => 17,
    inFlightMutations: () => 0,
    status: () => {
      calls.push('status')
      return { ok: true, activityEpoch: 17, version: 'test' }
    },
    diagnostics: () => {
      calls.push('diagnostics')
      return [{ id: 'terminal-one', exited: false }]
    },
    live: () => {
      calls.push('live')
      return [{ id: 'terminal-one', pid: 42 }]
    },
  })

  assert.deepEqual(calls, ['status', 'diagnostics', 'live'])
  assert.deepEqual(snapshot, {
    ok: true,
    state: 'stable',
    activityEpoch: 17,
    status: { ok: true, activityEpoch: 17, version: 'test' },
    diagnostics: [{ id: 'terminal-one', exited: false }],
    live: [{ id: 'terminal-one', pid: 42 }],
  })
})

test('an epoch change discards every collected row', () => {
  let epoch = 21
  const snapshot = collectBrokerInventorySnapshot({
    activityEpoch: () => epoch,
    inFlightMutations: () => 0,
    status: () => ({ ok: true, activityEpoch: epoch }),
    diagnostics: () => {
      epoch += 1
      return [{ id: 'must-not-escape', secret: 'diagnostic' }]
    },
    live: () => [{ id: 'must-not-escape', secret: 'live' }],
  })

  assert.deepEqual(snapshot, {
    ok: false,
    state: 'activity_changed',
    activityEpoch: 22,
  })
  assert.doesNotMatch(JSON.stringify(snapshot), /must-not-escape|secret/)
})

test('a mutation already in flight rejects before any inventory collector runs', () => {
  const calls = []
  const snapshot = collectBrokerInventorySnapshot({
    activityEpoch: () => 31,
    inFlightMutations: () => 1,
    status: () => calls.push('status'),
    diagnostics: () => calls.push('diagnostics'),
    live: () => calls.push('live'),
  })

  assert.deepEqual(calls, [])
  assert.deepEqual(snapshot, {
    ok: false,
    state: 'activity_changed',
    activityEpoch: 31,
  })
})

test('a mutation beginning during collection and a mismatched status epoch both fail closed', () => {
  let inFlightChecks = 0
  const mutation = collectBrokerInventorySnapshot({
    activityEpoch: () => 41,
    inFlightMutations: () => inFlightChecks++ === 0 ? 0 : 1,
    status: () => ({ ok: true, activityEpoch: 41 }),
    diagnostics: () => [],
    live: () => [],
  })
  assert.equal(mutation.ok, false)

  const mismatched = collectBrokerInventorySnapshot({
    activityEpoch: () => 51,
    inFlightMutations: () => 0,
    status: () => ({ ok: true, activityEpoch: 50 }),
    diagnostics: () => [],
    live: () => [],
  })
  assert.deepEqual(mismatched, {
    ok: false,
    state: 'activity_changed',
    activityEpoch: 51,
  })
})
