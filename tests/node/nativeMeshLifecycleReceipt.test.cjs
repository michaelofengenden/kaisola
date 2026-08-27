const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '../..')
const validator = path.join(repoRoot, 'scripts/native-mesh-lifecycle-receipt.cjs')
const workflow = path.join(repoRoot, '.github/workflows/native-mesh-lifecycle.yml')
const packagePolicy = require(path.join(
  repoRoot,
  'native/KaisolaMac/BrokerHelper/package-policy.json'
))
const pinnedNodeVersion = packagePolicy.node.version
const swiftTest = path.join(
  repoRoot,
  'native/KaisolaMac/KaisolaTests/MeshSessionTests.swift'
)

function validReceipt(overrides = {}) {
  return {
    schemaVersion: 1,
    nodeVersion: pinnedNodeVersion,
    columns: 3,
    adapterProcessesAtStart: 3,
    minimumAdapterFileDescriptorsAtStart: 4,
    adaptersStoppedAfterSuspend: true,
    adaptersStoppedAfterDestroy: true,
    worktreesPreservedAfterSuspend: true,
    descriptorColumnsAfterSuspend: 3,
    recoverableColumnCount: 1,
    unconfirmedDestroyRefused: true,
    restoredColumns: 3,
    adapterProcessesAfterRestore: 3,
    restoredWithoutDuplicateWorktrees: true,
    meshWorktreesRemoved: true,
    meshBranchesRemoved: true,
    unrelatedProcessPreserved: true,
    unrelatedWorktreePreserved: true,
    ...overrides,
  }
}

function fixture(receipt = validReceipt()) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-mesh-receipt-'))
  const receiptPath = path.join(root, 'receipt.json')
  fs.writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 })
  return { root, receiptPath }
}

function runValidator(receiptPath, extra = []) {
  return spawnSync(process.execPath, [validator, '--receipt', receiptPath, ...extra], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
}

test('required Mesh workflow pins the runtime, selector, receipt gate, and artifact', () => {
  assert.ok(fs.existsSync(workflow), 'the dedicated required workflow must exist')
  const source = fs.readFileSync(workflow, 'utf8')
  assert.match(source, /actions\/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38/)
  // The runtime version is single-sourced from the package policy: the
  // workflow must READ it (a hardcoded copy is what broke the 0.1.141
  // candidate) and must not restate it anywhere.
  assert.match(source, /package-policy\.json'\)\.node\.version/)
  assert.match(source, /node-version:\s*\$\{\{\s*steps\.pinned-node\.outputs\.version\s*\}\}/)
  assert.match(source, /KAISOLA_EXPECTED_NODE_VERSION=\$version/)
  assert.doesNotMatch(
    source,
    /\d+\.\d+\.\d+-darwin|node-version:\s*['"]\d/,
    'the workflow must not restate the pinned runtime version'
  )
  assert.match(source, /KAISOLA_REQUIRE_MESH_INTEGRATION:\s*['"]1['"]/)
  assert.match(source, /KAISOLA_MESH_LIFECYCLE_RECEIPT:/)
  const jobEnvironment = source.slice(source.indexOf('    env:'), source.indexOf('    steps:'))
  assert.doesNotMatch(
    jobEnvironment,
    /runner\.temp/,
    'runner context is unavailable while GitHub evaluates a job-level environment'
  )
  assert.match(source, /required-mesh-lifecycle\.json/)
  assert.match(source, /pull_request:\s*\n\s+push:/, 'the required lane must run on every pull request')
  assert.match(
    source,
    /-only-testing:KaisolaTests\/MeshSessionTests\/testMeshSuspendPreservesRecoverableWorkAndConfirmedDestroyCleansIt/
  )
  assert.match(source, /native-mesh-lifecycle-receipt\.cjs/)
  assert.match(source, /actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a/)
  assert.match(source, /if-no-files-found:\s*error/)
})

test('required Mesh test fails closed and records bounded lifecycle evidence', () => {
  const source = fs.readFileSync(swiftTest, 'utf8')
  assert.match(source, /KAISOLA_REQUIRE_MESH_INTEGRATION/)
  assert.match(source, /KAISOLA_EXPECTED_NODE_VERSION/)
  assert.match(source, /KAISOLA_MESH_LIFECYCLE_RECEIPT/)
  assert.match(source, /required-mesh-lifecycle\.json/)
  assert.match(source, /BrokerHelper\/package-policy\.json/)
  assert.doesNotMatch(
    source,
    /configuration\.nodeVersion\s*==\s*["']\d+\.\d+\.\d+/,
    'the Swift gate must read the package policy instead of restating the runtime version'
  )
  assert.match(source, /missingRequiredNode/)
  assert.match(source, /adapterProcessesAtStart/)
  assert.match(source, /minimumAdapterFileDescriptorsAtStart/)
  assert.match(source, /adaptersStoppedAfterDestroy/)
  assert.match(source, /unrelatedProcessPreserved/)
  assert.match(source, /unrelatedWorktreePreserved/)
})

test('receipt validator accepts one complete redacted lifecycle proof', () => {
  const source = fs.readFileSync(validator, 'utf8')
  assert.match(source, /package-policy\.json/)
  assert.doesNotMatch(
    source,
    /expectedNodeVersion\s*=\s*["']\d+\.\d+\.\d+/,
    'the receipt validator must read the package policy instead of restating the runtime version'
  )
  const { root, receiptPath } = fixture()
  try {
    const result = runValidator(receiptPath)
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(JSON.parse(result.stdout), {
      ok: true,
      schemaVersion: 1,
      nodeVersion: pinnedNodeVersion,
      columns: 3,
      recoverableColumnCount: 1,
    })
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('receipt validator rejects missing evidence, count drift, and unknown fields', () => {
  for (const receipt of [
    validReceipt({ nodeVersion: '0.0.0' }),
    validReceipt({ adaptersStoppedAfterSuspend: false }),
    validReceipt({ adapterProcessesAtStart: 2 }),
    validReceipt({ minimumAdapterFileDescriptorsAtStart: 0 }),
    validReceipt({ unexpectedPath: '/private/tmp/secret' }),
  ]) {
    const { root, receiptPath } = fixture(receipt)
    try {
      const result = runValidator(receiptPath)
      assert.notEqual(result.status, 0, 'invalid lifecycle evidence must fail closed')
      assert.equal(result.stdout, '')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  }
})

test('receipt validator rejects unsafe files and ambiguous CLI arguments', () => {
  const { root, receiptPath } = fixture()
  try {
    fs.chmodSync(receiptPath, 0o644)
    assert.notEqual(runValidator(receiptPath).status, 0)

    fs.chmodSync(receiptPath, 0o600)
    const alias = path.join(root, 'alias.json')
    fs.symlinkSync(receiptPath, alias)
    assert.notEqual(runValidator(alias).status, 0)

    assert.notEqual(runValidator(receiptPath, ['--extra']).status, 0)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})
