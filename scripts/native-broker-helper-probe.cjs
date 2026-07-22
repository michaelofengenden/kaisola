#!/usr/bin/env node
'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const cliArguments = process.argv.slice(2)
const requireSignedHost = cliArguments.includes('--require-signed-host')
const unknownOption = cliArguments.find((argument) => argument.startsWith('--') && argument !== '--require-signed-host')
if (unknownOption) {
  console.error(`NATIVE_BROKER_HELPER_PROBE=FAIL unknown argument: ${unknownOption}`)
  process.exit(1)
}
const packageArgument = cliArguments.find((argument) => !argument.startsWith('--'))
const packageRoot = path.resolve(packageArgument || '')
const manifestFile = path.join(packageRoot, 'manifest.json')
if (!fs.existsSync(manifestFile)) {
  console.error('NATIVE_BROKER_HELPER_PROBE=FAIL pass a packaged BrokerHelper directory')
  process.exit(1)
}
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
// Keep AF_UNIX below Darwin's short sockaddr_un limit even when TMPDIR itself
// lives under a long per-user /var/folders path.
const root = fs.mkdtempSync('/tmp/knhp-')
fs.chmodSync(root, 0o700)
const brokerRoot = path.join(root, 'session-broker')
const storageDir = path.join(root, 'terminal-cache')
fs.mkdirSync(brokerRoot, { mode: 0o700 })
const socketPath = path.join(brokerRoot, 'broker.sock')
const infoFile = path.join(brokerRoot, 'broker.json')
const lockFile = path.join(brokerRoot, 'broker.lock')
const logFile = path.join(brokerRoot, 'broker.log')
const launchFile = path.join(brokerRoot, `launch-native-${crypto.randomUUID()}.json`)
const token = crypto.randomBytes(32).toString('hex')
const launch = {
  protocol: 2,
  securityEpoch: 1,
  implementationVersion: manifest.brokerImplementationVersion,
  packageSchema: manifest.schemaVersion,
  packageVersion: manifest.packageVersion,
  token,
  socketPath,
  infoFile,
  lockFile,
  storageDir,
  logFile,
  startedAt: Date.now(),
  version: 'native-helper-probe',
  smoke: false,
}
fs.writeFileSync(launchFile, JSON.stringify(launch), { mode: 0o600 })

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

class Client {
  constructor(access, appVersion = 'native-helper-probe') {
    this.access = access
    this.appVersion = appVersion
    this.instanceId = crypto.randomUUID()
    this.socket = null
    this.buffer = ''
    this.pending = new Map()
    this.events = []
    this.sequence = 0
  }

  async connect() {
    return await new Promise((resolve, reject) => {
      const socket = net.createConnection(socketPath)
      this.socket = socket
      let authenticated = false
      socket.setNoDelay(true)
      socket.once('connect', () => socket.write(`${JSON.stringify({
        type: 'hello', protocol: 2, token, instanceId: this.instanceId,
        appVersion: this.appVersion, access: this.access,
      })}\n`))
      socket.on('data', (chunk) => {
        this.buffer += chunk.toString('utf8')
        let newline
        while ((newline = this.buffer.indexOf('\n')) >= 0) {
          const line = this.buffer.slice(0, newline)
          this.buffer = this.buffer.slice(newline + 1)
          if (!line) continue
          const frame = JSON.parse(line)
          if (!authenticated && frame.type === 'hello') {
            if (!frame.ok) reject(new Error(frame.message || 'broker hello rejected'))
            else { authenticated = true; resolve(frame) }
          } else if (frame.type === 'response') {
            const pending = this.pending.get(frame.id)
            if (!pending) continue
            this.pending.delete(frame.id)
            if (frame.ok) pending.resolve(frame.result)
            else pending.reject(new Error(frame.message || 'broker request failed'))
          } else if (frame.type === 'event') {
            this.events.push(frame)
          }
        }
      })
      socket.once('error', reject)
    })
  }

