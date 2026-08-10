'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  MAX_FRAME,
  TERMINAL_HISTORY_PAGE_BYTES,
  HELLO_FRAME_BYTES,
  DEFAULT_REQUEST_FRAME_BYTES,
  DEFAULT_RESPONSE_FRAME_BYTES,
  DEFAULT_EVENT_FRAME_BYTES,
  maximumEncodedFrameBytes,
  inspectBrokerFrame,
  validateEncodedBrokerFrame,
  encodeBrokerFrame,
} = require('../../runtime/node-broker/ipc/brokerWire.cjs')

test('method frame limits stay below the global transport ceiling', () => {
  assert.equal(MAX_FRAME, 56 * 1024 * 1024)
  assert.equal(TERMINAL_HISTORY_PAGE_BYTES, 4 * 1024 * 1024)
  assert.equal(HELLO_FRAME_BYTES, 64 * 1024)
  assert.equal(DEFAULT_REQUEST_FRAME_BYTES, 64 * 1024)
  assert.equal(DEFAULT_RESPONSE_FRAME_BYTES, 256 * 1024)
  assert.equal(DEFAULT_EVENT_FRAME_BYTES, 64 * 1024)
  assert.equal(maximumEncodedFrameBytes({ type: 'request', method: 'terminal.write' }), 1024 * 1024)
  assert.equal(maximumEncodedFrameBytes({ type: 'request', method: 'terminal.create' }), 256 * 1024)
  assert.equal(maximumEncodedFrameBytes({ type: 'response', method: 'terminal.attach' }), 50 * 1024 * 1024)
  assert.equal(maximumEncodedFrameBytes({ type: 'response', method: 'terminal.history' }), 26 * 1024 * 1024)
  assert.equal(maximumEncodedFrameBytes({ type: 'response', method: 'broker.status' }), 4 * 1024 * 1024)
  assert.equal(maximumEncodedFrameBytes({ type: 'response', method: 'terminal.resize' }), 256 * 1024)
  assert.equal(maximumEncodedFrameBytes({ type: 'event', channel: 'terminal:observer-output' }), 512 * 1024)
  assert.equal(maximumEncodedFrameBytes({ type: 'event', channel: 'terminal:observer-exit' }), 64 * 1024)
})

test('routing scan skips nested payloads and honors escaped top-level keys', () => {
  const encoded = '{"params":{"nested":[{"text":"} ] \\" still data"}]},"m\\u0065thod":"terminal.write","id":"request-1","type":"request"}'
  assert.deepEqual(inspectBrokerFrame(encoded), {
    type: 'request',
    id: 'request-1',
    method: 'terminal.write',
    channel: null,
  })
})

test('request encoding accepts the exact method boundary and rejects one byte over', () => {
  const maximum = maximumEncodedFrameBytes({ type: 'request', method: 'broker.status' })
  const frame = { type: 'request', id: 'request-2', method: 'broker.status', params: { padding: '' } }
  const overhead = Buffer.byteLength(JSON.stringify(frame))
  frame.params.padding = 'x'.repeat(maximum - overhead)

  const exact = encodeBrokerFrame(frame)
  assert.equal(Buffer.byteLength(exact), maximum + 1)
  assert.equal(validateEncodedBrokerFrame(exact.slice(0, -1)).encodedBytes, maximum)

  frame.params.padding += 'x'
  assert.throws(
    () => encodeBrokerFrame(frame),
    (error) => error.code === 'BROKER_FRAME_TOO_LARGE'
      && error.maximumBytes === maximum
      && error.encodedBytes === maximum + 1,
  )
})

test('response limits are correlated to the originating method before parse', () => {
  const encoded = JSON.stringify({
    result: { padding: 'x'.repeat(300 * 1024) },
    ok: true,
    id: 'request-3',
    type: 'response',
  })
  const envelope = inspectBrokerFrame(encoded)
  assert.throws(
    () => validateEncodedBrokerFrame(encoded, { envelope, method: 'terminal.resize' }),
    (error) => error.code === 'BROKER_FRAME_TOO_LARGE' && error.maximumBytes === 256 * 1024,
  )
  assert.doesNotThrow(() => validateEncodedBrokerFrame(encoded, { envelope, method: 'terminal.attach' }))
})

test('one worst-case escaped history page fits only its bounded paged response contract', () => {
  const encoded = JSON.stringify({
    type: 'response',
    id: 'request-4',
    ok: true,
    result: {
      ok: true,
      streamEpoch: 'epoch',
      output: '\u0000'.repeat(TERMINAL_HISTORY_PAGE_BYTES),
      startOffset: 0,
      endOffset: TERMINAL_HISTORY_PAGE_BYTES,
      hasMore: false,
      truncated: false,
    },
  })
  const result = validateEncodedBrokerFrame(encoded, { method: 'terminal.history' })
  assert.ok(result.encodedBytes > 24 * 1024 * 1024)
  assert.ok(result.encodedBytes <= 26 * 1024 * 1024)
  assert.throws(
    () => validateEncodedBrokerFrame(encoded, { method: 'terminal.resize' }),
    { code: 'BROKER_FRAME_TOO_LARGE' },
  )
})
