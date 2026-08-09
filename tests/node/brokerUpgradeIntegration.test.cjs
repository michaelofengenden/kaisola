'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')

const brokerScript = path.resolve(__dirname, '../../runtime/node-broker/session-broker.cjs')
const oldDigest = 'a'.repeat(64)
const newDigest = 'b'.repeat(64)

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
  const root = fs.mkdtempSync('/tmp/kaisola-broker-upgrade-')
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
    packageVersion: 'integration-old',
    contentDigest: oldDigest,
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
  const launchFile = path.join(brokerRoot, 'launch-native-integration.json')
  fs.writeFileSync(launchFile, JSON.stringify(config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: {
      ...process.env,
      NODE_ENV: 'test',
      KAISOLA_TEST_BROKER_NO_CLIENT_EXIT_MS: '100',
    },
  })
  let stderr = ''
  child.stderr.on('data', (chunk) => { stderr += chunk })
  return { root, config, child, stderr: () => stderr }
}

async function connectClient(config, access = 'controller') {
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
  const next = async (predicate) => waitFor(() => frames.find(predicate), 'broker frame')
  socket.write(`${JSON.stringify({
    type: 'hello',
    protocol: 2,
    token: config.token,
    instanceId: crypto.randomUUID(),
    appVersion: 'integration-test',
    access,
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

test('oversized small-method request is rejected before dispatch without poisoning the socket', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')

  const controller = await connectClient(fixture.config)
  const rejected = await controller.request('broker.status', {
    padding: 'x'.repeat(70 * 1024),
  })
  assert.equal(rejected.ok, false)
  assert.match(rejected.message, /broker request exceeds 65536 byte limit/)

  const healthy = await controller.request('broker.status')
  assert.equal(healthy.ok, true)
  assert.equal(healthy.result.pid, fixture.child.pid)
  assert.equal(fixture.child.exitCode, null)
  controller.socket.destroy()
})

test('sealed broker identity is published and safe update commit rejects racing mutations', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    // SIGKILL gives the broker no chance to reap its PTY children, and the
    // orphaned spawn-helpers otherwise outlive the test by days. The mkdtemp
    // root is unique to this fixture, so a full-command-line match kills
    // exactly its helpers and nothing else.
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')
    .catch((error) => {
      const log = fs.existsSync(fixture.config.logFile) ? fs.readFileSync(fixture.config.logFile, 'utf8') : ''
      throw new Error(`${error.message}: exit=${fixture.child.exitCode} stderr=${fixture.stderr()} log=${log}`)
    })
  const metadata = JSON.parse(fs.readFileSync(fixture.config.infoFile, 'utf8'))
  assert.equal(metadata.contentDigest, oldDigest)

  const observer = await connectClient(fixture.config, 'observer')
  assert.equal(observer.hello.contentDigest, oldDigest)
  assert.ok(observer.hello.features.includes('broker-update-v1'))
  const forbidden = await observer.request('broker.shutdownForUpdate', { ownerId: '0' })
  assert.equal(forbidden.ok, false)
  assert.match(forbidden.message, /observer access cannot invoke broker mutations/)
  observer.socket.destroy()

  const controller = await connectClient(fixture.config)
  assert.equal(controller.hello.contentDigest, oldDigest)
  const status = await controller.request('broker.status', { ownerId: '0' })
  assert.equal(status.ok, true)
  assert.equal(status.result.contentDigest, oldDigest)
  assert.ok(status.result.features.includes('broker-update-v1'))

  const staleIdentity = await controller.request('broker.shutdownForUpdate', {
    ownerId: '0',
    expectedPid: fixture.child.pid,
    expectedStartedAt: fixture.config.startedAt + 1,
    expectedContentDigest: oldDigest,
    targetContentDigest: newDigest,
  })
  assert.equal(staleIdentity.result.state, 'identity_changed')
  assert.equal(fixture.child.exitCode, null)

  const accepted = await controller.request('broker.shutdownForUpdate', {
    ownerId: '0',
    expectedPid: fixture.child.pid,
    expectedStartedAt: fixture.config.startedAt,
    expectedContentDigest: oldDigest,
    targetContentDigest: newDigest,
  })
  assert.deepEqual(accepted.result, {
    ok: true,
    state: 'updating',
    fromContentDigest: oldDigest,
    targetContentDigest: newDigest,
  })

  const raced = await controller.request('terminal.create', {
    ownerId: '0', projectId: 'integration', id: 'must-not-spawn',
  })
  assert.equal(raced.ok, false)
  assert.match(raced.message, /update is already committed/)
  controller.socket.destroy()

  const exit = await waitFor(
    () => fixture.child.exitCode != null ? { code: fixture.child.exitCode } : null,
    'safe broker exit',
  )
  assert.equal(exit.code, 0)
  assert.equal(fs.existsSync(fixture.config.infoFile), false)
  assert.equal(fs.existsSync(fixture.config.socketPath), false)
  assert.equal(fixture.stderr(), '')
})

test('rolling cutover preserves an idle PTY and rejects late activity, input, and lease races', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    // SIGKILL gives the broker no chance to reap its PTY children, and the
    // orphaned spawn-helpers otherwise outlive the test by days. The mkdtemp
    // root is unique to this fixture, so a full-command-line match kills
    // exactly its helpers and nothing else.
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')
  const controller = await connectClient(fixture.config)
  const created = await controller.request('terminal.create', {
    ownerId: '0',
    projectId: 'rolling-test',
    id: 'preserved-terminal',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(created.ok, true)
  assert.equal(created.result.ok, true)
  const terminalPid = created.result.pid

  const prepare = (stabilityWindowMs = 150) => controller.request('broker.prepareRollingUpdate', {
    ownerId: '0',
    expectedPid: fixture.child.pid,
    expectedStartedAt: fixture.config.startedAt,
    expectedContentDigest: oldDigest,
    targetContentDigest: newDigest,
    stabilityWindowMs,
  })

  const outputTrigger = path.join(fixture.root, 'emit-synthetic-output')
  const synthetic = await controller.request('terminal.create', {
    ownerId: '0',
    projectId: 'rolling-test',
    id: 'synthetic-output-terminal',
    command: '/bin/sh',
    args: [
      '-c',
      // Bounded poll (~60s ceiling): if the test aborts before writing the
      // trigger file, the watcher exits on its own instead of spinning
      // forever in an orphaned PTY.
      'i=0; while [ ! -f "$1" ]; do i=$((i+1)); [ "$i" -gt 6000 ] && exit 1; sleep 0.01; done; printf synthetic-output; sleep 5',
      'kaisola-output-race',
      outputTrigger,
    ],
    cwd: fixture.root,
  })
  assert.equal(synthetic.result.ok, true)
  const pendingOutputRace = prepare(300)
  await delay(30)
  fs.writeFileSync(outputTrigger, 'emit', { mode: 0o600 })
  const outputRace = await pendingOutputRace
  assert.equal(outputRace.result.state, 'pending')
  assert.equal(outputRace.result.reason, 'activity_changed')
  await controller.request('terminal.release', {
    ownerId: '0', projectId: 'rolling-test', id: 'synthetic-output-terminal',
  })

  const inputRace = prepare()
  await delay(30)
  const input = await controller.request('terminal.write', {
    ownerId: '0', projectId: 'rolling-test', id: 'preserved-terminal', data: 'late input\n',
  })
  assert.equal(input.result.ok, true)
  const inputResult = await inputRace
  assert.equal(inputResult.result.state, 'pending')
  assert.equal(inputResult.result.reason, 'activity_changed')

  const agentRace = prepare()
  await delay(30)
  const busy = await controller.request('terminal.agentTurn', {
    ownerId: '0', projectId: 'rolling-test', id: 'preserved-terminal', busy: true,
  })
  assert.equal(busy.result.ok, true)
  const agentResult = await agentRace
  assert.equal(agentResult.result.state, 'pending')
  assert.equal(agentResult.result.reason, 'activity_changed')
  await controller.request('terminal.agentTurn', {
    ownerId: '0', projectId: 'rolling-test', id: 'preserved-terminal', busy: false,
  })

  const leaseRace = prepare()
  await delay(30)
  const lease = await controller.request('terminal.controlLease', {
    ownerId: '0', projectId: 'rolling-test', id: 'preserved-terminal', active: true,
  })
  assert.equal(lease.result.ok, true)
  const leaseResult = await leaseRace
  assert.equal(leaseResult.result.state, 'pending')
  assert.equal(leaseResult.result.reason, 'lease_changed')

  const rolling = await prepare(75)
  assert.equal(rolling.result.state, 'rolling')
  assert.equal(rolling.result.fromContentDigest, oldDigest)
  assert.equal(rolling.result.targetContentDigest, newDigest)

  const rejectedCreate = await controller.request('terminal.create', {
    ownerId: '0', projectId: 'rolling-test', id: 'must-route-to-new-generation',
  })
  assert.equal(rejectedCreate.ok, false)
  assert.match(rejectedCreate.message, /generation is draining/)

  const status = await controller.request('broker.status', { ownerId: '0' })
  const preserved = status.result.terminals.find((terminal) => terminal.id === 'preserved-terminal')
  assert.equal(preserved.pid, terminalPid)
  assert.equal(status.result.generationState, 'draining')
  assert.equal(status.result.drainingTargetContentDigest, newDigest)

  await controller.request('terminal.controlLease', {
    ownerId: '0', projectId: 'rolling-test', id: 'preserved-terminal', active: false,
  })
  await controller.request('terminal.release', {
    ownerId: '0', projectId: 'rolling-test', id: 'preserved-terminal',
  })
  controller.socket.destroy()
  await delay(250)
  assert.equal(fixture.child.exitCode, null, 'an empty drain waits for explicit retirement')
  assert.equal(fs.existsSync(fixture.config.infoFile), true)

  const retirementController = await connectClient(fixture.config)
  const retired = await retirementController.request('broker.retireDraining', {
    ownerId: '0',
    expectedPid: fixture.child.pid,
    expectedStartedAt: fixture.config.startedAt,
    expectedContentDigest: oldDigest,
    targetContentDigest: newDigest,
  })
  assert.equal(retired.result.state, 'retiring')
  retirementController.socket.destroy()
  const exit = await waitFor(
    () => fixture.child.exitCode != null ? { code: fixture.child.exitCode } : null,
    'draining broker retirement',
  )
  assert.equal(exit.code, 0)
})
