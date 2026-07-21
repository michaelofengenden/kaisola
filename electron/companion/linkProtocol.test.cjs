'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  MUX_CLOSE,
  MUX_DATA,
  MUX_OPEN,
  MAX_RELAY_MESSAGE_BYTES,
  decodeMuxFrame,
  encodeMuxFrame,
} = require('./linkProtocol.cjs')

test('desktop relay multiplex codec matches the opaque binary contract', () => {
  const channelId = 'a'.repeat(22)
  const payload = Buffer.from([0, 1, 2, 127, 255])
  for (const type of [MUX_OPEN, MUX_DATA, MUX_CLOSE]) {
    const decoded = decodeMuxFrame(encodeMuxFrame(type, channelId, payload))
    assert.equal(decoded.type, type)
    assert.equal(decoded.channelId, channelId)
    assert.deepEqual(decoded.payload, payload)
  }
  assert.throws(() => decodeMuxFrame(Buffer.from([1, MUX_DATA, 22, 1])), /invalid relay multiplex frame/)
  assert.throws(
    () => encodeMuxFrame(MUX_DATA, channelId, Buffer.alloc(MAX_RELAY_MESSAGE_BYTES)),
    /invalid relay multiplex frame/,
  )
  assert.throws(
    () => decodeMuxFrame(Buffer.alloc(MAX_RELAY_MESSAGE_BYTES + 1)),
    /invalid relay multiplex frame/,
  )
})
