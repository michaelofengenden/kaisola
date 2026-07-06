// Experiment sandbox — runs agent/experiment code in an ISOLATED runner, kept
// deliberately distinct from the user's interactive node-pty dock terminals.
// Three modes:
//   - 'mock'   : a deterministic dry-run (no container) — the safe default; lets
//                the whole flow work + be verified with no Docker/key.
//   - 'docker' : a real `docker run --rm` container, streamed live.
//   - 'e2b'    : E2B cloud sandbox (drop-in if @e2b/code-interpreter + key present).
// Streams `sandbox:event:<id>` {type:'stdout'|'stderr'|'exit', data|code} and
// resolves after exit. Never throws to the renderer.
const { spawn } = require('child_process')

function send(sender, channel, payload) {
  if (sender && !sender.isDestroyed()) sender.send(channel, payload)
}

function runMock(sender, chan, req) {
  const lines = [
    '[sandbox] mock runner — set Settings → Execution → sandbox mode to Docker for real isolated runs',
    `$ ${req.command || 'python experiment.py'}`,
    'epoch 1/3  loss=0.62  acc=0.31',
    'epoch 2/3  loss=0.44  acc=0.42',
    'epoch 3/3  loss=0.33  acc=0.49',
    'success_rate=0.49',
  ]
  for (const l of lines) send(sender, chan, { type: 'stdout', data: `${l}\n` })
  send(sender, chan, { type: 'exit', code: 0 })
  return Promise.resolve({ ok: true, code: 0 })
}

function runDocker(sender, chan, req) {
  return new Promise((resolve) => {
    const img = req.image || 'python:3.12-slim'
    const args = ['run', '--rm', '-i']
    if (req.cwd) args.push('-v', `${req.cwd}:/work`, '-w', '/work')
    for (const [k, v] of Object.entries(req.env || {})) args.push('-e', `${k}=${v}`)
    args.push(img, 'sh', '-c', req.command || 'echo "no command"')
    let proc
    try {
      proc = spawn('docker', args)
    } catch (e) {
      send(sender, chan, { type: 'stderr', data: `docker unavailable: ${e.message}\n` })
      send(sender, chan, { type: 'exit', code: 127 })
      return resolve({ ok: false, code: 127, message: 'docker unavailable' })
    }
    proc.on('error', (e) => {
      send(sender, chan, { type: 'stderr', data: `${e.message}\n` })
      send(sender, chan, { type: 'exit', code: 127 })
      resolve({ ok: false, code: 127, message: String(e.message) })
    })
    proc.stdout.on('data', (d) => send(sender, chan, { type: 'stdout', data: d.toString() }))
    proc.stderr.on('data', (d) => send(sender, chan, { type: 'stderr', data: d.toString() }))
    proc.on('close', (code) => {
      send(sender, chan, { type: 'exit', code })
      resolve({ ok: code === 0, code })
    })
  })
}

async function runE2B(sender, chan, req) {
  let E2B
  try {
    E2B = require('@e2b/code-interpreter')
  } catch {
    send(sender, chan, { type: 'stderr', data: 'E2B SDK not installed (npm i @e2b/code-interpreter) and E2B_API_KEY required.\n' })
    send(sender, chan, { type: 'exit', code: 127 })
    return { ok: false, code: 127, message: 'E2B not configured' }
  }
  let sbx
  try {
    sbx = await E2B.Sandbox.create()
    const exec = await sbx.runCode(req.command || 'print("hello from e2b")')
    const out = ((exec.logs && exec.logs.stdout) || []).join('') + (exec.text || '')
    send(sender, chan, { type: 'stdout', data: `${out}\n` })
    send(sender, chan, { type: 'exit', code: 0 })
    return { ok: true, code: 0 }
  } catch (e) {
    send(sender, chan, { type: 'stderr', data: `${e.message}\n` })
    send(sender, chan, { type: 'exit', code: 1 })
    return { ok: false, code: 1, message: String(e.message) }
  } finally {
    // always release the cloud sandbox, even if runCode threw
    try { if (sbx && sbx.kill) await sbx.kill() } catch { /* best-effort */ }
  }
}

function registerSandboxHandlers(ipcMain) {
  ipcMain.handle('sandbox:run', (event, { id, mode, ...req } = {}) => {
    const chan = `sandbox:event:${id}`
    if (mode === 'docker') return runDocker(event.sender, chan, req)
    if (mode === 'e2b') return runE2B(event.sender, chan, req)
    return runMock(event.sender, chan, req)
  })
  ipcMain.handle('sandbox:available', () =>
    new Promise((resolve) => {
      let proc
      try {
        proc = spawn('docker', ['--version'])
      } catch {
        return resolve({ docker: false })
      }
      proc.on('error', () => resolve({ docker: false }))
      proc.on('close', (code) => resolve({ docker: code === 0 }))
    }),
  )
}

module.exports = { registerSandboxHandlers }
