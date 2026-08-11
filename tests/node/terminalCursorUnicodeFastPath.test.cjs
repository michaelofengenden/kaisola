'use strict'

// The append path skips a per-code-unit rebuild when nothing needs repairing.
// It has to produce byte-identical output to the rebuild it replaces, and the
// inputs most likely to break it are astral scalars — genuine surrogate pairs
// that a careless scan would mistake for damage.

const test = require('node:test')
const assert = require('node:assert/strict')

const { TerminalCursor } = require('../../runtime/node-broker/companion/terminalCursor.cjs')

const epoch = 'terminal-unicode-fast-path'
const ESC = ''

test('well-formed output takes the fast path and survives it exactly', () => {
  const cases = [
    '',
    'plain ascii output\r\n',
    'accents: éüñ',
    'astral: \u{1F600}\u{1F389}',
    'zwj family: \u{1F469}‍\u{1F469}‍\u{1F467}',
    'cjk: 日本語のテキスト',
    `control bytes: ${ESC}[31mred${ESC}[0m`,
    'pair at the very end: \u{1F600}',
    'mixed \u{1F600} middle \u{1F600} end',
  ]
  for (const value of cases) {
    const cursor = new TerminalCursor({ streamEpoch: epoch, startOffset: 0 })
    const chunk = cursor.append(value)
    assert.equal(chunk.data, value, `round trip preserved: ${JSON.stringify(value)}`)
    assert.equal(
      chunk.endOffset - chunk.startOffset,
      Buffer.byteLength(value, 'utf8'),
      `offsets count real utf-8 bytes: ${JSON.stringify(value)}`
    )
    assert.equal(chunk.unicodeRepair, undefined, `nothing repaired: ${JSON.stringify(value)}`)
  }
})

test('a lone surrogate still takes the repair path and is still reported', () => {
  for (const [value, expected] of [
    ['lead only \uD83D', 1],
    ['\uDE00 trail only', 1],
    ['two \uD83D bad \uDE00 halves', 2],
  ]) {
    const cursor = new TerminalCursor({ streamEpoch: epoch, startOffset: 0 })
    const chunk = cursor.append(value)
    assert.ok(chunk.unicodeRepair, `repair reported for ${JSON.stringify(value)}`)
    assert.equal(chunk.unicodeRepair.replacements, expected)
    assert.ok(chunk.data.includes('�'), 'the damaged scalar became a replacement character')
    assert.equal(
      chunk.endOffset - chunk.startOffset,
      Buffer.byteLength(chunk.data, 'utf8'),
      'offsets still describe the bytes actually sent'
    )
  }
})

// A randomised sweep, because the interesting inputs are the ones nobody thinks
// to write down: a pair split across the end, a lead followed by another lead,
// two pairs back to back. Seeded so a failure is reproducible.
test('fast and repair paths agree across randomised surrogate soup', () => {
  const alphabet = ['a', '\r\n', `${ESC}[0m`, 'é', '日', '\u{1F600}', '\uD83D', '\uDE00', ' ']
  let seed = 20260811
  const next = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    return seed
  }
  for (let iteration = 0; iteration < 400; iteration += 1) {
    let value = ''
    const length = next() % 12
    for (let piece = 0; piece < length; piece += 1) {
      value += alphabet[next() % alphabet.length]
    }
    const cursor = new TerminalCursor({ streamEpoch: epoch, startOffset: 0 })
    const chunk = cursor.append(value)
    // Whichever path ran, the advertised offsets must describe exactly the
    // bytes delivered, or the app's contiguity check turns a merge into a gap
    // recovery.
    assert.equal(
      chunk.endOffset - chunk.startOffset,
      Buffer.byteLength(chunk.data, 'utf8'),
      `offsets match bytes for ${JSON.stringify(value)}`
    )
    if (!chunk.unicodeRepair) {
      assert.equal(chunk.data, value, `untouched input survives exactly: ${JSON.stringify(value)}`)
    }
  }
})
