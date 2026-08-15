'use strict'

// The generation lock is an exclusive-create file removed only by an orderly
// broker exit. These tests pin the recovery contract added after the
// 2026-08-14 reboot incident: a stale lock with no living owner is taken
// over (with a logged reason), while any lock whose recorded owner or
// published rendezvous still names a living process keeps failing closed
// with exit code 2.
const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { spawn } = require('node:child_process')

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

function makeFixture() {
  const root = fs.mkdtempSync('/tmp/kaisola-stale-lock-')
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
    packageVersion: 'stale-lock-test',
    contentDigest: 'a'.repeat(64),
    token: crypto.randomBytes(32).toString('hex'),
    socketPath: path.join(brokerRoot, 'broker.sock'),
    infoFile: path.join(brokerRoot, 'broker.json'),
    lockFile: path.join(brokerRoot, 'broker.lock'),
    storageDir,
    logFile: path.join(brokerRoot, 'broker.log'),
    startedAt: Date.now(),
    version: 'stale-lock-test',
    smoke: false,
  }
  return { root, config }
}

function startBroker(fixture, name) {
  const launchFile = path.join(fixture.root, 'session-broker', `launch-${name}.json`)
  fs.writeFileSync(launchFile, JSON.stringify(fixture.config), { mode: 0o600 })
  const child = spawn(process.execPath, [brokerScript, '--launch', launchFile], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, NODE_ENV: 'test' },
  })
  let stderr = ''
  child.stderr.on('data', (chunk) => { stderr += chunk })
  const exited = new Promise((resolve) => {
    child.once('exit', (code, signal) => resolve({ code, signal }))
  })
  return { child, exited, stderr: () => stderr }
}

function readLog(fixture) {
  try { return fs.readFileSync(fixture.config.logFile, 'utf8') } catch { return '' }
}

async function terminate(broker) {
  if (broker.child.exitCode == null && broker.child.signalCode == null) {
    broker.child.kill('SIGTERM')
  }
  await broker.exited
}

test('a stale lock with no recorded owner is recovered and relaunch succeeds', async () => {
  const fixture = makeFixture()
  // Unclean death (crash, reboot) leaves an empty lock file and no
  // rendezvous info behind.
  fs.writeFileSync(fixture.config.lockFile, '', { mode: 0o600 })
  const broker = startBroker(fixture, 'recover-empty')
  try {
    await waitFor(() => fs.existsSync(fixture.config.infoFile), 'published rendezvous')
    const published = JSON.parse(fs.readFileSync(fixture.config.infoFile, 'utf8'))
    assert.equal(published.pid, broker.child.pid)
    const lockContents = fs.readFileSync(fixture.config.lockFile, 'utf8')
    assert.equal(lockContents.trim(), String(broker.child.pid))
    assert.match(readLog(fixture), /recovered stale generation lock/)
  } finally {
    await terminate(broker)
  }
  // An orderly exit still removes the lock so the next launch is clean.
  await waitFor(() => !fs.existsSync(fixture.config.lockFile), 'lock removed on exit')
})

test('a lock naming a provably dead pid is recovered', async () => {
  const fixture = makeFixture()
  // 99999998 exceeds the macOS pid space, so kill(pid, 0) reports ESRCH.
  fs.writeFileSync(fixture.config.lockFile, '99999998\n', { mode: 0o600 })
  const broker = startBroker(fixture, 'recover-dead-pid')
  try {
    await waitFor(() => fs.existsSync(fixture.config.socketPath), 'listening socket')
    assert.match(readLog(fixture), /recovered stale generation lock deadOwner=99999998/)
  } finally {
    await terminate(broker)
  }
})

test('a lock naming a living process keeps failing closed with exit 2', async () => {
  const fixture = makeFixture()
  fs.writeFileSync(fixture.config.lockFile, `${process.pid}\n`, { mode: 0o600 })
  const broker = startBroker(fixture, 'refuse-live-lock')
  const { code } = await broker.exited
  assert.equal(code, 2)
  assert.equal(fs.existsSync(fixture.config.infoFile), false)
  // The refusal names its reason instead of exiting silently, and the live
  // owner's lock file survives untouched.
  assert.match(readLog(fixture), /generation lock unavailable ELOCKHELD/)
  assert.equal(fs.readFileSync(fixture.config.lockFile, 'utf8').trim(), String(process.pid))
})

test('the lock is born owned: pid inside from creation, claim file cleaned up', async () => {
  const fixture = makeFixture()
  const broker = startBroker(fixture, 'atomic-claim')
  try {
    await waitFor(() => fs.existsSync(fixture.config.infoFile), 'published rendezvous')
    // The lock is created by hard-linking a pre-written claim file, so at no
    // instant does it exist empty — an empty lock read mid-creation is what
    // let a concurrent relaunch judge a fresh lock ownerless and steal it.
    assert.equal(
      fs.readFileSync(fixture.config.lockFile, 'utf8').trim(),
      String(broker.child.pid)
    )
    const leftovers = fs.readdirSync(path.dirname(fixture.config.lockFile))
      .filter((name) => name.endsWith('.claim'))
    assert.deepEqual(leftovers, [])
  } finally {
    await terminate(broker)
  }
})

test('a live published rendezvous blocks takeover of an unrecorded lock', async () => {
  const fixture = makeFixture()
  fs.writeFileSync(fixture.config.lockFile, '', { mode: 0o600 })
  fs.writeFileSync(
    fixture.config.infoFile,
    JSON.stringify({ pid: process.pid }),
    { mode: 0o600 }
  )
  const broker = startBroker(fixture, 'refuse-live-info')
  const { code } = await broker.exited
  assert.equal(code, 2)
  assert.match(readLog(fixture), /generation lock unavailable ELOCKHELD/)
  assert.equal(fs.existsSync(fixture.config.lockFile), true)
})
