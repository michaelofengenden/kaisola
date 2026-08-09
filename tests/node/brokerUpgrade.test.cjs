'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { __test } = require('../../runtime/node-broker/ipc/terminalManager.cjs')
const {
  backgroundRejection,
  createBrokerRejectionSupervisor,
} = require('../../runtime/node-broker/ipc/brokerRejectionPolicy.cjs')

test('broker update readiness requires zero live PTYs, working agents, and child tasks', () => {
  assert.deepEqual(__test.summarizeUpgradeReadiness([], 0), {
    safe: true,
    liveTerminalCount: 0,
    liveTerminalIds: [],
    busyAgentCount: 0,
    busyTerminalIds: [],
    childTaskCount: 0,
  })

  const blocked = __test.summarizeUpgradeReadiness([
    { id: 'z-live', exited: false, agentBusy: false },
    { id: 'a-working', exited: true, agentBusy: true },
    { id: 'm-both', exited: false, agentBusy: true },
  ], 2)
  assert.deepEqual(blocked, {
    safe: false,
    liveTerminalCount: 2,
    liveTerminalIds: ['m-both', 'z-live'],
    busyAgentCount: 2,
    busyTerminalIds: ['a-working', 'm-both'],
    childTaskCount: 2,
  })
})

test('an exited quiet diagnostic does not strand a helper update', () => {
  const readiness = __test.summarizeUpgradeReadiness([
    { id: 'finished', exited: true, agentBusy: false },
  ], 0)
  assert.equal(readiness.safe, true)
  assert.equal(readiness.liveTerminalCount, 0)
})

test('known background rejections stay classified and do not fence mutations', () => {
  const logs = []
  const supervisor = createBrokerRejectionSupervisor({ log: (line) => logs.push(line) })

  const classification = supervisor.handle(backgroundRejection('rendezvous-retry'))

  assert.deepEqual(classification, {
    kind: 'background',
    operation: 'rendezvous-retry',
  })
  assert.equal(supervisor.allows('terminal.create'), true)
  assert.deepEqual(supervisor.status(), {
    state: 'healthy',
    mutationFence: false,
    backgroundRejectionCount: 1,
    invariantFailureCount: 0,
    lastBackgroundOperation: 'rendezvous-retry',
  })
  assert.deepEqual(logs, ['background rejection operation=rendezvous-retry'])
})

test('an unclassified rejection latches a mutation fence without hiding observation', () => {
  const logs = []
  const supervisor = createBrokerRejectionSupervisor({ log: (line) => logs.push(line) })

  const classification = supervisor.handle(new Error('provider-secret-marker'))

  assert.deepEqual(classification, { kind: 'invariant' })
  assert.equal(supervisor.allows('terminal.create'), false)
  assert.equal(supervisor.allows('terminal.write'), false)
  assert.equal(supervisor.allows('broker.shutdownForUpdate'), false)
  for (const method of [
    'broker.status',
    'terminal.available',
    'terminal.subscribe',
    'terminal.unsubscribe',
    'terminal.snapshot',
    'terminal.history',
    'terminal.waitForExit',
    'terminal.list',
    'terminal.diagnostics',
  ]) assert.equal(supervisor.allows(method), true, method)
  assert.deepEqual(supervisor.status(), {
    state: 'degraded',
    mutationFence: true,
    backgroundRejectionCount: 0,
    invariantFailureCount: 1,
    lastBackgroundOperation: null,
  })
  assert.deepEqual(logs, ['fatal rejection classification=unhandled mutations=fenced'])
  assert.doesNotMatch(logs.join('\n'), /provider-secret-marker/)

  supervisor.handle(new Error('second-secret'))
  assert.equal(supervisor.status().invariantFailureCount, 2)
  assert.equal(supervisor.allows('terminal.create'), false)
})
