'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  fixture,
  normalizeClaude,
  normalizeCodex,
  normalizedWindow,
} = require('../scripts/native-usage-service.cjs')

test('native usage bridge normalizes Codex account windows', () => {
  const value = normalizeCodex({
    ok: true,
    email: 'person@example.com',
    plan: 'plus',
    primary: { usedPercent: 41, resetsAt: 1_800_000_000 },
    secondary: { usedPercent: 12 },
    updatedAt: 123,
  }, 999)
  assert.equal(value.provider, 'codex')
  assert.equal(value.ok, true)
  assert.equal(value.account, 'person@example.com')
  assert.deepEqual(value.windows.map((window) => window.label), ['5 hour', 'Weekly'])
  assert.equal(value.windows[0].usedPercent, 41)
})

test('native usage bridge normalizes Claude Agent SDK windows', () => {
  const value = normalizeClaude({
    ok: true,
    subscriptionType: 'max',
    limits: {
      fiveHour: { usedPercent: 28, resetsAt: 1_800_000_000 },
      sevenDay: { usedPercent: 9 },
      modelScoped: [{ label: 'Opus', usedPercent: 4 }],
    },
  }, 999)
  assert.equal(value.provider, 'claude')
  assert.equal(value.plan, 'max')
  assert.equal(value.experimental, true)
  assert.deepEqual(value.windows.map((window) => window.label), ['5 hour', '7 day', 'Opus'])
})

test('native usage window rejects malformed percentage and fixture is deterministic in shape', () => {
  assert.equal(normalizedWindow('bad', { usedPercent: 101 }), null)
  const value = fixture(1_700_000_000_000)
  assert.deepEqual(value.providers.map((provider) => provider.provider), ['claude', 'codex'])
  assert.ok(value.providers.every((provider) => provider.windows.length === 2))
})
