'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')

function fakeManager({ live = false, recovered = null } = {}) {
  const calls = []
  return {
    calls,
    available: () => true,
    has: () => !live,
    isLive: () => live,
    spawn: (options) => {
      calls.push(options)
      return { pty: { pid: 4242 }, recovered }
    },
    setSender: () => null,
    snapshot: () => ({
      output: 'new-session-output',
      streamEpoch: 'new-stream-epoch',
      startOffset: 0,
      endOffset: 18,
      truncated: false,
      exited: false,
      exitStatus: null,
    }),
  }
}

test('terminal create route forwards restore and returns recovered scrollback for reused id', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager({
    recovered: { text: 'retained-before-restart', truncated: true },
  })
  const authorized = []

  const response = terminalCreateRoute({
    manager,
    params: {
      id: 'caller-supplied-terminal-id',
      command: '/bin/zsh',
      args: ['-l'],
      cwd: '/tmp/restored-cwd',
      restore: true,
      cols: 132,
      rows: 44,
    },
    owner: 'instance|owner|project',
    clientInstanceId: 'new-instance',
    requireAllowed: (id, adopt) => authorized.push([id, adopt]),
    brokerPid: 5151,
    now: () => 1234,
  })

  assert.deepEqual(authorized, [['caller-supplied-terminal-id', true]])
  assert.equal(manager.calls.length, 1)
  assert.equal(manager.calls[0].id, 'caller-supplied-terminal-id')
  assert.equal(manager.calls[0].restore, true)
  assert.deepEqual(response.recovered, {
    text: 'retained-before-restart',
    truncated: true,
  })
  assert.equal(response.output, 'new-session-output')
})

test('terminal create route always returns recovered null for a plain spawn', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager({
    recovered: { text: 'must-not-leak', truncated: false },
  })

  const response = terminalCreateRoute({
    manager,
    params: { id: 'fresh-terminal', cwd: '/tmp/fresh' },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })

  assert.equal(manager.calls[0].restore, false)
  assert.equal(response.recovered, null)
})

test('restore for an id unknown to this broker requires the id-embedded project to match', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager({ recovered: { text: 'secret-project-a-output', truncated: false } })
  manager.has = () => false // fresh broker process: nothing in memory to check ownership against

  const denied = terminalCreateRoute({
    manager,
    params: {
      id: 'term-nproj_project-a-11112222',
      projectId: 'nproj_project-b',
      restore: true,
    },
    owner: 'instance|owner|nproj_project-b',
    clientInstanceId: 'new-instance',
    requireAllowed: () => { throw new Error('nothing to check against post-restart') },
  })
  assert.equal(denied.ok, false)
  assert.match(denied.message, /project mismatch/)
  assert.equal(manager.calls.length, 0, 'a denied restore must never reach spawn')

  const allowed = terminalCreateRoute({
    manager,
    params: {
      id: 'term-nproj_project-a-11112222',
      projectId: 'nproj_project-a',
      restore: true,
    },
    owner: 'instance|owner|nproj_project-a',
    clientInstanceId: 'new-instance',
    requireAllowed: () => {},
  })
  assert.equal(allowed.ok, true)
  assert.equal(allowed.recovered.text, 'secret-project-a-output')
})
