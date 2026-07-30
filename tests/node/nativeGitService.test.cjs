'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')
const {
  DIFF_MAX_BYTES,
  commit,
  diff,
  log,
  stage,
  status,
  unstage,
} = require('../../scripts/native-git-service.cjs')

const script = path.join(__dirname, '..', '..', 'scripts', 'native-git-service.cjs')

function runGit(root, arguments_) {
  const result = spawnSync('git', arguments_, {
    cwd: root,
    encoding: 'utf8',
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0', LANG: 'C', LC_ALL: 'C' },
  })
  assert.equal(result.status, 0, result.stderr || result.stdout)
  return result.stdout.trim()
}

function write(root, file, contents) {
  const target = path.join(root, file)
  fs.mkdirSync(path.dirname(target), { recursive: true })
  fs.writeFileSync(target, contents)
}

function fixture(t, files = { 'tracked.txt': 'alpha\nbeta\n' }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-git-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  runGit(root, ['init', '--quiet', '--initial-branch=main'])
  runGit(root, ['config', 'user.name', 'Native Git Test'])
  runGit(root, ['config', 'user.email', 'native-git@example.test'])
  runGit(root, ['config', 'commit.gpgSign', 'false'])
  runGit(root, ['config', 'core.hooksPath', '/dev/null'])
  for (const [file, contents] of Object.entries(files)) write(root, file, contents)
  runGit(root, ['add', '--all'])
  runGit(root, ['commit', '--quiet', '-m', 'initial commit'])
  return root
}

test('status parses branch plus staged, unstaged, and untracked entries', (t) => {
  const root = fixture(t)
  fs.appendFileSync(path.join(root, 'tracked.txt'), 'unstaged line\n')
  write(root, 'staged file.txt', 'staged line\n')
  runGit(root, ['add', '--', 'staged file.txt'])
  write(root, 'untracked file.txt', 'untracked line\n')

  assert.deepEqual(status(root), {
    ok: true,
    branch: 'main',
    ahead: 0,
    behind: 0,
    staged: [{ path: 'staged file.txt', status: 'A' }],
    unstaged: [{ path: 'tracked.txt', status: 'M' }],
    untracked: ['untracked file.txt'],
  })
})

test('status parses porcelain v2 rename records using the destination path', (t) => {
  const root = fixture(t, {
    'old name.txt': 'rename content stays byte-identical\n',
    'tracked.txt': 'base\n',
  })
  runGit(root, ['mv', 'old name.txt', 'renamed file.txt'])

  const result = status(root)
  assert.equal(result.ok, true)
  assert.deepEqual(result.staged, [{ path: 'renamed file.txt', status: 'R' }])
  assert.deepEqual(result.unstaged, [])
})

test('diff returns bounded unified hunks for unstaged and staged content', (t) => {
  const root = fixture(t)
  write(root, 'tracked.txt', 'alpha\nchanged beta\n')

  const unstaged = diff(root, 'tracked.txt')
  assert.equal(unstaged.ok, true)
  assert.equal(unstaged.truncated, false)
  assert.match(unstaged.diff, /^diff --git a\/tracked\.txt b\/tracked\.txt/m)
  assert.match(unstaged.diff, /^-beta$/m)
  assert.match(unstaged.diff, /^\+changed beta$/m)

  assert.deepEqual(stage(root, 'tracked.txt'), { ok: true })
  const staged = diff(root, 'tracked.txt', { staged: true })
  assert.equal(staged.ok, true)
  assert.match(staged.diff, /^\+changed beta$/m)
})

test('diff marks and bounds output that exceeds the service limit', (t) => {
  const original = `${'a'.repeat(700_000)}\n`
  const root = fixture(t, { 'large.txt': original })
  write(root, 'large.txt', `${'b'.repeat(700_000)}\n`)

  const result = diff(root, 'large.txt')
  assert.equal(result.ok, true)
  assert.equal(result.truncated, true)
  assert.match(result.diff, /\[diff truncated at 1048576 bytes\]\n$/)
  assert.ok(Buffer.byteLength(result.diff) <= DIFF_MAX_BYTES)
})

test('stage and unstage move a modified file between worktree sections', (t) => {
  const root = fixture(t)
  fs.appendFileSync(path.join(root, 'tracked.txt'), 'change\n')
  assert.deepEqual(status(root).unstaged, [{ path: 'tracked.txt', status: 'M' }])

  assert.deepEqual(stage(root, 'tracked.txt'), { ok: true })
  assert.deepEqual(status(root).staged, [{ path: 'tracked.txt', status: 'M' }])
  assert.deepEqual(status(root).unstaged, [])

  assert.deepEqual(unstage(root, 'tracked.txt'), { ok: true })
  assert.deepEqual(status(root).staged, [])
  assert.deepEqual(status(root).unstaged, [{ path: 'tracked.txt', status: 'M' }])
})

test('commit returns the new hash and clears a staged change', (t) => {
  const root = fixture(t)
  write(root, 'committed.txt', 'ready\n')
  assert.deepEqual(stage(root, 'committed.txt'), { ok: true })

  const result = commit(root, 'native service commit')
  assert.equal(result.ok, true)
  assert.match(result.hash, /^[0-9a-f]{40,64}$/)
  assert.equal(runGit(root, ['rev-parse', 'HEAD']), result.hash)
  assert.deepEqual(status(root), {
    ok: true,
    branch: 'main',
    ahead: 0,
    behind: 0,
    staged: [],
    unstaged: [],
    untracked: [],
  })
})

test('commit returns ok false when nothing is staged', (t) => {
  const root = fixture(t)
  const result = commit(root, 'should not exist')
  assert.equal(result.ok, false)
  assert.match(result.reason, /nothing staged/i)
})

test('log returns structured commit metadata up to the requested limit', (t) => {
  const root = fixture(t)
  const entries = log(root, { limit: 1 })
  assert.equal(entries.length, 1)
  assert.match(entries[0].hash, /^[0-9a-f]{40,64}$/)
  assert.equal(entries[0].shortHash, entries[0].hash.slice(0, entries[0].shortHash.length))
  assert.equal(entries[0].author, 'Native Git Test')
  assert.match(entries[0].date, /^\d{4}-\d{2}-\d{2}T/)
  assert.equal(entries[0].subject, 'initial commit')
})

test('a non-repository path returns a structured failure', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-git-nonrepo-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const result = status(root)
  assert.equal(result.ok, false)
  assert.match(result.reason, /not a git repository/i)
})

test('path traversal outside the repository root is rejected', (t) => {
  const root = fixture(t)
  const result = stage(root, '../outside.txt')
  assert.equal(result.ok, false)
  assert.match(result.reason, /escapes the repository root/i)
})

test('CLI emits the exact status JSON shape with an explicit repository root', (t) => {
  const root = fixture(t)
  const result = spawnSync(process.execPath, [script, 'status', '--repo', root, '--json'], {
    encoding: 'utf8',
    env: process.env,
  })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), {
    ok: true,
    branch: 'main',
    ahead: 0,
    behind: 0,
    staged: [],
    unstaged: [],
    untracked: [],
  })
})
