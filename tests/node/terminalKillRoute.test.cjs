'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { terminalKillRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')

test('terminal kill wire route returns typed nested failure verbatim', () => {
  const failure = {
    id: 'kill-refused-on-wire',
    ok: false,
    code: 'terminal_kill_failed',
    message: 'terminal signal failed',
  }
  const calls = []
  const response = terminalKillRoute({
    manager: {
      kill: (id) => {
        calls.push(['kill', id])
        return failure
      },
    },
    id: 'kill-refused-on-wire',
    requireAllowed: (id) => calls.push(['authorize', id]),
  })

  assert.equal(response, failure)
  assert.deepEqual(calls, [
    ['authorize', 'kill-refused-on-wire'],
    ['kill', 'kill-refused-on-wire'],
  ])
})

test('terminal kill wire route preserves success and idempotent-exit details', async (t) => {
  for (const result of [
    { id: 'kill-success-on-wire', ok: true },
    { id: 'kill-success-on-wire', ok: true, alreadyExited: true },
  ]) {
    await t.test(JSON.stringify(result), () => {
      const response = terminalKillRoute({
        manager: { kill: () => result },
        id: 'kill-success-on-wire',
        requireAllowed: () => {},
      })
      assert.equal(response, result)
    })
  }
})
