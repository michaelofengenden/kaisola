const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { test } = require('node:test')

const source = fs.readFileSync(
  path.resolve(
    __dirname,
    '../../native/KaisolaMac/Kaisola/Features/Settings/SettingsView.swift',
  ),
  'utf8',
)

test('sensitive glob validation belongs to its input accessibility element', () => {
  const start = source.indexOf('TextField("Add glob')
  const end = source.indexOf('Button("Add"', start)
  assert.notEqual(start, -1)
  assert.notEqual(end, -1)
  const field = source.slice(start, end)

  assert.match(field, /\.accessibilityLabel\("Sensitive file pattern"\)/u)
  assert.match(field, /\.accessibilityValue\(newGlobAccessibility\.value\)/u)
  assert.match(field, /\.accessibilityHint\(newGlobAccessibility\.description\)/u)
  assert.match(
    field,
    /\.accessibilityIdentifier\(SensitiveGlobFieldAccessibility\.identifier\)/u,
  )
})

test('validation announcements are transition-deduplicated and noninterrupting', () => {
  assert.match(
    source,
    /\.onChange\(of: newGlobIssue\) \{ previous, current in[\s\S]*announceValidationChange/u,
  )
  assert.match(source, /guard previous != current else \{ return nil \}/u)
  assert.match(source, /NSAccessibilityPriorityLevel\.low\.rawValue/u)
  assert.match(source, /notification: \.announcementRequested/u)
})

test('visible validation copy is not duplicated as a separate accessibility element', () => {
  const start = source.indexOf('if let issue = newGlobIssue')
  const end = source.indexOf('Button("Restore Defaults")', start)
  assert.notEqual(start, -1)
  assert.notEqual(end, -1)
  assert.match(source.slice(start, end), /\.accessibilityHidden\(true\)/u)
})
