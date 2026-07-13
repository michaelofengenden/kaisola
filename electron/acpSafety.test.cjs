const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const { AcpConnection } = require('./ipc/acp.cjs')
const { _acpTest } = require('./ipc/acpHandler.cjs')

const invoke = async (connection, method, params) => {
  let result
  let error
  connection.respond = (_id, value) => { result = value }
  connection.respondError = (_id, code, message) => { error = { code, message } }
  await connection._handleRequest({ jsonrpc: '2.0', id: 1, method, params })
  return { result, error }
}

test('ACP file callbacks stay inside the workspace across traversal and symlinks', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-acp-root-'))
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-acp-outside-'))
  t.after(() => {
    fs.rmSync(root, { recursive: true, force: true })
    fs.rmSync(outside, { recursive: true, force: true })
  })
  fs.writeFileSync(path.join(root, 'inside.txt'), 'inside')
  fs.writeFileSync(path.join(outside, 'secret.txt'), 'secret')
  fs.symlinkSync(outside, path.join(root, 'escape'))
  const connection = new AcpConnection({ cwd: root })

  const valid = await invoke(connection, 'fs/read_text_file', { path: 'inside.txt' })
  assert.deepEqual(valid.result, { content: 'inside' })

  const traversal = await invoke(connection, 'fs/read_text_file', { path: '../secret.txt' })
  assert.match(traversal.error.message, /outside the active workspace/)

  const symlink = await invoke(connection, 'fs/read_text_file', { path: 'escape/secret.txt' })
  assert.match(symlink.error.message, /resolves outside the active workspace/)

  const write = await invoke(connection, 'fs/write_text_file', { path: 'nested/result.txt', content: 'safe' })
  assert.deepEqual(write.result, {})
  assert.equal(fs.readFileSync(path.join(root, 'nested/result.txt'), 'utf8'), 'safe')
})

test('ACP callbacks bound file size and terminal cwd', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-acp-limits-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  let terminalCreated = false
  const connection = new AcpConnection({ cwd: root }, {
    terminalHost: { create: async () => { terminalCreated = true; return { terminalId: 'bad' } } },
  })

  const oversized = await invoke(connection, 'fs/write_text_file', {
    path: 'large.txt',
    content: 'x'.repeat((8 * 1024 * 1024) + 1),
  })
  assert.match(oversized.error.message, /exceeds/)
  assert.equal(fs.existsSync(path.join(root, 'large.txt')), false)

  const terminal = await invoke(connection, 'terminal/create', {
    command: 'pwd',
    cwd: path.dirname(root),
  })
  assert.match(terminal.error.message, /outside the active workspace/)
  assert.equal(terminalCreated, false)
})

test('ACP requests fail immediately when the adapter is disconnected', async () => {
  const connection = new AcpConnection({ cwd: os.tmpdir() })
  await assert.rejects(connection.request('initialize', {}), /not connected/)
  assert.equal(connection.pending.size, 0)
})

test('ACP terminal callbacks are isolated to the connection that created them', async () => {
  const calls = []
  let createRequest
  const terminalHost = {
    async create(request) { createRequest = request; calls.push(['create']); return { terminalId: 'acp-term-owned' } },
    async output(id) { calls.push(['output', id]); return { output: 'private' } },
    async waitForExit(id) { calls.push(['wait', id]); return { exitCode: 0 } },
    async kill(id) { calls.push(['kill', id]) },
    async release(id) { calls.push(['release', id]) },
  }
  const owner = new AcpConnection({ cwd: os.tmpdir() }, { terminalHost })
  const peer = new AcpConnection({ cwd: os.tmpdir() }, { terminalHost })

  const created = await invoke(owner, 'terminal/create', {
    command: 'true',
    cwd: os.tmpdir(),
    env: [{ name: 'KAISOLA_TEST_VALUE', value: 'mesh-ready' }, { name: 'bad-name', value: 'ignored' }],
    outputByteLimit: 0,
  })
  assert.deepEqual(created.result, { terminalId: 'acp-term-owned' })
  assert.equal(createRequest.env.KAISOLA_TEST_VALUE, 'mesh-ready')
  assert.deepEqual(Object.keys(createRequest.env), ['KAISOLA_TEST_VALUE'])
  assert.equal(createRequest.outputByteLimit, 0)

  for (const method of ['terminal/output', 'terminal/wait_for_exit', 'terminal/kill', 'terminal/release']) {
    const blocked = await invoke(peer, method, { terminalId: 'acp-term-owned' })
    assert.match(blocked.error.message, /not owned by this agent connection/)
  }
  assert.deepEqual(calls, [['create']])

  const output = await invoke(owner, 'terminal/output', { terminalId: 'acp-term-owned' })
  assert.deepEqual(output.result, { output: 'private' })
  const released = await invoke(owner, 'terminal/release', { terminalId: 'acp-term-owned' })
  assert.deepEqual(released.result, {})
  const afterRelease = await invoke(owner, 'terminal/output', { terminalId: 'acp-term-owned' })
  assert.match(afterRelease.error.message, /not owned by this agent connection/)
  assert.deepEqual(calls, [['create'], ['output', 'acp-term-owned'], ['release', 'acp-term-owned']])
})

