'use strict'

// The broker's terminal id cap is an authorization boundary: truncating an
// overlong caller id to a fixed prefix hands the caller whatever terminal
// already owns that prefix, across projects and owners. These contracts drive
// the real socket so the rejection is proven on the wire, not just in the route.
const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')
const { TERMINAL_ID_MAX_LENGTH } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')

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
  const root = fs.mkdtempSync('/tmp/kaisola-broker-id-limit-')
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
    packageVersion: 'id-limit-test',
    contentDigest: 'c'.repeat(64),
    token: crypto.randomBytes(32).toString('hex'),
    socketPath: path.join(brokerRoot, 'broker.sock'),
    infoFile: path.join(brokerRoot, 'broker.json'),
    lockFile: path.join(brokerRoot, 'broker.lock'),
    storageDir,
    logFile: path.join(brokerRoot, 'broker.log'),
    startedAt: Date.now(),
    version: 'id-limit-test',
    smoke: false,
  }
  const launchFile = path.join(brokerRoot, 'launch-id-limit.json')
  fs.writeFileSync(launchFile, JSON.stringify(config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: {
      ...process.env,
      NODE_ENV: 'test',
      KAISOLA_TEST_BROKER_NO_CLIENT_EXIT_MS: '2000',
    },
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
    appVersion: 'id-limit-test',
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

test('colliding long id prefixes never alias one terminal across projects and owners', async (t) => {
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

  const projectA = 'nproj_alias-a'
  const projectB = 'nproj_alias-b'
  const head = `term-${projectA}-`
  const atCap = `${head}${'a'.repeat(TERMINAL_ID_MAX_LENGTH - head.length)}`
  assert.equal(atCap.length, TERMINAL_ID_MAX_LENGTH)

  const ownerA = await connectClient(fixture.config)
  const ownerB = await connectClient(fixture.config)

  const held = await ownerA.request('terminal.create', {
    ownerId: '1', projectId: projectA, id: atCap, command: '/bin/cat', args: [], cwd: fixture.root,
  })
  assert.equal(held.ok, true)
  assert.equal(held.result.ok, true, 'an id at the cap is still legal')

  // Same owner, an id one character past the cap: truncation used to hand this
  // caller the terminal above under a different name.
  const sameOwnerOverlong = await ownerA.request('terminal.create', {
    ownerId: '1', projectId: projectA, id: `${atCap}x`, command: '/bin/cat', args: [], cwd: fixture.root,
  })
  assert.equal(sameOwnerOverlong.result.ok, false)
  assert.equal(sameOwnerOverlong.result.code, 'terminal_id_too_long')
  assert.equal(sameOwnerOverlong.result.maxLength, TERMINAL_ID_MAX_LENGTH)
  assert.equal(sameOwnerOverlong.result.actualLength, `${atCap}x`.length)

  // Another project and owner sharing the same prefix is the ownership-record
  // collision: it must be rejected on the id, before any ownership comparison.
  const crossProject = await ownerB.request('terminal.create', {
    ownerId: '2', projectId: projectB, id: `${atCap}-${projectB}`, command: '/bin/cat', args: [], cwd: fixture.root,
  })
  assert.equal(crossProject.result.ok, false)
  assert.equal(crossProject.result.code, 'terminal_id_too_long')

  // The follow-on terminal methods share the cap. Attaching as the legitimate
  // owner is the case truncation silently satisfied.
  const attach = await ownerA.request('terminal.attach', {
    ownerId: '1', projectId: projectA, id: `${atCap}-tail`,
  })
  assert.equal(attach.ok, false)
  assert.match(attach.message, /terminal id exceeds 240 characters/)

  const write = await ownerA.request('terminal.write', {
    ownerId: '1', projectId: projectA, id: `${atCap}-tail`, data: 'must not reach the held pty\n',
  })
  assert.equal(write.ok, false)
  assert.match(write.message, /terminal id exceeds 240 characters/)

  // detachOwner is routed through its own exact-id seam, so prove the shared
  // wire gate still rejects before that otherwise non-truncating route runs.
  const detachOwner = await ownerA.request('terminal.detachOwner', {
    ownerId: '1', projectId: projectA, id: `${atCap}-tail`,
  })
  assert.equal(detachOwner.ok, false)
  assert.match(detachOwner.message, /terminal id exceeds 240 characters/)

  const status = await ownerA.request('broker.status', { ownerId: '0' })
  assert.deepEqual(
    status.result.terminals.map((entry) => entry.id),
    [atCap],
    'the rejected ids left no extra record and claimed no existing one',
  )

  await ownerA.request('terminal.release', { ownerId: '1', projectId: projectA, id: atCap })
  ownerA.socket.destroy()
  ownerB.socket.destroy()
})
