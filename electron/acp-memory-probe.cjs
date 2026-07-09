// No-prompt memory/process probe for the maintained direct Codex ACP adapter.
// Creates a resumable session, measures its exact owned process group, disposes
// it with the production lifecycle, then verifies the group is gone.
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const { AcpConnection } = require('./ipc/acp.cjs')

const adapter = path.join(__dirname, '..', 'node_modules', '@agentclientprotocol', 'codex-acp', 'dist', 'index.js')
const codex = process.env.CODEX_PATH || 'codex'

function group(pgid) {
  try {
    const raw = execFileSync('/bin/ps', ['-axo', 'pid=,pgid=,rss=,command='], { encoding: 'utf8' })
    return raw.split('\n').map((line) => {
      const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/)
      return m ? { pid: Number(m[1]), pgid: Number(m[2]), rssKb: Number(m[3]), command: m[4] } : null
    }).filter((row) => row && row.pgid === pgid)
  } catch { return [] }
}

const conn = new AcpConnection({ command: process.execPath, args: [adapter], env: { CODEX_PATH: codex }, cwd: path.join(__dirname, '..'), mcpServers: [] })
const timeout = setTimeout(() => { conn.dispose(); process.exit(1) }, 30_000)

;(async () => {
  try {
    conn.start()
    await conn.initialize()
    const session = await conn.newSession()
    await new Promise((resolve) => setTimeout(resolve, 400))
    const live = group(conn.proc.pid)
    console.log('ACP_MEMORY_LIVE=' + JSON.stringify({
      sessionId: session.sessionId,
      rootPid: conn.proc.pid,
      processCount: live.length,
      rssKb: live.reduce((n, row) => n + row.rssKb, 0),
      commands: live.map((row) => path.basename(row.command.split(/\s+/)[0])),
    }))
    conn.dispose()
    await new Promise((resolve) => setTimeout(resolve, 2200))
    const after = group(conn.proc.pid)
    console.log('ACP_MEMORY_AFTER_PARK=' + JSON.stringify({ processCount: after.length, rssKb: after.reduce((n, row) => n + row.rssKb, 0) }))
    if (after.length) process.exitCode = 1
  } catch (error) {
    console.error('ACP_MEMORY_PROBE=FAIL', error.message)
    process.exitCode = 1
  } finally {
    clearTimeout(timeout)
    conn.dispose()
  }
})()
