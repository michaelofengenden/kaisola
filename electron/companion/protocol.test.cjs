'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {
  CompanionProtocolError,
  MAX_FRAME_BYTES,
  decodeEnvelope,
  requiredCapability,
  validateEnvelope,
} = require('./protocol.cjs')

const fixtureDir = path.join(__dirname, 'fixtures')
const fixture = (name) => JSON.parse(fs.readFileSync(path.join(fixtureDir, name), 'utf8'))

test('golden companion frames validate and preserve the backlog-inspired board lanes', () => {
  for (const name of [
    'hello.json',
    'snapshot-board.json',
    'terminal-output.json',
    'agent-delta.json',
    'permission-requested.json',
    'command-receipt.json',
    'terminal-control-command.json',
    'terminal-control-receipt.json',
    'stale-revision-error.json',
  ]) {
    assert.deepEqual(validateEnvelope(fixture(name)), fixture(name), name)
  }
  const board = fixture('snapshot-board.json').body.projection.board
  assert.deepEqual(board.columns.map(({ id, count }) => ({ id, count })), [
    { id: 'running', count: 1 },
    { id: 'waiting', count: 1 },
    { id: 'done', count: 1 },
  ])
  assert.equal(board.columns[1].sourceLabel, 'Waiting for review')
})

test('protocol mismatch, unknown top-level fields, and control characters fail closed', () => {
  assert.throws(() => validateEnvelope(fixture('protocol-mismatch.json')), (error) => {
    assert.equal(error instanceof CompanionProtocolError, true)
    assert.equal(error.code, 'protocol_mismatch')
    return true
  })
  assert.throws(() => validateEnvelope({ ...fixture('hello.json'), brokerToken: 'secret' }), /not allowed/)
  assert.throws(() => validateEnvelope({ ...fixture('hello.json'), deviceId: 'bad\nvalue' }), /deviceId is invalid/)
  const hello = fixture('hello.json')
  assert.deepEqual(validateEnvelope({
    ...hello,
    body: {
      ...hello.body,
      transportHint: {
        service: '_kaisola._tcp', protocol: 'tcp', host: '192.168.1.23', tailscaleHost: '100.90.1.14', port: 49321,
      },
    },
  }).body.transportHint.tailscaleHost, '100.90.1.14')
  assert.throws(() => validateEnvelope({
    ...hello,
    body: { ...hello.body, transportHint: { service: '_kaisola._tcp', protocol: 'tcp', tailscaleHost: 'bad\nvalue', port: 49321 } },
  }), /tailscaleHost is invalid/)
})

