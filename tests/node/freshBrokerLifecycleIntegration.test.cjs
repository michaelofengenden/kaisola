'use strict'

// Focused clean-start source-runtime smoke. This fixture starts with no prior
// broker or session state and exercises one newly created session through an
// empty post-release inventory; it does not cover packaged bootstrap or
// retained-session continuity.
const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')
const {
  BROKER_INVENTORY_FEATURE,
  TERMINAL_EXIT_STATUS_FEATURE,
} = require('../../runtime/node-broker/ipc/brokerWire.cjs')

const brokerScript = path.resolve(__dirname, '../../runtime/node-broker/session-broker.cjs')

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitFor(probe, description, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await probe()
    if (value) return value
    await delay(20)
  }
  throw new Error(`timed out waiting for ${description}`)
}

function startFreshBroker() {
  const root = fs.mkdtempSync('/tmp/kaisola-fresh-broker-lifecycle-')
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
    packageVersion: 'fresh-lifecycle-test',
    contentDigest: 'f'.repeat(64),
    token: crypto.randomBytes(32).toString('hex'),
    socketPath: path.join(brokerRoot, 'broker.sock'),
    infoFile: path.join(brokerRoot, 'broker.json'),
    lockFile: path.join(brokerRoot, 'broker.lock'),
    storageDir,
    logFile: path.join(brokerRoot, 'broker.log'),
    startedAt: Date.now(),
    version: 'fresh-lifecycle-test',
    smoke: false,
  }
  const launchFile = path.join(brokerRoot, 'launch-fresh-lifecycle.json')
  fs.writeFileSync(launchFile, JSON.stringify(config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, NODE_ENV: 'test' },
  })
  let stderr = ''
  child.stderr.on('data', (chunk) => { stderr += chunk })
  return { root, config, child, stderr: () => stderr }
}

async function connectClient(
  config,
  { access = 'controller', features = [TERMINAL_EXIT_STATUS_FEATURE] } = {}
) {
  await waitFor(() => fs.existsSync(config.socketPath), 'fresh broker socket')
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
    appVersion: 'fresh-lifecycle-test',
    access,
    features,
  })}\n`)
  const hello = await waitFor(
    () => frames.find((frame) => frame.type === 'hello'),
    'authenticated broker hello'
  )
  assert.equal(hello.ok, true)
  assert.deepEqual(hello.negotiatedFeatures, features)

  let sequence = 0
  const request = async (method, params = {}) => {
    const id = `fresh-request-${++sequence}`
    socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`)
    return waitFor(
      () => frames.find((frame) => frame.type === 'response' && frame.id === id),
      `${method} response`
    )
  }
  return { socket, frames, request }
}

function terminalOutput(frames, terminalID) {
  return frames
    .filter((frame) => frame.type === 'event' && frame.channel === `terminal:data:${terminalID}`)
    .map((frame) => String(frame.payload ?? ''))
    .join('')
}

test('a brand-new source broker completes create, write, resize, ETX, exit, release, and empty inventory', async (t) => {
  const fixture = startFreshBroker()
  let controller
  let observer
  t.after(() => {
    controller?.socket.destroy()
    observer?.socket.destroy()
    try { fixture.child.kill('SIGKILL') } catch { /* already gone */ }
    // A failed assertion can leave the pty spawn helper alive. The unique
    // launch root appears in its command line, so this fallback stays bounded
    // to the one clean-start fixture created above.
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch { /* nothing to reap */ }
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })

  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'fresh broker metadata')
    .catch((error) => {
      const log = fs.existsSync(fixture.config.logFile)
        ? fs.readFileSync(fixture.config.logFile, 'utf8')
        : ''
      throw new Error(`${error.message}: exit=${fixture.child.exitCode} stderr=${fixture.stderr()} log=${log}`)
    })
  controller = await connectClient(fixture.config)

  const identity = {
    ownerId: 'fresh-owner',
    projectId: 'fresh-project',
    id: 'fresh-lifecycle-terminal',
  }
  const created = await controller.request('terminal.create', {
    ...identity,
    command: '/bin/sh',
    args: [],
    cwd: fixture.root,
    cols: 80,
    rows: 24,
  })
  assert.equal(created.ok, true, JSON.stringify(created))
  assert.equal(created.result.ok, true, JSON.stringify(created.result))
  assert.equal(Number.isInteger(created.result.pid), true)

  // Octal escapes keep the expected token out of the tty's echoed command, so
  // observing it proves command output rather than local line discipline echo.
  const write = await controller.request('terminal.write', {
    ...identity,
    data: "printf '\\106\\122\\105\\123\\110\\137\\127\\122\\111\\124\\105\\137\\117\\113\\012'\n",
  })
  assert.equal(write.result.ok, true)
  await waitFor(
    () => terminalOutput(controller.frames, identity.id).includes('FRESH_WRITE_OK'),
    'written command output'
  )

  const resized = await controller.request('terminal.resize', {
    ...identity,
    cols: 132,
    rows: 41,
  })
  assert.equal(resized.result.ok, true)
  const geometry = await controller.request('terminal.write', {
    ...identity,
    data: "printf '\\107\\105\\117\\115\\105\\124\\122\\131\\040'; stty size\n",
  })
  assert.equal(geometry.result.ok, true)
  await waitFor(
    () => /GEOMETRY\s+41\s+132/u.test(terminalOutput(controller.frames, identity.id)),
    'resized pty geometry in terminal output'
  )

  const enterCat = await controller.request('terminal.write', {
    ...identity,
    data: "printf '\\103\\101\\124\\137\\122\\105\\101\\104\\131\\012'; exec /bin/cat\n",
  })
  assert.equal(enterCat.result.ok, true)
  await waitFor(
    () => terminalOutput(controller.frames, identity.id).includes('CAT_READY'),
    'foreground cat readiness'
  )

  const signalled = await controller.request('terminal.signal', identity)
  assert.equal(signalled.result.ok, true)
  const exit = await waitFor(
    () => controller.frames.find((frame) =>
      frame.type === 'event' && frame.channel === `terminal:exit:${identity.id}`),
    'structured terminal exit'
  )
  assert.deepEqual(exit.payload, { exitCode: 0, signal: 2 })

  const released = await controller.request('terminal.release', identity)
  assert.equal(released.result.ok, true)

  observer = await connectClient(fixture.config, {
    access: 'observer',
    features: [BROKER_INVENTORY_FEATURE],
  })
  const inventory = await observer.request('broker.inventory', { ownerId: '0' })
  assert.equal(inventory.ok, true)
  assert.equal(inventory.result.ok, true)
  assert.equal(inventory.result.state, 'stable')
  assert.deepEqual(inventory.result.live, [])
  assert.deepEqual(inventory.result.diagnostics, [])
  assert.equal(fixture.stderr(), '')
})
