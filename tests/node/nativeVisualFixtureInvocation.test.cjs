const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { test } = require('node:test')

const root = path.resolve(__dirname, '../..')

test('non-Retina visual fixtures pass a writable log before the command', () => {
  const workflow = fs.readFileSync(
    path.join(root, '.github/workflows/native-visual.yml'),
    'utf8',
  )
  const start = workflow.indexOf(
    '          for surface in settings-minimum settings-ideal; do',
  )
  const end = workflow.indexOf('          done', start)
  const loop = workflow.slice(start, end)

  assert.ok(start >= 0 && end > start)
  assert.match(loop, /log="\$output\/nonretina-\$surface\.log"/u)
  assert.match(
    loop,
    /run_fixture "\$surface" "\$capture" "\$log" \\\n+\s+\/usr\/bin\/env KAISOLA_NATIVE_VISUAL_SCALE=1 "\$binary"/u,
  )
})

test('every visual fixture call passes a log argument before its command', () => {
  const workflow = fs.readFileSync(
    path.join(root, '.github/workflows/native-visual.yml'),
    'utf8',
  )
  const invocations = workflow
    .split(/\r?\n/u)
    .filter((line) => line.trimStart().startsWith('run_fixture '))

  assert.equal(invocations.length, 6)
  for (const invocation of invocations) {
    assert.match(
      invocation,
      /^\s*run_fixture\s+(?:"[^"]+"|\S+)\s+"?\$[A-Za-z_][A-Za-z0-9_]*"?\s+"?\$[A-Za-z_][A-Za-z0-9_]*"?(?:\s|$)/u,
    )
  }
})
