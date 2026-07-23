#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')

const DEFAULT_SECONDS = 10
const MAX_OUTPUT_BYTES = 256 * 1024

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  const options = { seconds: DEFAULT_SECONDS }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--app') {
      const value = argv[++index]
      if (!value) fail('--app requires a path')
      options.app = path.resolve(value)
    } else if (argument === '--seconds') {
      const value = Number(argv[++index])
      if (!Number.isInteger(value) || value < 3 || value > 60) {
        fail('--seconds must be an integer from 3 through 60')
      }
      options.seconds = value
    } else if (argument === '--help' || argument === '-h') {
      options.help = true
    } else {
      fail(`unknown argument: ${argument}`)
    }
  }
  return options
}

function usage() {
  return `Usage:
  node scripts/native-launch-smoke.cjs --app /path/KaisolaMacPreview.app [--seconds 10]

Launches the real app (not --launch-probe), requires it to stay alive for the
observation window, then fails if a new macOS crash report appeared.`
}

function readBundleExecutable(app) {
  const plist = path.join(app, 'Contents', 'Info.plist')
  const result = spawnSync('/usr/bin/plutil', ['-extract', 'CFBundleExecutable', 'raw', plist], {
    encoding: 'utf8',
  })
  if (result.error) throw result.error
  if (result.status !== 0) {
    fail(`cannot read CFBundleExecutable: ${(result.stderr || result.stdout || '').trim()}`)
  }
  return result.stdout.trim()
}

function crashReports(directory, executableName) {
  if (!fs.existsSync(directory)) return []
  const prefix = `${executableName}-`
  return fs.readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.startsWith(prefix) && entry.name.endsWith('.ips'))
    .map((entry) => {
      const absolute = path.join(directory, entry.name)
      return { path: absolute, mtimeMs: fs.statSync(absolute).mtimeMs }
    })
}

function newCrashReports({ before, after, startedAt }) {
  const existing = new Set(before.map((entry) => entry.path))
  return after.filter((entry) => !existing.has(entry.path) && entry.mtimeMs >= startedAt - 1_000)
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

function boundedAppend(current, chunk) {
  const next = current + String(chunk)
  return next.length <= MAX_OUTPUT_BYTES ? next : next.slice(-MAX_OUTPUT_BYTES)
}

async function smokeLaunch(options) {
  if (!options.app) fail('launch smoke requires --app')
  const appStat = fs.lstatSync(options.app)
  if (!appStat.isDirectory() || appStat.isSymbolicLink()) {
    fail('app path must be a real application directory')
  }

  const executableName = readBundleExecutable(options.app)
  const executable = path.join(options.app, 'Contents', 'MacOS', executableName)
  if (!fs.statSync(executable).isFile()) fail(`bundle executable is missing: ${executable}`)

  const reportDirectory = options.crashDirectory
    || path.join(process.env.HOME || '', 'Library', 'Logs', 'DiagnosticReports')
  const before = crashReports(reportDirectory, executableName)
  const startedAt = Date.now()
  let stdout = ''
  let stderr = ''
  const child = spawn(executable, [], {
    env: {
      ...process.env,
      KAISOLA_NATIVE_RUNTIME_SMOKE: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  child.stdout.on('data', (chunk) => { stdout = boundedAppend(stdout, chunk) })
  child.stderr.on('data', (chunk) => { stderr = boundedAppend(stderr, chunk) })

  const exited = new Promise((resolve, reject) => {
    child.once('error', reject)
    child.once('exit', (code, signal) => resolve({ code, signal }))
  })
  const observationMs = options.seconds * 1_000
  const outcome = await Promise.race([
    exited.then((exit) => ({ kind: 'exit', exit })),
    delay(observationMs).then(() => ({ kind: 'alive' })),
  ])

  if (outcome.kind === 'exit') {
    await delay(2_000)
    const reports = newCrashReports({
      before,
      after: crashReports(reportDirectory, executableName),
      startedAt,
    })
    const detail = [
      `app exited before ${options.seconds}s (code=${outcome.exit.code}, signal=${outcome.exit.signal || 'none'})`,
      stderr.trim() && `stderr: ${stderr.trim()}`,
      stdout.trim() && `stdout: ${stdout.trim()}`,
      reports.length && `crash reports: ${reports.map((entry) => entry.path).join(', ')}`,
    ].filter(Boolean).join('\n')
    fail(detail)
  }

  child.kill('SIGTERM')
  const stopped = await Promise.race([
    exited.then(() => true),
    delay(3_000).then(() => false),
  ])
  if (!stopped) {
    child.kill('SIGKILL')
    await exited
  }

  // DiagnosticReports is asynchronous; leave enough time for CrashReporter to
  // materialize a report after an in-window failure.
  await delay(2_000)
  const reports = newCrashReports({
    before,
    after: crashReports(reportDirectory, executableName),
    startedAt,
  })
  if (reports.length) {
    fail(`app produced a crash report: ${reports.map((entry) => entry.path).join(', ')}`)
  }

  return {
    pass: true,
    app: options.app,
    executable: executableName,
    observedSeconds: options.seconds,
    pid: child.pid,
    crashReports: 0,
  }
}

if (require.main === module) {
  ;(async () => {
    try {
      const options = parseArguments(process.argv.slice(2))
      if (options.help) console.log(usage())
      else console.log(`NATIVE_LAUNCH_SMOKE=${JSON.stringify(await smokeLaunch(options))}`)
    } catch (error) {
      console.error(`NATIVE_LAUNCH_SMOKE=FAIL ${error.message}`)
      process.exitCode = 1
    }
  })()
}

module.exports = {
  crashReports,
  newCrashReports,
  parseArguments,
  smokeLaunch,
}
