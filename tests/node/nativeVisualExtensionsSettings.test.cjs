const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { test } = require('node:test')

const root = path.resolve(__dirname, '../..')

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8')
}

test('wide Extensions visual receipt accepts exactly 1000 points on both gates', () => {
  const delegate = read(
    'native/KaisolaMac/Kaisola/App/KaisolaMacAppDelegate.swift',
  )
  const workflow = read('.github/workflows/native-visual.yml')

  assert.match(delegate, /guard contentWidth >= 1_000 else/u)
  assert.doesNotMatch(delegate, /guard contentWidth >= 1_050 else/u)
  assert.match(
    workflow,
    /receipt\.surface === "settings-extensions" && receipt\.contentWidth < 1000/u,
  )
  assert.doesNotMatch(workflow, /receipt\.contentWidth < 1050/u)
})

test('compact Extensions AX gate validates mounted rows without requiring offscreen catalog rows', () => {
  const gate = read('scripts/native-visual-ax-gate.swift')
  const workflow = read('.github/workflows/native-visual.yml')
  const failureStart = gate.indexOf('private func failure(')
  const surfaceSwitch = gate.indexOf('    switch surface {', failureStart)
  const sharedChecks = gate.slice(failureStart, surfaceSwitch)
  const narrowStart = gate.indexOf('    case "settings-extensions-narrow":', surfaceSwitch)
  const narrowEnd = gate.indexOf('    default:', narrowStart)
  const narrowChecks = gate.slice(narrowStart, narrowEnd)

  assert.ok(failureStart >= 0 && surfaceSwitch > failureStart)
  assert.ok(narrowStart > surfaceSwitch && narrowEnd > narrowStart)
  assert.doesNotMatch(sharedChecks, /for title in categoryTitles/u)
  assert.doesNotMatch(sharedChecks, /for identifier in itemIdentifiers/u)
  assert.doesNotMatch(sharedChecks, /missing-validation-identifier/u)
  assert.match(narrowChecks, /missing-enabled-compact-category-picker/u)
  assert.match(narrowChecks, /wide-category-rail-visible-in-narrow-layout/u)
  assert.match(narrowChecks, /missing-mounted-compact-category/u)
  assert.match(narrowChecks, /missing-mounted-compact-item/u)

  assert.match(
    workflow,
    /wide && \(receipt\.categoryLabels\.length !== 5[\s\S]*?receipt\.itemIdentifierCount !== 5/u,
  )
  assert.match(
    workflow,
    /!wide && \(receipt\.categoryLabels\.length < 1[\s\S]*?receipt\.itemIdentifierCount < 1/u,
  )
  assert.match(
    workflow,
    /wide && \([\s\S]*?!receipt\.validationIdentifierPresent[\s\S]*?categoryNavigationRoles/u,
  )
})
