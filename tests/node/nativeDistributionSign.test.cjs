'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const {
  parseArguments,
  resealBrokerHelper,
  resolveAppTarget,
} = require('../../scripts/native-distribution-sign.cjs')
const { createManifest, verifyPackage } = require('../../scripts/native-broker-package.cjs')

test('distribution signer requires explicit bounded arguments', () => {
  assert.deepEqual(parseArguments([
    '--app', '/tmp/Kaisola.app',
    '--identity', 'Developer ID Application: Example (TEAMID)',
  ]), {
    app: '/tmp/Kaisola.app',
    identity: 'Developer ID Application: Example (TEAMID)',
  })
  assert.throws(() => parseArguments(['--unknown']), /unknown argument/)
  assert.throws(() => parseArguments(['--app']), /requires a path/)
})

test('distribution signer refuses broad and incomplete targets', () => {
  assert.throws(() => resolveAppTarget('/'), /one \.app bundle/)
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-sign-contract-'))
  try {
    const app = path.join(root, 'Kaisola.app')
    fs.mkdirSync(app)
    assert.throws(() => resolveAppTarget(app), /missing Contents\/Info\.plist/)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('distribution signer resolves one complete Kaisola bundle', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-sign-contract-'))
  try {
    const app = path.join(root, 'Kaisola.app')
    for (const entry of [
      'Contents/Info.plist',
      'Contents/MacOS/Kaisola',
      'Contents/Frameworks/Sparkle.framework/.keep',
      'Contents/Resources/BrokerHelper/bin/node',
      'Contents/Resources/BrokerHelper/manifest.json',
    ]) {
      const target = path.join(app, entry)
      fs.mkdirSync(path.dirname(target), { recursive: true })
      fs.writeFileSync(target, '')
    }
    assert.equal(resolveAppTarget(app), fs.realpathSync(app))
    fs.rmSync(path.join(app, 'Contents/Resources/BrokerHelper/bin/node'))
    assert.throws(
      () => resolveAppTarget(app),
      /missing Contents\/Resources\/BrokerHelper\/bin\/node/,
    )
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('distribution signer explicitly signs loose helper Mach-Os and refreshes their manifest', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-sign-helper-contract-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const app = path.join(root, 'Kaisola.app')
  const helper = path.join(app, 'Contents', 'Resources', 'BrokerHelper')
  fs.mkdirSync(path.join(helper, 'bin'), { recursive: true })
  fs.copyFileSync('/usr/bin/true', path.join(helper, 'bin', 'node'))
  fs.chmodSync(path.join(helper, 'bin', 'node'), 0o755)
  const policy = require('../../native/KaisolaMac/BrokerHelper/package-policy.json')
  const metadata = {
    schemaVersion: policy.schemaVersion,
    packageVersion: policy.packageVersion,
    brokerImplementationVersion: policy.brokerImplementationVersion,
    brokerProtocol: policy.brokerProtocol,
    node: { ...policy.node, architectures: ['arm64', 'x86_64'] },
    nodePty: { version: policy.nodePtyVersion },
    claudeAgentSDK: { version: policy.claudeAgentSDKVersion },
    generatedAt: 'fixture',
  }
  const before = createManifest(helper, metadata)
  fs.writeFileSync(path.join(helper, 'manifest.json'), `${JSON.stringify(before, null, 2)}\n`, { mode: 0o644 })

  const after = resealBrokerHelper({ app, identity: '-' })
  assert.equal(after.files.filter((entry) => entry.machO).length, 1)
  assert.ok(after.files.every((entry) => !entry.machO || entry.machO.designatedRequirement))
  assert.notEqual(after.files.find((entry) => entry.path === 'bin/node').sha256,
    before.files.find((entry) => entry.path === 'bin/node').sha256)
  assert.deepEqual(verifyPackage(helper, { requireSignatures: true }), after)
})
