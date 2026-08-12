'use strict'

// End-to-end proof of the observer-only output negotiation, against a real
// broker process over a real unix socket with a real pty. The unit tests cover
// the decision inside terminalManager; this covers that the handshake actually
// reaches it and that an undeclared client is unaffected.

const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn } = require('node:child_process')

const brokerScript = path.resolve(__dirname, '../../runtime/node-broker/session-broker.cjs')
const {
  TERMINAL_OBSERVER_ONLY_OUTPUT_FEATURE,
  TERMINAL_OBSERVE_FEATURE,
} = require('../../runtime/node-broker/ipc/brokerWire.cjs')

async function waitFor(probe, description, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await probe()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  throw new Error(`timed out waiting for ${description}`)
}

function startBroker() {
  const root = fs.mkdtempSync('/tmp/kaisola-observer-only-')
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
    packageVersion: 'observer-only-integration',
    contentDigest: 'b'.repeat(64),
    token: crypto.randomBytes(32).toString('hex'),
    socketPath: path.join(brokerRoot, 'broker.sock'),
    infoFile: path.join(brokerRoot, 'broker.json'),
    lockFile: path.join(brokerRoot, 'broker.lock'),
    storageDir,
    logFile: path.join(brokerRoot, 'broker.log'),
    startedAt: Date.now(),
    version: 'integration-test',
    smoke: false,
  }
  const launchFile = path.join(brokerRoot, 'launch.json')
  fs.writeFileSync(launchFile, JSON.stringify(config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, NODE_ENV: 'test' },
  })
  child.stderr.resume()
  return { child, config, root }
}

async function connectClient(config, { features }) {
  await waitFor(() => fs.existsSync(config.socketPath), 'broker socket')
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
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  const next = async (predicate) => waitFor(
    async () => frames.find(predicate),
    'broker frame'
  )
  socket.write(`${JSON.stringify({
    type: 'hello',
    protocol: 2,
    token: config.token,
    instanceId: crypto.randomUUID(),
    appVersion: 'integration-test',
    access: 'controller',
    features,
  })}\n`)
  const hello = await next((frame) => frame.type === 'hello')
  assert.equal(hello.ok, true)
  let sequence = 0
  const request = async (method, params = {}) => {
    const id = `request-${++sequence}`
    socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`)
    return next((frame) => frame.type === 'response' && frame.id === id)
  }
  return { socket, hello, request, frames }
}

/** Drive one terminal to completion and report which channels it produced. */
async function observedChannels(t, { features, terminalId }) {
  const fixture = startBroker()
  t.after(() => {
    fixture.child.kill('SIGKILL')
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')
  const client = await connectClient(fixture.config, { features })
  t.after(() => client.socket.destroy())

  const ownerId = 'observer-only-owner'
  const projectId = 'observer-only-project'
  const created = await client.request('terminal.create', {
    ownerId,
    projectId,
    id: terminalId,
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(created.result.ok, true)

  // Subscribe on the same connection so both channels would reach these frames
  // if the broker produced both.
  const subscribed = await client.request('terminal.subscribe', {
    ownerId, projectId, id: terminalId,
  })
  assert.equal(subscribed.result.ok, true)

  await client.request('terminal.write', {
    ownerId, projectId, id: terminalId, data: 'observer-only round trip\n',
  })

  await waitFor(
    async () => client.frames.find((frame) =>
      frame.type === 'event'
      && frame.channel === 'terminal:observer-output'
      && String(frame.payload?.data || '').includes('observer-only round trip')),
    'the observer stream carried the output'
  )
  // Give any primary copy a generous chance to arrive; its flush window is 16ms.
  await new Promise((resolve) => setTimeout(resolve, 400))

  const channels = new Set(
    client.frames.filter((frame) => frame.type === 'event').map((frame) => frame.channel)
  )
  return channels
}

test('a client that does not negotiate still receives the primary terminal stream', async (t) => {
  const channels = await observedChannels(t, {
    features: [TERMINAL_OBSERVE_FEATURE],
    terminalId: 'legacy-primary-terminal',
  })
  assert.ok(
    channels.has('terminal:data:legacy-primary-terminal'),
    `an undeclared client must keep terminal:data, saw ${[...channels].join(', ')}`
  )
})

test('a client that negotiates observer-only output stops receiving the duplicate', async (t) => {
  const channels = await observedChannels(t, {
    features: [TERMINAL_OBSERVE_FEATURE, TERMINAL_OBSERVER_ONLY_OUTPUT_FEATURE],
    terminalId: 'observer-only-terminal',
  })
  assert.ok(
    channels.has('terminal:observer-output'),
    'the observer stream is what the client actually reads'
  )
  assert.ok(
    !channels.has('terminal:data:observer-only-terminal'),
    `the duplicate must not be produced, saw ${[...channels].join(', ')}`
  )
})
