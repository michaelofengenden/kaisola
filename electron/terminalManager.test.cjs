const test = require('node:test')
const assert = require('node:assert/strict')
const terminalManager = require('./ipc/terminalManager.cjs')

test('waiting on a released ACP terminal never fabricates a successful exit', async () => {
  await assert.rejects(
    terminalManager.waitForExit('released-acp-terminal'),
    /no longer available/i,
  )
})

test('observer chunks and resume snapshots preserve UTF-8 byte boundaries', () => {
  const { splitUtf8, resumeFromSnapshot } = terminalManager.__test
  assert.deepEqual(splitUtf8('abc🙂\r\n', 4), ['abc', '🙂', '\r\n'])
  const snapshot = {
    streamEpoch: 'stream-1',
    output: '🙂\r\n',
    startOffset: 3,
    endOffset: 9,
    truncated: true,
    exited: false,
    exitStatus: null,
  }
  assert.deepEqual(resumeFromSnapshot(snapshot, 'stream-1', 9), {
    mode: 'current',
    cursor: { streamEpoch: 'stream-1', offset: 9 },
  })
  assert.deepEqual(resumeFromSnapshot(snapshot, 'stream-1', 7).snapshot, {
    ...snapshot,
    output: '\r\n',
    startOffset: 7,
  })
  assert.equal(resumeFromSnapshot(snapshot, 'stream-1', 2).resetReason, 'event_gap')
  assert.equal(resumeFromSnapshot(snapshot, 'stream-old', 9).resetReason, 'epoch_mismatch')
  assert.equal(resumeFromSnapshot(snapshot, 'stream-1', 4).resetReason, 'invalid_utf8_boundary')
})

test('fresh terminals suppress zsh partial-line markers without losing the shell environment', () => {
  const env = terminalManager.__test.terminalEnv({ KAISOLA_TEST_VALUE: 'present' })
  assert.equal(env.PROMPT_EOL_MARK, '')
  assert.equal(env.KAISOLA_TEST_VALUE, 'present')
  assert.equal(env.TERM, 'xterm-256color')
  assert.equal(env.TERM_PROGRAM, 'Kaisola')
})
