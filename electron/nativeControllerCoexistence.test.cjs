'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const {
  PROTOCOL,
  SECURITY_EPOCH,
  BROKER_IMPLEMENTATION_VERSION,
  BROKER_PACKAGE_SCHEMA,
} = require('./ipc/brokerWire.cjs')

const BROKER_SCRIPT = path.join(__dirname, 'session-broker.cjs')
const REQUEST_TIMEOUT_MS = 5_000
const WAIT_TIMEOUT_MS = 8_000

// Broker instance ids are UUID-shaped by contract, so these stable UUIDs carry
// the human roles that the test names call electron-like and native-like.
const ELECTRON_INSTANCE_ID = '10000000-0000-4000-8000-000000000001'
const NATIVE_INSTANCE_ID = '20000000-0000-4000-8000-000000000001'
const NATIVE_RECONNECT_INSTANCE_ID = '20000000-0000-4000-8000-000000000002'
const OBSERVER_INSTANCE_ID = '30000000-0000-4000-8000-000000000001'
const ELECTRON_OWNER_ID = 'electron-owner'
const NATIVE_OWNER_ID = 'native-owner'
const ELECTRON_PROJECT_ID = 'project-electron'
const NATIVE_PROJECT_ID = 'project-native'

const waitTick = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

async function waitFor(predicate, description, timeoutMs = WAIT_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value) return value
    await waitTick(20)
  }
  throw new Error(`timed out waiting for ${description}`)
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

class BrokerClient {
  constructor({ socketPath, token, instanceId, access = 'controller' }) {
    this.socketPath = socketPath
    this.token = token
    this.instanceId = instanceId
    this.access = access
    this.socket = null
    this.buffer = ''
    this.pending = new Map()
    this.events = []
    this.sequence = 0
    this.hello = null
  }