  request(method, params = {}) {
    const id = `${this.instanceId}:${++this.sequence}`
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`)
    })
  }

  close() {
    this.socket?.destroy()
    this.socket = null
  }
}

async function waitFor(predicate, timeoutMs = 8_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await wait(25)
  }
  throw new Error('probe condition timed out')
}

function observerSlice(subscription, events) {
  const snapshot = subscription.snapshot
  const relevantEvents = events.filter((event) => event.channel === 'terminal:observer-output')
  const output = (snapshot?.output || '')
    + relevantEvents.map((event) => event.payload?.data || '').join('')
  const lastEvent = relevantEvents.at(-1)
  const cursor = lastEvent
    ? { streamEpoch: lastEvent.payload.streamEpoch, offset: lastEvent.payload.endOffset }
    : snapshot
      ? { streamEpoch: snapshot.streamEpoch, offset: snapshot.endOffset }
      : subscription.cursor
  if (!cursor?.streamEpoch || !Number.isSafeInteger(cursor.offset)) {
    throw new Error('observer replacement produced no exact cursor')
  }
  return { output, cursor }
}

;(async () => {
  const bootstrap = path.join(packageRoot, 'bin', 'kaisola-broker-bootstrap')
  if (requireSignedHost) {
    const verification = spawnSync(bootstrap, ['--verify-package'], {
      encoding: 'utf8',
      env: Object.fromEntries(
        Object.entries(process.env).filter(([key]) => key !== 'KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER')
      ),
    })
    if (verification.status !== 0) {
      throw new Error(String(verification.stderr || verification.stdout).trim())
    }
  }
  const launchEnvironment = { ...process.env }
  if (requireSignedHost) delete launchEnvironment.KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER
  else launchEnvironment.KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER = '1'
  const result = spawnSync(bootstrap, ['--launch', launchFile], {
    encoding: 'utf8',
    env: launchEnvironment,
  })
  if (result.status !== 0) throw new Error(String(result.stderr || result.stdout).trim())
  const bootstrapPid = Number(String(result.stdout).match(/BROKER_BOOTSTRAP_PID=([0-9]+)/)?.[1])
  if (!Number.isInteger(bootstrapPid) || bootstrapPid <= 1) throw new Error('bootstrap returned no broker PID')
  const info = await waitFor(() => {
    try { return JSON.parse(fs.readFileSync(infoFile, 'utf8')) } catch { return null }
  })
  if (info.pid !== bootstrapPid) throw new Error('published broker identity differs from bootstrap PID')

  const controller = new Client('controller', 'native-preview-N')
  await controller.connect()
  const created = await controller.request('terminal.create', {
    ownerId: 'probe-controller',
    projectId: 'nativehelperprobe',
    id: 'native-helper-probe',
    command: '/bin/sh',
    args: ['-lc', 'for n in 1 2 3 4 5; do printf "sequence=%s\\n" "$n"; sleep 0.35; done'],
    cwd: root,
    cols: 80,
    rows: 24,
  })
  if (!created.ok || !Number.isInteger(created.pid)) {
    throw new Error(`packaged node-pty could not create a PTY: ${JSON.stringify(created)}`)
  }
  const terminalPid = created.pid
  controller.close()

  const observerN = new Client('observer', 'native-preview-N')
  const helloN = await observerN.connect()
  // Inventory is the observer's read-only administrative surface. Streaming
  // still requires the exact project capability below.
  const statusN = await observerN.request('broker.status', { ownerId: '0' })
  const diagnostics = await observerN.request('terminal.diagnostics', { ownerId: '0' })
  const before = diagnostics.find((row) => row.id === 'native-helper-probe')
  if (!before || before.pid !== terminalPid) {
    throw new Error(`terminal PID did not survive client replacement expected=${terminalPid} diagnostics=${JSON.stringify(diagnostics)}`)
  }
  const subscriptionN = await observerN.request('terminal.subscribe', {
    ownerId: 'probe-observer-N',
    projectId: 'nativehelperprobe',
    id: 'native-helper-probe',
    maxQueueBytes: 256 * 1024,
  })
  await waitFor(() => observerSlice(subscriptionN, observerN.events).output.includes('sequence=2'))
  const sliceN = observerSlice(subscriptionN, observerN.events)
  observerN.close()

  const observerN1 = new Client('observer', 'native-preview-N+1')
  const helloN1 = await observerN1.connect()
  const statusN1 = await observerN1.request('broker.status', { ownerId: '0' })
  const subscriptionN1 = await observerN1.request('terminal.subscribe', {
    ownerId: 'probe-observer-N1',
    projectId: 'nativehelperprobe',
    id: 'native-helper-probe',
    streamEpoch: sliceN.cursor.streamEpoch,
    afterOffset: sliceN.cursor.offset,
    maxQueueBytes: 256 * 1024,
  })
  await waitFor(() => observerSlice(subscriptionN1, observerN1.events).output.includes('sequence=4'))
  const sliceN1 = observerSlice(subscriptionN1, observerN1.events)
  observerN1.close()

  const observerRollback = new Client('observer', 'native-preview-rollback-N')
  const helloRollback = await observerRollback.connect()
  const statusRollback = await observerRollback.request('broker.status', { ownerId: '0' })
  const subscriptionRollback = await observerRollback.request('terminal.subscribe', {
    ownerId: 'probe-observer-rollback',
    projectId: 'nativehelperprobe',
    id: 'native-helper-probe',
    streamEpoch: sliceN1.cursor.streamEpoch,
    afterOffset: sliceN1.cursor.offset,
    maxQueueBytes: 256 * 1024,
  })
  await waitFor(() => observerSlice(subscriptionRollback, observerRollback.events).output.includes('sequence=5'))
  const sliceRollback = observerSlice(subscriptionRollback, observerRollback.events)
  observerRollback.close()

  const continuousOutput = sliceN.output + sliceN1.output + sliceRollback.output
  const numberedOutput = [...continuousOutput.matchAll(/sequence=(\d+)/g)].map((match) => Number(match[1]))
  if (JSON.stringify(numberedOutput) !== JSON.stringify([1, 2, 3, 4, 5])) {
    throw new Error(`client replacement duplicated or lost output: ${JSON.stringify(numberedOutput)} output=${JSON.stringify(continuousOutput)}`)
  }

  const cleanup = new Client('controller')
  await cleanup.connect()
  await cleanup.request('terminal.release', {
    ownerId: '0', projectId: 'nativehelperprobe', id: 'native-helper-probe',
  })
  await cleanup.request('broker.shutdown', {})
  cleanup.close()

  console.log('NATIVE_BROKER_HELPER_PROBE=' + JSON.stringify({
    pass: true,
    packageVersion: manifest.packageVersion,
    nodeVersion: manifest.node.version,
    nodeArchitectures: manifest.node.architectures,
    brokerPid: info.pid,
    terminalPid,
    brokerPidStable: [statusN.pid, statusN1.pid, statusRollback.pid].every((pid) => pid === info.pid),
    terminalPidStable: before.pid === terminalPid,
    observerEnforced: [helloN.access, helloN1.access, helloRollback.access].every((access) => access === 'observer'),
    nodePtyAvailable: true,
    sequenceContinuous: true,
    signedHostVerified: requireSignedHost,
    clientReplacementSequence: ['N', 'N+1', 'rollback-N'],
    numberedOutput,
  }))
})().catch(async (error) => {
  try {
    if (fs.existsSync(infoFile)) {
      const cleanup = new Client('controller')
      await cleanup.connect()
      await cleanup.request('broker.shutdown', {})
      cleanup.close()
    }
  } catch { /* best-effort temp broker cleanup */ }
  let brokerLog = ''
  try { brokerLog = fs.readFileSync(logFile, 'utf8').trim().slice(-4_000) } catch { /* absent */ }
  console.error(`NATIVE_BROKER_HELPER_PROBE=FAIL ${error.message}${brokerLog ? ` log=${JSON.stringify(brokerLog)}` : ''} root=${root}`)
  process.exitCode = 1
}).finally(() => {
  if (!process.exitCode) setTimeout(() => fs.rmSync(root, { recursive: true, force: true }), 200).unref()
})
