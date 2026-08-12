'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')

const {
  TerminalCursor,
  classifyResume,
  makeBoundedSnapshot,
} = require('../../runtime/node-broker/companion/terminalCursor.cjs')

const epoch = 'terminal-unicode-recovery'

test('snapshot repairs truncated UTF-8 without changing byte offsets', () => {
  const bytes = Buffer.concat([
    Buffer.from('before-', 'utf8'),
    Buffer.from([0xf0, 0x9f, 0x99]), // truncated four-byte scalar
    Buffer.from('-after', 'utf8'),
  ])

  const snapshot = makeBoundedSnapshot({
    streamEpoch: epoch,
    output: bytes,
    endOffset: bytes.length,
  })

  assert.equal(snapshot.output, 'before-�-after')
  assert.equal(Buffer.byteLength(snapshot.output, 'utf8'), bytes.length)
  assert.equal(snapshot.startOffset, 0)
  assert.equal(snapshot.endOffset, bytes.length)
  assert.deepEqual(snapshot.unicodeRepair, {
    code: 'invalid_unicode_repaired',
    replacements: 1,
    sourceBytes: 3,
  })
})

test('repair spans preserve offsets for one, two, and four corrupt bytes', () => {
  const cases = [
    { bytes: [0x80], output: '?', sourceBytes: 1 },
    { bytes: [0xc0, 0xaf], output: '??', sourceBytes: 2 },
    { bytes: [0xf5, 0x80, 0x80, 0x80], output: '�?', sourceBytes: 4 },
  ]

  for (const fixture of cases) {
    const bytes = Buffer.from(fixture.bytes)
    const snapshot = makeBoundedSnapshot({
      streamEpoch: epoch,
      output: bytes,
      endOffset: bytes.length,
    })
    assert.equal(snapshot.output, fixture.output)
    assert.equal(Buffer.byteLength(snapshot.output, 'utf8'), bytes.length)
    assert.deepEqual(snapshot.unicodeRepair, {
      code: 'invalid_unicode_repaired',
      replacements: 1,
      sourceBytes: fixture.sourceBytes,
    })
  }
})

test('repair does not consume valid bytes surrounding malformed continuation bytes', () => {
  const bytes = Buffer.from([0x61, 0xe2, 0x28, 0xa1, 0x62])
  const snapshot = makeBoundedSnapshot({
    streamEpoch: epoch,
    output: bytes,
    endOffset: bytes.length,
  })

  assert.equal(snapshot.output, 'a?(?b')
  assert.equal(Buffer.byteLength(snapshot.output, 'utf8'), bytes.length)
  assert.deepEqual(snapshot.unicodeRepair, {
    code: 'invalid_unicode_repaired',
    replacements: 2,
    sourceBytes: 2,
  })
})

test('cursor repairs a lone surrogate and reports the repair exactly once', () => {
  const cursor = new TerminalCursor({ streamEpoch: epoch })
  const event = cursor.append(`left-${String.fromCharCode(0xd83d)}-right`)

  assert.equal(event.data, 'left-�-right')
  assert.equal(event.startOffset, 0)
  assert.equal(event.endOffset, Buffer.byteLength(event.data, 'utf8'))
  assert.deepEqual(event.unicodeRepair, {
    code: 'invalid_unicode_repaired',
    replacements: 1,
    sourceBytes: 3,
  })
  assert.equal(cursor.position().offset, event.endOffset)
})

test('valid combining sequences and surrounding bytes remain byte-exact', () => {
  const output = `plain e\u0301 isolated \u0301 tail 🙂`
  const snapshot = makeBoundedSnapshot({
    streamEpoch: epoch,
    output,
    endOffset: Buffer.byteLength(output, 'utf8'),
  })

  assert.equal(snapshot.output, output)
  assert.equal(snapshot.unicodeRepair, undefined)
})

