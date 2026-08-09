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
    unconfirmedTurnCount: 0,
    unconfirmedTurnIds: [],
    childTaskCount: 0,
  })

  const blocked = __test.summarizeUpgradeReadiness([
    { id: 'z-live', exited: false, agentBusy: false, agentTurnOpen: false },
    { id: 'a-working', exited: true, agentBusy: true, agentTurnOpen: true },
    { id: 'm-both', exited: false, agentBusy: true, agentTurnOpen: true },
    // Quiet for longer than AGENT_QUIET_MS, but no completion signal ever
    // arrived: still counted as an agent at work.
    { id: 'q-unconfirmed', exited: false, agentBusy: false, agentTurnOpen: true },
  ], 2)
  assert.deepEqual(blocked, {
    safe: false,
    liveTerminalCount: 3,
    liveTerminalIds: ['m-both', 'q-unconfirmed', 'z-live'],
    busyAgentCount: 3,
    busyTerminalIds: ['a-working', 'm-both', 'q-unconfirmed'],
    unconfirmedTurnCount: 1,
    unconfirmedTurnIds: ['q-unconfirmed'],
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
