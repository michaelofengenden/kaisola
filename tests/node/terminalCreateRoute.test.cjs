'use strict'

const { after, test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const realManager = require('../../runtime/node-broker/ipc/terminalManager.cjs')
const { TerminalSpool } = require('../../runtime/node-broker/ipc/terminalSpool.cjs')

const managerSpoolDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-create-route-'))
realManager.configureStorage(managerSpoolDir)
realManager.setEventSink(() => true)
after(() => {
  realManager.killAll()
  realManager.setEventSink(null)
  fs.rmSync(managerSpoolDir, { recursive: true, force: true })
})

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

test('terminal create route forwards restore but never returns a recovered payload', () => {
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
  assert.equal(response.recovered, null)
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

test('terminal create route preserves an id at the 240-character boundary', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  const id = 't'.repeat(240)

  const response = terminalCreateRoute({
    manager,
    params: { id, projectId: 'project-boundary' },
    owner: 'instance|owner|project-boundary',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })

  assert.equal(response.ok, true)
  assert.equal(manager.calls.length, 1)
  assert.equal(manager.calls[0].id, id)
})

test('terminal create route rejects an overlong id before authorization or spawn', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => assert.fail('an overlong id must not reach terminal lookup')
  const authorized = []

  const response = terminalCreateRoute({
    manager,
    params: { id: 't'.repeat(241), projectId: 'project-a' },
    owner: 'instance-a|owner-a|project-a',
    clientInstanceId: 'instance-a',
    requireAllowed: (...args) => authorized.push(args),
  })

  assert.deepEqual(response, {
    ok: false,
    code: 'terminal_id_too_long',
    message: 'terminal id exceeds 240 characters',
    maxLength: 240,
    actualLength: 241,
  })
  assert.deepEqual(authorized, [])
  assert.equal(manager.calls.length, 0)
})

test('terminal create route never aliases overlong ids with a shared 240-character prefix', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => assert.fail('colliding overlong ids must not reach terminal lookup')
  const prefix = 't'.repeat(240)
  const authorized = []

  const first = terminalCreateRoute({
    manager,
    params: { id: `${prefix}a`, projectId: 'project-a' },
    owner: 'instance-a|owner-a|project-a',
    clientInstanceId: 'instance-a',
    requireAllowed: (...args) => authorized.push(args),
  })
  const second = terminalCreateRoute({
    manager,
    params: { id: `${prefix}b`, projectId: 'project-b' },
    owner: 'instance-b|owner-b|project-b',
    clientInstanceId: 'instance-b',
    requireAllowed: (...args) => authorized.push(args),
  })

  assert.equal(first.code, 'terminal_id_too_long')
  assert.equal(second.code, 'terminal_id_too_long')
  assert.deepEqual(authorized, [])
  assert.equal(manager.calls.length, 0)
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
  assert.equal(allowed.recovered, null)
})

test('restore of naturally ended spool registers a history-serving cold record', (t) => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const projectId = 'nproj_cold-history'
  const id = `term-${projectId}-deadbeef`
  const oldOutput = 'first byte through final byte\n'
  const exitStatus = { exitCode: 23, signal: null }
  const spool = new TerminalSpool({ dir: managerSpoolDir, id, fresh: true })
  spool.push(oldOutput)
  spool.markExited(exitStatus)
  spool.close()
  t.after(() => realManager.release(id))

  const response = terminalCreateRoute({
    manager: realManager,
    params: {
      id,
      projectId,
      command: '/bin/cat',
      cwd: managerSpoolDir,
      restore: true,
    },
    owner: `instance|owner|${projectId}`,
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })

  const oldBytes = Buffer.byteLength(oldOutput)
  assert.equal(response.ok, true)
  assert.equal(response.existed, false)
  assert.equal(response.pid, null)
  assert.equal(response.exited, true)
  assert.deepEqual(response.exitStatus, exitStatus)
  assert.equal(response.recovered, null)
  assert.equal(response.output, '')
  assert.equal(response.startOffset, oldBytes)
  assert.equal(response.endOffset, oldBytes)

  assert.deepEqual(realManager.history(id, {
    streamEpoch: response.streamEpoch,
    beforeOffset: response.endOffset,
    maxBytes: 1024 * 1024,
  }), {
    ok: true,
    streamEpoch: response.streamEpoch,
    output: oldOutput,
    startOffset: 0,
    endOffset: oldBytes,
    hasMore: false,
    truncated: false,
  })
  assert.deepEqual(realManager.write(id, 'must not reach a pty'), {
    ok: false,
    message: 'terminal already ended',
  })
  assert.deepEqual(realManager.resize(id, 100, 40), {
    ok: false,
    message: 'terminal already ended',
  })
})