test('oversized corrupt tails stay bounded and retain their repair diagnostic', () => {
  const prefix = Buffer.alloc(512, 0x78)
  const suffix = Buffer.concat([
    Buffer.from('-tool-error-', 'utf8'),
    Buffer.from([0xed, 0xa0, 0x80]), // UTF-8 encoding of a lone surrogate
    Buffer.from('-end', 'utf8'),
  ])
  const bytes = Buffer.concat([prefix, suffix])

  const snapshot = makeBoundedSnapshot({
    streamEpoch: epoch,
    output: bytes,
    endOffset: bytes.length,
    maxBytes: 32,
  })

  assert.ok(Buffer.byteLength(snapshot.output, 'utf8') <= 32)
  assert.match(snapshot.output, /tool-error-�-end$/)
  assert.equal(snapshot.truncated, true)
  assert.equal(snapshot.endOffset - snapshot.startOffset, Buffer.byteLength(snapshot.output, 'utf8'))
  assert.deepEqual(snapshot.unicodeRepair, {
    code: 'invalid_unicode_repaired',
    replacements: 1,
    sourceBytes: 3,
  })
})

test('resume preserves a persisted repair diagnostic while slicing a valid suffix', () => {
  const output = 'prefix-�-suffix'
  const outputBytes = Buffer.byteLength(output, 'utf8')
  const snapshot = {
    streamEpoch: epoch,
    output,
    startOffset: 0,
    endOffset: outputBytes,
    truncated: false,
    exited: false,
    unicodeRepair: {
      code: 'invalid_unicode_repaired',
      replacements: 1,
      sourceBytes: 3,
    },
  }

  const offset = Buffer.byteLength('prefix-�', 'utf8')
  const resumed = classifyResume(snapshot, { streamEpoch: epoch, offset })

  assert.equal(resumed.kind, 'snapshot')
  assert.equal(resumed.reason, 'available_suffix')
  assert.equal(resumed.snapshot.output, '-suffix')
  assert.deepEqual(resumed.snapshot.unicodeRepair, snapshot.unicodeRepair)
})

test('a current cursor still receives the persisted repair diagnostic', () => {
  const output = 'repaired-�'
  const endOffset = Buffer.byteLength(output, 'utf8')
  const unicodeRepair = {
    code: 'invalid_unicode_repaired',
    replacements: 1,
    sourceBytes: 3,
  }
  const resumed = classifyResume({
    streamEpoch: epoch,
    output,
    startOffset: 0,
    endOffset,
    truncated: false,
    exited: false,
    unicodeRepair,
  }, { streamEpoch: epoch, offset: endOffset })

  assert.deepEqual(resumed, {
    kind: 'current',
    streamEpoch: epoch,
    offset: endOffset,
    unicodeRepair,
  })
})

test('resume repairs an old corrupt byte snapshot instead of dropping the session', () => {
  const output = Buffer.concat([
    Buffer.from('kept-', 'utf8'),
    Buffer.from([0xed, 0xa0, 0x80]),
    Buffer.from('-tail', 'utf8'),
  ])
  const resumed = classifyResume({
    streamEpoch: epoch,
    output,
    startOffset: 0,
    endOffset: output.length,
    truncated: false,
    exited: false,
  }, { streamEpoch: epoch, offset: 0 })

  assert.equal(resumed.kind, 'snapshot')
  assert.equal(resumed.snapshot.output, 'kept-�-tail')
  assert.deepEqual(resumed.snapshot.unicodeRepair, {
    code: 'invalid_unicode_repaired',
    replacements: 1,
    sourceBytes: 3,
  })
})

test('persisted repair diagnostics are validated fail closed', () => {
  assert.throws(() => makeBoundedSnapshot({
    streamEpoch: epoch,
    output: 'safe',
    endOffset: 4,
    unicodeRepair: {
      code: 'invalid_unicode_repaired',
      replacements: 1,
      sourceBytes: 3,
      raw: 'must not cross the diagnostic boundary',
    },
  }), (error) => error?.code === 'invalid_unicode_repair')

  assert.throws(() => makeBoundedSnapshot({
    streamEpoch: epoch,
    output: 'safe',
    endOffset: 4,
    unicodeRepair: {
      code: 'invalid_unicode_repaired',
      replacements: 2,
      sourceBytes: 1,
    },
  }), (error) => error?.code === 'invalid_unicode_repair')
})

test('ordinary valid snapshots keep their existing wire shape', () => {
  const output = 'ordinary terminal output 🙂'
  const snapshot = makeBoundedSnapshot({
    streamEpoch: epoch,
    output,
    endOffset: Buffer.byteLength(output, 'utf8'),
  })

  assert.deepEqual(snapshot, {
    streamEpoch: epoch,
    output,
    startOffset: 0,
    endOffset: Buffer.byteLength(output, 'utf8'),
    truncated: false,
    exited: false,
  })
})
