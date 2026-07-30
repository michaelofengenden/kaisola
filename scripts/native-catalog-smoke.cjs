#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')

const MAX_OUTPUT_BYTES = 64 * 1024
const TIMEOUT_MS = 95_000
const PASS = 'KAISOLA_NATIVE_CATALOG_SMOKE=PASS publish=1 read=exact remove=1 absent=1 account-scoped=1 credential=keychain'
const PASS_LINES = [
  'KAISOLA_NATIVE_CATALOG_STAGE=PUBLISHED',
  'KAISOLA_NATIVE_CATALOG_STAGE=READ_EXACT',
  'KAISOLA_NATIVE_CATALOG_STAGE=REMOVED',
  PASS,
]

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  const options = {}
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--app') {
      const value = argv[++index]
      if (!value) fail('--app requires a path')
      options.app = path.resolve(value)
    } else if (argument === '--allow-auth-required') {
      options.allowAuthRequired = true
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
  node scripts/native-catalog-smoke.cjs --app /path/Kaisola.app [--allow-auth-required]

Runs the signed app's broker-free remembered-session proof. The app must already
have a deliberate Google sign-in in its production Keychain namespace. The
probe publishes one synthetic record, reads it exactly, removes it, and proves
it absent. No token is accepted through argv, environment, stdin, logs, or disk.`
}

function bundleExecutable(app) {
  if (!app) fail('catalog smoke requires --app')
  const stat = fs.lstatSync(app)
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail('app path must be a real application directory')
  }
  const plist = path.join(app, 'Contents', 'Info.plist')
  const result = spawnSync('/usr/bin/plutil', [
    '-extract', 'CFBundleExecutable', 'raw', plist,
  ], { encoding: 'utf8' })
  if (result.error) throw result.error
  if (result.status !== 0) fail('could not read the app bundle executable')
  const executable = path.join(app, 'Contents', 'MacOS', result.stdout.trim())
  const executableStat = fs.statSync(executable)
  if (!executableStat.isFile() || (executableStat.mode & 0o111) === 0) {
    fail('app bundle executable is missing or not executable')
  }
  return executable
}

function requireTeamSignature(app) {
  const result = spawnSync('/usr/bin/codesign', ['-dv', '--verbose=4', app], {
    encoding: 'utf8',
  })
  const output = `${result.stdout || ''}\n${result.stderr || ''}`
  if (result.error) throw result.error
  if (result.status !== 0 || !/^TeamIdentifier=[A-Z0-9]+$/m.test(output)) {
    fail('app must have a real team signature; ad-hoc builds cannot prove production Keychain access')
  }
}

function appendBounded(current, chunk, child) {
  const next = Buffer.concat([current, Buffer.from(chunk)])
  if (next.length > MAX_OUTPUT_BYTES) {
    child.kill('SIGKILL')
    return null
  }
  return next
}

function classifyResult({ code, signal, stdout, stderr, allowAuthRequired = false }) {
  if (stderr.length !== 0) fail('catalog smoke wrote unexpected stderr')
  const lines = stdout.toString('utf8').trim().split(/\r?\n/).filter(Boolean)
  if (code === 0 && !signal && JSON.stringify(lines) === JSON.stringify(PASS_LINES)) {
    return { status: 'PASS', lifecycle: 'publish-read-remove-absent' }
  }
  if (allowAuthRequired
      && code === 1
      && !signal
      && lines.length === 1
      && lines[0] === 'KAISOLA_NATIVE_CATALOG_SMOKE=AUTH_REQUIRED') {
    return { status: 'AUTH_REQUIRED' }
  }
  const status = lines.find((line) => /^KAISOLA_NATIVE_CATALOG_SMOKE=[A-Z_]+(?: .*)?$/.test(line))
    || 'no-status'
  fail(`catalog smoke failed (${code ?? signal ?? 'unknown'}; ${status})`)
}

async function runCatalogSmoke(options) {
  const executable = bundleExecutable(options.app)
  requireTeamSignature(options.app)
  const childEnvironment = { KAISOLA_NATIVE_CATALOG_SMOKE: '1' }
  for (const name of ['HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL']) {
    if (typeof process.env[name] === 'string') childEnvironment[name] = process.env[name]
  }

  const child = spawn(executable, [], {
    env: childEnvironment,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let stdout = Buffer.alloc(0)
  let stderr = Buffer.alloc(0)
  let outputOverflow = false
  child.stdout.on('data', (chunk) => {
    const next = appendBounded(stdout, chunk, child)
    if (next === null) outputOverflow = true
    else stdout = next
  })
  child.stderr.on('data', (chunk) => {
    const next = appendBounded(stderr, chunk, child)
    if (next === null) outputOverflow = true
    else stderr = next
  })

  const result = await new Promise((resolve, reject) => {
    const deadline = setTimeout(() => {
      child.kill('SIGKILL')
      reject(new Error('catalog smoke exceeded 95 seconds'))
    }, TIMEOUT_MS)
    deadline.unref?.()
    child.once('error', (error) => {
      clearTimeout(deadline)
      reject(error)
    })
    child.once('exit', (code, signal) => {
      clearTimeout(deadline)
      resolve({ code, signal })
    })
  })

  if (outputOverflow) fail('catalog smoke output exceeded its safety bound')
  return classifyResult({
    ...result,
    stdout,
    stderr,
    allowAuthRequired: options.allowAuthRequired,
  })
}

if (require.main === module) {
  ;(async () => {
    try {
      const options = parseArguments(process.argv.slice(2))
      if (options.help) console.log(usage())
      else console.log(`NATIVE_CATALOG_SMOKE=${JSON.stringify(await runCatalogSmoke(options))}`)
    } catch (error) {
      console.error(`NATIVE_CATALOG_SMOKE=FAIL ${error.message}`)
      process.exitCode = 1
    }
  })()
}

module.exports = {
  PASS,
  PASS_LINES,
  classifyResult,
  parseArguments,
  runCatalogSmoke,
}
