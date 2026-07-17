'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { TerminalSpool, utf8Tail } = require('./ipc/terminalSpool.cjs')

test('UTF-8 tail truncation never begins inside an emoji', () => {
  assert.equal(utf8Tail('abc🙂\r\n', 6), '🙂\r\n')
  assert.equal(utf8Tail('abc🙂\r\n', 5), '\r\n')
})

test('a fresh terminal stream cannot inherit stale bytes from a dead PTY', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-test-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const old = new TerminalSpool({ dir, id: 'same-terminal', hotCap: 8, queueCap: 1 })
  old.push('old output')
  old.setVisible(false)
  old.close()
  assert.match(new TerminalSpool({ dir, id: 'same-terminal' }).snapshot().output, /old output/)
  assert.equal(new TerminalSpool({ dir, id: 'same-terminal', fresh: true }).snapshot().output, '')
})

