'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')
const {
  FEATURES,
  TERMINAL_EXIT_STATUS_FEATURE,
  negotiateFeatures,
  eventPayloadForFeatures,
} = require('../../runtime/node-broker/ipc/brokerWire.cjs')

const brokerScript = path.resolve(__dirname, '../../runtime/node-broker/session-broker.cjs')

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
  const root = fs.mkdtempSync('/tmp/kaisola-broker-exit-status-')
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
    packageVersion: 'exit-status-test',
    contentDigest: 'c'.repeat(64),
    token: crypto.randomBytes(32).toString('hex'),
    socketPath: path.join(brokerRoot, 'broker.sock'),
    infoFile: path.join(brokerRoot, 'broker.json'),
    lockFile: path.join(brokerRoot, 'broker.lock'),
    storageDir,
    logFile: path.join(brokerRoot, 'broker.log'),
    startedAt: Date.now(),
    version: 'exit-status-test',
    smoke: false,
  }
  const launchFile = path.join(brokerRoot, 'launch-exit-status.json')
  fs.writeFileSync(launchFile, JSON.stringify(config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, NODE_ENV: 'test' },
  })
  let stderr = ''
  child.stderr.on('data', (chunk) => { stderr += chunk })
  return { root, config, child, stderr: () => stderr }
}

/** One authenticated controller connection. `features` is what this client
 * claims it can decode — omit it to impersonate a build that predates the
 * structured exit status. */
async function connectClient(config, { features } = {}) {
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
    appVersion: 'exit-status-test',
    ...(features ? { features } : {}),
  })}\n`)
  const hello = await next((frame) => frame.type === 'hello')
  assert.equal(hello.ok, true)
  let sequence = 0
  const request = async (method, params = {}) => {
    const id = `request-${++sequence}`
    socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`)
    return next((frame) => frame.type === 'response' && frame.id === id)
  }
  const event = async (channel) => next((frame) => frame.type === 'event' && frame.channel === channel)
  return { socket, hello, request, event }
}

/** Run a shell that kills itself with SIGTERM and hand back the exit event the
 * given client received. SIGTERM leaves exit code 0, so the bare code cannot
 * tell this apart from a session that finished normally. */
async function exitEventForSignalledTerminal(client, terminalID, cwd) {
  const created = await client.request('terminal.create', {
    id: terminalID,
    ownerId: '1',
    projectId: 'exit-status',
    command: '/bin/sh',
    args: ['-c', 'kill -TERM $$'],
    cwd,
  })
  assert.equal(created.ok, true, JSON.stringify(created))
  assert.equal(created.result.ok, true, JSON.stringify(created.result))
  return client.event(`terminal:exit:${terminalID}`)
}

test('negotiation keeps a client to the event shapes it asked for', () => {
  assert.ok(FEATURES.includes(TERMINAL_EXIT_STATUS_FEATURE))
  assert.deepEqual([...negotiateFeatures(undefined)], [])
  assert.deepEqual([...negotiateFeatures(['not-a-broker-feature'])], [])
  assert.deepEqual(
    [...negotiateFeatures([TERMINAL_EXIT_STATUS_FEATURE, 'not-a-broker-feature'])],
    [TERMINAL_EXIT_STATUS_FEATURE],
  )

  const status = { exitCode: 0, signal: 15 }
  const negotiated = negotiateFeatures([TERMINAL_EXIT_STATUS_FEATURE])
  assert.deepEqual(eventPayloadForFeatures('terminal:exit:t1', status, negotiated), status)
  assert.equal(eventPayloadForFeatures('terminal:exit:t1', status, new Set()), 0)
  // Only the exit channel changed shape; everything else passes through.
  assert.equal(eventPayloadForFeatures('terminal:data:t1', 'output', new Set()), 'output')
  assert.deepEqual(
    eventPayloadForFeatures('terminal:observer-exit', { exitStatus: status }, new Set()),
    { exitStatus: status },
  )
})

test('the broker sends the structured exit status only to clients that negotiated it', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    // SIGKILL gives the broker no chance to reap its PTY children; the mkdtemp
    // root is unique to this fixture, so a full-command-line match kills
    // exactly its helpers and nothing else.
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata').catch((error) => {
    const log = fs.existsSync(fixture.config.logFile) ? fs.readFileSync(fixture.config.logFile, 'utf8') : ''
    throw new Error(`${error.message}: exit=${fixture.child.exitCode} stderr=${fixture.stderr()} log=${log}`)
  })

  const modern = await connectClient(fixture.config, { features: [TERMINAL_EXIT_STATUS_FEATURE] })
  t.after(() => modern.socket.destroy())
  assert.deepEqual(modern.hello.negotiatedFeatures, [TERMINAL_EXIT_STATUS_FEATURE])

  const legacy = await connectClient(fixture.config)
  t.after(() => legacy.socket.destroy())
  assert.deepEqual(legacy.hello.negotiatedFeatures, [])

  const modernExit = await exitEventForSignalledTerminal(
    modern,
    'term-exit-status-aaaaaaa1',
    fixture.config.storageDir,
  )
  assert.deepEqual(modernExit.payload, { exitCode: 0, signal: 15 })

  const legacyExit = await exitEventForSignalledTerminal(
    legacy,
    'term-exit-status-aaaaaaa2',
    fixture.config.storageDir,
  )
  assert.equal(legacyExit.payload, 0)
})
