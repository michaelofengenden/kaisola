const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { test } = require('node:test')

const root = path.resolve(__dirname, '../..')

test('workspace action sheets receive a private deterministic tree before launch', () => {
  const workflow = fs.readFileSync(
    path.join(root, '.github', 'workflows', 'native-visual.yml'),
    'utf8',
  )
  const runFixtureStart = workflow.indexOf('          run_fixture() {')
  const runFixtureEnd = workflow.indexOf('\n          verify_extensions_receipt()', runFixtureStart)
  assert.notEqual(runFixtureStart, -1)
  assert.notEqual(runFixtureEnd, -1)
  const runFixture = workflow.slice(runFixtureStart, runFixtureEnd)

  const seedStart = runFixture.indexOf('            # File-action sheets need')
  const launchStart = runFixture.indexOf("            if [[ \"$surface\" == settings-extensions")
  assert.notEqual(seedStart, -1, 'missing private workspace sheet seed')
  assert.notEqual(launchStart, -1, 'missing fixture launch boundary')
  assert.ok(seedStart < launchStart, 'the workspace must be seeded before the app launches')

  const seed = runFixture.slice(seedStart, launchStart)
  assert.match(
    seed,
    /if \[\[ "\$surface" == workspace-rename \|\| "\$surface" == workspace-new-file\n\s+\|\| "\$surface" == workspace-move \]\]; then/u,
  )
  assert.doesNotMatch(seed, /empty-workspace/u)
  assert.doesNotMatch(seed, /GITHUB_WORKSPACE/u)
  assert.match(seed, /mkdir -p \\\n\s+"\$profile\/workspace\/A Source" \\\n\s+"\$profile\/workspace\/B Destination"/u)
  assert.match(seed, /test -d "\$profile\/workspace\/A Source"/u)
  assert.match(seed, /test -d "\$profile\/workspace\/B Destination"/u)
})