  async connect() {
    assert.equal(this.socket, null, 'client cannot connect twice')
    const socket = net.createConnection(this.socketPath)
    this.socket = socket
    socket.setNoDelay(true)

    return await new Promise((resolve, reject) => {
      let settled = false
      const finish = (callback, value) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        callback(value)
      }
      const timer = setTimeout(() => {
        socket.destroy()
        finish(reject, new Error('broker hello timed out'))
      }, REQUEST_TIMEOUT_MS)

      socket.once('connect', () => {
        socket.write(`${JSON.stringify({
          type: 'hello',
          protocol: PROTOCOL,
          token: this.token,
          instanceId: this.instanceId,
          appVersion: 'native-controller-coexistence-test',
          access: this.access,
        })}\n`)
      })
      socket.on('data', (chunk) => {
        this.buffer += chunk.toString('utf8')
        let newline
        while ((newline = this.buffer.indexOf('\n')) >= 0) {
          const line = this.buffer.slice(0, newline)
          this.buffer = this.buffer.slice(newline + 1)
          if (!line) continue
          let frame
          try {
            frame = JSON.parse(line)
          } catch (error) {
            socket.destroy()
            finish(reject, error)
            continue
          }
          if (!this.hello && frame.type === 'hello') {
            if (!frame.ok) {
              socket.destroy()
              finish(reject, new Error(frame.message || 'broker hello rejected'))
            } else {
              this.hello = frame
              finish(resolve, frame)
            }
          } else if (frame.type === 'response') {
            const pending = this.pending.get(frame.id)
            if (!pending) continue
            this.pending.delete(frame.id)
            clearTimeout(pending.timer)
            if (frame.ok) pending.resolve(frame.result)
            else pending.reject(Object.assign(
              new Error(frame.message || 'broker request failed'),
              { response: frame },
            ))
          } else if (frame.type === 'event') {
            this.events.push(frame)
          }
        }
      })
      socket.on('error', (error) => finish(reject, error))
      socket.on('close', () => {
        finish(reject, new Error('broker socket closed during hello'))
        for (const pending of this.pending.values()) {
          clearTimeout(pending.timer)
          pending.reject(new Error('broker socket closed'))
        }
        this.pending.clear()
      })
    })
  }

  request(method, params = {}) {
    const socket = this.socket
    if (!socket || socket.destroyed || !this.hello) {
      return Promise.reject(new Error('broker client is not connected'))
    }
    const id = `${this.instanceId}:${++this.sequence}`
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`broker request timed out: ${method}`))
      }, REQUEST_TIMEOUT_MS)
      this.pending.set(id, { resolve, reject, timer })
      socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`, (error) => {
        if (!error) return
        const pending = this.pending.get(id)
        if (!pending) return
        this.pending.delete(id)
        clearTimeout(pending.timer)
        reject(error)
      })
    })
  }

  async close() {
    const socket = this.socket
    this.socket = null
    this.hello = null
    if (!socket || socket.destroyed) return
    await new Promise((resolve) => {
      socket.once('close', resolve)
      socket.destroy()
    })
  }
}

function ownerKey(instanceId, ownerId, projectId) {
  return `${instanceId}|${ownerId}|${projectId}`
}

async function startBroker(t) {
  // Keeping the listener path directly below the generated temp directory also
  // stays under Darwin's short sockaddr_un path limit.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kncc-'))
  fs.chmodSync(root, 0o700)
  const socketPath = path.join(root, 'broker.sock')
  const infoFile = path.join(root, 'broker.json')
  const lockFile = path.join(root, 'broker.lock')
  const logFile = path.join(root, 'broker.log')
  const storageDir = path.join(root, 'terminal-cache')
  const launchFile = path.join(root, `launch-${crypto.randomUUID()}.json`)
  const token = crypto.randomBytes(32).toString('hex')
  const launch = {
    protocol: PROTOCOL,
    securityEpoch: SECURITY_EPOCH,
    implementationVersion: BROKER_IMPLEMENTATION_VERSION,
    packageSchema: BROKER_PACKAGE_SCHEMA,
    packageVersion: 'test',
    token,
    socketPath,
    infoFile,
    lockFile,
    storageDir,
    logFile,
    startedAt: Date.now(),
    version: 'native-controller-coexistence-test',
    smoke: false,
  }
  fs.writeFileSync(launchFile, JSON.stringify(launch), { mode: 0o600 })

  const child = spawn(process.execPath, [BROKER_SCRIPT, '--launch', launchFile], {
    cwd: root,
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: '1',
      KAISOLA_SESSION_BROKER: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let childOutput = ''
  let childError = null
  child.stdout.on('data', (chunk) => { childOutput += chunk.toString('utf8') })
  child.stderr.on('data', (chunk) => { childOutput += chunk.toString('utf8') })
  child.on('error', (error) => { childError = error })

  const clients = new Set()
  const terminalPids = new Set()
  let cleaningUp = false

  async function stopProcess(target, label) {
    if (!target || !pidAlive(target.pid)) return
    target.kill('SIGTERM')
    try {
      await waitFor(() => !pidAlive(target.pid), `${label} to exit`, 2_000)
    } catch {
      target.kill('SIGKILL')
      await waitFor(() => !pidAlive(target.pid), `${label} to be killed`, 2_000)
    }
  }

  async function cleanup() {
    if (cleaningUp) return
    cleaningUp = true
    for (const client of clients) {
      try { await client.close() } catch { /* best effort */ }
    }
    clients.clear()

    if (pidAlive(child.pid)) {
      let cleanupClient = null
      try {
        cleanupClient = new BrokerClient({
          socketPath,
          token,
          instanceId: crypto.randomUUID(),
        })
        await cleanupClient.connect()
        await cleanupClient.request('broker.shutdown')
      } catch {
        // The direct child fallback below is still scoped to this test broker.
      } finally {
        try { await cleanupClient?.close() } catch { /* best effort */ }
      }
    }

    try {
      await waitFor(() => !pidAlive(child.pid), 'test broker to shut down', 2_000)
    } catch {
      await stopProcess(child, 'test broker')
    }

    for (const pid of terminalPids) {
      if (!pidAlive(pid)) continue
      try { process.kill(pid, 'SIGTERM') } catch { /* already exited */ }
      try {
        await waitFor(() => !pidAlive(pid), `terminal ${pid} to exit`, 1_000)
      } catch {
        try { process.kill(pid, 'SIGKILL') } catch { /* already exited */ }
        await waitFor(() => !pidAlive(pid), `terminal ${pid} to be killed`, 1_000)
      }
    }
    fs.rmSync(root, { recursive: true, force: true })
  }
  t.after(cleanup)

  const info = await waitFor(() => {
    if (childError) throw childError
    if (child.exitCode != null) {
      let log = ''
      try { log = fs.readFileSync(logFile, 'utf8') } catch { /* absent */ }
      throw new Error(`broker exited with ${child.exitCode}: ${childOutput}${log}`)
    }
    try {
      return JSON.parse(fs.readFileSync(infoFile, 'utf8'))
    } catch {
      return null
    }
  }, 'broker info publication')
  assert.equal(info.pid, child.pid)
  assert.equal(info.socketPath, socketPath)

  return {
    root,
    child,
    terminalPids,
    async client(instanceId, access = 'controller') {
      const client = new BrokerClient({ socketPath, token, instanceId, access })
      clients.add(client)
      const hello = await client.connect()
      assert.equal(hello.pid, child.pid)
      assert.equal(hello.access, access)
      return client
    },
  }
}

async function diagnostics(client) {
  return await client.request('terminal.diagnostics', { ownerId: '0' })
}

async function diagnostic(client, id) {
  return (await diagnostics(client)).find((row) => row.id === id)
}

async function waitForDiagnostic(client, id, predicate = () => true) {
  return await waitFor(async () => {
    const row = await diagnostic(client, id)
    return row && predicate(row) ? row : null
  }, `terminal diagnostics for ${id}`)
}

async function stableDiagnostic(client, id) {
  let previousOffset = null
  let repeats = 0
  return await waitFor(async () => {
    const row = await diagnostic(client, id)
    if (!row) return null
    if (row.endOffset === previousOffset) repeats++
    else {
      previousOffset = row.endOffset
      repeats = 0
    }
    return repeats >= 2 ? row : null
  }, `stable output offset for ${id}`)
}

async function waitForSnapshot(client, params, predicate) {
  return await waitFor(async () => {
    const snapshot = await client.request('terminal.snapshot', params)
    return predicate(snapshot) ? snapshot : null
  }, `terminal output for ${params.id}`)
}

async function createInteractiveTerminal(fixture, client, {
  id,
  ownerId,
  projectId,
  label,
}) {
  const created = await client.request('terminal.create', {
    ownerId,
    projectId,
    id,
    command: '/bin/sh',
    args: [
      '-c',
      'printf "ready:%s\\n" "$KAISOLA_COEXISTENCE_LABEL"; while IFS= read -r line; do printf "echo:%s:%s\\n" "$KAISOLA_COEXISTENCE_LABEL" "$line"; done',
    ],
    env: { KAISOLA_COEXISTENCE_LABEL: label },
    cwd: fixture.root,
    cols: 80,
    rows: 24,
  })
  assert.equal(created.ok, true)
  assert.ok(Number.isInteger(created.pid) && created.pid > 1)
  fixture.terminalPids.add(created.pid)
  await waitForSnapshot(client, { ownerId, projectId, id }, (snapshot) => (
    String(snapshot.output).includes(`ready:${label}`)
  ))
  return created
}

function observerOutput(client, terminalId) {
  return client.events
    .filter((event) => (
      event.channel === 'terminal:observer-output'
      && event.payload?.id === terminalId
    ))
    .map((event) => String(event.payload?.data ?? ''))
    .join('')
}

test('electron-like and native-like controllers own independent terminals', async (t) => {
  const fixture = await startBroker(t)
  const electron = await fixture.client(ELECTRON_INSTANCE_ID)
  const native = await fixture.client(NATIVE_INSTANCE_ID)

  const electronTerminal = await createInteractiveTerminal(fixture, electron, {
    id: 'coexist-electron',
    ownerId: ELECTRON_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    label: 'electron',
  })
  const nativeTerminal = await createInteractiveTerminal(fixture, native, {
    id: 'coexist-native',
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
    label: 'native',
  })

  const rows = await diagnostics(electron)
  const electronRow = rows.find((row) => row.id === 'coexist-electron')
  const nativeRow = rows.find((row) => row.id === 'coexist-native')
  assert.ok(electronRow)
  assert.ok(nativeRow)
  assert.notEqual(electronTerminal.pid, nativeTerminal.pid)
  assert.equal(electronRow.owner, ownerKey(ELECTRON_INSTANCE_ID, ELECTRON_OWNER_ID, ELECTRON_PROJECT_ID))
  assert.equal(electronRow.lastOwner, electronRow.owner)
  assert.equal(nativeRow.owner, ownerKey(NATIVE_INSTANCE_ID, NATIVE_OWNER_ID, NATIVE_PROJECT_ID))
  assert.equal(nativeRow.lastOwner, nativeRow.owner)
})

test('cross-owner write is rejected without attach and does not advance output', async (t) => {
  const fixture = await startBroker(t)
  const electron = await fixture.client(ELECTRON_INSTANCE_ID)
  const native = await fixture.client(NATIVE_INSTANCE_ID)
  await createInteractiveTerminal(fixture, electron, {
    id: 'write-victim',
    ownerId: ELECTRON_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    label: 'victim',
  })

  const before = await stableDiagnostic(electron, 'write-victim')
  await assert.rejects(
    native.request('terminal.write', {
      ownerId: NATIVE_OWNER_ID,
      projectId: ELECTRON_PROJECT_ID,
      id: 'write-victim',
      data: 'must-not-run\r',
    }),
    /terminal access denied/,
  )
  const after = await diagnostic(electron, 'write-victim')
  assert.equal(after.endOffset, before.endOffset)
  assert.equal(after.owner, before.owner)
})

test('a disconnected controller terminal transfers only through explicit attach', async (t) => {
  const fixture = await startBroker(t)
  const electron = await fixture.client(ELECTRON_INSTANCE_ID)
  const native = await fixture.client(NATIVE_INSTANCE_ID)
  const created = await createInteractiveTerminal(fixture, electron, {
    id: 'takeover-terminal',
    ownerId: ELECTRON_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    label: 'takeover',
  })

  await electron.close()
  const detached = await waitForDiagnostic(native, 'takeover-terminal', (row) => row.owner === '')
  assert.equal(detached.lastOwner, ownerKey(ELECTRON_INSTANCE_ID, ELECTRON_OWNER_ID, ELECTRON_PROJECT_ID))

  const attached = await native.request('terminal.attach', {
    ownerId: NATIVE_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    id: 'takeover-terminal',
  })
  assert.equal(attached.exited, false)
  const subscription = await native.request('terminal.subscribe', {
    ownerId: NATIVE_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    id: 'takeover-terminal',
  })
  assert.equal(subscription.ok, true)

  const before = await diagnostic(native, 'takeover-terminal')
  const write = await native.request('terminal.write', {
    ownerId: NATIVE_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    id: 'takeover-terminal',
    data: 'native-takeover\r',
  })
  assert.equal(write.ok, true)
  await waitFor(
    () => observerOutput(native, 'takeover-terminal').includes('echo:takeover:native-takeover'),
    'reattached terminal output',
  )
  const after = await diagnostic(native, 'takeover-terminal')
  assert.equal(after.pid, created.pid)
  assert.equal(after.owner, ownerKey(NATIVE_INSTANCE_ID, NATIVE_OWNER_ID, ELECTRON_PROJECT_ID))
  assert.ok(after.endOffset > before.endOffset)
})

test('detachOwner survives disconnect and preserves the PTY across reattach', async (t) => {
  const fixture = await startBroker(t)
  const native = await fixture.client(NATIVE_INSTANCE_ID)
  const created = await createInteractiveTerminal(fixture, native, {
    id: 'detached-native',
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
    label: 'detached',
  })

  const result = await native.request('terminal.detachOwner', {
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
  })
  assert.equal(result.ok, true)
  assert.equal(result.detached, 1)
  const detached = await waitForDiagnostic(native, 'detached-native', (row) => row.owner === '')
  assert.equal(detached.pid, created.pid)
  assert.equal(detached.lastOwner, ownerKey(NATIVE_INSTANCE_ID, NATIVE_OWNER_ID, NATIVE_PROJECT_ID))
  await native.close()

  const reconnected = await fixture.client(NATIVE_RECONNECT_INSTANCE_ID)
  const attached = await reconnected.request('terminal.attach', {
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
    id: 'detached-native',
  })
  assert.equal(attached.exited, false)
  const write = await reconnected.request('terminal.write', {
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
    id: 'detached-native',
    data: 'after-detach-owner\r',
  })
  assert.equal(write.ok, true)
  await waitForSnapshot(
    reconnected,
    { ownerId: NATIVE_OWNER_ID, projectId: NATIVE_PROJECT_ID, id: 'detached-native' },
    (snapshot) => String(snapshot.output).includes('echo:detached:after-detach-owner'),
  )
  const reattached = await diagnostic(reconnected, 'detached-native')
  assert.equal(reattached.pid, created.pid)
  assert.equal(reattached.owner, ownerKey(
    NATIVE_RECONNECT_INSTANCE_ID,
    NATIVE_OWNER_ID,
    NATIVE_PROJECT_ID,
  ))
})

test('native kill affects only the native terminal', async (t) => {
  const fixture = await startBroker(t)
  const electron = await fixture.client(ELECTRON_INSTANCE_ID)
  const native = await fixture.client(NATIVE_INSTANCE_ID)
  const electronTerminal = await createInteractiveTerminal(fixture, electron, {
    id: 'kill-electron-survivor',
    ownerId: ELECTRON_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    label: 'survivor',
  })
  await createInteractiveTerminal(fixture, native, {
    id: 'kill-native-target',
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
    label: 'target',
  })

  const before = await stableDiagnostic(electron, 'kill-electron-survivor')
  const killed = await native.request('terminal.kill', {
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
    id: 'kill-native-target',
  })
  assert.equal(killed.ok, true)
  await waitForDiagnostic(native, 'kill-native-target', (row) => row.exited === true)

  const write = await electron.request('terminal.write', {
    ownerId: ELECTRON_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    id: 'kill-electron-survivor',
    data: 'still-alive\r',
  })
  assert.equal(write.ok, true)
  await waitForSnapshot(
    electron,
    { ownerId: ELECTRON_OWNER_ID, projectId: ELECTRON_PROJECT_ID, id: 'kill-electron-survivor' },
    (snapshot) => String(snapshot.output).includes('echo:survivor:still-alive'),
  )
  const survivor = await diagnostic(electron, 'kill-electron-survivor')
  assert.equal(survivor.pid, electronTerminal.pid)
  assert.equal(survivor.exited, false)
  assert.equal(pidAlive(electronTerminal.pid), true)
  assert.ok(survivor.endOffset > before.endOffset)
})

test('observer inventories and subscribes to both controllers but cannot write', async (t) => {
  const fixture = await startBroker(t)
  const electron = await fixture.client(ELECTRON_INSTANCE_ID)
  const native = await fixture.client(NATIVE_INSTANCE_ID)
  const observer = await fixture.client(OBSERVER_INSTANCE_ID, 'observer')
  await createInteractiveTerminal(fixture, electron, {
    id: 'observe-electron',
    ownerId: ELECTRON_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    label: 'observe-electron',
  })
  await createInteractiveTerminal(fixture, native, {
    id: 'observe-native',
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
    label: 'observe-native',
  })

  const rows = await diagnostics(observer)
  assert.ok(rows.some((row) => row.id === 'observe-electron'))
  assert.ok(rows.some((row) => row.id === 'observe-native'))
  const electronSubscription = await observer.request('terminal.subscribe', {
    ownerId: 'observer-electron',
    projectId: ELECTRON_PROJECT_ID,
    id: 'observe-electron',
  })
  const nativeSubscription = await observer.request('terminal.subscribe', {
    ownerId: 'observer-native',
    projectId: NATIVE_PROJECT_ID,
    id: 'observe-native',
  })
  assert.equal(electronSubscription.ok, true)
  assert.equal(nativeSubscription.ok, true)

  await electron.request('terminal.write', {
    ownerId: ELECTRON_OWNER_ID,
    projectId: ELECTRON_PROJECT_ID,
    id: 'observe-electron',
    data: 'electron-observed\r',
  })
  await native.request('terminal.write', {
    ownerId: NATIVE_OWNER_ID,
    projectId: NATIVE_PROJECT_ID,
    id: 'observe-native',
    data: 'native-observed\r',
  })
  await waitFor(
    () => observerOutput(observer, 'observe-electron').includes('echo:observe-electron:electron-observed'),
    'observer output from electron-like terminal',
  )
  await waitFor(
    () => observerOutput(observer, 'observe-native').includes('echo:observe-native:native-observed'),
    'observer output from native-like terminal',
  )

  await assert.rejects(
    observer.request('terminal.write', {
      ownerId: 'observer-electron',
      projectId: ELECTRON_PROJECT_ID,
      id: 'observe-electron',
      data: 'observer-must-not-write\r',
    }),
    /observer access cannot invoke broker mutations/,
  )
})
