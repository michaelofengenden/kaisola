'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const root = path.join(__dirname, '..', '..')

function workflowSource(file) {
  return fs.readFileSync(path.join(root, '.github', 'workflows', file), 'utf8')
}

function jobSource(source, job) {
  const lines = source.split('\n')
  const start = lines.findIndex((line) => line === `  ${job}:`)
  assert.notEqual(start, -1, `workflow must define the ${job} job`)

  let end = lines.length
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^  [a-zA-Z0-9_-]+:\s*(?:#.*)?$/.test(lines[index])) {
      end = index
      break
    }
  }
  return lines.slice(start, end)
}

function checkoutSteps(lines) {
  const checkouts = []
  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trimStart()
    if (!/^(?:-\s+)?uses:\s+actions\/checkout@\S+/.test(trimmed)) continue

    const usesIndentation = lines[index].length - trimmed.length
    const stepIndentation = trimmed.startsWith('- ') ? usesIndentation : usesIndentation - 2
    assert.ok(stepIndentation >= 0, 'checkout step must be nested beneath a workflow job')

    let start = index
    while (start >= 0) {
      const candidate = lines[start].trimStart()
      const candidateIndentation = lines[start].length - candidate.length
      if (candidateIndentation === stepIndentation && candidate.startsWith('- ')) break
      start -= 1
    }
    assert.ok(start >= 0, 'checkout uses must belong to a workflow step')

    let end = lines.length
    for (let cursor = start + 1; cursor < lines.length; cursor += 1) {
      const candidate = lines[cursor].trimStart()
      const candidateIndentation = lines[cursor].length - candidate.length
      if (candidateIndentation === stepIndentation && candidate.startsWith('- ')) {
        end = cursor
        break
      }
    }
    checkouts.push(lines.slice(start, end))
  }
  return checkouts
}

test('security-sensitive jobs do not persist checkout credentials', () => {
  const jobs = [
    ['swift-contracts.yml', 'verify'],
    ['landing-gate.yml', 'landing'],
    ['release-candidate.yml', 'candidate'],
    ['release.yml', 'promote'],
  ]

  for (const [file, job] of jobs) {
    const checkouts = checkoutSteps(jobSource(workflowSource(file), job))
    assert.ok(checkouts.length > 0, `${file}/${job} must contain a checkout step`)
    for (const checkout of checkouts) {
      assert.ok(
        checkout.some((line) => /^\s+persist-credentials: false\s*(?:#.*)?$/.test(line)),
        `${file}/${job} checkout must set persist-credentials: false`,
      )
    }
  }
})

test('the Swift contract workflow grants only read access to repository contents', () => {
  const source = workflowSource('swift-contracts.yml')
  const permissions = /^permissions:\n((?:  [^\n]+\n)+)/m.exec(source)
  assert.ok(permissions, 'swift-contracts.yml must declare workflow permissions')
  assert.equal(permissions[1], '  contents: read\n')
})

test('superseded contract and candidate runs are cancelled by ref', () => {
  const contracts = workflowSource('swift-contracts.yml')
  const candidate = workflowSource('release-candidate.yml')

  assert.match(
    contracts,
    /group: >-\n\s+swift-contracts-\$\{\{ github\.event\.pull_request\.number \|\| github\.ref \}\}/,
  )
  assert.match(
    contracts,
    /-\$\{\{ inputs\.skip-macos-release-build \}\}/,
  )
  assert.doesNotMatch(contracts, /inputs\.skip-ios/)
  assert.match(contracts, /cancel-in-progress: true/)
  assert.doesNotMatch(contracts, /concurrency:[\s\S]*?github\.sha/)

  assert.match(candidate, /group: kaisola-native-candidate-\$\{\{ github\.ref \}\}/)
  assert.match(candidate, /cancel-in-progress: true/)
  assert.doesNotMatch(candidate, /concurrency:[\s\S]*?github\.sha/)
})

test('the landing gate covers every pull request and main integration', () => {
  const source = workflowSource('landing-gate.yml')
  const triggers = /^on:\n([\s\S]*?)\npermissions:/m.exec(source)
  assert.ok(triggers, 'landing-gate.yml must declare triggers before permissions')
  assert.match(triggers[1], /  pull_request:/)
  assert.match(triggers[1], /  push:\n    branches: \[main\]/)
  assert.match(triggers[1], /  merge_group:/)
  assert.doesNotMatch(triggers[1], /paths:/)

  assert.match(source, /group: kaisola-landing-\$\{\{ github\.event\.pull_request\.number \|\| github\.ref \}\}/)
  assert.match(source, /cancel-in-progress: true/)
  assert.match(
    source,
    /LANDING_BASE: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.event\.merge_group\.base_sha \|\| github\.event\.before \}\}/,
  )
  assert.match(source, /git diff --check "\$LANDING_BASE"\.\.\.HEAD/)
  assert.doesNotMatch(source, /HEAD\^1/)
  assert.match(source, /tests\/node\/workflowSecurity\.test\.cjs/)
})
