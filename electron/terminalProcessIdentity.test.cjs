'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { __test } = require('./ipc/terminalHandler.cjs')

test('package-installed Codex is identified through its node foreground wrapper', () => {
  assert.equal(
    __test.wrappedCliProcess('node', 'node /Users/test/miniforge3/bin/codex'),
    'codex',
  )
  assert.equal(
    __test.wrappedCliProcess('node', 'node /opt/tools/codex.js app-server'),
    'codex',
  )
  assert.equal(__test.wrappedCliProcess('node', 'node /repo/scripts/dev-server.js'), 'node')
  assert.equal(__test.wrappedCliProcess('python', 'python codex'), 'python')
})
