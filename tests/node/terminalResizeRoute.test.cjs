'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const {
  TERMINAL_GEOMETRY_LIMITS,
  terminalResizeRoute,
} = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')

function fakeManager(response = { ok: true }) {
  const calls = []
  return {
    calls,
    resize: (...args) => {
      calls.push(args)
      return response
    },
  }
}

test('terminal geometry defaults and maxima are a pinned protocol contract', () => {
  assert.deepEqual(TERMINAL_GEOMETRY_LIMITS, {
    defaultCols: 80,
    defaultRows: 24,
    maxCols: 1_000,
    maxRows: 1_000,
  })
})

test('terminal resize wire route rejects raw numeric strings before authorization', async (t) => {
  for (const [name, params, field] of [
    ['columns', { cols: '120', rows: 40 }, 'cols'],
    ['rows', { cols: 120, rows: '40' }, 'rows'],
  ]) {
    await t.test(name, () => {
      const manager = fakeManager()
      const response = terminalResizeRoute({
        manager,
        id: `wire-string-${name}`,
        params,
        requireAllowed: () => assert.fail('invalid wire geometry must not authorize'),
      })

      assert.deepEqual(response, {
        ok: false,
        code: 'terminal_geometry_invalid',
        message: `terminal ${field} must be a finite positive integer`,
        field,
        expected: 'finite positive integer',
      })
      assert.equal(manager.calls.length, 0)
    })
  }
})

test('terminal resize wire route rejects omitted dimensions instead of defaulting', async (t) => {
  for (const [name, params, field] of [
    ['columns', { rows: 40 }, 'cols'],
    ['rows', { cols: 120 }, 'rows'],
  ]) {
    await t.test(name, () => {
      const manager = fakeManager()
      const response = terminalResizeRoute({
        manager,
        id: `wire-missing-${name}`,
        params,
        requireAllowed: () => assert.fail('incomplete wire geometry must not authorize'),
      })
      assert.equal(response.ok, false)
      assert.equal(response.field, field)
      assert.equal(manager.calls.length, 0)
    })
  }
})

test('terminal resize wire route clamps positive extremes after authorization', () => {
  const manager = fakeManager({ ok: true, marker: 'manager-response' })
  const authorized = []
  const response = terminalResizeRoute({
    manager,
    id: 'wire-extreme-geometry',
    params: { cols: Number.MAX_SAFE_INTEGER, rows: Number.MAX_SAFE_INTEGER },
    requireAllowed: (id) => authorized.push(id),
  })

  assert.deepEqual(authorized, ['wire-extreme-geometry'])
  assert.deepEqual(manager.calls, [[
    'wire-extreme-geometry',
    TERMINAL_GEOMETRY_LIMITS.maxCols,
    TERMINAL_GEOMETRY_LIMITS.maxRows,
  ]])
  assert.deepEqual(response, { ok: true, marker: 'manager-response' })
})
