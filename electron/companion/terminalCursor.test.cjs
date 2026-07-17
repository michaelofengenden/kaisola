'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {
  CompanionTerminalCursorError,
  TerminalCursor,
  classifyResume,
  makeBoundedSnapshot,
  utf8Tail,
} = require('./terminalCursor.cjs')

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'terminal-cursor.json'), 'utf8'))

test('terminal offsets count UTF-8 bytes and match the golden emoji fixture', () => {
  const cursor = new TerminalCursor({ streamEpoch: fixture.streamEpoch })
  const chunks = fixture.chunks.map(({ data }) => cursor.append(data))
  assert.deepEqual(chunks, fixture.chunks.map((chunk) => ({ streamEpoch: fixture.streamEpoch, ...chunk })))
  assert.deepEqual(cursor.position(), { streamEpoch: fixture.streamEpoch, offset: 9 })
})

test('bounded tails never split a UTF-8 code point', () => {
  assert.deepEqual(utf8Tail('abc🙂\r\n', 6), {
    text: '🙂\r\n',
    bytes: 6,
    droppedBytes: 3,
    truncated: true,
  })
  assert.deepEqual(utf8Tail('abc🙂\r\n', 5), {
    text: '\r\n',
    bytes: 2,
    droppedBytes: 7,
    truncated: true,
  })
  assert.deepEqual(utf8Tail('🙂', 1), { text: '', bytes: 0, droppedBytes: 4, truncated: true })
})

test('bounded snapshot matches golden offsets and declares truncation', () => {
  const snapshot = makeBoundedSnapshot({
    streamEpoch: fixture.streamEpoch,
    output: fixture.chunks.map(({ data }) => data).join(''),
    endOffset: 9,
    maxBytes: 6,
  })
  assert.deepEqual(snapshot, { ...fixture.snapshot, streamEpoch: fixture.streamEpoch, exited: false })
})

test('resume classification distinguishes current, suffix, gap, stale epoch, and invalid cursors', () => {
  const snapshot = { ...fixture.snapshot, streamEpoch: fixture.streamEpoch, exited: false }
  assert.deepEqual(classifyResume(snapshot, { streamEpoch: fixture.streamEpoch, offset: 9 }), {
    kind: 'current',
    streamEpoch: fixture.streamEpoch,
    offset: 9,
  })

  const suffix = classifyResume(snapshot, { streamEpoch: fixture.streamEpoch, offset: 7 })
  assert.equal(suffix.kind, 'snapshot')
  assert.equal(suffix.reason, 'available_suffix')
  assert.deepEqual(suffix.snapshot, {
    streamEpoch: fixture.streamEpoch,
    output: '\r\n',
    startOffset: 7,
    endOffset: 9,
    truncated: true,
    exited: false,
  })

  assert.equal(classifyResume(snapshot, { streamEpoch: fixture.streamEpoch, offset: 2 }).reason, 'event_gap')
  assert.equal(classifyResume(snapshot, { streamEpoch: 'terminal-epoch-old', offset: 9 }).reason, 'epoch_mismatch')
  assert.equal(classifyResume(snapshot, { streamEpoch: fixture.streamEpoch, offset: 10 }).reason, 'cursor_ahead')
  assert.equal(classifyResume(snapshot, { streamEpoch: fixture.streamEpoch, offset: 4 }).reason, 'invalid_utf8_boundary')
})

test('invalid UTF-8 bytes and inconsistent snapshot offsets fail closed', () => {
  const cursor = new TerminalCursor({ streamEpoch: fixture.streamEpoch })
  assert.throws(() => cursor.append(Buffer.from([0xf0, 0x9f])), (error) => {
    assert.equal(error instanceof CompanionTerminalCursorError, true)
    assert.equal(error.code, 'invalid_utf8')
    return true
  })
  assert.throws(() => classifyResume({
    streamEpoch: fixture.streamEpoch,
    output: '🙂',
    startOffset: 4,
    endOffset: 9,
    truncated: true,
  }, { streamEpoch: fixture.streamEpoch, offset: 9 }), /offsets do not match/)
})

