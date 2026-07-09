// No-prompt compatibility probe for the maintained Claude Agent ACP adapter.
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const { AcpConnection } = require('./ipc/acp.cjs')

const adapter = path.join(__dirname, '..', 'node_modules', '@agentclientprotocol', 'claude-agent-acp', 'dist', 'index.js')
const conn = new AcpConnection({
  command: process.execPath,
  args: [adapter],
  env: process.env.CLAUDE_CODE_EXECUTABLE ? { CLAUDE_CODE_EXECUTABLE: process.env.CLAUDE_CODE_EXECUTABLE } : {},
  cwd: path.join(__dirname, '..'),
  sessionMeta: { claudeCode: { options: { effort: 'max' } } },
  mcpServers: [],
})
const timeout = setTimeout(() => { conn.dispose(); process.exit(1) }, 30_000)
const group = (pgid) => {
  try {
    return execFileSync('/bin/ps', ['-axo', 'pid=,pgid=,rss=,command='], { encoding: 'utf8' }).split('\n').map((line) => {
      const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/)
      return m ? { pid: Number(m[1]), pgid: Number(m[2]), rssKb: Number(m[3]), command: m[4] } : null
    }).filter((row) => row && row.pgid === pgid)
  } catch { return [] }
}

;(async () => {
  try {
    conn.start()
    await conn.initialize()
    await conn.newSession()
    const effort = conn.getControls().configOptions?.find((option) => option.id === 'effort' || /effort/i.test(option.name))
    if (!effort?.options?.some((option) => option.value === 'max')) throw new Error('Maintained adapter did not expose native max effort')
    await conn.setConfigOption(effort.id, 'max')
    if (conn.getControls().configOptions.find((option) => option.id === effort.id)?.currentValue !== 'max') throw new Error('max effort was not retained')
    const live = group(conn.proc.pid)
    console.log('CLAUDE_ACP_EFFORT=PASS')
    console.log('CLAUDE_ACP_MEMORY=' + JSON.stringify({ processCount: live.length, rssKb: live.reduce((n, row) => n + row.rssKb, 0) }))
  } catch (error) {
    console.error('CLAUDE_ACP_EFFORT=FAIL', error.message)
    process.exitCode = 1
  } finally {
    clearTimeout(timeout)
    conn.dispose()
    await new Promise((resolve) => setTimeout(resolve, 1800))
    const after = group(conn.proc.pid)
    console.log('CLAUDE_ACP_AFTER_PARK=' + JSON.stringify({ processCount: after.length, rssKb: after.reduce((n, row) => n + row.rssKb, 0) }))
    if (after.length) process.exitCode = 1
  }
})()
