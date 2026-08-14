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
  'tests/node/brokerAuthorization.test.cjs',
  'tests/node/brokerCompatibility.test.cjs',
  'tests/node/brokerExitStatus.test.cjs',
  'tests/node/brokerFrameLimits.test.cjs',
  'tests/node/brokerInventorySnapshot.test.cjs',
  'tests/node/brokerObserverOnlyOutputIntegration.test.cjs',
  'tests/node/brokerProtocolConformance.test.cjs',
  'tests/node/brokerProtocolFeatures.test.cjs',
  'tests/node/brokerRendezvous.test.cjs',
  'tests/node/brokerRequestGate.test.cjs',
  'tests/node/brokerTerminalIdLimit.test.cjs',
  'tests/node/brokerUpgrade.test.cjs',
  'tests/node/brokerUpgradeIntegration.test.cjs',
  'tests/node/brokerWire.test.cjs',
  'tests/node/companionProtocolTables.test.cjs',
  'tests/node/companionTerminalCursor.test.cjs',
  'tests/node/freshBrokerLifecycleIntegration.test.cjs',
  'tests/node/sessionBrokerExitWaits.test.cjs',
  'tests/node/shellEnv.test.cjs',
  'tests/node/terminalAttachRoute.test.cjs',
  'tests/node/terminalCreateRoute.test.cjs',
  'tests/node/terminalCursorUnicodeFastPath.test.cjs',
  'tests/node/terminalDetachOwnerRoute.test.cjs',
  'tests/node/terminalKillRoute.test.cjs',
  'tests/node/terminalManager.test.cjs',
  'tests/node/terminalObservers.test.cjs',
  'tests/node/terminalReleaseRoute.test.cjs',
  'tests/node/terminalResizeRoute.test.cjs',
  'tests/node/terminalSpool.test.cjs',
  'tests/node/terminalSpoolAsync.test.cjs',
  'tests/node/terminalWarning.test.cjs',
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
