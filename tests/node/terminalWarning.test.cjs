'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const manager = require('../../runtime/node-broker/ipc/terminalManager.cjs')
const {
  escapeTerminalText,
  missingCwdWarning,
} = require('../../runtime/node-broker/ipc/terminalText.cjs')

test('ordinary readable paths remain unchanged in terminal warnings', () => {
  // ZWJ emoji and the Persian ZWNJ are intentional readable path content, not
  // terminal or bidi controls, and must not be hidden by over-broad escaping.
  const cwd = '/Users/Michael/Projects/Café notes/👩‍💻/می‌رود/📁-draft'

  assert.equal(escapeTerminalText(cwd), cwd)
  assert.equal(
    missingCwdWarning(cwd, '/Users/Michael'),
    `\r\n\x1b[33m⚠ working directory not found:\x1b[0m ${cwd}\r\n` +
      '\x1b[33m  started in /Users/Michael instead — this session is NOT isolated.\x1b[0m\r\n\r\n',
  )
})

test('terminal controls, bidi controls, and line separators use visible deterministic escapes', async (t) => {
  const fixtures = [
    {
      name: 'ESC and BEL',
      input: '/tmp/link\x1b]8;;https://attacker.example\x07label\x1b]8;;\x07',
      output: '/tmp/link\\u{001B}]8;;https://attacker.example\\u{0007}label\\u{001B}]8;;\\u{0007}',
    },
    {
      name: 'CR LF and embedded newline',
      input: '/tmp/first\rforged\nsecond',
      output: '/tmp/first\\u{000D}forged\\u{000A}second',
    },
    {
      name: 'C0 DEL and C1 CSI',
      input: '/tmp/nul\x00tab\x09back\x08del\x7fcsi\x9b31m',
      output: '/tmp/nul\\u{0000}tab\\u{0009}back\\u{0008}del\\u{007F}csi\\u{009B}31m',
    },
    {
      name: 'bidi and invisible format controls',
      input: '/tmp/arabic\u061c/lrm\u200e/rlm\u200f/override\u202eexe/isolates\u2066name\u2069/bom\ufeff',
      output: '/tmp/arabic\\u{061C}/lrm\\u{200E}/rlm\\u{200F}/override\\u{202E}exe/isolates\\u{2066}name\\u{2069}/bom\\u{FEFF}',
    },
    {
      name: 'Unicode line and paragraph separators',
      input: '/tmp/line\u2028paragraph\u2029end',
      output: '/tmp/line\\u{2028}paragraph\\u{2029}end',
    },
  ]

  for (const fixture of fixtures) {
    await t.test(fixture.name, () => {
      const escaped = escapeTerminalText(fixture.input)
      assert.equal(escaped, fixture.output)
      assert.doesNotMatch(escaped, /[\p{Cc}\p{Zl}\p{Zp}\u061c\u200e\u200f\u202a-\u202e\u2066-\u206f\ufeff]/u)
    })
  }
})

test('the missing-cwd warning conveys the escaped hostile path without adding terminal commands', () => {
  const cwd = '/tmp/gone\x1b[2J\x07\rforged\nreport\u202eexe'
  const safeCwd = '/tmp/gone\\u{001B}[2J\\u{0007}\\u{000D}forged\\u{000A}report\\u{202E}exe'

  const warning = missingCwdWarning(cwd, '/safe/home')

  assert.equal(
    warning,
    `\r\n\x1b[33m⚠ working directory not found:\x1b[0m ${safeCwd}\r\n` +
      '\x1b[33m  started in /safe/home instead — this session is NOT isolated.\x1b[0m\r\n\r\n',
  )
  assert.equal((warning.match(/\x1b/g) || []).length, 4, 'only the four trusted color escapes remain')
  assert.ok(warning.includes(safeCwd), 'the requested path stays visible in escaped form')
})

test('terminal spawn seeds only the escaped missing cwd into its warning snapshot', async (t) => {
  const storage = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-warning-'))
  const id = 'escaped-missing-cwd-warning'
  const cwd = path.join(storage, 'gone\x1b[2J\x07\rforged\nreport\u202eexe')
  const safeCwd = escapeTerminalText(cwd)
  manager.configureStorage(storage)
  t.after(() => {
    manager.release(id)
    fs.rmSync(storage, { recursive: true, force: true })
  })

  manager.spawn({
    id,
    command: '/bin/sh',
    args: ['-c', 'exit 0'],
    cwd,
  })
  await manager.waitForExit(id)

  const output = manager.snapshot(id).output
  assert.ok(output.includes(safeCwd))
  assert.equal((output.match(/\x1b/g) || []).length, 4, 'only the warning color escapes reach the pty snapshot')
  assert.doesNotMatch(output, /\x1b\[2J|\x07|\u202e/)
})
