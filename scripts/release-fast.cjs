const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')

function command(program, args, { capture = false, allowFailure = false } = {}) {
  const result = spawnSync(program, args, {
    cwd: root,
    encoding: capture ? 'utf8' : undefined,
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
  })
  if (result.error) throw result.error
  if (!allowFailure && result.status !== 0) process.exit(result.status ?? 1)
  return result
}

function output(program, args) {
  return command(program, args, { capture: true }).stdout.trim()
}

function fail(message) {
  console.error(`release-fast: ${message}`)
  process.exit(1)
}

const requested = process.argv[2]?.replace(/^v/, '')
if (!requested || !/^\d+\.\d+\.\d+$/.test(requested)) {
  fail('usage: npm run release:fast -- <version> [commit message]')
}

const tag = `v${requested}`
const message = process.argv.slice(3).join(' ') || `Release ${tag}`
if (output('git', ['branch', '--show-current']) !== 'main') fail('releases must be cut from main')

// Existing tracked edits must already be staged. This keeps the release
// boundary explicit and never sweeps unrelated untracked files into a commit.
if (command('git', ['diff', '--quiet'], { allowFailure: true }).status !== 0) {
  fail('stage the intended tracked changes before releasing')
}
command('git', ['fetch', '--quiet', '--tags', 'origin'])
if (command('git', ['show-ref', '--verify', '--quiet', `refs/tags/${tag}`], { allowFailure: true }).status === 0) {
  fail(`tag ${tag} already exists`)
}
if (Number(output('git', ['rev-list', '--count', 'HEAD..origin/main'])) > 0) {
  fail('local main is behind origin/main; update it before releasing')
}

const packagePath = path.join(root, 'package.json')
const current = JSON.parse(fs.readFileSync(packagePath, 'utf8')).version
if (current === requested) fail(`package.json is already at ${requested}`)
const requestedParts = requested.split('.').map(Number)
const currentParts = current.split('.').map(Number)
const isNewer = requestedParts.some((part, index) => (
  part > currentParts[index] && requestedParts.slice(0, index).every((value, prior) => value === currentParts[prior])
))
if (!isNewer) fail(`${requested} must be newer than package version ${current}`)

command('npm', ['version', requested, '--no-git-tag-version', '--ignore-scripts'])
command('git', ['add', 'package.json', 'package-lock.json'])
if (command('git', ['diff', '--cached', '--quiet'], { allowFailure: true }).status === 0) {
  fail('there is nothing staged to release')
}

command('git', ['commit', '-m', message])
command('git', ['tag', '-a', tag, '-m', `Kaisola ${tag}`])

// One network round trip, and the server accepts the commit and tag together.
// This also prevents a tag-triggered release from seeing only half the push.
command('git', ['push', '--atomic', 'origin', 'HEAD:refs/heads/main', `refs/tags/${tag}`])

console.log(`Release ${tag} started: https://github.com/michaelofengenden/kaisola/actions/workflows/release.yml`)
