'use strict'

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const { PROTOCOL } = require('../runtime/node-broker/ipc/brokerWire.cjs')
const { requestBrokerControl } = require('../runtime/node-broker/ipc/brokerControlClient.cjs')

const READY_NATIVE = 'KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY='
const workloadAliases = new Map([
  ['idle', 'one-window-idle-terminal-fresh-broker'],
  ['streaming', 'one-window-streaming-terminal-fresh-broker'],
  ['restored', 'three-restored-project-windows-fresh-broker'],
])

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

function fail(message) {
  throw new Error(message)
}

function isAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

async function terminate(pid, signal = 'SIGTERM', timeoutMs = 5_000) {
  if (!Number.isSafeInteger(pid) || pid <= 1 || !isAlive(pid)) return
  process.kill(pid, signal)
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline && isAlive(pid)) await wait(50)
  if (isAlive(pid) && signal !== 'SIGKILL') process.kill(pid, 'SIGKILL')
}

function fixtureEnvironment(overrides = {}) {
  const environment = { ...process.env, ...overrides }
  delete environment.MallocNanoZone
  return environment
}

function lineReader(stream, onLine, capture) {
  let buffered = ''
  stream.on('data', (chunk) => {
    const text = chunk.toString('utf8')
    capture.push(text)
    buffered += text
    let newline
    while ((newline = buffered.indexOf('\n')) >= 0) {
      const line = buffered.slice(0, newline)
      buffered = buffered.slice(newline + 1)
      onLine(line)
    }
  })
}

function outputTail(chunks, limit = 2_000) {
  return chunks.join('').slice(-limit).trim()
}

function readinessError(error, output, errors) {
  const stdout = outputTail(output)
  const stderr = outputTail(errors)
  const diagnostics = [
    stdout ? `fixture stdout tail:\n${stdout}` : '',
    stderr ? `fixture stderr tail:\n${stderr}` : '',
  ].filter(Boolean).join('\n')
  return new Error(`${error.message}${diagnostics ? `\n${diagnostics}` : ''}`, { cause: error })
}

function launchAndWait(command, args, launchOptions, readyParser, timeoutMs = 45_000, onSpawn = () => {}) {
  return new Promise((resolve, reject) => {
    const startedAt = process.hrtime.bigint()
    const child = spawn(command, args, { ...launchOptions, stdio: ['ignore', 'pipe', 'pipe'] })
    const output = []
    const errors = []
    let settled = false
    const finish = async (error, receipt) => {
      if (settled) return
      settled = true
      clearTimeout(deadline)
      if (error) {
        await terminate(child.pid)
        reject(readinessError(error, output, errors))
      } else {
        const readyElapsedMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000
        resolve({ child, receipt, output, errors, readyElapsedMs })
      }
    }
    const deadline = setTimeout(() => {
      void finish(new Error(`fixture readiness timed out after ${timeoutMs}ms`))
    }, timeoutMs)
    try {
      onSpawn(child)
    } catch (error) {
      void finish(error)
      return
    }
    lineReader(child.stdout, (line) => {
      try {
        const receipt = readyParser(line, child)
        if (receipt) void finish(null, receipt)
      } catch (error) {
        void finish(error)
      }
    }, output)
    lineReader(child.stderr, () => {}, errors)
    child.once('error', (error) => { void finish(error) })
    child.once('exit', (code, signal) => {
      if (!settled) void finish(new Error(`fixture exited before readiness (${code ?? signal})`))
    })
  })
}

function brokerPIDFromRoot(root) {
  try {
    const payload = JSON.parse(fs.readFileSync(path.join(root, 'session-broker', 'broker.json'), 'utf8'))
    return Number.isSafeInteger(payload.pid) && payload.pid > 1 ? payload.pid : null
  } catch {
    return null
  }
}

async function cleanFailedFixtureLaunch(root, appPid) {
  await terminate(appPid)
  const brokerPid = brokerPIDFromRoot(root)
  await terminate(brokerPid)
  if (!isAlive(appPid) && !isAlive(brokerPid)) fs.rmSync(root, { recursive: true, force: true })
}

