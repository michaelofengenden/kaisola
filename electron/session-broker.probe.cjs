// Cross-process continuity probe. Run outside command sandboxes that deny
// AF_UNIX/named-pipe listeners: `npm run broker:probe`.
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const net = require('node:net')
const { execFileSync } = require('node:child_process')
const { SessionBrokerClient, PROTOCOL } = require('./ipc/sessionBrokerClient.cjs')

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const sender = (id) => ({ id, isDestroyed: () => false, send: () => {} })
const PROJECT_ALPHA = 'probe-project-alpha'
const PROJECT_BETA = 'probe-project-beta'

async function denied(promise) {
  try { await promise; return false } catch (error) { return /access denied/i.test(String(error?.message || error)) }
}

async function main() {
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-broker-probe-'))
  const config = {
    userData,
    execPath: process.env.KAISOLA_BROKER_EXEC_PATH || process.execPath,
    brokerScript: process.env.KAISOLA_BROKER_SCRIPT || path.join(__dirname, 'session-broker.cjs'),
    appVersion: 'probe',
  }
  let firstClient = null
  let secondClient = null
  try {
    firstClient = new SessionBrokerClient(config)
    const firstHello = await firstClient.connect()
    const first = await firstClient.terminal('create', sender(101), {
      id: 'restart-continuity',
      command: process.platform === 'win32' ? process.env.ComSpec : '/bin/sh',
      args: process.platform === 'win32'
        ? ['/d', '/s', '/c', 'echo before & ping -n 2 127.0.0.1 >nul & echo during & ping -n 4 127.0.0.1 >nul']
        : ['-c', 'printf "run-as-node=%s broker-env=%s\\n" "${ELECTRON_RUN_AS_NODE-unset}" "${KAISOLA_SESSION_BROKER-unset}"; printf "before\\n"; sleep 1; printf "during\\n"; sleep 4'],
      cwd: process.cwd(),
      cols: 80,
      rows: 24,
      projectId: PROJECT_ALPHA,
    })
    if (!first?.ok || !first.pid) throw new Error(`first terminal failed: ${first?.message || 'missing pid'}`)

    await firstClient.disconnect()
    await wait(1600)

    secondClient = new SessionBrokerClient(config)
    const secondHello = await secondClient.connect()
    const detachedInventory = await secondClient.terminal('list', sender(202), { projectId: PROJECT_ALPHA })
    const second = await secondClient.terminal('create', sender(202), {
      id: 'restart-continuity',
      command: process.platform === 'win32' ? process.env.ComSpec : '/bin/sh',
      args: process.platform === 'win32' ? ['/d', '/s', '/c', 'echo respawned'] : ['-c', 'printf "respawned\\n"'],
      cwd: process.cwd(),
      cols: 80,
      rows: 24,
      projectId: PROJECT_ALPHA,
    })

    // A live renderer cannot inspect or operate another renderer's PTY, even
    // when it guesses the id. Same-project attach/create is the sole explicit
    // transfer path used by project tear-off, terminal pop-out, and reapply.
    const scoped = await secondClient.terminal('create', sender(301), {
      id: 'project-scope-boundary',
      command: process.platform === 'win32' ? process.env.ComSpec : '/bin/sh',
      args: process.platform === 'win32'
        ? ['/d', '/s', '/c', 'echo scope-ready & ping -t 127.0.0.1 >nul']
        : ['-c', 'printf "scope-ready\\n"; while :; do sleep 1; done'],
      cwd: process.cwd(),
      cols: 80,
      rows: 24,
      projectId: PROJECT_ALPHA,
    })
    const crossProjectInventory = await secondClient.terminal('list', sender(302), { projectId: PROJECT_BETA })
    const sameProjectInventoryBeforeAttach = await secondClient.terminal('list', sender(303), { projectId: PROJECT_ALPHA })
    const crossProjectReadDenied = await denied(secondClient.terminal('snapshot', sender(302), { id: 'project-scope-boundary', projectId: PROJECT_BETA }))
    const crossProjectAttachDenied = await denied(secondClient.terminal('attach', sender(302), { id: 'project-scope-boundary', projectId: PROJECT_BETA }))
    const sameProjectReadDeniedBeforeAttach = await denied(secondClient.terminal('snapshot', sender(303), { id: 'project-scope-boundary', projectId: PROJECT_ALPHA }))
    const handoff = await secondClient.terminal('attach', sender(303), { id: 'project-scope-boundary', projectId: PROJECT_ALPHA })
    const handoffInventory = await secondClient.terminal('diagnostics', sender(303), { projectId: PROJECT_ALPHA })
    const priorOwnerDeniedAfterHandoff = await denied(secondClient.terminal('snapshot', sender(301), { id: 'project-scope-boundary', projectId: PROJECT_ALPHA }))
    await secondClient.terminal('release', sender(303), { id: 'project-scope-boundary', projectId: PROJECT_ALPHA })

    // Close grace lives in the broker, not a renderer timer. It can be armed
    // from another same-project window (source vs pop), cancelled by reopen,
    // and deterministically reaps an abandoned PTY.
    const grace = await secondClient.terminal('create', sender(401), {
      id: 'broker-close-grace',
      command: process.platform === 'win32' ? process.env.ComSpec : '/bin/sh',
      args: process.platform === 'win32' ? ['/d', '/s', '/c', 'ping -t 127.0.0.1 >nul'] : ['-c', 'while :; do sleep 1; done'],
      cwd: process.cwd(), cols: 80, rows: 24, projectId: PROJECT_ALPHA,
    })
    const graceScheduled = await secondClient.terminal('scheduleRelease', sender(402), { id: 'broker-close-grace', projectId: PROJECT_ALPHA, delayMs: 1_000 })
    const graceCancelled = await secondClient.terminal('cancelRelease', sender(402), { id: 'broker-close-grace', projectId: PROJECT_ALPHA })
    await wait(1_150)
    const graceStillThere = (await secondClient.terminal('diagnostics', sender(401), { projectId: PROJECT_ALPHA })).some((row) => row.id === 'broker-close-grace' && row.pid === grace.pid)
    await secondClient.terminal('scheduleRelease', sender(402), { id: 'broker-close-grace', projectId: PROJECT_ALPHA, delayMs: 1_000 })
    await wait(1_150)
    const graceReaped = !(await secondClient.terminal('diagnostics', sender(401), { projectId: PROJECT_ALPHA })).some((row) => row.id === 'broker-close-grace')

    const assertions = {
      sameBrokerPid: firstHello.pid === secondHello.pid,
      sameTerminalPid: first.pid === second.pid,
      existingSessionAdopted: second.existed === true,
      restartMarked: second.continuation?.acrossRestart === true,
      detachedOutputReplayed: String(second.output || '').includes('during'),
      duplicateBootPrevented: !String(second.output || '').includes('respawned'),
      detachedTerminalNotInventoried: !detachedInventory.some((row) => row.id === 'restart-continuity'),
      brokerEnvironmentStripped: process.platform === 'win32' || String(second.output || '').includes('run-as-node=unset broker-env=unset'),
      crossProjectNotInventoried: !crossProjectInventory.some((row) => row.id === 'project-scope-boundary'),
      sameProjectNotInventoriedBeforeAttach: !sameProjectInventoryBeforeAttach.some((row) => row.id === 'project-scope-boundary'),
      crossProjectReadDenied,
      crossProjectAttachDenied,
      sameProjectReadDeniedBeforeAttach,
      explicitSameProjectHandoff: !!scoped?.ok && !handoff?.exited && handoffInventory.some((row) => row.id === 'project-scope-boundary' && row.pid === scoped.pid),
      previousOwnerRevokedAfterHandoff: priorOwnerDeniedAfterHandoff,
      brokerOwnedCloseGrace: !!grace?.ok && graceScheduled.ok && graceCancelled.ok && graceStillThere && graceReaped,
      privateSpawnHelper: process.platform !== 'darwin' || (() => {
        try {
          const helper = path.join(userData, 'terminal-cache', '.native', `darwin-${process.arch}`, 'spawn-helper')
          return fs.statSync(helper).isFile() && (fs.statSync(helper).mode & 0o111) !== 0
        } catch { return false }
      })(),
    }
    const failed = Object.entries(assertions).filter(([, ok]) => !ok).map(([name]) => name)
    let brokerRssKiB = null
    if (process.platform !== 'win32') {
      try { brokerRssKiB = Number(String(execFileSync('ps', ['-o', 'rss=', '-p', String(secondHello.pid)])).trim()) || null } catch { /* diagnostic only */ }
    }
    console.log(JSON.stringify({
      brokerPid: secondHello.pid,
      terminalPid: second.pid,
      brokerRssKiB,
      detachedBytes: second.continuation?.outputBytes ?? 0,
      assertions,
    }, null, 2))
    if (failed.length) throw new Error(`broker continuity failed: ${failed.join(', ')}`)

    // Authentication is a hard boundary: a local process that discovers only
    // the private socket path cannot inventory or control sessions.
    const info = JSON.parse(fs.readFileSync(path.join(userData, 'session-broker', 'broker.json'), 'utf8'))
    await new Promise((resolve, reject) => {
      const socket = net.createConnection(info.socketPath)
      let reply = ''
      const timer = setTimeout(() => { socket.destroy(); reject(new Error('unauthorized client was not rejected')) }, 2000)
      socket.once('connect', () => socket.write(`${JSON.stringify({ type: 'hello', protocol: PROTOCOL, token: '0'.repeat(64), instanceId: '00000000-0000-4000-8000-000000000000' })}\n`))
      socket.on('data', (chunk) => { reply += chunk.toString('utf8') })
      socket.once('close', () => {
        clearTimeout(timer)
        try {
          const frame = JSON.parse(reply.trim())
          if (frame.ok !== false) reject(new Error('unauthorized client received access'))
          else resolve()
        } catch (error) { reject(error) }
      })
      socket.once('error', reject)
    })
    console.log('SESSION_BROKER_RESULT=PASS')
  } finally {
    if (secondClient) await secondClient.shutdown()
    else if (firstClient) await firstClient.shutdown()
    await wait(100)
    fs.rmSync(userData, { recursive: true, force: true })
  }
}

main().catch((error) => {
  console.error(error?.stack || error)
  process.exitCode = 1
})
