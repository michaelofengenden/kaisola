const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '../..')
const workflow = path.join(repoRoot, '.github/workflows/native-fish-compatibility.yml')
const swiftTest = path.join(
  repoRoot,
  'native/KaisolaMac/KaisolaTests/NativeTerminalInteractionTests.swift'
)
const supportMatrix = path.join(
  repoRoot,
  'native/KaisolaMac/ResourceGates/fish-compatibility-v1.md'
)
const resultValidator = path.join(repoRoot, 'scripts/native-fish-compatibility-result.cjs')
const expectedIdentifier =
  'NativeTerminalInteractionTests/testGeneratedFishIntegrationExecutesWhenFishRuntimeIsAvailable()'

function resultTree(result = 'Passed', copies = 1) {
  return {
    testNodes: [{
      nodeType: 'Test Plan',
      result,
      children: [{
        nodeType: 'Unit test bundle',
        result,
        children: Array.from({ length: copies }, () => ({
          nodeType: 'Test Case',
          nodeIdentifier: expectedIdentifier,
          result,
        })),
      }],
    }],
  }
}

function runResultValidator(tree, extra = []) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-fish-result-'))
  const resultsPath = path.join(root, 'test-results.json')
  fs.writeFileSync(resultsPath, `${JSON.stringify(tree)}\n`, { mode: 0o600 })
  const result = spawnSync(
    process.execPath,
    [resultValidator, '--results', resultsPath, ...extra],
    { cwd: repoRoot, encoding: 'utf8' }
  )
  fs.rmSync(root, { recursive: true, force: true })
  return result
}

function resultTreeWithUnexpectedPass() {
  const tree = resultTree()
  tree.testNodes[0].children[0].children.push({
    nodeType: 'Test Case',
    nodeIdentifier: 'UnexpectedTests/testUnexpectedPass()',
    result: 'Passed',
  })
  return tree
}

test('required Fish workflow pins the runtime and exact executable artifact', () => {
  assert.ok(fs.existsSync(workflow), 'the dedicated required Fish workflow must exist')
  const source = fs.readFileSync(workflow, 'utf8')
  assert.match(source, /runs-on:\s*macos-15/)
  assert.match(source, /fish-4\.8\.1\.app\.zip/)
  assert.match(source, /aec7606269bbd0af8ac29f66d7f50f32f72b1d68d3b278227ae3e94cf501bb7f/)
  assert.match(source, /Contents\/Resources\/base\/usr\/local\/bin\/fish/)
  assert.match(source, /test -x \/usr\/bin\/expect/)
  assert.match(source, /KAISOLA_TEST_FISH=/)
  assert.match(source, /KAISOLA_REQUIRE_FISH_COMPATIBILITY:\s*['"]1['"]/)
  assert.match(source, /required-fish-compatibility\.json/)
  assert.match(source, /pull_request:\s*\n\s+push:/, 'the required lane must run on every pull request')
  assert.match(
    source,
    /-only-testing:KaisolaTests\/NativeTerminalInteractionTests\/testGeneratedFishIntegrationExecutesWhenFishRuntimeIsAvailable/
  )
  assert.match(source, /xcresulttool get test-results tests/)
  assert.match(source, /native-fish-compatibility-result\.cjs/)
  assert.match(source, /actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a/)
  assert.match(source, /if-no-files-found:\s*error/)
})

test('required Fish XCTest fails closed and exercises both semantic paths', () => {
  const source = fs.readFileSync(swiftTest, 'utf8')
  assert.match(source, /KAISOLA_REQUIRE_FISH_COMPATIBILITY/)
  assert.match(source, /KAISOLA_EXPECTED_FISH_VERSION/)
  assert.match(source, /required-fish-compatibility\.json/)
  assert.match(source, /missingRequiredFish/)
  assert.match(source, /custom-config-ok/)
  assert.match(source, /modern-path-ok/)
  assert.match(source, /fallback-path-ok/)
  assert.match(source, /cancel-path-ok/)
  assert.match(source, /resize-path-ok/)
  assert.match(source, /D;17/)
})

test('support matrix names the pinned required lane and fallback boundary', () => {
  assert.ok(fs.existsSync(supportMatrix), 'the supported Fish matrix must be documented')
  const source = fs.readFileSync(supportMatrix, 'utf8')
  assert.match(source, /Fish 4\.8\.1/)
  assert.match(source, /Required CI/)
  assert.match(source, /native OSC 133/i)
  assert.match(source, /generated fallback/i)
  assert.match(source, /older Fish/i)
})

test('Fish result validator accepts exactly one passed required test', () => {
  const result = runResultValidator(resultTree())
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), {
    ok: true,
    fishVersion: '4.8.1',
    test: expectedIdentifier,
    result: 'Passed',
  })
})

test('Fish result validator rejects skips, failures, duplication, and ambiguity', () => {
  for (const [tree, extra] of [
    [resultTree('Skipped'), []],
    [resultTree('Failed'), []],
    [resultTree('Passed', 2), []],
    [resultTreeWithUnexpectedPass(), []],
    [{ testNodes: [] }, []],
    [resultTree(), ['--extra']],
  ]) {
    const result = runResultValidator(tree, extra)
    assert.notEqual(result.status, 0, 'a non-unique pass must fail the required lane')
    assert.equal(result.stdout, '')
  }
})