test('disposing an ACP connection releases every terminal it still owns', async () => {
  const released = []
  const connection = new AcpConnection({ cwd: os.tmpdir() }, {
    terminalHost: {
      async create() { return { terminalId: 'acp-term-dispose' } },
      release(id) { released.push(id); return Promise.resolve() },
      kill() { throw new Error('release should succeed') },
    },
  })
  const created = await invoke(connection, 'terminal/create', { command: 'true', cwd: os.tmpdir() })
  assert.equal(created.result.terminalId, 'acp-term-dispose')
  connection.dispose()
  assert.deepEqual(released, ['acp-term-dispose'])
  assert.equal(connection.ownedTerminalIds.size, 0)
})

test('awaited ACP disposal releases command PTYs before broker disconnect', async () => {
  const calls = []
  let releases = 0
  const connection = new AcpConnection({ cwd: os.tmpdir() }, {
    terminalHost: {
      async create() { return { terminalId: 'acp-term-quit' } },
      async release(id) {
        calls.push(['release', id])
        releases++
        if (releases === 1) throw new Error('command still exiting')
      },
      async kill(id) { calls.push(['kill', id]) },
    },
  })
  const created = await invoke(connection, 'terminal/create', { command: 'true', cwd: os.tmpdir() })
  assert.equal(created.result.terminalId, 'acp-term-quit')
  const result = await connection.disposeAndWait()
  assert.deepEqual(result, { ok: true, released: 1, failed: 0 })
  assert.deepEqual(calls, [
    ['release', 'acp-term-quit'],
    ['kill', 'acp-term-quit'],
    ['release', 'acp-term-quit'],
  ])
  assert.equal(connection.ownedTerminalIds.size, 0)
})

test('ACP terminal ownership follows renderer adoption and remains releasable', async () => {
  const calls = []
  const oldSender = { id: 9601, isDestroyed: () => false, send() {} }
  const newSender = { id: 9602, isDestroyed: () => false, send() {} }
  const broker = {
    async terminal(method, sender, params) {
      calls.push({ method, sender, id: params.id, projectId: params.projectId })
      if (method === 'create') return { ok: true }
      if (method === 'output') return { output: 'survived', truncated: false }
      return { ok: true }
    },
  }
  const entry = { sender: oldSender, conn: { ownedTerminalIds: new Set() } }
  const host = _acpTest.buildTerminalHost(entry, os.tmpdir(), 'codex', 'Codex', 'project-adopt', broker)
  entry.terminalHost = host

  const { terminalId } = await host.create({ command: 'true', args: [] })
  entry.conn.ownedTerminalIds.add(terminalId)
  oldSender.isDestroyed = () => true
  const moved = await _acpTest.transferEntryTerminalOwnership(entry, newSender)
  assert.deepEqual(moved, { ok: true, moved: 1 })
  _acpTest.bindEntryToSender(entry, newSender)

  assert.deepEqual(await host.output(terminalId), { output: 'survived', truncated: false, exitStatus: undefined })
  await host.release(terminalId)
  assert.deepEqual(calls.map(({ method, sender }) => [method, sender.id]), [
    ['create', 9601],
    ['attach', 9602],
    ['output', 9602],
    ['release', 9602],
  ])
  await assert.rejects(host.output(terminalId), /ownership is unavailable/)
})

test('ACP terminal ownership handoff rolls back every earlier PTY on failure', async () => {
  const calls = []
  const oldSender = { id: 9701, isDestroyed: () => false, send() {} }
  const newSender = { id: 9702, isDestroyed: () => false, send() {} }
  let failId = null
  const broker = {
    async terminal(method, sender, params) {
      calls.push([method, sender.id, params.id])
      if (method === 'create') return { ok: true }
      if (method === 'attach' && sender === newSender && params.id === failId) {
        throw new Error('injected handoff failure')
      }
      if (method === 'output') return { output: String(sender.id) }
      return { ok: true }
    },
  }
  const entry = { sender: oldSender, conn: { ownedTerminalIds: new Set() } }
  const host = _acpTest.buildTerminalHost(entry, os.tmpdir(), 'codex', 'Codex', 'project-rollback', broker)
  entry.terminalHost = host
  const first = (await host.create({ command: 'one', args: [] })).terminalId
  const second = (await host.create({ command: 'two', args: [] })).terminalId
  failId = second
  entry.conn.ownedTerminalIds = new Set([first, second])

  const moved = await _acpTest.transferEntryTerminalOwnership(entry, newSender)
  assert.equal(moved.ok, false)
  assert.match(moved.message, /injected handoff failure/)
  assert.equal((await host.output(first)).output, String(oldSender.id))
  assert.equal((await host.output(second)).output, String(oldSender.id))
  assert.deepEqual(calls.filter(([method]) => method === 'attach').map(([, owner, id]) => [owner, id]), [
    [newSender.id, first],
    [newSender.id, second],
    [oldSender.id, first],
  ])
})

