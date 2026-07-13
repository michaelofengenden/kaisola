const test = require('node:test')
const assert = require('node:assert/strict')
const terminalManager = require('./ipc/terminalManager.cjs')

test('waiting on a released ACP terminal never fabricates a successful exit', async () => {
  await assert.rejects(
    terminalManager.waitForExit('released-acp-terminal'),
    /no longer available/i,
  )
})
