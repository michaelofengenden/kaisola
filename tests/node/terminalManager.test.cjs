'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { __test } = require('../../runtime/node-broker/ipc/terminalManager.cjs')

test('terminal resize commits geometry only after node-pty accepts it', () => {
  const calls = []
  const record = {
    cols: 80,
    rows: 24,
    pty: { resize: (cols, rows) => calls.push([cols, rows]) },
  }

  assert.equal(__test.resizeRecord(record, 132, 44), true)
  assert.deepEqual(calls, [[132, 44]])
  assert.equal(record.cols, 132)
  assert.equal(record.rows, 44)
})

test('terminal resize returns false and preserves geometry when node-pty throws', () => {
  const record = {
    cols: 80,
    rows: 24,
    pty: { resize: () => { throw new Error('pty exited during resize') } },
  }

  assert.equal(__test.resizeRecord(record, 20, 8), false)
  assert.equal(record.cols, 80)
  assert.equal(record.rows, 24)
})

test('terminal resize rejects invalid or fractional wire geometry', () => {
  const record = {
    cols: 80,
    rows: 24,
    pty: { resize: () => assert.fail('invalid geometry reached node-pty') },
  }

  assert.equal(__test.resizeRecord(record, 0, 24), false)
  assert.equal(__test.resizeRecord(record, 80.5, 24), false)
  assert.equal(__test.resizeRecord(record, 80, Number.NaN), false)
  assert.equal(record.cols, 80)
  assert.equal(record.rows, 24)
})
