'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '..', '..')
const workflowPath = path.join(repoRoot, '.github/workflows/swift-contracts.yml')
const workflow = fs.readFileSync(workflowPath, 'utf8')
const packageManifest = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))

const releaseWorkflowFiles = [
  '.github/workflows/release-candidate.yml',
  '.github/workflows/release.yml',
]

const releaseScriptFiles = [
  'scripts/companion-contract-receipt.cjs',
  'scripts/download-native-node-runtime.cjs',
  'scripts/native-appcast.cjs',
  'scripts/native-broker-helper-probe.cjs',
  'scripts/native-broker-package.cjs',
  'scripts/native-distribution-sign.cjs',
  'scripts/native-launch-smoke.cjs',
  'scripts/native-release-candidate.cjs',
  'scripts/native-release-preflight.cjs',
  'scripts/release-fast.cjs',
]

// These files define or directly execute candidate creation, validation,
// signing, notarization, promotion, appcast publication, or fast release.
// Keep the list explicit so adding a release-critical file requires deciding
// how both branch-push and pull-request validation should be triggered.
const releaseCriticalFiles = [
  ...releaseWorkflowFiles,
  '.github/workflows/swift-contracts.yml',
  'package-lock.json',
  'package.json',
  ...releaseScriptFiles,
]

function pathsForEvent(source, event) {
  const lines = source.split(/\r?\n/u)
  const eventStart = lines.indexOf(`  ${event}:`)
  assert.notEqual(eventStart, -1, `swift-contracts must declare an ${event} trigger`)

  const nextEventOrTopLevel = lines.slice(eventStart + 1)
    .findIndex((line) => /^(?:\S| {2}\S)/u.test(line))
  const eventEnd = nextEventOrTopLevel === -1 ? lines.length : eventStart + 1 + nextEventOrTopLevel
  const eventLines = lines.slice(eventStart + 1, eventEnd)
  const pathsStart = eventLines.indexOf('    paths:')
  assert.notEqual(pathsStart, -1, `${event} must declare path filters`)

  const remainingEventLines = eventLines.slice(pathsStart + 1)
  const nextEventKey = remainingEventLines.findIndex((line) => /^ {4}\S/u.test(line))
  const pathLines = remainingEventLines.slice(0, nextEventKey === -1 ? undefined : nextEventKey)

  return pathLines
    .map((line) => line.match(/^      - ['"](.+)['"]$/u)?.[1])
    .filter(Boolean)
}

function matchesPathFilter(file, filter) {
  let expression = '^'
  for (let index = 0; index < filter.length; index += 1) {
    const character = filter[index]
    if (character === '*' && filter[index + 1] === '*') {
      expression += '.*'
      index += 1
    } else if (character === '*') {
      expression += '[^/]*'
    } else {
      expression += character.replace(/[\\^$.*+?()[\]{}|]/gu, '\\$&')
    }
  }
  return new RegExp(`${expression}$`, 'u').test(file)
}

function referencedReleaseScripts() {
  const references = new Set()
  const workflowSources = releaseWorkflowFiles.map((file) => (
    fs.readFileSync(path.join(repoRoot, file), 'utf8')
  ))

  for (const source of workflowSources) {
    for (const match of source.matchAll(/\bscripts\/[A-Za-z0-9._/-]+\.(?:cjs|sh)\b/gu)) {
      references.add(match[0])
    }
    for (const match of source.matchAll(/\bnpm run ([A-Za-z0-9:_-]+)/gu)) {
      const command = packageManifest.scripts[match[1]]
      assert.equal(typeof command, 'string', `release workflow references missing npm script ${match[1]}`)
      for (const scriptMatch of command.matchAll(/\bscripts\/[A-Za-z0-9._/-]+\.(?:cjs|sh)\b/gu)) {
        references.add(scriptMatch[0])
      }
    }
  }

  const namedReleaseScripts = fs.readdirSync(path.join(repoRoot, 'scripts'))
    .filter((name) => /(?:release|appcast|distribution-sign)/u.test(name))
    .map((name) => `scripts/${name}`)
  for (const file of namedReleaseScripts) references.add(file)

  return [...references].sort()
}

test('the explicit inventory covers every release workflow and release script', () => {
  const discoveredWorkflows = fs.readdirSync(path.join(repoRoot, '.github/workflows'))
    .filter((name) => /^release(?:-[A-Za-z0-9-]+)?\.ya?ml$/u.test(name))
    .map((name) => `.github/workflows/${name}`)
    .sort()

  assert.deepEqual([...releaseWorkflowFiles].sort(), discoveredWorkflows)
  assert.deepEqual([...releaseScriptFiles].sort(), referencedReleaseScripts())
})

// push only, on purpose (2026-08-20): the PR-side copy of the heavy suite was
// removed — `landing` gates merges and this suite gates the release on the
// main commit, so push is the one event whose path filters must stay complete.
for (const event of ['push']) {
  test(`${event} validates every release-critical workflow and script`, () => {
    const filters = pathsForEvent(workflow, event)
    const uncovered = releaseCriticalFiles.filter((file) => (
      !filters.some((filter) => matchesPathFilter(file, filter))
    ))

    assert.deepEqual(
      uncovered,
      [],
      `${event}.paths does not cover: ${uncovered.join(', ')}`,
    )
  })
}

test('the required contract lane runs this path-filter regression check', () => {
  assert.match(workflow, /tests\/node\/swiftContractsPaths\.test\.cjs/u)
})
