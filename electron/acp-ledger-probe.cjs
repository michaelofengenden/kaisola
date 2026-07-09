// Safe integration probe for exact-marker stale process reclamation.
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const { AcpProcessLedger } = require('./ipc/acpProcessLedger.cjs')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-ledger-probe-'))
const first = new AcpProcessLedger(dir)
const token = first.newToken()
const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
  detached: process.platform !== 'win32',
  stdio: 'ignore',
  env: { ...process.env, ...first.markers(token) },
})
child.unref()
first.recordSpawn({ token, pid: child.pid, pgid: child.pid, presetId: 'probe', command: process.execPath })

;(async () => {
  try {
    await new Promise((resolve) => setTimeout(resolve, 250))
    const second = new AcpProcessLedger(dir)
    const reclaimed = second.reclaimStale()
    await new Promise((resolve) => setTimeout(resolve, 1900))
    let alive = false
    try { process.kill(child.pid, 0); alive = true } catch { /* gone */ }
    console.log(`ACP_LEDGER_PROBE=${reclaimed.matched >= 1 && !alive ? 'PASS' : 'FAIL'} matched=${reclaimed.matched} alive=${alive}`)
    if (alive || reclaimed.matched < 1) process.exitCode = 1
  } finally {
    try { process.kill(-child.pid, 'SIGKILL') } catch { try { child.kill('SIGKILL') } catch { /* gone */ } }
    fs.rmSync(dir, { recursive: true, force: true })
  }
})()