test('renderer sensitive globs are sanitized, deduplicated, and bounded', () => {
  const long = `**/${'x'.repeat(700)}`
  const clean = _acpTest.sanitizeSensitiveGlobs([
    '  **/private-a  ',
    '**/private-a',
    '**/nul\0-secret',
    long,
    null,
    ...Array.from({ length: 90 }, (_, index) => `**/bounded-${index}`),
  ])

  assert.equal(clean[0], '**/private-a')
  assert.equal(clean[1], '**/nul-secret')
  assert.equal(clean.filter((glob) => glob === '**/private-a').length, 1)
  assert.equal(clean.length, 64)
  assert.ok(clean.every((glob) => typeof glob === 'string' && glob.length > 0 && glob.length <= 512 && !glob.includes('\0')))
  assert.equal(_acpTest.sanitizeSensitiveGlobs('**/not-an-array'), null)
})

test('renderer sensitive globs are isolated by exact sender identity', (t) => {
  const senderA = { id: 9401 }
  const senderB = { id: 9402 }
  const reusedId = { id: 9401 }
  const entryA = _acpTest.bindEntryToSender({}, senderA)
  const entryB = _acpTest.bindEntryToSender({}, senderB)
  const keyA = '9401|guardrail-test-a'
  const keyB = '9402|guardrail-test-b'
  _acpTest.connections.set(keyA, entryA)
  _acpTest.connections.set(keyB, entryB)
  t.after(() => {
    _acpTest.connections.delete(keyA)
    _acpTest.connections.delete(keyB)
    _acpTest.clearRendererSensitiveGlobs(senderA)
    _acpTest.clearRendererSensitiveGlobs(senderB)
    _acpTest.clearRendererSensitiveGlobs(reusedId)
  })

  _acpTest.setRendererSensitiveGlobs(senderA, ['**/alpha.secret'])
  _acpTest.setRendererSensitiveGlobs(senderB, ['**/beta.secret'])

  assert.equal(_acpTest.isSensitivePath('/repo/alpha.secret', _acpTest.sensitiveGlobsForSender(senderA)), true)
  assert.equal(_acpTest.isSensitivePath('/repo/beta.secret', _acpTest.sensitiveGlobsForSender(senderA)), false)
  assert.equal(_acpTest.isSensitivePath('/repo/beta.secret', _acpTest.sensitiveGlobsForSender(senderB)), true)
  assert.equal(_acpTest.isSensitivePath('/repo/alpha.secret', entryA.sensitiveGlobs), true)
  assert.equal(_acpTest.isSensitivePath('/repo/alpha.secret', entryB.sensitiveGlobs), false)
  // A new WebContents object cannot inherit policy merely by reusing an id.
  _acpTest.setRendererSensitiveGlobs(reusedId, ['**/reused-id.secret'])
  assert.equal(_acpTest.isSensitivePath('/repo/reused-id.secret', entryA.sensitiveGlobs), false)
  assert.equal(_acpTest.isSensitivePath('/repo/alpha.secret', _acpTest.sensitiveGlobsForSender(reusedId)), false)
  assert.equal(_acpTest.isSensitivePath('/repo/reused-id.secret', _acpTest.sensitiveGlobsForSender(reusedId)), true)
})

test('orphan cleanup preserves its snapshot but adoption rebinds guardrails', (t) => {
  const oldSender = { id: 9501 }
  const livePeer = { id: 9502 }
  const adopter = { id: 9503 }
  t.after(() => {
    _acpTest.clearRendererSensitiveGlobs(oldSender)
    _acpTest.clearRendererSensitiveGlobs(livePeer)
    _acpTest.clearRendererSensitiveGlobs(adopter)
  })

  _acpTest.setRendererSensitiveGlobs(oldSender, ['**/old-window.secret'])
  _acpTest.setRendererSensitiveGlobs(livePeer, ['**/peer-window.secret'])
  _acpTest.setRendererSensitiveGlobs(adopter, ['**/adopter.secret'])
  const entry = _acpTest.bindEntryToSender({}, oldSender)

  assert.equal(_acpTest.releaseAcpRenderer(oldSender), 0)
  assert.equal(_acpTest.isSensitivePath('/repo/old-window.secret', _acpTest.sensitiveGlobsForSender(oldSender)), false)
  assert.equal(_acpTest.isSensitivePath('/repo/.env.local', _acpTest.sensitiveGlobsForSender(oldSender)), true)
  assert.equal(_acpTest.isSensitivePath('/repo/old-window.secret', entry.sensitiveGlobs), true)
  assert.equal(_acpTest.isSensitivePath('/repo/peer-window.secret', entry.sensitiveGlobs), false)

  _acpTest.bindEntryToSender(entry, adopter)
  assert.equal(_acpTest.isSensitivePath('/repo/old-window.secret', entry.sensitiveGlobs), false)
  assert.equal(_acpTest.isSensitivePath('/repo/peer-window.secret', entry.sensitiveGlobs), false)
  assert.equal(_acpTest.isSensitivePath('/repo/adopter.secret', entry.sensitiveGlobs), true)
})
