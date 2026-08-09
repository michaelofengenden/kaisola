'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')

const brokerScript = path.resolve(__dirname, '../../runtime/node-broker/session-broker.cjs')
const { MAX_TERMINAL_WRITE_BYTES } = require('../../runtime/node-broker/ipc/terminalManager.cjs')
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

function startBroker({ rejectionProbe = false, maximumLiveTerminals } = {}) {
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
    ...(maximumLiveTerminals == null ? {} : { maximumLiveTerminals }),
  }
  const launchFile = path.join(brokerRoot, 'launch-native-integration.json')
  fs.writeFileSync(launchFile, JSON.stringify(config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: {
      ...process.env,
      NODE_ENV: 'test',
      KAISOLA_TEST_BROKER_NO_CLIENT_EXIT_MS: '100',
      ...(rejectionProbe ? { KAISOLA_TEST_BROKER_REJECTION_PROBE: '1' } : {}),
    },
  })
  let stderr = ''
  child.stderr.on('data', (chunk) => { stderr += chunk })
  return { root, config, child, stderr: () => stderr }
}

test('process-wide pty capacity is typed, scoped, diagnostic, and reusable', async (t) => {
  const fixture = startBroker({ maximumLiveTerminals: 1 })
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')

  const first = await connectClient(fixture.config, 'controller')
  const firstParams = {
    mutationId: crypto.randomUUID(),
    ownerId: 'first-owner',
    projectId: 'capacity-first-project',
    id: 'capacity-first-terminal',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  }
  const created = await first.request('terminal.create', firstParams)
  assert.equal(created.ok, true)
  assert.equal(created.result.ok, true)

  const idempotent = await first.request('terminal.create', {
    ...firstParams,
    mutationId: crypto.randomUUID(),
  })
  assert.equal(idempotent.result.ok, true)
  assert.equal(idempotent.result.existed, true)

  const controllerStatus = await first.request('broker.status', {
    ownerId: 'first-owner',
    projectId: 'capacity-first-project',
  })
  assert.equal(controllerStatus.ok, true)
  assert.equal(controllerStatus.result.terminalCapacity, undefined)

  const second = await connectClient(fixture.config, 'controller')
  const denied = await second.request('terminal.create', {
    mutationId: crypto.randomUUID(),
    ownerId: 'second-owner',
    projectId: 'capacity-second-project',
    id: 'capacity-second-terminal',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(denied.ok, true)
  assert.deepEqual(denied.result, {
    ok: false,
    code: 'terminal_capacity_exceeded',
    message: 'broker terminal capacity reached',
    maximumLiveTerminals: 1,
  })

  const observer = await connectClient(fixture.config, 'observer')
  const inventory = await observer.request('broker.inventory', { ownerId: '0' })
  assert.equal(inventory.ok, true)
  assert.deepEqual(inventory.result.status.terminalCapacity, {
    liveTerminalCount: 1,
    maximumLiveTerminals: 1,
    availableTerminalSlots: 0,
  })
  assert.deepEqual(
    inventory.result.live.map((row) => row.id),
    ['capacity-first-terminal'],
  )

  const released = await first.request('terminal.release', {
    mutationId: crypto.randomUUID(),
    ownerId: 'first-owner',
    projectId: 'capacity-first-project',
    id: 'capacity-first-terminal',
  })
  assert.equal(released.result.ok, true)
  const replacement = await second.request('terminal.create', {
    mutationId: crypto.randomUUID(),
    ownerId: 'second-owner',
    projectId: 'capacity-second-project',
    id: 'capacity-second-terminal',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(replacement.result.ok, true)

  await second.request('terminal.release', {
    mutationId: crypto.randomUUID(),
    ownerId: 'second-owner',
    projectId: 'capacity-second-project',
    id: 'capacity-second-terminal',
  })
  observer.socket.destroy()
  second.socket.destroy()
  first.socket.destroy()
})

async function connectClient(
  config,
  access = 'administrator',
  requestedFeatures,
  expectAccepted = true,
) {
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
  const features = requestedFeatures
    ?? (access === 'administrator' ? ['broker-administration-v1'] : [])
  socket.write(`${JSON.stringify({
    type: 'hello',
    protocol: 2,
    token: config.token,
    instanceId: crypto.randomUUID(),
    appVersion: 'integration-test',
    access,
    features,
  })}\n`)
  const hello = await next((frame) => frame.type === 'hello')
  assert.equal(hello.ok, expectAccepted)
  let sequence = 0
  const request = async (method, params = {}) => {
    const id = `request-${++sequence}`
    socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`)
    return next((frame) => frame.type === 'response' && frame.id === id)
  }
  return { socket, hello, request }
}

test('broker mutation ids replay one terminal.write outcome without duplicate input', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')
  const controller = await connectClient(fixture.config)
  const ownerId = 'mutation-owner'
  const projectId = 'mutation-idempotency'
  const terminalId = 'idempotent-write-terminal'
  const created = await controller.request('terminal.create', {
    mutationId: crypto.randomUUID(),
    ownerId,
    projectId,
    id: terminalId,
    command: '/bin/sh',
    args: ['-c', 'stty -echo; while IFS= read -r line; do printf "SEEN:%s\\n" "$line"; done'],
    cwd: fixture.root,
  })
  assert.equal(created.result.ok, true)

  const mutationId = crypto.randomUUID()
  const params = {
    mutationId,
    ownerId,
    projectId,
    id: terminalId,
    data: 'apply-once\n',
  }
  const first = await controller.request('terminal.write', params)
  const replay = await controller.request('terminal.write', params)
  assert.deepEqual(replay.result, first.result)
  assert.equal(first.result.ok, true)

  const output = await waitFor(async () => {
    const response = await controller.request('terminal.snapshot', {
      ownerId, projectId, id: terminalId,
    })
    return response.result.output.includes('SEEN:apply-once') ? response.result.output : null
  }, 'one applied write')
  assert.equal(output.match(/SEEN:apply-once/g)?.length, 1)

  const reused = await controller.request('terminal.write', { ...params, data: 'different-input\n' })
  assert.equal(reused.ok, false)
  assert.equal(reused.code, 'mutation_id_reused')

  await controller.request('terminal.release', {
    mutationId: crypto.randomUUID(), ownerId, projectId, id: terminalId,
  })
  controller.socket.destroy()
})

test('terminal.write rejects coercible and oversized wire payloads before node-pty', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')
  const controller = await connectClient(fixture.config)
  const ownerId = 'bounded-write-owner'
  const projectId = 'bounded-write-project'
  const terminalId = 'bounded-write-terminal'
  const created = await controller.request('terminal.create', {
    mutationId: crypto.randomUUID(),
    ownerId,
    projectId,
    id: terminalId,
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(created.result.ok, true)

  const nonString = await controller.request('terminal.write', {
    mutationId: crypto.randomUUID(), ownerId, projectId, id: terminalId, data: 42,
  })
  assert.deepEqual(nonString.result, {
    ok: false,
    code: 'invalid_terminal_write_payload',
    message: 'terminal.write data must be a string',
    maximumBytes: MAX_TERMINAL_WRITE_BYTES,
  })

  const oversized = await controller.request('terminal.write', {
    mutationId: crypto.randomUUID(),
    ownerId,
    projectId,
    id: terminalId,
    data: 'x'.repeat(MAX_TERMINAL_WRITE_BYTES + 1),
  })
  assert.deepEqual(oversized.result, {
    ok: false,
    code: 'terminal_write_payload_too_large',
    message: `terminal.write data exceeds ${MAX_TERMINAL_WRITE_BYTES} UTF-8 bytes`,
    maximumBytes: MAX_TERMINAL_WRITE_BYTES,
    actualBytes: MAX_TERMINAL_WRITE_BYTES + 1,
  })

  const exact = await controller.request('terminal.write', {
    mutationId: crypto.randomUUID(),
    ownerId,
    projectId,
    id: terminalId,
    data: 'é'.repeat(MAX_TERMINAL_WRITE_BYTES / 2),
  })
  assert.deepEqual(exact.result, { ok: true })

  await controller.request('terminal.release', {
    mutationId: crypto.randomUUID(), ownerId, projectId, id: terminalId,
  })
  controller.socket.destroy()
})

test('administration is negotiated separately from controller owner identity', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })

  const rejectedAdministrator = await connectClient(
    fixture.config,
    'administrator',
    [],
    false,
  )
  assert.match(rejectedAdministrator.hello.message, /authentication failed/)
  rejectedAdministrator.socket.destroy()

  const controller = await connectClient(
    fixture.config,
    'controller',
    ['broker-administration-v1'],
  )
  assert.equal(controller.hello.access, 'controller')
  assert.equal(controller.hello.negotiatedFeatures.includes('broker-administration-v1'), false)
  const created = await controller.request('terminal.create', {
    ownerId: 'ordinary-owner',
    projectId: 'authorization-test',
    id: 'authorization-terminal',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(created.result.ok, true)

  for (const params of [
    { ownerId: '0' },
    { ownerId: 0 },
    { ownerId: ' 0 ' },
    {},
    { ownerId: null },
  ]) {
    const rejected = await controller.request('terminal.list', params)
    assert.equal(rejected.ok, false)
    assert.match(rejected.message, /requires a nonzero owner identity/)
  }
  const forbiddenShutdown = await controller.request('broker.shutdown', {
    ownerId: 'ordinary-owner',
  })
  assert.equal(forbiddenShutdown.ok, false)
  assert.match(forbiddenShutdown.message, /cannot invoke broker administration/)

  const ownedStatus = await controller.request('broker.status', {
    ownerId: 'ordinary-owner',
    projectId: 'authorization-test',
  })
  assert.equal(ownedStatus.ok, true)
  assert.deepEqual(ownedStatus.result.terminals.map((row) => row.id), ['authorization-terminal'])

  const peer = await connectClient(fixture.config, 'controller')
  const peerStatus = await peer.request('broker.status', {
    ownerId: 'ordinary-owner',
    projectId: 'authorization-test',
  })
  assert.equal(peerStatus.ok, true)
  assert.deepEqual(peerStatus.result.terminals, [])

  const observer = await connectClient(fixture.config, 'observer')
  const observed = await observer.request('broker.inventory', { ownerId: '0' })
  assert.equal(observed.ok, true)
  assert.ok(observed.result.live.some((row) => row.id === 'authorization-terminal'))

  const administrator = await connectClient(fixture.config, 'administrator')
  assert.equal(administrator.hello.access, 'administrator')
  assert.ok(administrator.hello.negotiatedFeatures.includes('broker-administration-v1'))
  const global = await administrator.request('broker.inventory', { ownerId: '0' })
  assert.equal(global.ok, true)
  assert.ok(global.result.live.some((row) => row.id === 'authorization-terminal'))

  administrator.socket.destroy()
  observer.socket.destroy()
  peer.socket.destroy()
  controller.socket.destroy()
})

test('broker.inventory returns one stable observer snapshot', async (t) => {
  const fixture = startBroker()
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')

  const controller = await connectClient(fixture.config)
  const created = await controller.request('terminal.create', {
    ownerId: '0',
    projectId: 'atomic-inventory',
    id: 'atomic-inventory-terminal',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(created.result.ok, true)

  const observer = await connectClient(fixture.config, 'observer')
  assert.ok(observer.hello.features.includes('broker-inventory-v1'))
  const response = await observer.request('broker.inventory', { ownerId: '0' })
  assert.equal(response.ok, true)
  assert.equal(response.result.ok, true)
  assert.equal(response.result.state, 'stable')
  assert.equal(response.result.activityEpoch, response.result.status.activityEpoch)
  assert.equal(response.result.status.inFlightMutations, 0)
  for (const rows of [response.result.diagnostics, response.result.live]) {
    assert.ok(rows.some((row) => row.id === 'atomic-inventory-terminal'))
  }

  observer.socket.destroy()
  controller.socket.destroy()
})

test('unhandled rejection policy preserves observation while fencing mutations', async (t) => {
  const fixture = startBroker({ rejectionProbe: true })
  t.after(() => {
    try { fixture.child.kill('SIGKILL') } catch {}
    try { spawnSync('/usr/bin/pkill', ['-9', '-f', fixture.root]) } catch {}
    fs.rmSync(fixture.root, { recursive: true, force: true })
  })
  await waitFor(() => fs.existsSync(fixture.config.infoFile), 'broker metadata')
  const controller = await connectClient(fixture.config)
  const created = await controller.request('terminal.create', {
    ownerId: '0',
    projectId: 'rejection-policy',
    id: 'preserved-after-rejection',
    command: '/bin/cat',
    args: [],
    cwd: fixture.root,
  })
  assert.equal(created.ok, true)
  assert.equal(created.result.ok, true)
  const terminalPid = created.result.pid

  process.kill(fixture.child.pid, 'SIGUSR1')
  const background = await waitFor(async () => {
    const status = await controller.request('broker.status', { ownerId: '0' })
    return status.result?.health?.backgroundRejectionCount === 1 ? status.result.health : null
  }, 'classified background rejection')
  assert.deepEqual(background, {
    state: 'healthy',
    mutationFence: false,
    backgroundRejectionCount: 1,
    invariantFailureCount: 0,
    lastBackgroundOperation: 'test-probe',
  })
  const stillWritable = await controller.request('terminal.write', {
    ownerId: '0', projectId: 'rejection-policy', id: 'preserved-after-rejection', data: 'still-live\n',
  })
  assert.equal(stillWritable.result.ok, true)

  process.kill(fixture.child.pid, 'SIGUSR2')
  const degraded = await waitFor(async () => {
    const status = await controller.request('broker.status', { ownerId: '0' })
    return status.result?.health?.state === 'degraded' ? status.result.health : null
  }, 'degraded broker health')
  assert.deepEqual(degraded, {
    state: 'degraded',
    mutationFence: true,
    backgroundRejectionCount: 1,
    invariantFailureCount: 1,
    lastBackgroundOperation: 'test-probe',
  })

  const blocked = await controller.request('terminal.write', {
    ownerId: '0', projectId: 'rejection-policy', id: 'preserved-after-rejection', data: 'must-not-commit\n',
  })
  assert.equal(blocked.ok, false)
  assert.match(blocked.message, /mutations are fenced after an invariant failure/)

  const visible = await controller.request('terminal.list', { ownerId: '0' })
  assert.equal(visible.ok, true)
  assert.ok(visible.result.some((terminal) => terminal.id === 'preserved-after-rejection'))
  assert.equal(fixture.child.exitCode, null)
  assert.doesNotThrow(() => process.kill(terminalPid, 0))

  const log = fs.readFileSync(fixture.config.logFile, 'utf8')
  assert.match(log, /background rejection operation=test-probe/)
  assert.match(log, /fatal rejection classification=unhandled mutations=fenced/)
  assert.doesNotMatch(log, /rejection-probe-secret-marker/)
  controller.socket.destroy()
})

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
