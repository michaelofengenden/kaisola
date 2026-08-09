'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const repoRoot = path.resolve(__dirname, '..', '..')
const guardTestFile = 'tests/node/brokerRuntimeManifest.test.cjs'

// The required durability lane runs exactly this manifest. Keep it explicit:
// adding a broker-prefixed suite or a test that directly loads the Node broker
// runtime makes the guard fail until the new path is reviewed and listed here.
const brokerRuntimeTestFiles = Object.freeze([
  'tests/node/brokerCompatibility.test.cjs',
  'tests/node/brokerRendezvous.test.cjs',
  'tests/node/brokerUpgrade.test.cjs',
  'tests/node/brokerUpgradeIntegration.test.cjs',
  'tests/node/companionProtocolTables.test.cjs',
  'tests/node/terminalCreateRoute.test.cjs',
  'tests/node/terminalManager.test.cjs',
  'tests/node/terminalSpool.test.cjs',
])

function discoversBrokerRuntime(source, file) {
  if (/^broker.*\.test\.cjs$/u.test(file)) return true
  return /(?:require|path\.resolve)\s*\([^)]*['"]\.\.\/\.\.\/runtime\/node-broker\//u
    .test(source)
}

function discoverBrokerRuntimeTestFiles(directory = path.join(repoRoot, 'tests', 'node')) {
  return fs.readdirSync(directory)
    .filter((file) => file.endsWith('.test.cjs') && file !== path.basename(guardTestFile))
    .filter((file) => discoversBrokerRuntime(
      fs.readFileSync(path.join(directory, file), 'utf8'),
      file,
    ))
    .map((file) => `tests/node/${file}`)
    .sort()
}

function runManifest() {
  const result = spawnSync(
    process.execPath,
    ['--test', '--test-concurrency=1', guardTestFile, ...brokerRuntimeTestFiles],
    { cwd: repoRoot, stdio: 'inherit' },
  )
  if (result.error) throw result.error
  process.exitCode = result.status ?? 1
}

if (require.main === module) runManifest()

module.exports = {
  brokerRuntimeTestFiles,
  discoverBrokerRuntimeTestFiles,
  guardTestFile,
}
