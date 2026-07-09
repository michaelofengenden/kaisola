// Deterministic managed-memory probe: equivalent terminal output under the old
// 1 MB-per-pty ring and the new disk-backed detached lifecycle.
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { TerminalSpool } = require('./ipc/terminalSpool.cjs')

const count = Math.max(1, Number(process.env.KAISOLA_MEMORY_PROBE_TERMINALS) || 16)
const bytesPerTerminal = Math.max(128 * 1024, Number(process.env.KAISOLA_MEMORY_PROBE_BYTES) || 4 * 1024 * 1024)
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-memory-probe-'))
try {
  const chunk = 'x'.repeat(64 * 1024)
  const spools = []
  for (let i = 0; i < count; i++) {
    const spool = new TerminalSpool({ dir, id: `term-${i}` })
    for (let n = 0; n < bytesPerTerminal; n += chunk.length) spool.push(chunk)
    spool.setVisible(false, { scrollFromBottom: i, cols: 120, rows: 40 })
    spools.push(spool)
  }
  const stats = spools.map((s) => s.stats())
  const result = {
    terminals: count,
    outputBytes: count * bytesPerTerminal,
    oldMainRingBytes: count * 1024 * 1024,
    newDetachedOutputRamBytes: stats.reduce((n, s) => n + s.ramBytes, 0),
    newDiskBytes: stats.reduce((n, s) => n + s.diskBytes, 0),
    savedManagedRamBytes: count * 1024 * 1024 - stats.reduce((n, s) => n + s.ramBytes, 0),
  }
  console.log(`MEMORY_PROBE=${JSON.stringify(result)}`)
} finally {
  fs.rmSync(dir, { recursive: true, force: true })
}
