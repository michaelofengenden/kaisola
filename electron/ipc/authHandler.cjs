// Headless device-code login — runs a CLI's device-auth command (e.g.
// `codex login --device-auth`) as a background process, parses the URL + code
// it prints, and streams them to an in-app Sign-in card. No visible terminal:
// the user clicks "Open authorization page", signs in, and the process completes.
const { spawn } = require('node:child_process')
const { agentEnv } = require('./shellEnv.cjs')

const sessions = new Map() // id → child
const ANSI = /\x1b\[[0-9;]*m/g
const URL_RE = /https?:\/\/[^\s"'<>)\]]+/
const CODE_RE = /\b[A-Z0-9]{4}-[A-Z0-9]{4,8}\b/

function registerAuthHandlers(ipcMain) {
  ipcMain.handle('auth:start', (event, { id, command, args } = {}) => {
    if (sessions.has(id)) return { ok: true, reused: true }
    let child
    try {
      child = spawn(command, args || [], { env: agentEnv(), stdio: ['pipe', 'pipe', 'pipe'] })
    } catch (err) {
      return { ok: false, message: err.message }
    }
    sessions.set(id, child)
    const sender = event.sender
    const chan = `auth:event:${id}`
    let url = null
    let code = null
    let buf = ''
    const send = (ev) => { if (!sender.isDestroyed()) sender.send(chan, ev) }
    const onData = (d) => {
      const text = d.toString('utf8').replace(ANSI, '')
      buf += text
      buf = buf.slice(-4000)
      if (!url) { const m = buf.match(URL_RE); if (m) url = m[0] }
      if (!code) { const m = buf.match(CODE_RE); if (m) code = m[0] }
      send({ phase: 'progress', url, code })
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', onData)
    child.on('exit', (exitCode) => {
      sessions.delete(id)
      send({ phase: exitCode === 0 ? 'done' : 'failed', exitCode, url, code, tail: buf.slice(-300) })
    })
    child.on('error', (err) => {
      sessions.delete(id)
      send({ phase: 'failed', error: err.message })
    })
    return { ok: true }
  })

  ipcMain.handle('auth:cancel', (_e, { id } = {}) => {
    const c = sessions.get(id)
    if (c) {
      try { c.kill() } catch { /* noop */ }
      sessions.delete(id)
    }
    return { ok: true }
  })
}

function disposeAuth() {
  for (const c of sessions.values()) {
    try { c.kill() } catch { /* noop */ }
  }
  sessions.clear()
}

module.exports = { registerAuthHandlers, disposeAuth }
