'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')

const brokerScript = path.resolve(__dirname, '../../runtime/node-broker/session-broker.cjs')
const contentDigest = 'c'.repeat(64)
// Shortening the base delay also shortens the derived ceiling, so the whole
// retry ladder stays inside the test's patience instead of stalling on the
// production backoff.
const RENDEZVOUS_RETRY_MS = 50

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitFor(predicate, label, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value) return value
    await delay(20)
  }
  throw new Error(`timed out waiting for ${label}`)
}

function startBroker() {
  const root = fs.mkdtempSync('/tmp/kaisola-broker-rendezvous-')
  fs.chmodSync(root, 0o700)
  const brokerRoot = path.join(root, 'session-broker')
  // Production keeps the info file beside the socket. This regression needs an
  // unwritable rendezvous directory, and revoking write on the socket's own
  // directory would break the AF_UNIX rebind instead of only the info write,
  // so the fixture gives the info file a directory of its own.
  const rendezvousRoot = path.join(brokerRoot, 'rendezvous')
  const storageDir = path.join(root, 'terminal-cache')
  fs.mkdirSync(brokerRoot, { mode: 0o700 })
  fs.mkdirSync(rendezvousRoot, { mode: 0o700 })
  fs.mkdirSync(storageDir, { mode: 0o700 })
  const config = {
    protocol: 2,
    securityEpoch: 1,
    implementationVersion: 2,
    packageSchema: 1,
    packageVersion: 'rendezvous-test',
    contentDigest,
    token: crypto.randomBytes(32).toString('hex'),
    socketPath: path.join(brokerRoot, 'broker.sock'),
    infoFile: path.join(rendezvousRoot, 'broker.json'),
    lockFile: path.join(brokerRoot, 'broker.lock'),
    storageDir,
    logFile: path.join(brokerRoot, 'broker.log'),
    startedAt: Date.now(),
    version: 'rendezvous-test',
    smoke: false,
  }
  const launchFile = path.join(brokerRoot, 'launch-rendezvous.json')
  fs.writeFileSync(launchFile, JSON.stringify(config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: {
      ...process.env,
      NODE_ENV: 'test',
      KAISOLA_TEST_BROKER_RENDEZVOUS_RETRY_MS: String(RENDEZVOUS_RETRY_MS),
    },
  })
  let stderr = ''
  child.stderr.on('data', (chunk) => { stderr += chunk })
  return { root, brokerRoot, rendezvousRoot, config, child, stderr: () => stderr }
}

