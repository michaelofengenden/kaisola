const test = require('node:test')
const assert = require('node:assert/strict')

const { AcpConnection } = require('./ipc/acp.cjs')

test('ACP session creation forwards namespaced Claude effort metadata', async () => {
  const meta = { claudeCode: { options: { effort: 'xhigh' } } }
  const conn = new AcpConnection({ cwd: '/tmp', mcpServers: [], sessionMeta: meta })
  let request
  conn.request = async (method, params) => {
    request = { method, params }
    return { sessionId: 'session-1', modes: null, configOptions: [] }
  }
  await conn.newSession()
  assert.equal(request.method, 'session/new')
  assert.deepEqual(request.params._meta, meta)
  assert.deepEqual(request.params.mcpServers, [])
})

test('ACP MCP compatibility retry preserves provider metadata', async () => {
  const meta = { claudeCode: { options: { effort: 'max' } } }
  const conn = new AcpConnection({
    cwd: '/tmp',
    sessionMeta: meta,
    mcpServers: [{ name: 'local', command: 'node', args: ['server.js'] }],
  })
  const calls = []
  conn.request = async (_method, params) => {
    calls.push(params)
    if (calls.length === 1) throw new Error('Invalid params')
    return { sessionId: 'session-2' }
  }
  await conn.newSession()
  assert.equal(calls.length, 2)
  assert.equal(calls[0].mcpServers.length, 1)
  assert.deepEqual(calls[0]._meta, meta)
  assert.deepEqual(calls[1].mcpServers, [])
  assert.deepEqual(calls[1]._meta, meta)
})
