const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { test } = require('node:test')

const root = path.resolve(__dirname, '../..')

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8')
}

test('terminal palette preview is one labelled accessibility element', () => {
  const source = read(
    'native/KaisolaMac/Kaisola/Features/Settings/SettingsView.swift',
  )
  const start = source.indexOf('struct TerminalPalettePreview: View')
  const end = source.indexOf('\nenum SensitiveGlobPolicy', start)
  assert.notEqual(start, -1)
  assert.notEqual(end, -1)
  const preview = source.slice(start, end)

  assert.match(preview, /\.accessibilityElement\(children: \.ignore\)/u)
  assert.match(preview, /\.accessibilityLabel\(accessibility\.label\)/u)
  assert.match(
    preview,
    /\.accessibilityIdentifier\(TerminalPalettePreviewAccessibility\.identifier\)/u,
  )
  assert.doesNotMatch(preview, /\.accessibilityHidden\(true\)/u)
  assert.equal(
    preview.match(/\.accessibilityElement\(children: \.ignore\)/gu)?.length,
    1,
  )
})

test('terminal palette summary names the theme and every represented role', () => {
  const source = read(
    'native/KaisolaMac/Kaisola/Features/Settings/SettingsView.swift',
  )
  for (const phrase of [
    'Terminal palette preview',
    'themeTitle',
    'Foreground text',
    'Background',
    'Cursor',
    'ANSI green',
    'ANSI blue',
  ]) {
    assert.ok(source.includes(phrase), `missing accessibility role: ${phrase}`)
  }
  assert.match(source, /Text\("~\/Kaisola"\)/u)
  assert.match(source, /Text\("%"\)/u)
  assert.match(source, /Text\("codex"\)/u)
})

test('optimized Settings fixture gates the external terminal palette AX tree', () => {
  const gate = read('scripts/native-visual-ax-gate.swift')
  const workflow = read('.github/workflows/native-visual.yml')

  assert.match(gate, /settings\.terminal\.palette-preview/u)
  assert.match(gate, /wrong-terminal-palette-count/u)
  assert.match(gate, /preview\.childCount == 0/u)
  assert.match(gate, /KAISOLA_NATIVE_TERMINAL_PALETTE_AX/u)
  assert.match(workflow, /verify_terminal_palette_ax_receipt/u)
  assert.match(
    workflow,
    /terminalPaletteIdentifierCount !== 1[\s\S]*terminalPaletteChildCount !== 0/u,
  )
})
