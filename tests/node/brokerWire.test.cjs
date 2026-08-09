'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { writeFrame } = require('../../runtime/node-broker/ipc/brokerWire.cjs')

/** A net.Socket stand-in whose buffer never drains. */
function socket({ highWaterMark = 16 * 1024, writableLength = 0 } = {}) {
  return {
    destroyed: false,
    writableEnded: false,
    writableLength,
    frames: [],
    write(encoded) {
      this.frames.push(encoded)
      this.writableLength += Buffer.byteLength(encoded, 'utf8')
      return this.writableLength <= highWaterMark
    },
  }
}

test('a forced frame on a saturated but live socket is queued and reported delivered', () => {
  const client = socket({ writableLength: 256 * 1024 })

  assert.equal(writeFrame(client, { type: 'event', channel: 'terminal:observer-snapshot-required' }, {
    force: true,
    maxQueueBytes: 64 * 1024,
  }), true)
  assert.equal(client.frames.length, 1)
})

test('a forced frame is undeliverable once the socket is destroyed or ended', () => {
  const destroyed = socket()
  destroyed.destroyed = true
  const ended = socket()
  ended.writableEnded = true
  const throwing = { destroyed: false, writableEnded: false, writableLength: 0, write() { throw new Error('EPIPE') } }

  for (const client of [destroyed, ended, throwing, null]) {
    assert.equal(writeFrame(client, { type: 'event' }, { force: true, maxQueueBytes: 64 * 1024 }), false)
  }
  assert.equal(destroyed.frames.length, 0)
  assert.equal(ended.frames.length, 0)
})

test('an unforced frame past the subscriber queue cap never reaches the socket', () => {
  const client = socket({ writableLength: 64 * 1024 })

  assert.equal(writeFrame(client, { type: 'event', payload: 'delta' }, { maxQueueBytes: 64 * 1024 }), false)
  assert.equal(client.frames.length, 0)
})

test('an unforced frame within the cap reports the socket flow-control result', () => {
  const draining = socket({ highWaterMark: 1024 * 1024 })
  assert.equal(writeFrame(draining, { type: 'event', payload: 'delta' }, { maxQueueBytes: 64 * 1024 }), true)

  const backedUp = socket({ highWaterMark: 8 })
  assert.equal(writeFrame(backedUp, { type: 'event', payload: 'delta' }, { maxQueueBytes: 64 * 1024 }), false)
  assert.equal(backedUp.frames.length, 1)
})
