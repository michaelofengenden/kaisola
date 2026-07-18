'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { CompanionEventLog, CompanionEventLogError } = require('./eventLog.cjs')

function log(options = {}) {
  return new CompanionEventLog({ epoch: 'desktop-epoch-test', ...options })
}

test('reconnect receives the available ordered suffix', () => {
  const events = log()
  events.append({ type: 'desktop.status', payload: { state: 'online' }, at: 1 })
  events.append({ type: 'session.updated', payload: { sessionId: 'session-1' }, at: 2 })
  events.append({ type: 'terminal.output', payload: { data: 'ok' }, at: 3 })

  const replay = events.replay({ epoch: 'desktop-epoch-test', afterSeq: 1 })
  assert.equal(replay.kind, 'replay')
  assert.equal(replay.fromSeq, 2)
  assert.equal(replay.toSeq, 3)
  assert.deepEqual(replay.events.map((event) => event.seq), [2, 3])
})

test('count and byte limits force a snapshot for a slow client', () => {
  const countBounded = log({ maxEvents: 2, maxBytes: 10_000 })
  for (let index = 0; index < 4; index++) {
    countBounded.append({ type: 'desktop.status', payload: { index }, at: index })
  }
  assert.deepEqual(countBounded.stats(), {
    epoch: 'desktop-epoch-test',
    currentSeq: 4,
    droppedThrough: 2,
    earliestSeq: 3,
    retainedEvents: 2,
    retainedBytes: countBounded.stats().retainedBytes,
    activeClients: 0,
    maxEvents: 2,
    maxBytes: 10_000,
  })
  assert.deepEqual(countBounded.replay({ epoch: 'desktop-epoch-test', afterSeq: 1 }).reason, 'event_gap')
  assert.deepEqual(countBounded.replay({ epoch: 'desktop-epoch-test', afterSeq: 2 }).events.map((event) => event.seq), [3, 4])

  const byteBounded = log({ maxEvents: 10, maxBytes: 240 })
  byteBounded.append({ type: 'desktop.status', payload: { text: 'a'.repeat(80) }, at: 1 })
  byteBounded.append({ type: 'desktop.status', payload: { text: 'b'.repeat(80) }, at: 2 })
  assert.ok(byteBounded.stats().retainedBytes <= 240)
  assert.equal(byteBounded.stats().retainedEvents, 1)
})

test('ACK pruning waits for the slowest active client and ignores stale ACK regression', () => {
  const events = log()
  for (let index = 1; index <= 5; index++) {
    events.append({ type: 'desktop.status', payload: { index }, at: index })
  }
  events.acknowledge('phone-fast', 5)
  events.acknowledge('phone-slow', 2)
  assert.equal(events.pruneAcknowledged(), 2)
  assert.equal(events.stats().earliestSeq, 3)
  assert.equal(events.acknowledge('phone-slow', 1), 2)
  assert.equal(events.pruneAcknowledged(), 0)

  assert.equal(events.dropClient('phone-slow'), true)
  assert.equal(events.pruneAcknowledged(), 3)
  assert.equal(events.stats().retainedEvents, 0)
})

test('epoch mismatch, cursor ahead, and pruned gaps request a replacement snapshot', () => {
  const events = log({ maxEvents: 2 })
  for (let index = 1; index <= 3; index++) {
    events.append({ type: 'desktop.status', payload: { index }, at: index })
  }
  assert.equal(events.replay({ epoch: 'desktop-epoch-old', afterSeq: 3 }).reason, 'epoch_mismatch')
  assert.equal(events.replay({ epoch: 'desktop-epoch-test', afterSeq: 4 }).reason, 'cursor_ahead')
  assert.equal(events.replay({ epoch: 'desktop-epoch-test', afterSeq: 0 }).reason, 'event_gap')

  const restarted = new CompanionEventLog({ epoch: 'desktop-epoch-new' })
  assert.equal(restarted.replay({ epoch: 'desktop-epoch-test', afterSeq: 3 }).reason, 'epoch_mismatch')
  assert.deepEqual(restarted.replay({ epoch: 'desktop-epoch-new', afterSeq: 0 }).events, [])
})

test('an unretained event advances a snapshot boundary without serializing a payload', () => {
  const events = log()
  events.append({ type: 'desktop.status', payload: { connected: true }, at: 1 })
  assert.equal(events.invalidate(), 2)
  assert.equal(events.stats().retainedEvents, 0)
  assert.equal(events.stats().droppedThrough, 2)
  assert.equal(events.replay({ epoch: 'desktop-epoch-test', afterSeq: 1 }).reason, 'event_gap')
  assert.deepEqual(events.replay({ epoch: 'desktop-epoch-test', afterSeq: 2 }).events, [])
})

test('payloads are copied, event types are allowlisted, and oversized events are rejected', () => {
  const events = log({ maxBytes: 200 })
  const payload = { state: 'online' }
  const appended = events.append({ type: 'desktop.status', payload, at: 1 })
  payload.state = 'mutated'
  appended.payload.state = 'also-mutated'
  assert.equal(events.replay({ epoch: 'desktop-epoch-test', afterSeq: 0 }).events[0].payload.state, 'online')
  assert.throws(() => events.append({ type: 'desktop.secret', payload: {}, at: 2 }), /unsupported event type/)
  assert.throws(() => events.append({ type: 'desktop.status', payload: { text: 'x'.repeat(500) }, at: 2 }), (error) => {
    assert.equal(error instanceof CompanionEventLogError, true)
    assert.equal(error.code, 'event_too_large')
    return true
  })
  assert.throws(() => events.acknowledge('phone-1', 2), /ahead/)
})

test('a synthetic million-event stream remains strictly bounded', { timeout: 30_000 }, () => {
  const events = log({ maxEvents: 32, maxBytes: 8 * 1024 })
  for (let index = 0; index < 1_000_000; index++) {
    events.append({ type: 'desktop.status', payload: { connected: index % 2 === 0 }, at: index })
  }
  const stats = events.stats()
  assert.equal(stats.currentSeq, 1_000_000)
  assert.ok(stats.retainedEvents <= 32)
  assert.ok(stats.retainedBytes <= 8 * 1024)
  assert.equal(stats.droppedThrough + stats.retainedEvents, stats.currentSeq)
})
