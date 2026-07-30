'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { __test } = require('../../runtime/node-broker/ipc/terminalManager.cjs')

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
