#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const {
  createManifest,
  signNestedCode,
  verifyPackage,
} = require('./native-broker-package.cjs')

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  const options = {}
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--app') {
      options.app = argv[++index]
      if (!options.app) fail('--app requires a path')
    } else if (argument === '--identity') {
      options.identity = argv[++index]
      if (!options.identity) fail('--identity requires a value')
    } else if (argument === '--help' || argument === '-h') {
      options.help = true
    } else {
      fail(`unknown argument: ${argument}`)
    }
  }
  return options
}

function resolveAppTarget(rawPath) {
  if (!rawPath) fail('--app is required')
  const absolute = path.resolve(rawPath)
  if (!absolute.endsWith('.app')) fail('--app must target one .app bundle')
  const app = fs.realpathSync(absolute)
  if (!app.endsWith('.app')) fail('resolved target must remain one .app bundle')
  const required = [
    path.join(app, 'Contents', 'Info.plist'),
    path.join(app, 'Contents', 'MacOS', 'Kaisola'),
    path.join(app, 'Contents', 'Frameworks', 'Sparkle.framework'),
    path.join(app, 'Contents', 'Resources', 'BrokerHelper', 'bin', 'node'),
    path.join(app, 'Contents', 'Resources', 'BrokerHelper', 'manifest.json'),
  ]
  for (const entry of required) {
    if (!fs.existsSync(entry)) fail(`Kaisola distribution bundle is missing ${path.relative(app, entry)}`)
  }
  return app
}

function run(executable, args) {
  const result = spawnSync(executable, args, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 })
  if (result.error) throw result.error
  const output = `${result.stdout || ''}${result.stderr || ''}`.trim()
  if (result.status !== 0) fail(`${path.basename(executable)} failed${output ? `: ${output}` : ''}`)
  return output
}

function resealBrokerHelper({ app, identity }) {
  const helperRoot = path.join(app, 'Contents', 'Resources', 'BrokerHelper')
  const manifestFile = path.join(helperRoot, 'manifest.json')
  const entitlements = path.resolve(
    __dirname,
    '..',
    'native',
    'KaisolaMac',
    'BrokerHelper',
    'BrokerHelper.entitlements',
  )
  if (!fs.existsSync(entitlements)) fail('broker helper entitlements are missing')

  let priorManifest
  try {
    priorManifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
  } catch {
    fail('broker helper manifest is unreadable')
  }
  if (!priorManifest || typeof priorManifest !== 'object' || !Array.isArray(priorManifest.files)) {
    fail('broker helper manifest is invalid')
  }

  // BrokerHelper is a resources directory, not a nested bundle. `codesign
  // --deep` therefore does not discover its loose bootstrap, Node runtime, or
  // node-pty Mach-Os. Sign those explicitly before regenerating the manifest:
  // signing changes both their bytes and designated requirements.
  signNestedCode(helperRoot, String(identity), entitlements)
  const { files: _priorFiles, ...metadata } = priorManifest
  const manifest = createManifest(helperRoot, {
    ...metadata,
    generatedAt: new Date().toISOString(),
  })
  const temporaryManifest = `${manifestFile}.tmp-${process.pid}`
  try {
    fs.writeFileSync(temporaryManifest, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 })
    fs.renameSync(temporaryManifest, manifestFile)
    fs.chmodSync(manifestFile, 0o644)
  } finally {
    fs.rmSync(temporaryManifest, { force: true })
  }
  verifyPackage(helperRoot, { requireSignatures: true })
  return manifest
}

function signDistribution({ app, identity }) {
  if (!identity || !String(identity).trim()) fail('--identity is required')
  resealBrokerHelper({ app, identity })
  run('/usr/bin/codesign', [
    '--force',
    '--deep',
    '--sign', String(identity),
    '--timestamp',
    '--options', 'runtime',
    '--preserve-metadata=identifier,entitlements,requirements,flags',
    app,
  ])
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=4', app])
}

function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv)
  if (options.help) {
    console.log(`Usage: npm run native:sign:distribution -- \\
  --app /path/Kaisola.app \\
  --identity "Developer ID Application: Example (TEAMID)"

Explicitly signs every manifest-covered helper Mach-O, regenerates the sealed
manifest, then re-signs the app and every nested code object with a secure
timestamp while preserving the minimum existing entitlements. Always follow
with native:preflight --require-updates --require-developer-id.`)
    return
  }
  const app = resolveAppTarget(options.app)
  signDistribution({ app, identity: options.identity })
  console.log(`NATIVE_DISTRIBUTION_SIGN=${JSON.stringify({ pass: true, app })}`)
}

if (require.main === module) {
  try {
    main()
  } catch (error) {
    console.error(`NATIVE_DISTRIBUTION_SIGN=FAIL ${error instanceof Error ? error.message : String(error)}`)
    process.exit(1)
  }
}

module.exports = {
  parseArguments,
  resealBrokerHelper,
  resolveAppTarget,
  signDistribution,
}
