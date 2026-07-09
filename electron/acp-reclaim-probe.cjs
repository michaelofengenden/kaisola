// Re-run exact ledger cleanup for Kaisola's ephemeral integration harnesses.
// Useful after an interrupted/older harness run; never matches by process name.
const os = require('node:os')
const path = require('node:path')
const fs = require('node:fs')
const { AcpProcessLedger, readPs } = require('./ipc/acpProcessLedger.cjs')

let matched = 0
let signalled = 0
for (const name of ['kaisola-smoke-userdata', 'kaisola-solidprobe', 'kaisola-reapplyprobe']) {
  const dir = path.join(os.tmpdir(), name, 'process-ledger')
  if (!fs.existsSync(path.join(dir, 'acp-processes.json'))) continue
  const result = new AcpProcessLedger(dir).reclaimStale()
  matched += result.matched
  signalled += result.signalled
}
// Migration cleanup for harness processes created after ownership markers were
// introduced but before the harness learned to retain/replay its ledger. The
// conjunction is exact: Kaisola owner marker + smoke marker + this checkout.
// Unmarked Zed/Traycer/other-app adapters never match.
const checkout = `INIT_CWD=${path.join(__dirname, '..')}`
const harnessRows = readPs().filter((row) => row.command.includes('KAISOLA_ACP_OWNER=') && row.command.includes('KAISOLA_SMOKE=1') && row.command.includes(checkout))
for (const pgid of new Set(harnessRows.map((row) => row.pgid).filter((pgid) => pgid > 1))) {
  try { process.kill(-pgid, 'SIGTERM'); signalled++ } catch { /* exited */ }
}
matched += harnessRows.length
console.log(`ACP_RECLAIM_PROBE=PASS matched=${matched} signalled=${signalled}`)