async function launchNative(options) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-frame-'))
  fs.chmodSync(root, 0o700)
  const executable = path.join(options.app, 'Contents', 'MacOS', 'Kaisola')
  if (!fs.existsSync(executable)) fail(`native executable missing: ${executable}`)
  let appPid = null
  try {
    const environment = fixtureEnvironment({
      ...(options.extraEnvironment || {}),
      KAISOLA_NATIVE_RESOURCE_WORKLOAD: options.workload,
      KAISOLA_NATIVE_RESOURCE_ROOT: root,
    })
    const run = await launchAndWait(executable, [], {
      cwd: root,
      env: environment,
    }, (line, child) => {
      if (!line.startsWith(READY_NATIVE)) return null
      const raw = line.slice(READY_NATIVE.length)
      if (raw.startsWith('FAIL ')) fail(raw)
      const receipt = JSON.parse(raw)
      if (receipt.appPid !== child.pid || receipt.workload !== options.workload) {
        fail('native readiness receipt mismatch')
      }
      const expectedWindowCount = options.workload === workloadAliases.get('restored') ? 3 : 1
      if (receipt.rendererScrollbackLines !== 5_000
          || receipt.windowWidth !== 1_280
          || receipt.windowHeight !== 800
          || receipt.windowCount !== expectedWindowCount
          || !Array.isArray(receipt.terminalIds)
          || new Set(receipt.terminalIds).size !== expectedWindowCount) {
        fail('native fixture dimensions or scrollback budget drifted')
      }
      return receipt
    }, 45_000, (child) => { appPid = child.pid })
    return { ...run, root, appPid: run.child.pid, brokerPid: run.receipt.brokerPid }
  } catch (error) {
    await cleanFailedFixtureLaunch(root, appPid)
    throw error
  }
}

function terminalStreamDelta(before, after) {
  const ids = Object.keys(before).sort()
  if (!ids.length || ids.length !== Object.keys(after).length
      || ids.some((id) => after[id] == null)) {
    fail('terminal stream heads changed identity during frame capture')
  }
  const terminals = ids.map((id) => {
    const previous = before[id]
    const current = after[id]
    if (previous.streamEpoch !== current.streamEpoch
        || !(current.endOffset >= previous.endOffset)) {
      fail(`terminal stream reset during frame capture: ${id}`)
    }
    return {
      id,
      streamEpoch: current.streamEpoch,
      beforeOffset: previous.endOffset,
      afterOffset: current.endOffset,
      deltaBytes: current.endOffset - previous.endOffset,
    }
  })
  return {
    terminals,
    totalDeltaBytes: terminals.reduce((sum, terminal) => sum + terminal.deltaBytes, 0),
  }
}

function brokerInfoForFixture(fixture) {
  const file = path.join(fixture.root, 'session-broker', 'broker.json')
  try {
    const info = JSON.parse(fs.readFileSync(file, 'utf8'))
    if (Number(info.pid) === fixture.brokerPid
        && typeof info.socketPath === 'string'
        && typeof info.token === 'string') return info
  } catch {}
  fail(`isolated broker metadata does not match PID ${fixture.brokerPid}`)
}

async function terminalStreamHeads(fixture) {
  const status = await requestBrokerControl(brokerInfoForFixture(fixture), {
    protocol: PROTOCOL,
    appVersion: 'kaisola-native-frame-cadence',
    method: 'broker.status',
  })
  const terminalIDs = fixture.receipt.terminalIds || [fixture.receipt.terminalId]
  const rows = new Map((status?.terminals || []).map((terminal) => [terminal.id, terminal]))
  return Object.fromEntries(terminalIDs.map((id) => {
    const row = rows.get(id)
    if (!row || typeof row.streamEpoch !== 'string'
        || !Number.isSafeInteger(row.endOffset) || row.endOffset < 0) {
      fail(`broker status has no valid stream head for ${id}`)
    }
    return [id, { streamEpoch: row.streamEpoch, endOffset: row.endOffset }]
  }))
}

module.exports = {
  isAlive,
  launchNative,
  terminalStreamDelta,
  terminalStreamHeads,
  terminate,
  wait,
  workloadAliases,
}
