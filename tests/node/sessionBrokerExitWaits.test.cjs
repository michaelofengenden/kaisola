'use strict'

// A terminal exit wait outlives the request that made it: the reply only comes
// when the pty exits, which can be hours later. These contracts pin the wait to
// the socket that asked, so a dropped connection takes its closures with it and
// the terminal itself keeps running.
const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')

const brokerScript = path.resolve(__dirname, '../../runtime/node-broker/session-broker.cjs')

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitFor(predicate, label, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value) return value
    await delay(20)
  }
  throw new Error(`timed out waiting for ${label}`)
}

function startBroker() {
  const root = fs.mkdtempSync('/tmp/kaisola-broker-exit-waits-')
  fs.chmodSync(root, 0o700)
  const brokerRoot = path.join(root, 'session-broker')
  const storageDir = path.join(root, 'terminal-cache')
  fs.mkdirSync(brokerRoot, { mode: 0o700 })
  fs.mkdirSync(storageDir, { mode: 0o700 })
  const config = {
    protocol: 2,
    securityEpoch: 1,
    implementationVersion: 2,
    packageSchema: 1,
    packageVersion: 'exit-waits',
    contentDigest: 'c'.repeat(64),
    token: crypto.randomBytes(32).toString('hex'),
    socketPath: path.join(brokerRoot, 'broker.sock'),
    infoFile: path.join(brokerRoot, 'broker.json'),
    lockFile: path.join(brokerRoot, 'broker.lock'),
    storageDir,
    logFile: path.join(brokerRoot, 'broker.log'),
    startedAt: Date.now(),
    version: 'exit-waits-test',
    smoke: false,
  }
  const launchFile = path.join(brokerRoot, 'launch-native-exit-waits.json')
  fs.writeFileSync(launchFile, JSON.stringify(config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, NODE_ENV: 'test' },
  })
  let stderr = ''
  child.stderr.on('data', (chunk) => { stderr += chunk })
  return { root, config, child, stderr: () => stderr }
}

async function connectClient(config) {
  const socket = net.createConnection(config.socketPath)
  socket.setEncoding('utf8')
  let buffer = ''
  const frames = []
  socket.on('data', (chunk) => {
    buffer += chunk
    let newline
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline)
      buffer = buffer.slice(newline + 1)
      if (line) frames.push(JSON.parse(line))
    }
  })
  socket.on('error', () => {})
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  socket.write(`${JSON.stringify({
    type: 'hello',
    protocol: 2,
    token: config.token,
    instanceId: crypto.randomUUID(),
    appVersion: 'exit-waits-test',
    access: 'administrator',
    features: ['broker-administration-v1'],
  })}\n`)
  const hello = await waitFor(() => frames.find((frame) => frame.type === 'hello'), 'broker hello')
  assert.equal(hello.ok, true)
  let sequence = 0
  const send = (method, params = {}) => {
    const id = `request-${++sequence}`
    socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`)
    return id
  }
  const request = async (method, params = {}) => {
    const id = send(method, params)
    return waitFor(() => frames.find((frame) => frame.type === 'response' && frame.id === id), `${method} response`)
  }
  const response = (id) => frames.find((frame) => frame.type === 'response' && frame.id === id)
  return { socket, hello, send, request, response }
}

test('a dropped client takes its terminal exit wait with it', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch { /* already gone */ }
    // SIGKILL gives the broker no chance to reap its PTY children, and the
    // orphaned spawn-helpers otherwise outlive the test. The mkdtemp root is
    // unique to this fixture, so a full-command-line match kills exactly its
    // helpers and nothing else.
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch { /* nothing to reap */ }
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')

  const watcher = await connectClient(fixture.config)
  const observerClient = await connectClient(fixture.config)
  const created = await watcher.request('terminal.create', {
    ownerId: '0',
    projectId: 'exit-waits',
    id: 'long-running-terminal',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(created.result.ok, true)

  const diagnostics = async () => {
    const rows = await observerClient.request('terminal.diagnostics', { ownerId: '0' })
    return rows.result.find((row) => row.id === 'long-running-terminal')
  }

  // The reply cannot arrive until the pty exits, so the request is sent without
  // awaiting it: the broker's retained waiter is the thing under test.
  const pendingWait = watcher.send('terminal.waitForExit', {
    ownerId: '0',
    projectId: 'exit-waits',
    id: 'long-running-terminal',
  })
  await waitFor(async () => (await diagnostics()).exitWaiterCount === 1, 'a retained exit waiter')
  assert.equal(watcher.response(pendingWait), undefined, 'a live terminal answers no exit wait')

  watcher.socket.destroy()

  await waitFor(async () => (await diagnostics()).exitWaiterCount === 0, 'the waiter to leave with the socket')
  const survivor = await diagnostics()
  assert.equal(survivor.exited, false, 'cancelling a wait must not stop the terminal')
  assert.equal(fixture.stderr(), '')

  observerClient.socket.destroy()
})
