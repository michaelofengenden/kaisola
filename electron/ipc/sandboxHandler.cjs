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
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const MAX_COMMAND_CHARS = 16 * 1024
const MAX_OUTPUT_BYTES = 8 * 1024 * 1024
const MAX_RUNTIME_MS = 10 * 60 * 1000
const DEFAULT_IMAGE = 'python:3.12-slim'

/** Campaigns persist a shell command string. Interpret it only *inside* the
 * networkless, capability-free container; it is passed as one Docker argv
 * value and is never evaluated by the host shell. */
function shellCommand(command) {
  const input = String(command || '').trim()
  if (!input) return { ok: false, message: 'sandbox command is required' }
  if (input.length > MAX_COMMAND_CHARS || input.includes('\0')) {
    return { ok: false, message: 'sandbox command is invalid or too long' }
  }
  return { ok: true, command: input }
}

function dockerImage(image) {
  const value = String(image || DEFAULT_IMAGE)
  // Docker references are data passed to the CLI, never shell text. Still
  // reject flags, digests of the wrong shape, and control characters.
  if (value.length > 200 || value.startsWith('-') || !/^[a-zA-Z0-9][a-zA-Z0-9._/-]*(?::[a-zA-Z0-9._-]+|@sha256:[a-fA-F0-9]{64})?$/.test(value)) {
    return null
  }
  return value
}

function dockerEnv(env) {
  const entries = Object.entries(env && typeof env === 'object' ? env : {})
  if (entries.length > 64) return { ok: false, message: 'sandbox environment has too many entries' }
  const args = []
  for (const [rawKey, rawValue] of entries) {
    const key = String(rawKey)
    const value = String(rawValue)
    if (!/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(key) || value.length > 4096 || /[\0\r\n]/.test(value)) {
      return { ok: false, message: `sandbox environment entry is invalid: ${key.slice(0, 80)}` }
    }
    if (key === 'HOME' || key === 'PYTHONDONTWRITEBYTECODE') continue
    args.push('--env', `${key}=${value}`)
  }
  return { ok: true, args }
}

