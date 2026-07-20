'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = require('typescript')

function loadPairingQrModule() {
  const filename = path.join(__dirname, '..', '..', 'src', 'lib', 'pairingQr.ts')
  const source = fs.readFileSync(filename, 'utf8')
  const output = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022,
      esModuleInterop: true,
    },
    fileName: filename,
    reportDiagnostics: true,
  })
  assert.deepEqual((output.diagnostics ?? []).filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error), [])
  const module = { exports: {} }
  Function('require', 'module', 'exports', output.outputText)(require, module, module.exports)
  return module.exports
}

const { createPairingQrGraphic } = loadPairingQrModule()

test('pairing QR graphic is a real deterministic matrix with an encoded quiet zone', () => {
  const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'crypto-noise-xx-v1.json'), 'utf8'))
  const payload = JSON.stringify(fixture.qrPayload)
  const first = createPairingQrGraphic(payload)
  const second = createPairingQrGraphic(payload)
  const changed = createPairingQrGraphic(`${payload}x`)

  assert.ok(first.size >= 29)
  assert.equal((first.size - 8 - 21) % 4, 0)
  assert.match(first.path, /^M\d+ \d+h\d+v1H\d+z/)
  assert.deepEqual(first, second)
  assert.notEqual(first.path, changed.path)
})

test('pairing QR graphic rejects an empty payload instead of drawing a fake code', () => {
  assert.throws(() => createPairingQrGraphic(''), /empty/i)
})
