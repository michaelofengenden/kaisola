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
