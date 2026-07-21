'use strict'

// Wire-contract coverage for the commands the iPhone actually sends
// (CompanionClient.swift / CompanionConnectionCoordinator.swift). The desktop's
// validateEnvelope is the authority; this asserts every outbound command type
// validates with its declared capability and fails closed on a wrong or unknown
// capability — so a renamed command, a capability downgrade, or a dropped
// command type is caught here instead of silently rejecting the phone at runtime.
const test = require('node:test')
const assert = require('node:assert/strict')
const { validateEnvelope, COMMAND_CAPABILITIES } = require('./protocol.cjs')

// Representative payloads matching what the coordinator sends. Payload field
// shapes (leaseId/data/cols/rows) are enforced deeper in terminalControl.cjs;
// here we lock the envelope-level command→capability contract.
const OUTBOUND = {
  'attention.ack': {},
  'stream.subscribe': {},
  'stream.unsubscribe': {},
  'agent.prompt': { text: 'hello' },
  'agent.steer': { text: 'also this' },
  'agent.cancel': {},
  'permission.respond': { permId: 'perm-1', decision: 'allow_once' },
  'terminal.acquire-control': { cols: 80, rows: 24 },
  'terminal.renew-control': { leaseId: 'lease-1' },
  'terminal.write': { leaseId: 'lease-1', data: 'bHM=' },
  'terminal.resize': { leaseId: 'lease-1', cols: 80, rows: 24 },
  'terminal.interrupt': { leaseId: 'lease-1' },
  'terminal.release-control': { leaseId: 'lease-1' },
}

function commandFrame(type, capability, payload) {
  const commandId = 'cmd-fixture-1'
  return {
    v: 1,
    kind: 'command',
    desktopId: 'desktop-fixture',
    deviceId: 'device-fixture',
    connectionId: 'connection-fixture',
    epoch: 'desktop-epoch-1',
    seq: 3,
    id: commandId,
    sentAt: 1_784_250_000_000,
    body: {
      type,
      commandId,
      projectId: 'project-fixture',
      targetId: 'target-fixture',
      capability,
      ...(Object.keys(payload).length ? { payload } : {}),
    },
  }
}

test('every command the iPhone sends is a known command with a declared capability', () => {
  // Guards against the mobile and desktop drifting: OUTBOUND must be exactly the
  // set of command types the desktop declares (and vice versa).
  assert.deepEqual(
    Object.keys(OUTBOUND).sort(),
    Object.keys(COMMAND_CAPABILITIES).sort(),
    'the outbound command fixtures and COMMAND_CAPABILITIES must cover the same command types',
  )
})

test('each outbound command validates with its declared capability', () => {
  for (const [type, payload] of Object.entries(OUTBOUND)) {
    const capability = COMMAND_CAPABILITIES[type]
    assert.doesNotThrow(
      () => validateEnvelope(commandFrame(type, capability, payload)),
      `${type} should validate with capability ${capability}`,
    )
  }
})

test('a command sent with the wrong capability fails closed', () => {
  for (const [type, payload] of Object.entries(OUTBOUND)) {
    const wrong = COMMAND_CAPABILITIES[type] === 'observe' ? 'terminal-control' : 'observe'
    assert.throws(
      () => validateEnvelope(commandFrame(type, wrong, payload)),
      (error) => error.code === 'invalid_capability',
      `${type} must be rejected when it claims capability ${wrong}`,
    )
  }
})

test('an unknown command type fails closed', () => {
  assert.throws(
    () => validateEnvelope(commandFrame('terminal.teleport', 'terminal-control', {})),
    (error) => error.code === 'unknown_command',
  )
})