test('commands require the exact capability, project, target, and envelope identity', () => {
  const base = {
    ...fixture('hello.json'),
    kind: 'command',
    seq: 2,
    id: 'command-2',
    body: {
      type: 'terminal.write',
      commandId: 'command-2',
      projectId: 'project-kaisola',
      targetId: 'terminal-codex',
      capability: 'terminal-control',
      payload: { data: 'npm test\r' },
    },
  }
  assert.deepEqual(validateEnvelope(base), base)
  assert.equal(requiredCapability('terminal.write'), 'terminal-control')
  assert.equal(requiredCapability('terminal.acquire-control'), 'terminal-control')
  assert.equal(requiredCapability('terminal.renew-control'), 'terminal-control')
  assert.equal(requiredCapability('agent.prompt'), 'agent-control')
  assert.equal(requiredCapability('attention.ack'), 'observe')
  assert.equal(requiredCapability('stream.subscribe'), 'observe')
  assert.equal(requiredCapability('terminal.kill'), null)
  assert.throws(() => validateEnvelope({ ...base, body: { ...base.body, capability: 'observe' } }), /requires terminal-control/)
  assert.throws(() => validateEnvelope({ ...base, body: { ...base.body, commandId: 'other-command' } }), /does not match/)
  assert.throws(() => validateEnvelope({ ...base, body: { ...base.body, projectId: '' } }), /projectId is invalid/)
  assert.throws(() => validateEnvelope({ ...base, body: { ...base.body, type: 'terminal.kill' } }), /unsupported command/)

  const attentionAck = {
    ...base,
    id: 'attention-command',
    body: {
      type: 'attention.ack',
      commandId: 'attention-command',
      projectId: 'project-kaisola',
      targetId: 'attention-f00dcafe',
      capability: 'observe',
      payload: {},
    },
  }
  assert.deepEqual(validateEnvelope(attentionAck), attentionAck)
  assert.throws(() => validateEnvelope({ ...attentionAck, body: { ...attentionAck.body, targetId: '' } }), /targetId is invalid/)
  assert.throws(() => validateEnvelope({ ...attentionAck, body: { ...attentionAck.body, capability: 'agent-control' } }), /requires observe/)

  const streamSubscribe = {
    ...base,
    id: 'stream-command',
    body: {
      type: 'stream.subscribe',
      commandId: 'stream-command',
      projectId: 'project-kaisola',
      targetId: 'terminal-codex',
      capability: 'observe',
      payload: { streamEpoch: 'terminal-epoch-3', afterOffset: 42 },
    },
  }
  assert.deepEqual(validateEnvelope(streamSubscribe), streamSubscribe)

  const acquire = {
    ...base,
    id: 'terminal-acquire',
    body: {
      type: 'terminal.acquire-control',
      commandId: 'terminal-acquire',
      projectId: 'project-kaisola',
      targetId: 'terminal-codex',
      capability: 'terminal-control',
      payload: {},
    },
  }
  assert.deepEqual(validateEnvelope(acquire), acquire)

  const receiptWithLease = {
    ...base,
    kind: 'receipt',
    id: 'receipt-terminal-acquire',
    body: {
      type: 'command.receipt',
      commandId: 'terminal-acquire',
      status: 'applied',
      message: 'Terminal control enabled.',
      payload: { leaseId: 'lease-safe', expiresAt: 1_784_250_031_300, renewAfterMs: 10_000 },
    },
  }
  assert.deepEqual(validateEnvelope(receiptWithLease), receiptWithLease)
  assert.throws(() => validateEnvelope({ ...receiptWithLease, body: { ...receiptWithLease.body, payload: [] } }), /body.payload must be an object/)
})

test('decoder bounds bytes before JSON parsing and rejects malformed bodies', () => {
  assert.deepEqual(decodeEnvelope(JSON.stringify(fixture('hello.json'))), fixture('hello.json'))
  assert.throws(() => decodeEnvelope('{'), /valid JSON/)
  assert.throws(() => decodeEnvelope(Buffer.alloc(MAX_FRAME_BYTES + 1)), /too large/)
  assert.throws(() => validateEnvelope({ ...fixture('hello.json'), body: [] }), /body must be an object/)
})

test('fuzz-shaped envelopes fail closed without widening protocol behavior', () => {
  const hello = fixture('hello.json')
  const invalidFrames = [
    { frame: { ...hello, kind: '__proto__' }, pattern: /unsupported frame kind/ },
    { frame: { ...hello, seq: -1 }, pattern: /seq is invalid/ },
    { frame: { ...hello, body: { ...hello.body, capabilities: ['observe', 'observe'] } }, pattern: /capabilities is invalid/ },
    { frame: { ...hello, body: { ...hello.body, role: 'relay' } }, pattern: /hello role is invalid/ },
    { frame: { ...hello, kind: 'ack', body: { type: 'ack', ackSeq: -1 } }, pattern: /ackSeq is invalid/ },
    { frame: { ...hello, kind: 'receipt', body: { type: 'command.receipt', commandId: 'command-1', status: 'maybe' } }, pattern: /receipt status is invalid/ },
  ]
  for (const { frame, pattern } of invalidFrames) assert.throws(() => validateEnvelope(frame), pattern)

  const cyclic = { ...hello }
  cyclic.body = { type: 'hello', role: 'device', capabilities: [], cyclic }
  assert.throws(() => validateEnvelope(cyclic), /JSON serializable/)
})
