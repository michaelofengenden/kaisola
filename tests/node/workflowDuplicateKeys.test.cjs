'use strict'

// A duplicated mapping key makes GitHub reject a workflow file outright: the
// run is created and immediately fails with "workflow file issue", before any
// step exists to report why. Nothing else in the suite noticed, because every
// other workflow assertion reads the file as text and a duplicate key is
// perfectly good text. One stray `env:` above the real `env:` block in
// `swift-contracts.yml` therefore reached `main` green and killed the release
// candidate that `release.yml` promotes from.
//
// The repository has no YAML dependency, and adding one to guard a structural
// mistake is a poor trade, so the scan below reads indentation the way YAML
// does: a mapping scope opens when indentation increases, closes when it
// decreases, and restarts at every sequence dash. Block scalars are skipped
// whole, since their contents are text and may legitimately repeat a line.

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '..', '..')
const workflowDirectory = path.join(repoRoot, '.github/workflows')

// `key: |`, `key: >-`, and friends introduce a literal block: everything
// indented under it is content rather than structure.
const blockScalarHeader = /:\s*[|>][-+\d]*\s*(#.*)?$/
const sequenceDash = /^( *)- +/
const emptySequenceDash = /^ *-\s*$/
const mappingKey = /^( *)("[^"]*"|'[^']*'|[^\s:#][^:#]*):(\s|$)/

function duplicateKeys(source) {
  const duplicates = []
  const lines = source.split('\n')
  const scopes = []
  let blockScalarIndent = null

  for (let index = 0; index < lines.length; index += 1) {
    let line = lines[index]
    if (!line.trim() || line.trim().startsWith('#')) continue

    const indent = line.match(/^ */)[0].length
    if (blockScalarIndent !== null) {
      if (indent > blockScalarIndent) continue
      blockScalarIndent = null
    }

    // Every dash opens a fresh mapping, so `- name:` twice in a list is fine.
    let restartsScope = false
    let dash = sequenceDash.exec(line)
    while (dash) {
      restartsScope = true
      line = ' '.repeat(dash[0].length) + line.slice(dash[0].length)
      dash = sequenceDash.exec(line)
    }
    if (emptySequenceDash.test(line)) continue

    const matched = mappingKey.exec(line)
    if (!matched) {
      if (blockScalarHeader.test(line)) blockScalarIndent = indent
      continue
    }

    const keyIndent = matched[1].length
    const key = matched[2].trim()

    while (scopes.length && scopes[scopes.length - 1].indent > keyIndent) scopes.pop()
    if (restartsScope) {
      while (scopes.length && scopes[scopes.length - 1].indent >= keyIndent) scopes.pop()
      scopes.push({ indent: keyIndent, seen: new Map() })
    } else if (!scopes.length || scopes[scopes.length - 1].indent < keyIndent) {
      scopes.push({ indent: keyIndent, seen: new Map() })
    }

    const scope = scopes[scopes.length - 1]
    if (scope.seen.has(key)) {
      duplicates.push({ key, line: index + 1, firstSeen: scope.seen.get(key) })
    } else {
      scope.seen.set(key, index + 1)
    }

    if (blockScalarHeader.test(line)) blockScalarIndent = keyIndent
  }

  return duplicates
}

test('every workflow file is free of duplicate mapping keys', () => {
  const files = fs
    .readdirSync(workflowDirectory)
    .filter((name) => name.endsWith('.yml') || name.endsWith('.yaml'))
    .sort()

  assert.ok(files.length > 0, 'expected at least one workflow file to scan')

  const failures = []
  for (const name of files) {
    const source = fs.readFileSync(path.join(workflowDirectory, name), 'utf8')
    for (const duplicate of duplicateKeys(source)) {
      failures.push(
        `${name}:${duplicate.line} repeats "${duplicate.key}" first seen on line ${duplicate.firstSeen}`
      )
    }
  }

  assert.deepEqual(failures, [], `duplicate workflow keys:\n${failures.join('\n')}`)
})

test('the scan catches the stray key shape that broke the release candidate', () => {
  const stray = [
    'jobs:',
    '  companion:',
    '    runs-on: macos-15',
    '    env:',
    '    env:',
    '      DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer',
    '',
  ].join('\n')

  const found = duplicateKeys(stray)
  assert.equal(found.length, 1)
  assert.equal(found[0].key, 'env')
  assert.equal(found[0].line, 5)
  assert.equal(found[0].firstSeen, 4)
})

test('repetition that YAML actually permits is not reported', () => {
  // Repeated keys across sibling list items, across sibling jobs, and inside a
  // block scalar are all legal, and a scan that flagged them would be worse
  // than no scan at all.
  const legal = [
    'jobs:',
    '  first:',
    '    runs-on: macos-15',
    '    steps:',
    '      - name: checkout',
    '        run: git status',
    '      - name: build',
    '        run: |',
    '          echo name: build',
    '          echo name: build',
    '  second:',
    '    runs-on: macos-15',
    '    steps:',
    '      - name: checkout',
    '',
  ].join('\n')

  assert.deepEqual(duplicateKeys(legal), [])
})
