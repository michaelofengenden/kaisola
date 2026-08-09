'use strict'

const { after, test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const manager = require('../../runtime/node-broker/ipc/terminalManager.cjs')
const { terminalDetachOwnerRoute } = require('../../runtime/node-broker/ipc/terminalDetachOwnerRoute.cjs')

const spoolDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-detach-owner-'))
manager.configureStorage(spoolDir)
after(() => {
  manager.killAll()
  fs.rmSync(spoolDir, { recursive: true, force: true })
})

test('terminal detach authorizes the exact id before changing ownership', () => {
  const calls = []
  assert.throws(() => terminalDetachOwnerRoute({
    manager: {
      detachSender: () => assert.fail('denied detach must not mutate ownership'),
    },
    params: { id: 'terminal-denied' },
    owner: 'instance-a|renderer-1|project-a',
    requireAllowed: (id) => {
      calls.push(['authorize', id])
      throw new Error('terminal access denied')
    },
  }), /terminal access denied/)
  assert.deepEqual(calls, [['authorize', 'terminal-denied']])
})

test('terminal detach returns the exact id and manager result', () => {
  const calls = []
  const id = 'terminal-detach-response'
  const owner = 'instance-a|renderer-1|project-a'
  const result = terminalDetachOwnerRoute({
    manager: {
      detachSender: (candidateOwner, candidateID) => {
        calls.push(['detach', candidateOwner, candidateID])
        return 0
      },
    },
    params: { id },
    owner,
    requireAllowed: (candidate) => calls.push(['authorize', candidate]),
  })

  assert.deepEqual(result, { id, ok: true, detached: 0 })
  assert.deepEqual(calls, [
    ['authorize', id],
    ['detach', owner, id],
  ])
})

test('terminal detach never truncates an overlong id into another terminal', () => {
  const id = `terminal-detach-${'x'.repeat(240)}`
  const calls = []
  const result = terminalDetachOwnerRoute({
    manager: {
      detachSender: (owner, candidate) => {
        calls.push(['detach', owner, candidate])
        return 0
      },
    },
    params: { id },
    owner: 'instance-a|renderer-1|project-a',
    requireAllowed: (candidate) => calls.push(['authorize', candidate]),
  })

  assert.equal(result.id, id)
  assert.deepEqual(calls, [
    ['authorize', id],
    ['detach', 'instance-a|renderer-1|project-a', id],
  ])
})

test('two projects sharing one renderer owner remain isolated', (t) => {
  const firstID = 'detach-owner-project-a'
  const secondID = 'detach-owner-project-b'
  const firstOwner = 'instance-shared|renderer-7|project-a'
  const secondOwner = 'instance-shared|renderer-7|project-b'
  const firstSender = { id: firstOwner, send: () => {}, isDestroyed: () => false }
  const secondSender = { id: secondOwner, send: () => {}, isDestroyed: () => false }
  manager.spawn({
    id: firstID,
    command: '/bin/cat',
    args: [],
    cwd: spoolDir,
    sender: firstSender,
  })
  manager.spawn({
    id: secondID,
    command: '/bin/cat',
    args: [],
    cwd: spoolDir,
    sender: secondSender,
  })
  t.after(() => {
    manager.release(firstID)
    manager.release(secondID)
  })

  assert.deepEqual(terminalDetachOwnerRoute({
    manager,
    params: { id: firstID },
    owner: firstOwner,
    requireAllowed: () => {},
  }), { id: firstID, ok: true, detached: 1 })
  assert.equal(manager.ownership(firstID).owner, '')
  assert.equal(manager.ownership(secondID).owner, secondOwner)
})
