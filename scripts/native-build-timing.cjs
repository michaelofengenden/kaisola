#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const repoRoot = path.resolve(__dirname, '..')

function usage() {
  return [
    'Usage: node scripts/native-build-timing.cjs --label LABEL [options]',
    '',
    '  --warm-runs COUNT    Immediate incremental builds after the cold build (default: 1)',
    '  --output FILE        JSONL history (default: .build/metrics/native-build-timings.jsonl)',
    '  --keep-derived-data  Preserve the isolated timing cache and print its path',
    '  --verbose            Show the full xcodebuild log',
    '',
    'The command creates a new temporary DerivedData directory. It never cleans or',
    'replaces the persistent native:fast cache, and it skips broker packaging so',
    'cold/warm comparisons measure the same active-architecture Swift build.',
  ].join('\n')
}

function parseArguments(argv) {
  const options = {
    label: null,
    warmRuns: 1,
    output: path.join(repoRoot, '.build', 'metrics', 'native-build-timings.jsonl'),
    keepDerivedData: false,
    verbose: false,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const takeValue = () => {
      index += 1
      if (index >= argv.length) throw new Error(`${argument} requires a value`)
      return argv[index]
    }
    if (argument === '--label') options.label = takeValue()
    else if (argument === '--warm-runs') options.warmRuns = Number(takeValue())
    else if (argument === '--output') options.output = path.resolve(takeValue())
    else if (argument === '--keep-derived-data') options.keepDerivedData = true
    else if (argument === '--verbose') options.verbose = true
    else if (argument === '--help' || argument === '-h') options.help = true
    else throw new Error(`unknown option: ${argument}`)
  }
  if (!options.help && (!options.label || !options.label.trim())) throw new Error('--label is required')
  if (!Number.isSafeInteger(options.warmRuns) || options.warmRuns < 1 || options.warmRuns > 10) {
    throw new Error('--warm-runs must be an integer from 1 through 10')
  }
  return options
}

function readCommand(command, args) {
  const result = spawnSync(command, args, { cwd: repoRoot, encoding: 'utf8' })
  if (result.error || result.status !== 0) return null
  return String(result.stdout || '').trim() || null
}

function measureBuild(derivedData, { verbose = false } = {}) {
  const args = ['--build-only', '--skip-helper']
  if (verbose) args.push('--verbose')
  const started = process.hrtime.bigint()
  const result = spawnSync(path.join(repoRoot, 'scripts', 'native-fast.sh'), args, {
    cwd: repoRoot,
    env: {
      ...process.env,
      KAISOLA_NATIVE_DERIVED_DATA: derivedData,
      KAISOLA_NATIVE_TIMING_ISOLATED: '1',
    },
    stdio: 'inherit',
  })
  const elapsedMilliseconds = Number(process.hrtime.bigint() - started) / 1_000_000
  return {
    elapsedMilliseconds: Math.round(elapsedMilliseconds),
    elapsedSeconds: Number((elapsedMilliseconds / 1000).toFixed(3)),
    exitCode: result.status ?? 1,
    signal: result.signal || null,
    succeeded: !result.error && result.status === 0,
    ...(result.error ? { error: result.error.message } : {}),
  }
}

function appendReceipt(file, receipt) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.appendFileSync(file, `${JSON.stringify(receipt)}\n`, { encoding: 'utf8', mode: 0o600 })
}

function safeCleanup(directory) {
  const resolved = path.resolve(directory)
  const expectedParent = path.resolve(os.tmpdir())
  const expectedName = /^kaisola-native-timing-[A-Za-z0-9]+$/u
  if (path.dirname(resolved) !== expectedParent || !expectedName.test(path.basename(resolved))) {
    throw new Error(`refusing to remove unexpected timing directory: ${resolved}`)
  }
  fs.rmSync(resolved, { recursive: true, force: true })
}

function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv)
  if (options.help) {
    process.stdout.write(`${usage()}\n`)
    return
  }

  const derivedData = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-timing-'))
  const receipt = {
    schemaVersion: 1,
    measuredAt: new Date().toISOString(),
    label: options.label.trim(),
    sourceCommit: readCommand('/usr/bin/git', ['rev-parse', 'HEAD']),
    sourceDirty: Boolean(readCommand('/usr/bin/git', ['status', '--porcelain'])),
    appVersion: readCommand(process.execPath, ['-p', 'require("./package.json").version']),
    architecture: os.arch(),
    configuration: 'Debug',
    helperPackaging: 'skipped-consistently',
    cachePolicy: 'fresh-isolated-derived-data',
    results: [],
  }

  let buildFailure = null
  try {
    process.stdout.write(`Cold timing run (${options.label})…\n`)
    receipt.results.push({ kind: 'cold', run: 1, ...measureBuild(derivedData, options) })
    if (!receipt.results.at(-1).succeeded) throw new Error('cold native build failed')

    for (let index = 1; index <= options.warmRuns; index += 1) {
      process.stdout.write(`Warm timing run ${index}/${options.warmRuns}…\n`)
      receipt.results.push({ kind: 'warm', run: index, ...measureBuild(derivedData, options) })
      if (!receipt.results.at(-1).succeeded) throw new Error(`warm native build ${index} failed`)
    }
  } catch (error) {
    buildFailure = error
    receipt.failure = error.message
  } finally {
    if (options.keepDerivedData) receipt.derivedData = derivedData
    else safeCleanup(derivedData)
  }

  receipt.completedAt = new Date().toISOString()
  appendReceipt(options.output, receipt)
  if (buildFailure) {
    process.stderr.write(`Native build timing failed; receipt recorded at ${options.output}\n`)
    process.exitCode = 1
    return
  }
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`)
  process.stdout.write(`Timing receipt appended to ${options.output}\n`)
  if (options.keepDerivedData) process.stdout.write(`Isolated DerivedData preserved at ${derivedData}\n`)
}

if (require.main === module) {
  try {
    main()
  } catch (error) {
    process.stderr.write(`native-build-timing: ${error.message}\n`)
    process.exitCode = 2
  }
}

module.exports = { measureBuild, parseArguments, safeCleanup }
