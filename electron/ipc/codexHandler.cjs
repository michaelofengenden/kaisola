// Codex on your subscription. `codex exec` runs Codex headlessly using its cached
// "Sign in with ChatGPT" login (~/.codex/auth.json) — so research reasoning runs
// on your ChatGPT/Codex subscription, NOT per-token API billing. (If you signed
// in with an API key instead, it uses that.) Read-only sandbox so it can never
// edit files; this is a pure reasoning call. Graceful: missing CLI / timeout /
// non-zero exit all resolve { ok:false } rather than throwing.
const { spawn } = require('child_process')
const { agentEnv } = require('./shellEnv.cjs')

const TIMEOUT_MS = 90_000

function codexExec({ prompt, cwd } = {}) {
  return new Promise((resolve) => {
    if (process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE) return resolve({ ok: false, message: 'codex disabled during smoke' })
    if (!prompt) return resolve({ ok: false, message: 'No prompt.' })
    const args = ['exec', '--skip-git-repo-check', '--sandbox', 'read-only', prompt]
    let proc
    try {
      proc = spawn('codex', args, { cwd: cwd || undefined, env: agentEnv() })
    } catch (e) {
      return resolve({ ok: false, message: `codex CLI not found — install it (npm i -g @openai/codex) and run \`codex login\`. (${e.message})` })
    }
    let out = ''
    let err = ''
    let done = false
    const finish = (r) => { if (!done) { done = true; resolve(r) } }
    const timer = setTimeout(() => { try { proc.kill('SIGKILL') } catch { /* */ } finish({ ok: false, message: 'codex exec timed out.' }) }, TIMEOUT_MS)
    proc.on('error', (e) => { clearTimeout(timer); finish({ ok: false, message: `codex not available: ${e.message}` }) })
    proc.stdout.on('data', (d) => { out += d.toString() })
    proc.stderr.on('data', (d) => { err += d.toString() })
    proc.on('close', (code) => {
      clearTimeout(timer)
      if (out.trim()) finish({ ok: true, text: out })
      else finish({ ok: false, message: err.trim() || `codex exec exited ${code}` })
    })
  })
}

function registerCodexHandlers(ipcMain) {
  ipcMain.handle('codex:exec', (_e, req = {}) => codexExec(req))
}

module.exports = { registerCodexHandlers, codexExec }
