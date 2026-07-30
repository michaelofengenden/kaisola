'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '..', '..')
const selector = require('../../scripts/native-test-select.cjs')
const timing = require('../../scripts/native-build-timing.cjs')

const inventory = selector.discoverInventory(repoRoot)

test('selection is deterministic regardless of changed-file order and duplicates', () => {
  const files = [
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
    'scripts/native-mcp-registry.cjs',
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
  ]
  const forward = selector.planForChanges(files, inventory)
  const reverse = selector.planForChanges([...files].reverse(), inventory)

  assert.deepEqual(reverse, forward)
  assert.deepEqual(forward.changedFiles, [
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
    'scripts/native-mcp-registry.cjs',
  ])
  assert.deepEqual(forward.native.selectors, [
    'DataPreviewsTests', 'SyntaxHighlighterTests', 'WorkspaceFilesTests',
  ])
  assert.deepEqual(forward.node.files, ['tests/node/nativeMcpRegistry.test.cjs'])
  assert.equal(forward.fallback, false)
})

test('a native test file selects exactly its test class', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/KaisolaTests/TerminalScrollPinTests.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, ['TerminalScrollPinTests'])
  assert.equal(plan.node.mode, 'none')
  assert.deepEqual(plan.swiftPackages, [])
})

test('extracted workspace rail stays on the narrow workspace contract', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Features/Workspace/WorkspaceRailView.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, ['WorkspaceFilesTests'])
  assert.equal(plan.node.mode, 'none')
})

test('broker and shared wire changes expand to the reproducible contract lane', () => {
  const plan = selector.planForChanges([
    'runtime/node-broker/ipc/brokerWire.cjs',
  ], inventory)

  assert.equal(plan.native.mode, 'contract')
  assert.deepEqual(plan.native.selectors, [...selector.NATIVE_CONTRACT_TESTS].sort())
  assert.equal(plan.node.mode, 'all')
  assert.deepEqual(plan.swiftPackages, ['native/KaisolaCore'])
  assert.equal(plan.fallback, false)
  assert.match(plan.reasons.join('\n'), /broker\/shared protocol changed/u)
})

test('release changes select all Node contracts plus update-facing native tests', () => {
  const plan = selector.planForChanges(['scripts/native-appcast.cjs'], inventory)

  assert.equal(plan.node.mode, 'all')
  assert.deepEqual(plan.native.selectors, [
    'BrokerHelperPackageTests', 'NativeUpdateConfigurationTests',
  ])
  assert.equal(plan.fallback, false)
})

test('an unmapped runtime change uses the broad fallback rather than skipping', () => {
  const plan = selector.planForChanges(['unexpected/runtime-policy.toml'], inventory)

  assert.equal(plan.fallback, true)
  assert.equal(plan.node.mode, 'all')
  assert.equal(plan.native.mode, 'contract')
  assert.deepEqual(plan.native.selectors, [...selector.NATIVE_CONTRACT_TESTS].sort())
  assert.deepEqual(plan.swiftPackages, ['native/KaisolaCore'])
})

test('known documentation-only changes produce an explicit empty runtime plan', () => {
  const plan = selector.planForChanges(['docs/fast-loop.md', 'README.md'], inventory)

  assert.equal(plan.fallback, false)
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.native.mode, 'none')
  assert.deepEqual(plan.swiftPackages, [])
  assert.deepEqual(plan.reasons, ['known documentation-only change'])
})

test('repository-relative path normalization is strict', () => {
  assert.equal(selector.normalizeChangedFile('./native\\KaisolaMac\\project.yml'), 'native/KaisolaMac/project.yml')
  assert.throws(() => selector.normalizeChangedFile('../outside.swift'), /repository-relative/u)
  assert.throws(() => selector.normalizeChangedFile('/tmp/outside.swift'), /repository-relative/u)
})

test('CLI accepts explicit files and emits the same machine-readable plan', () => {
  const script = path.join(repoRoot, 'scripts', 'native-test-select.cjs')
  const result = spawnSync(process.execPath, [
    script,
    '--changed-file', 'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
    '--format', 'json',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 0, result.stderr)
  const plan = JSON.parse(result.stdout)
  assert.deepEqual(plan.native.selectors, [
    'DataPreviewsTests', 'SyntaxHighlighterTests', 'WorkspaceFilesTests',
  ])
  assert.equal(plan.node.mode, 'none')
})

test('CLI rejects an empty explicit changed-file list instead of skipping tests', () => {
  const script = path.join(repoRoot, 'scripts', 'native-test-select.cjs')
  const result = spawnSync(process.execPath, [
    script, '--changed-files-from', '-', '--format', 'json',
  ], { cwd: repoRoot, input: '', encoding: 'utf8' })

  assert.equal(result.status, 2)
  assert.match(result.stderr, /no changed files/u)
})

test('changed-file runner prints a plan without invoking xcodebuild in dry-run mode', () => {
  const script = path.join(repoRoot, 'scripts', 'native-test-changed.sh')
  const result = spawnSync(script, [
    '--changed-file', 'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
    '--dry-run',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /Native tests \(focused\): DataPreviewsTests, SyntaxHighlighterTests, WorkspaceFilesTests/u)
  assert.match(result.stdout, /Dry run: no tests executed/u)
})

test('changed-file runner isolates SwiftPM caches from repository moves', () => {
  const runner = fs.readFileSync(path.join(repoRoot, 'scripts', 'native-test-changed.sh'), 'utf8')
  assert.match(runner, /shasum -a 256/)
  assert.match(runner, /--scratch-path "\$package_scratch"/)
})

test('changed-file runner executes a focused Node file from its JSON plan', () => {
  const script = path.join(repoRoot, 'scripts', 'native-test-changed.sh')
  const result = spawnSync(script, [
    '--changed-file', 'tests/node/nativeCatalogSmoke.test.cjs',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /Node tests \(focused\): tests\/node\/nativeCatalogSmoke\.test\.cjs/u)
  assert.match(result.stdout, /Changed-file test lane passed/u)
})

test('build timing arguments require a bounded warm-run count and a label', () => {
  const parsed = timing.parseArguments(['--label', 'after-split', '--warm-runs', '2'])
  assert.equal(parsed.label, 'after-split')
  assert.equal(parsed.warmRuns, 2)
  assert.throws(() => timing.parseArguments([]), /--label is required/u)
  assert.throws(
    () => timing.parseArguments(['--label', 'bad', '--warm-runs', '0']),
    /integer from 1 through 10/u,
  )
})

test('build timing cleanup refuses paths outside its exact temporary namespace', () => {
  assert.throws(() => timing.safeCleanup(repoRoot), /refusing to remove unexpected timing directory/u)
})

test('fast build refuses contradictory helper options before touching the build cache', () => {
  const script = path.join(repoRoot, 'scripts', 'native-fast.sh')
  const result = spawnSync(script, [
    '--build-only', '--refresh-helper', '--skip-helper',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 2)
  assert.match(result.stderr, /mutually exclusive/u)
})

test('helper skipping is restricted to the isolated timing runner', () => {
  const script = path.join(repoRoot, 'scripts', 'native-fast.sh')
  const result = spawnSync(script, [
    '--build-only', '--skip-helper',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 2)
  assert.match(result.stderr, /reserved for the isolated native:timing runner/u)
})
