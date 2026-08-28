const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const root = path.resolve(__dirname, '..', '..')

test('account recovery visual QA covers both appearances and accessibility text', () => {
  const workflow = fs.readFileSync(
    path.join(root, '.github', 'workflows', 'native-visual.yml'),
    'utf8'
  )

  // Membership in the dark loop, not position within it: the trailing `; do`
  // anchor made this fail the moment any surface was appended after account
  // recovery, which says nothing about the coverage being asserted.
  assert.match(
    workflow,
    /for surface in [^\n]*\bsettings-account-recovery\b[^\n]*; do\n\s*capture="\$output\/dark-\$surface\.png"/
  )
  assert.match(workflow, /large-text-settings-account-recovery\.png/)
  assert.match(workflow, /KAISOLA_NATIVE_VISUAL_LARGE_TEXT=1/)
  assert.match(
    workflow,
    /PASS largeText=true verticalAction=true unclampedHeadline=true/
  )
})

test('the fixture applies accessibility dynamic type before asserting layout', () => {
  const delegate = fs.readFileSync(
    path.join(
      root,
      'native',
      'KaisolaMac',
      'Kaisola',
      'App',
      'KaisolaMacAppDelegate.swift'
    ),
    'utf8'
  )

  assert.match(delegate, /visualLargeText \? \.accessibility1 : \.large/)
  assert.match(delegate, /AppAccountRecoveryLayout\.resolve/)
  assert.match(delegate, /KAISOLA_NATIVE_ACCOUNT_RECOVERY_LAYOUT=PASS/)
})
