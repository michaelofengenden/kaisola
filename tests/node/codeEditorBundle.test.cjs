'use strict'

const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '../..')
const resourceRoot = path.join(
  repoRoot,
  'native/KaisolaMac/Kaisola/Resources/CodeEditor',
)
const checkedBundle = path.join(resourceRoot, 'editor.bundle.js')

function digest(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

test('CodeMirror bundle is reproducible from exact pinned packages', () => {
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-code-editor-'))
  const output = path.join(temporaryRoot, 'editor.bundle.js')
  try {
    const result = spawnSync(
      process.execPath,
      [
        path.join(repoRoot, 'node_modules/rollup/dist/bin/rollup'),
        '--config',
        path.join(repoRoot, 'scripts/code-editor/rollup.config.mjs'),
      ],
      {
        cwd: repoRoot,
        encoding: 'utf8',
        env: { ...process.env, KAISOLA_CODE_EDITOR_OUTPUT: output },
      },
    )
    assert.equal(result.status, 0, result.stderr || result.stdout)
    assert.equal(digest(output), digest(checkedBundle))
  } finally {
    fs.rmSync(temporaryRoot, { recursive: true, force: true })
  }
})

test('editor document denies network, frames, workers, forms, and arbitrary assets', () => {
  const html = fs.readFileSync(path.join(resourceRoot, 'index.html'), 'utf8')
  assert.match(html, /default-src 'none'/u)
  assert.match(html, /script-src 'self'/u)
  assert.match(html, /connect-src 'none'/u)
  assert.match(html, /frame-src 'none'/u)
  assert.match(html, /worker-src 'none'/u)
  assert.match(html, /form-action 'none'/u)
  assert.match(html, /base-uri 'none'/u)
  assert.deepEqual(
    [...html.matchAll(/<script\b[^>]*src="([^"]+)"[^>]*><\/script>/gu)].map((match) => match[1]),
    ['editor.bundle.js'],
  )
  assert.equal(/<script\b(?![^>]*\bsrc=)[^>]*>/u.test(html), false)
})

test('editor package versions and runtime bridge stay explicit', () => {
  const packageJSON = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))
  const editorDependencies = Object.entries(packageJSON.devDependencies)
    .filter(([name]) => name.startsWith('@codemirror/')
      || name.startsWith('@lezer/')
      || name === 'rollup'
      || name.startsWith('@rollup/'))
  assert.ok(editorDependencies.length >= 10)
  for (const [name, version] of editorDependencies) {
    assert.match(version, /^\d+\.\d+\.\d+$/u, `${name} must be exact`)
  }

  const bundle = fs.readFileSync(checkedBundle, 'utf8')
  assert.ok(bundle.length > 100_000)
  assert.match(bundle, /kaisolaEditor/u)
  assert.doesNotMatch(bundle, /sourceMappingURL/u)
  for (const networkPrimitive of [
    'fetch(', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'navigator.sendBeacon',
  ]) {
    assert.equal(bundle.includes(networkPrimitive), false, networkPrimitive)
  }

  const source = fs.readFileSync(path.join(repoRoot, 'scripts/code-editor/editor.mjs'), 'utf8')
  assert.match(source, /EditorState\.lineSeparator\.of/u)
  assert.match(source, /inserted\.sliceString/u)
  assert.match(source, /function serializedOffset/u)
  assert.doesNotMatch(source, /\.doc\.toString\(\)/u)
})
