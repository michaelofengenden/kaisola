'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { terminalAttachRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')

test('terminal attach reports missing before ownership or snapshot mutation', () => {
  const calls = []
  const id = 'missing-terminal-attach'
  const result = terminalAttachRoute({
    manager: {
      has: (candidate) => {
        calls.push(['has', candidate])
        return false
      },
      setSender: () => assert.fail('missing attach must not mutate ownership'),
      snapshot: () => assert.fail('missing attach must not synthesize a snapshot'),
    },
    id,
    owner: 'native-owner',
    clientInstanceId: 'native-instance',
    requireAllowed: (candidate, adopt) => calls.push(['authorize', candidate, adopt]),
  })

  assert.deepEqual(result, {
    id,
    ok: false,
    code: 'terminal_not_found',
    message: 'terminal is no longer available',
  })
  assert.deepEqual(calls, [
    ['authorize', id, true],
    ['has', id],
  ])
})

test('terminal attach authorizes before revealing existence or changing ownership', () => {
  const calls = []
  assert.throws(() => terminalAttachRoute({
    manager: {
      has: () => assert.fail('denied attach must not reveal existence'),
      setSender: () => assert.fail('denied attach must not mutate ownership'),
      snapshot: () => assert.fail('denied attach must not expose output'),
    },
    id: 'terminal-denied',
    owner: 'native-owner',
    clientInstanceId: 'native-instance',
    requireAllowed: (id, adopt) => {
      calls.push(['authorize', id, adopt])
      throw new Error('terminal access denied')
    },
  }), /terminal access denied/)
  assert.deepEqual(calls, [['authorize', 'terminal-denied', true]])
})

test('terminal attach awaits its durable snapshot and then seals success and identity', async () => {
  const calls = []
  const id = 'terminal-existing'
  const result = terminalAttachRoute({
    manager: {
      has: (candidate) => {
        calls.push(['has', candidate])
        return true
      },
      setSender: (candidate, owner) => {
        calls.push(['setSender', candidate, owner])
        return {
          detachedAt: 123,
          previousOwner: 'previous-instance|native-owner|project-one',
        }
      },
      snapshot: async (candidate, options) => {
        calls.push(['snapshot', candidate, options])
        return { id: 'forged-id', ok: false, output: 'retained', exited: false }
      },
    },
    id,
    owner: 'native-owner',
    clientInstanceId: 'native-instance',
    requireAllowed: (candidate, adopt) => calls.push(['authorize', candidate, adopt]),
    now: () => 456,
    brokerPid: 789,
  })

  assert.deepEqual(await result, {
    id,
    ok: true,
    output: 'retained',
    exited: false,
    continuation: {
      detachedAt: 123,
      previousOwner: 'previous-instance|native-owner|project-one',
      acrossRestart: true,
      reattachedAt: 456,
      brokerPid: 789,
    },
  })
  assert.deepEqual(calls, [
    ['authorize', id, true],
    ['has', id],
    ['setSender', id, 'native-owner'],
    ['snapshot', id, { responseBarrier: true }],
  ])
})