async function connectClient(config) {
  const socket = net.createConnection(config.socketPath)
  socket.setEncoding('utf8')
  let buffer = ''
  const frames = []
  const waiters = []
  socket.on('data', (chunk) => {
    buffer += chunk
    let newline
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline)
      buffer = buffer.slice(newline + 1)
      if (!line) continue
      frames.push(JSON.parse(line))
      for (const wake of waiters.splice(0)) wake()
    }
  })
  socket.on('error', () => {})
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  const next = async (predicate) => waitFor(() => frames.find(predicate), 'broker frame')
  socket.write(`${JSON.stringify({
    type: 'hello',
    protocol: 2,
    token: config.token,
    instanceId: crypto.randomUUID(),
    appVersion: 'rendezvous-test',
    access: 'controller',
  })}\n`)
  const hello = await next((frame) => frame.type === 'hello')
  assert.equal(hello.ok, true)
  let sequence = 0
  const request = async (method, params = {}) => {
    const id = `request-${++sequence}`
    socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`)
    return next((frame) => frame.type === 'response' && frame.id === id)
  }
  return { socket, hello, request }
}

test('an unwritable info file degrades rendezvous, then republishes for a restarted GUI', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    // The test deliberately leaves the rendezvous directory unwritable if it
    // fails midway; the temporary root cannot be removed until write is back.
    try { fs.chmodSync(fixture.rendezvousRoot, 0o700) } catch {}
    try { fixture.child.kill('SIGKILL') } catch {}
    // SIGKILL gives the broker no chance to reap its PTY children, and the
    // orphaned spawn-helpers otherwise outlive the test by days. The mkdtemp
    // root is unique to this fixture, so a full-command-line match kills
    // exactly its helpers and nothing else.
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })

  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'initial broker rendezvous')
    .catch((error) => {
      const log = fs.existsSync(fixture.config.logFile) ? fs.readFileSync(fixture.config.logFile, 'utf8') : ''
      throw new Error(`${error.message}: exit=${fixture.child.exitCode} stderr=${fixture.stderr()} log=${log}`)
    })

  const controller = await connectClient(fixture.config)
  const created = await controller.request('terminal.create', {
    ownerId: '0',
    projectId: 'rendezvous-test',
    id: 'durable-terminal',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(created.result.ok, true)
  const terminalPid = created.result.pid

  const healthy = await controller.request('broker.status', { ownerId: '0' })
  assert.equal(typeof healthy.result.rendezvous, 'object')
  assert.equal(healthy.result.rendezvous.state, 'published')
  assert.equal(healthy.result.rendezvous.consecutiveFailures, 0)
  assert.equal(healthy.result.rendezvous.lastError, null)
  assert.equal(healthy.result.rendezvous.retryPending, false)
  assert.ok(Number.isFinite(healthy.result.rendezvous.publishedAt))

  // Reproduce the stranding: the rendezvous directory turns unwritable (ENOSPC
  // or an unwritable userData in the field) and something reaps the socket
  // pathname, which is the production trigger for republishing the info file.
  fs.unlinkSync(fixture.config.infoFile)
  fs.chmodSync(fixture.rendezvousRoot, 0o500)
  fs.unlinkSync(fixture.config.socketPath)

  const degraded = await waitFor(async () => {
    const status = await controller.request('broker.status', { ownerId: '0' })
    const rendezvous = status.result?.rendezvous
    return rendezvous?.state === 'degraded' ? rendezvous : null
  }, 'degraded rendezvous state')
  assert.ok(degraded.consecutiveFailures >= 1)
  assert.equal(degraded.lastError, 'EACCES')
  assert.equal(degraded.retryPending, true)
  assert.equal(fs.existsSync(fixture.config.infoFile), false)
  // The PTY and the already-authenticated socket are untouched by the
  // bookkeeping failure.
  const survivors = await controller.request('terminal.list', { ownerId: '0' })
  assert.equal(survivors.result.find((row) => row.id === 'durable-terminal')?.pid, terminalPid)

  // Nothing republishes the info file after this point except the broker's own
  // backoff, so the file coming back is the retry proving itself.
  fs.chmodSync(fixture.rendezvousRoot, 0o700)
  const republished = await waitFor(async () => {
    const status = await controller.request('broker.status', { ownerId: '0' })
    const rendezvous = status.result?.rendezvous
    return rendezvous?.state === 'published' ? rendezvous : null
  }, 'republished rendezvous state')
  assert.equal(republished.consecutiveFailures, 0)
  assert.equal(republished.lastError, null)
  assert.equal(republished.retryPending, false)

  const info = JSON.parse(fs.readFileSync(fixture.config.infoFile, 'utf8'))
  assert.equal(info.pid, fixture.child.pid)
  assert.equal(info.contentDigest, contentDigest)
  assert.equal(info.socketPath, fixture.config.socketPath)

  // A restarted GUI knows nothing but the republished file: it rendezvouses
  // with the recovered listener and adopts the PTY that stayed alive.
  const restarted = await connectClient({ socketPath: info.socketPath, token: info.token })
  assert.equal(restarted.hello.pid, fixture.child.pid)
  const rows = await restarted.request('terminal.list', { ownerId: '0' })
  const durable = rows.result.find((row) => row.id === 'durable-terminal')
  assert.ok(durable, 'restarted client cannot see the durable terminal')
  assert.equal(durable.pid, terminalPid)

  restarted.socket.destroy()
  controller.socket.destroy()
  assert.equal(fixture.stderr(), '')
})
