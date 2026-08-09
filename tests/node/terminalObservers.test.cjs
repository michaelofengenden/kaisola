'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { TerminalObservers } = require('../../runtime/node-broker/ipc/terminalObservers.cjs')
const { writeFrame } = require('../../runtime/node-broker/ipc/brokerWire.cjs')

const OWNER = 'instance-a|1|project'
const QUEUE_BYTES = 64 * 1024
const CHUNK = 'x'.repeat(8 * 1024)

/** A net.Socket stand-in: writes always queue, and write() reports false once
 * the buffered amount passes the high water mark. Nothing ever drains, so the
 * saturated state a slow consumer reaches is reproduced exactly. */
function saturatingSocket({ highWaterMark = 16 * 1024 } = {}) {
  return {
    destroyed: false,
    writableEnded: false,
    writableLength: 0,
    frames: [],
    write(encoded) {
      this.frames.push(JSON.parse(encoded))
      this.writableLength += Buffer.byteLength(encoded, 'utf8')
      return this.writableLength <= highWaterMark
    },
  }
}

function socketObservers(socket, { onDrop } = {}) {
  return new TerminalObservers({
    terminalId: 'terminal-1',
    deliver: (owner, channel, payload, options) => writeFrame(socket, { owner, channel, payload }, options),
    onDrop,
  })
}

function pushUntil(observers, stop, limit = 64) {
  for (let attempt = 0; attempt < limit; attempt++) {
    const result = observers.broadcast('terminal:observer-output', { id: 'terminal-1', data: CHUNK }, {
      streamEpoch: 'epoch-1',
      endOffset: (attempt + 1) * CHUNK.length,
    })
    if (stop(result)) return result
  }
  assert.fail('the observer queue never reached the expected state')
}

test('a saturated subscriber pauses once its recovery marker is queued', () => {
  const socket = saturatingSocket()
  const observers = socketObservers(socket)
  observers.subscribe(OWNER, { maxQueueBytes: QUEUE_BYTES })

  const paused = pushUntil(observers, (result) => result.paused > 0)

  assert.deepEqual(paused, { delivered: 0, paused: 1, dropped: 0 })
  // The forced marker is queued on a live socket even though write() reported
  // backpressure, so the subscription survives and waits for the resubscribe.
  assert.equal(socket.frames.at(-1).channel, 'terminal:observer-snapshot-required')
  assert.deepEqual(socket.frames.at(-1).payload, {
    id: 'terminal-1',
    reason: 'slow_consumer',
    streamEpoch: 'epoch-1',
    endOffset: socket.frames.at(-1).payload.endOffset,
  })
  assert.deepEqual(observers.stats(), { subscribers: 1, paused: 1 })

  const frameCount = socket.frames.length
  assert.deepEqual(
    observers.broadcast('terminal:observer-output', { id: 'terminal-1', data: CHUNK }),
    { delivered: 0, paused: 0, dropped: 0 },
  )
  assert.equal(socket.frames.length, frameCount)
})

test('a subscriber whose recovery marker cannot be delivered is closed, not silently paused', () => {
  const socket = saturatingSocket()
  const drops = []
  const observers = socketObservers(socket, { onDrop: (owner, reason) => drops.push([owner, reason]) })
  observers.subscribe(OWNER, { maxQueueBytes: QUEUE_BYTES })

  observers.broadcast('terminal:observer-output', { id: 'terminal-1', data: CHUNK })
  // The consumer's socket dies while its queue is backed up: the one marker it
  // would ever receive cannot land, so the subscription must not linger.
  socket.destroyed = true

  const result = observers.broadcast('terminal:observer-output', { id: 'terminal-1', data: CHUNK }, {
    streamEpoch: 'epoch-1',
    endOffset: 4096,
  })

  assert.deepEqual(result, { delivered: 0, paused: 0, dropped: 1 })
  assert.deepEqual(observers.stats(), { subscribers: 0, paused: 0 })
  assert.deepEqual(drops, [[OWNER, 'undeliverable_snapshot_marker']])
})

test('a closed subscription is reachable again only through a fresh subscribe', () => {
  const socket = saturatingSocket()
  const observers = socketObservers(socket)
  observers.subscribe(OWNER, { maxQueueBytes: QUEUE_BYTES })
  socket.writableEnded = true

  assert.equal(observers.broadcast('terminal:observer-output', { id: 'terminal-1' }).dropped, 1)
  assert.equal(observers.unsubscribe(OWNER), false)

  const live = saturatingSocket()
  const resubscribed = socketObservers(live)
  assert.deepEqual(resubscribed.subscribe(OWNER, { maxQueueBytes: QUEUE_BYTES }), {
    subscriberCount: 1,
    maxQueueBytes: QUEUE_BYTES,
  })
  assert.equal(resubscribed.broadcast('terminal:observer-output', { id: 'terminal-1' }).delivered, 1)
})

test('closing one subscription mid-broadcast leaves the other subscribers intact', () => {
  const dead = saturatingSocket()
  dead.destroyed = true
  const healthy = saturatingSocket()
  const sockets = new Map([['dead-owner', dead], ['healthy-owner', healthy]])
  const observers = new TerminalObservers({
    terminalId: 'terminal-1',
    deliver: (owner, channel, payload, options) => writeFrame(sockets.get(owner), { channel, payload }, options),
  })
  observers.subscribe('dead-owner', { maxQueueBytes: QUEUE_BYTES })
  observers.subscribe('healthy-owner', { maxQueueBytes: QUEUE_BYTES })

  const result = observers.broadcast('terminal:observer-output', { id: 'terminal-1', data: 'hello' })

  assert.deepEqual(result, { delivered: 1, paused: 0, dropped: 1 })
  assert.deepEqual(observers.stats(), { subscribers: 1, paused: 0 })
  assert.equal(healthy.frames.length, 1)
})
