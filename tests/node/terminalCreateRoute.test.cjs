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

test('an id past the length cap is rejected with a structured error instead of truncated', () => {
  const {
    terminalCreateRoute,
    TERMINAL_ID_MAX_LENGTH,
  } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  const authorized = []
  const atCap = `term-nproj_cap-${'a'.repeat(TERMINAL_ID_MAX_LENGTH - 'term-nproj_cap-'.length)}`
  assert.equal(atCap.length, TERMINAL_ID_MAX_LENGTH)

  const rejected = terminalCreateRoute({
    manager,
    params: { id: `${atCap}-overflow` },
    owner: 'instance|owner|nproj_cap',
    clientInstanceId: 'instance',
    requireAllowed: (id, adopt) => authorized.push([id, adopt]),
  })

  assert.equal(rejected.ok, false)
  assert.equal(rejected.code, 'terminal_id_too_long')
  assert.equal(rejected.limit, TERMINAL_ID_MAX_LENGTH)
  assert.equal(rejected.length, `${atCap}-overflow`.length)
  assert.match(rejected.message, /exceeds 240 characters/)
  assert.equal(manager.calls.length, 0, 'a rejected id must never reach spawn')
  assert.deepEqual(authorized, [], 'a rejected id must never consult an ownership record')

  // The cap itself still spawns, under the id exactly as the caller sent it.
  const accepted = terminalCreateRoute({
    manager,
    params: { id: atCap },
    owner: 'instance|owner|nproj_cap',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })
  assert.equal(accepted.ok, true)
  assert.equal(manager.calls.length, 1)
  assert.equal(manager.calls[0].id, atCap)
})

test('colliding long id prefixes cannot alias one terminal across projects and owners', () => {
  const {
    terminalCreateRoute,
    TERMINAL_ID_MAX_LENGTH,
  } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  // Both ids agree through the cap and diverge only after it, which is exactly
  // the pair a truncating route collapsed into one terminal and one owner.
  const sharedPrefix = `term-nproj_shared-${'b'.repeat(TERMINAL_ID_MAX_LENGTH - 'term-nproj_shared-'.length)}`
  assert.equal(sharedPrefix.length, TERMINAL_ID_MAX_LENGTH)
  const projectAId = `${sharedPrefix}-nproj_project-a`
  const projectBId = `${sharedPrefix}-nproj_project-b`
  const spawnedIds = []
  const manager = {
    available: () => true,
    has: (id) => spawnedIds.includes(id),
    isLive: (id) => spawnedIds.includes(id),
    spawn: ({ id }) => {
      spawnedIds.push(id)
      return { pty: { pid: 4242 } }
    },
    setSender: () => null,
    snapshot: () => ({ output: '', streamEpoch: 'epoch', startOffset: 0, endOffset: 0 }),
  }
  const ownershipChecks = []

  const first = terminalCreateRoute({
    manager,
    params: { id: projectAId },
    owner: 'instance|owner-a|nproj_project-a',
    clientInstanceId: 'instance',
    requireAllowed: (id, adopt) => ownershipChecks.push([id, adopt]),
  })
  const second = terminalCreateRoute({
    manager,
    params: { id: projectBId, restore: true, projectId: 'nproj_project-b' },
    owner: 'other-instance|owner-b|nproj_project-b',
    clientInstanceId: 'other-instance',
    requireAllowed: (id, adopt) => ownershipChecks.push([id, adopt]),
  })

  assert.equal(first.code, 'terminal_id_too_long')
  assert.equal(second.code, 'terminal_id_too_long')
  assert.deepEqual(spawnedIds, [], 'neither caller may claim the shared prefix')
  assert.deepEqual(
    ownershipChecks,
    [],
    "project B must never be measured against project A's ownership record",
  )
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