function dockerRunArgs(req = {}, containerName = `kaisola-sandbox-${crypto.randomBytes(8).toString('hex')}`) {
  const parsed = shellCommand(req.command)
  if (!parsed.ok) return parsed
  const image = dockerImage(req.image)
  if (!image) return { ok: false, message: 'sandbox image reference is invalid' }
  const environment = dockerEnv(req.env)
  if (!environment.ok) return environment
  const args = [
    'run', '--rm', '--name', containerName,
    '--network=none', '--read-only', '--cap-drop=ALL',
    '--security-opt=no-new-privileges', '--pids-limit=128',
    '--memory=2g', '--cpus=2', '--stop-timeout=3',
    '--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=256m',
    '--env', 'HOME=/work/.home', '--env', 'KAISOLA_OUTPUT_DIR=/work/output', '--env', 'PYTHONDONTWRITEBYTECODE=1',
  ]
  if (typeof process.getuid === 'function' && typeof process.getgid === 'function') {
    args.push('--user', `${process.getuid()}:${process.getgid()}`)
  }
  if (req.cwd) {
    let cwd
    try {
      cwd = fs.realpathSync(String(req.cwd))
      if (!fs.statSync(cwd).isDirectory()) throw new Error('not a directory')
    } catch {
      return { ok: false, message: 'sandbox working directory does not exist' }
    }
    args.push('--volume', `${cwd}:/input:ro`)
  }
  let outputDir
  try {
    outputDir = fs.realpathSync(String(req.outputDir || ''))
    if (!fs.statSync(outputDir).isDirectory()) throw new Error('not a directory')
  } catch {
    return { ok: false, message: 'sandbox output directory does not exist' }
  }
  args.push('--volume', `${outputDir}:/work:rw`, '--workdir', '/work')
  const bootstrap = 'mkdir -p "$HOME" "$KAISOLA_OUTPUT_DIR"; if [ -d /input ]; then cp -a /input/. /work/; fi; exec /bin/sh -eu -c "$1"'
  args.push(...environment.args, image, '/bin/sh', '-eu', '-c', bootstrap, 'kaisola-command', parsed.command)
  return { ok: true, args, containerName, outputDir }
}

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
    let outputDir
    try { outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-sandbox-output-')) } catch {
      const message = 'could not create a writable sandbox output directory'
      send(sender, chan, { type: 'stderr', data: `${message}\n` })
      send(sender, chan, { type: 'exit', code: 2 })
      resolve({ ok: false, code: 2, message })
      return
    }
    const built = dockerRunArgs({ ...req, outputDir })
    if (!built.ok) {
      try { fs.rmSync(outputDir, { recursive: true, force: true }) } catch {}
      send(sender, chan, { type: 'stderr', data: `${built.message}\n` })
      send(sender, chan, { type: 'exit', code: 2 })
      resolve({ ok: false, code: 2, message: built.message })
      return
    }
    const timeoutMs = Math.max(1_000, Math.min(Number(req.timeoutMs) || MAX_RUNTIME_MS, MAX_RUNTIME_MS))
    let outputBytes = 0
    let settled = false
    let stoppingReason = ''
    let proc
    const stopContainer = () => {
      try {
        const cleanup = spawn('docker', ['rm', '-f', built.containerName], { stdio: 'ignore', windowsHide: true })
        cleanup.unref?.()
      } catch { /* best effort; --rm also cleans normal exits */ }
    }
    const finish = (result) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve({ ...result, outputDir: built.outputDir })
    }
    const forward = (type, data) => {
      if (settled || stoppingReason) return
      const chunk = Buffer.isBuffer(data) ? data : Buffer.from(String(data))
      outputBytes += chunk.length
      if (outputBytes > MAX_OUTPUT_BYTES) {
        stoppingReason = `sandbox output exceeded ${MAX_OUTPUT_BYTES / (1024 * 1024)} MiB`
        send(sender, chan, { type: 'stderr', data: `${stoppingReason}\n` })
        stopContainer()
        try { proc.kill('SIGTERM') } catch {}
        return
      }
      send(sender, chan, { type, data: chunk.toString('utf8') })
    }
    const timer = setTimeout(() => {
      stoppingReason = `sandbox exceeded its ${Math.round(timeoutMs / 1000)} second time limit`
      send(sender, chan, { type: 'stderr', data: `${stoppingReason}\n` })
      stopContainer()
      try { proc?.kill('SIGTERM') } catch {}
    }, timeoutMs)
    timer.unref?.()
    try {
      proc = spawn('docker', built.args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
    } catch (e) {
      clearTimeout(timer)
      send(sender, chan, { type: 'stderr', data: `docker unavailable: ${e.message}\n` })
      send(sender, chan, { type: 'exit', code: 127 })
      return finish({ ok: false, code: 127, message: 'docker unavailable' })
    }
    proc.on('error', (e) => {
      send(sender, chan, { type: 'stderr', data: `${e.message}\n` })
      send(sender, chan, { type: 'exit', code: 127 })
      finish({ ok: false, code: 127, message: String(e.message) })
    })
    proc.stdout.on('data', (d) => forward('stdout', d))
    proc.stderr.on('data', (d) => forward('stderr', d))
    proc.on('close', (code) => {
      const exitCode = stoppingReason ? 124 : (Number.isInteger(code) ? code : 1)
      send(sender, chan, { type: 'exit', code: exitCode })
      finish({ ok: exitCode === 0, code: exitCode, ...(stoppingReason ? { message: stoppingReason } : {}) })
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
    const safeId = String(id || '').replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 120)
    if (!safeId) return { ok: false, code: 2, message: 'sandbox run id is required' }
    const chan = `sandbox:event:${safeId}`
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

module.exports = {
  registerSandboxHandlers,
  _sandboxTest: { shellCommand, dockerImage, dockerEnv, dockerRunArgs, MAX_OUTPUT_BYTES, MAX_RUNTIME_MS },
}
