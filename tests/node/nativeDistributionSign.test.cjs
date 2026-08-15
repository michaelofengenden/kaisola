'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')
const {
  parseArguments,
  resealBrokerHelper,
  resealNativeBrokerHelper,
  resolveAppTarget,
} = require('../../scripts/native-distribution-sign.cjs')
const { createManifest, verifyPackage } = require('../../scripts/native-broker-package.cjs')

const repoRoot = path.resolve(__dirname, '..', '..')

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' })
  if (result.error || result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed: ${String(result.stderr || result.stdout || result.error?.message).trim()}`)
  }
  return result
}

function writeAppInfo(app, { version = '0.1.125', build = '1125000' } = {}) {
  const info = path.join(app, 'Contents', 'Info.plist')
  fs.mkdirSync(path.dirname(info), { recursive: true })
  fs.writeFileSync(info, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${build}</string>
</dict></plist>\n`)
}

function compileArm64Fixture(root, name) {
  const source = path.join(root, `${name}.c`)
  const executable = path.join(root, name)
  fs.writeFileSync(source, 'int main(void) { return 0; }\n')
  run('/usr/bin/xcrun', ['--sdk', 'macosx', 'clang', '-arch', 'arm64', source, '-o', executable])
  return executable
}

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
      'Contents/Resources/BrokerHelper/bin/kaisola-broker-bootstrap',
      'Contents/Resources/BrokerHelper/manifest.json',
      'Contents/Resources/BrokerSessionHelper/bin/kaisola-session-broker',
      'Contents/Resources/BrokerSessionHelper/bin/kaisola-broker-bootstrap',
      'Contents/Resources/BrokerSessionHelper/manifest.json',
    ]) {
      const target = path.join(app, entry)
      fs.mkdirSync(path.dirname(target), { recursive: true })
      fs.writeFileSync(target, '')
    }
    assert.equal(resolveAppTarget(app), fs.realpathSync(app))
    fs.rmSync(path.join(
      app,
      'Contents/Resources/BrokerSessionHelper/bin/kaisola-broker-bootstrap',
    ))
    assert.throws(
      () => resolveAppTarget(app),
      /missing Contents\/Resources\/BrokerSessionHelper\/bin\/kaisola-broker-bootstrap/,
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
  for (const name of ['node', 'kaisola-broker-bootstrap']) {
    fs.copyFileSync('/usr/bin/true', path.join(helper, 'bin', name))
    fs.chmodSync(path.join(helper, 'bin', name), 0o755)
  }
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
  assert.equal(after.files.filter((entry) => entry.machO).length, 2)
  assert.ok(after.files.every((entry) => !entry.machO || entry.machO.designatedRequirement))
  assert.notEqual(after.files.find((entry) => entry.path === 'bin/node').sha256,
    before.files.find((entry) => entry.path === 'bin/node').sha256)
  assert.deepEqual(verifyPackage(helper, { requireSignatures: true }), after)
})

test('distribution signer reseals schema-2 native helper without Node JIT entitlements', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-sign-native-helper-contract-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const app = path.join(root, 'Kaisola.app')
  writeAppInfo(app)
  const helper = path.join(app, 'Contents', 'Resources', 'BrokerSessionHelper')
  const broker = path.join(helper, 'bin', 'kaisola-session-broker')
  const bootstrap = path.join(helper, 'bin', 'kaisola-broker-bootstrap')
  fs.mkdirSync(path.dirname(broker), { recursive: true })
  fs.copyFileSync(compileArm64Fixture(root, 'broker-fixture'), broker)
  fs.copyFileSync(compileArm64Fixture(root, 'bootstrap-fixture'), bootstrap)
  fs.chmodSync(broker, 0o755)
  fs.chmodSync(bootstrap, 0o755)

  // Seed the fixture with the Node-only entitlements. The native reseal must
  // actively remove them, not merely avoid adding them to a clean executable.
  const nodeEntitlements = path.join(
    repoRoot,
    'native',
    'KaisolaMac',
    'BrokerHelper',
    'BrokerHelper.entitlements',
  )
  run('/usr/bin/codesign', ['--force', '--sign', '-', '--entitlements', nodeEntitlements, broker])
  const entitled = run('/usr/bin/codesign', ['-d', '--entitlements', ':-', broker])
  assert.match(`${entitled.stdout}\n${entitled.stderr}`, /allow-jit/)
  assert.match(`${entitled.stdout}\n${entitled.stderr}`, /allow-unsigned-executable-memory/)

  const policy = require('../../native/KaisolaMac/BrokerHelper/native-package-policy.json')
  const metadata = {
    schemaVersion: policy.schemaVersion,
    packageVersion: policy.packageVersion,
    appRelease: { version: '0.1.125', build: '1125000' },
    brokerImplementationVersion: policy.brokerImplementationVersion,
    brokerProtocol: policy.brokerProtocol,
    launch: {
      kind: 'native',
      executable: 'bin/kaisola-session-broker',
      arguments: [],
    },
    generatedAt: 'fixture',
  }
  const before = createManifest(helper, metadata)
  fs.writeFileSync(path.join(helper, 'manifest.json'), `${JSON.stringify(before, null, 2)}\n`, { mode: 0o644 })

  const after = resealNativeBrokerHelper({ app, identity: '-' })
  assert.equal(after.schemaVersion, 2)
  assert.deepEqual(after.appRelease, { version: '0.1.125', build: '1125000' })
  assert.notEqual(
    after.files.find((entry) => entry.path === 'bin/kaisola-session-broker').sha256,
    before.files.find((entry) => entry.path === 'bin/kaisola-session-broker').sha256,
  )
  assert.deepEqual(verifyPackage(helper, {
    requireSignatures: true,
    policy: { ...policy, appRelease: metadata.appRelease },
  }), after)

  const signature = run('/usr/bin/codesign', ['-d', '--entitlements', ':-', broker])
  assert.doesNotMatch(`${signature.stdout}\n${signature.stderr}`, /allow-jit|allow-unsigned-executable-memory/)
  const bootstrapSignature = run('/usr/bin/codesign', [
    '-d', '--entitlements', ':-', bootstrap,
  ])
  assert.doesNotMatch(
    `${bootstrapSignature.stdout}\n${bootstrapSignature.stderr}`,
    /allow-jit|allow-unsigned-executable-memory/,
  )

  writeAppInfo(app, { version: '0.1.125', build: '1125001' })
  assert.throws(
    () => resealNativeBrokerHelper({ app, identity: '-' }),
    /does not match the Kaisola app release/,
  )
})
